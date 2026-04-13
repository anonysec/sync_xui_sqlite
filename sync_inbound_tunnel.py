#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
WinNet - Inbound Tunnel Sync
Syncs traffic (up/down/total) and expiry_time across inbounds
that share the same remark and have protocol 'tunnel' or 'tun'.
"""
from __future__ import annotations
import sqlite3, json, argparse, os, time, shutil, subprocess
from datetime import datetime

DB_DEFAULT = "/etc/x-ui/x-ui.db"
TUNNEL_PROTOCOLS = ("tunnel", "tun")

def jload(s):
    if isinstance(s, dict): return s
    try: return json.loads(s)
    except: return {}

def jdump(o):
    return json.dumps(o, ensure_ascii=False, separators=(",", ":"))

def restart_xui():
    """Restart x-ui core immediately"""
    try:
        subprocess.run(["x-ui", "restart"], capture_output=True)
        print(f"[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] [INFO] x-ui core restarted due to tunnel expiration.")
    except Exception as e:
        print(f"[ERROR] Failed to restart x-ui: {e}")

def check_tunnel_expiry_and_disable(conn, debug=False):
    """Check for expired tunnel inbounds (traffic or time) every 10s and disable them"""
    now_ms = int(time.time() * 1000)
    cur = conn.cursor()
    placeholders = ",".join("?" for _ in TUNNEL_PROTOCOLS)
    
    # Select enabled tunnel inbounds
    cur.execute(f"""
        SELECT id, remark, up, down, total, expiry_time 
        FROM inbounds 
        WHERE enable = 1 AND LOWER(protocol) IN ({placeholders})
    """, [p.lower() for p in TUNNEL_PROTOCOLS])
    rows = cur.fetchall()
    
    deactivated_count = 0
    for iid, remark, up, down, total, expiry in rows:
        is_expired = False
        # Traffic check
        if total > 0 and (up + down) >= total:
            is_expired = True
        # Expiry check
        if expiry > 0 and now_ms >= expiry:
            is_expired = True
            
        if is_expired:
            if debug: print(f"[EXPIRY] Disabling tunnel inbound {remark} (ID {iid}) due to expiration.")
            cur.execute("UPDATE inbounds SET enable = 0 WHERE id = ?", (iid,))
            deactivated_count += 1
            
    if deactivated_count > 0:
        conn.commit()
        print(f"[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] [EXPIRY] Deactivated {deactivated_count} expired tunnel inbound(s).")
        restart_xui()
        return True
    return False

def ensure_meta(conn):
    c = conn.cursor()
    c.execute("""
    CREATE TABLE IF NOT EXISTS sync_meta_inbound_tunnel(
      key TEXT PRIMARY KEY,
      remark TEXT,
      protocol TEXT,
      inbound_id INTEGER,
      up INTEGER DEFAULT 0,
      down INTEGER DEFAULT 0,
      total INTEGER DEFAULT 0,
      expiry_time INTEGER DEFAULT 0,
      last_change INTEGER DEFAULT 0
    )""")
    conn.commit()

def meta_key(remark, protocol, iid):
    return f"{remark}|{protocol}|{iid}"

def load_tunnel_inbounds(conn):
    """Load all inbounds with tunnel/tun protocol"""
    cur = conn.cursor()
    placeholders = ",".join("?" for _ in TUNNEL_PROTOCOLS)
    cur.execute(f"""
        SELECT id, remark, protocol, up, down, total, expiry_time
        FROM inbounds
        WHERE LOWER(protocol) IN ({placeholders})
    """, [p.lower() for p in TUNNEL_PROTOCOLS])
    rows = cur.fetchall()
    out = []
    for iid, remark, protocol, up, down, total, expiry_time in rows:
        out.append({
            "id": int(iid),
            "remark": (remark or "").strip(),
            "protocol": (protocol or "").strip().lower(),
            "up": int(up or 0),
            "down": int(down or 0),
            "total": int(total or 0),
            "expiry_time": int(expiry_time or 0),
        })
    return out

def load_meta_map(conn):
    """Load existing meta data"""
    cur = conn.cursor()
    cur.execute("SELECT key, remark, protocol, inbound_id, up, down, total, expiry_time, last_change FROM sync_meta_inbound_tunnel")
    m = {}
    for key, remark, protocol, iid, up, down, total, expiry_time, lc in cur.fetchall():
        m[key] = {
            "remark": remark,
            "protocol": protocol,
            "inbound_id": int(iid),
            "up": int(up or 0),
            "down": int(down or 0),
            "total": int(total or 0),
            "expiry_time": int(expiry_time or 0),
            "last_change": int(lc or 0),
        }
    return m

def ensure_seed(conn, debug=False):
    """Initialize meta table with current inbound data"""
    ensure_meta(conn)
    now = int(time.time())
    inbounds = load_tunnel_inbounds(conn)
    cur = conn.cursor()
    n = 0
    for inb in inbounds:
        key = meta_key(inb["remark"], inb["protocol"], inb["id"])
        cur.execute("""
            INSERT OR REPLACE INTO sync_meta_inbound_tunnel
            (key, remark, protocol, inbound_id, up, down, total, expiry_time, last_change)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, (key, inb["remark"], inb["protocol"], inb["id"],
              inb["up"], inb["down"], inb["total"], inb["expiry_time"], now))
        n += 1
    conn.commit()
    if debug: print(f"[INFO] Seeded {n} tunnel inbound entries")

def sync_once(conn, apply=False, debug=False):
    """Run one sync cycle"""
    ensure_meta(conn)
    cur = conn.cursor()
    now = int(time.time())

    inbounds = load_tunnel_inbounds(conn)
    meta_map = load_meta_map(conn)

    if not inbounds:
        return 0

    meta_updates = []
    for inb in inbounds:
        key = meta_key(inb["remark"], inb["protocol"], inb["id"])
        old = meta_map.get(key)
        if old is None or (old["up"] != inb["up"] or old["down"] != inb["down"]
                           or old["total"] != inb["total"] or old["expiry_time"] != inb["expiry_time"]):
            meta_updates.append((key, inb["remark"], inb["protocol"], inb["id"],
                                 inb["up"], inb["down"], inb["total"], inb["expiry_time"], now))
            meta_map[key] = {
                "remark": inb["remark"], "protocol": inb["protocol"], "inbound_id": inb["id"],
                "up": inb["up"], "down": inb["down"], "total": inb["total"], "expiry_time": inb["expiry_time"],
                "last_change": now,
            }

    if meta_updates:
        for row in meta_updates:
            cur.execute("""
                INSERT OR REPLACE INTO sync_meta_inbound_tunnel
                (key, remark, protocol, inbound_id, up, down, total, expiry_time, last_change)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, row)
        conn.commit()

    groups = {}
    for inb in inbounds:
        gkey = (inb["remark"], inb["protocol"])
        groups.setdefault(gkey, []).append(inb)

    plans = []
    for (remark, protocol), items in groups.items():
        if len(items) < 2: continue
        max_up = max(i["up"] for i in items)
        max_down = max(i["down"] for i in items)
        items_with_lc = []
        for inb in items:
            key = meta_key(inb["remark"], inb["protocol"], inb["id"])
            lc = meta_map.get(key, {}).get("last_change", 0)
            items_with_lc.append((lc, inb))
        items_with_lc.sort(key=lambda t: t[0], reverse=True)
        ref = items_with_lc[0][1]
        ref_total = ref["total"]
        ref_expiry = ref["expiry_time"]
        ref_used = ref["up"] + ref["down"]
        max_used = max_up + max_down
        is_reset = ref_used < max_used

        target_up = ref["up"] if is_reset else max_up
        target_down = ref["down"] if is_reset else max_down

        for inb in items:
            changes = {}
            if inb["up"] != target_up: changes["up"] = (inb["up"], target_up)
            if inb["down"] != target_down: changes["down"] = (inb["down"], target_down)
            if inb["total"] != ref_total: changes["total"] = (inb["total"], ref_total)
            if inb["expiry_time"] != ref_expiry: changes["expiry_time"] = (inb["expiry_time"], ref_expiry)
            if changes:
                plans.append({"id": inb["id"], "remark": remark, "protocol": protocol, "changes": changes, "target_up": target_up, "target_down": target_down, "target_total": ref_total, "target_expiry": ref_expiry})

    if not plans:
        return 0

    if not apply:
        print(f"[DRY-RUN] {len(plans)} changes planned")
        return len(plans)

    conn.execute("BEGIN")
    writes = 0
    for p in plans:
        cur.execute("UPDATE inbounds SET up = ?, down = ?, total = ?, expiry_time = ? WHERE id = ?", (p["target_up"], p["target_down"], p["target_total"], p["target_expiry"], p["id"]))
        writes += 1
        key = meta_key(p["remark"], p["protocol"], p["id"])
        cur.execute("INSERT OR REPLACE INTO sync_meta_inbound_tunnel(key, remark, protocol, inbound_id, up, down, total, expiry_time, last_change) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)", (key, p["remark"], p["protocol"], p["id"], p["target_up"], p["target_down"], p["target_total"], p["target_expiry"], now))

    conn.commit()
    print(f"[APPLIED] {writes} tunnel inbound(s) updated")
    return len(plans)

def main():
    ap = argparse.ArgumentParser(description="WinNet - Inbound Tunnel Sync")
    ap.add_argument("--db", default=DB_DEFAULT)
    ap.add_argument("--interval", type=int, default=30)
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--backup", action="store_true")
    ap.add_argument("--init", action="store_true")
    ap.add_argument("--debug", action="store_true")
    args = ap.parse_args()

    if not os.path.exists(args.db):
        print("[ERROR] Database not found:", args.db); return

    if args.apply and args.backup:
        ts = datetime.now().strftime("%Y%m%d_%H%M%S")
        shutil.copy2(args.db, f"{args.db}.tunnel_bak_{ts}")

    conn = sqlite3.connect(args.db, timeout=60, check_same_thread=False)
    conn.execute("PRAGMA busy_timeout = 3000")
    try:
        if args.init:
            ensure_seed(conn, debug=args.debug); return
        
        last_sync = 0
        last_expiry_check = 0

        if args.interval <= 0:
            check_tunnel_expiry_and_disable(conn, debug=args.debug)
            sync_once(conn, apply=args.apply, debug=args.debug)
        else:
            print(f"[INFO] Loop interval={args.interval}s, expiry_check=10s, apply={args.apply}")
            while True:
                now = time.time()
                # 1. Independent Expiry Check every 10 seconds
                if now - last_expiry_check >= 10:
                    try:
                        check_tunnel_expiry_and_disable(conn, debug=args.debug)
                    except Exception as e:
                        print(f"[ERROR] expiry check: {e}")
                    last_expiry_check = now
                
                # 2. Sync Check every interval
                if now - last_sync >= args.interval:
                    try:
                        sync_once(conn, apply=args.apply, debug=args.debug)
                    except Exception as e:
                        print(f"[ERROR] iteration: {e}")
                    last_sync = now
                
                time.sleep(1)
    finally:
        conn.close()

if __name__ == "__main__":
    main()
