#!/bin/bash
# ============================================
#  WinNet - Enforce Expiry
#  Disables expired clients in all inbounds
#  and restarts xray core if traffic expired
#  Requires: sqlite3
# ============================================

DB_PATH="/etc/x-ui/x-ui.db"
INTERVAL=60
LOG_PREFIX="[enforce_expiry]"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $LOG_PREFIX $1"; }

if ! command -v sqlite3 &>/dev/null; then
    log "ERROR: sqlite3 not found. Install with: apt install -y sqlite3"
    exit 1
fi

if [ ! -f "$DB_PATH" ]; then
    log "ERROR: DB not found at $DB_PATH"
    exit 1
fi

restart_xray() {
    log "Restarting xray core..."
    # Try sending SIGUSR1 to xray process directly
    XRAY_PID=$(pgrep -x xray 2>/dev/null | head -1)
    if [ -n "$XRAY_PID" ]; then
        kill -SIGUSR1 "$XRAY_PID" 2>/dev/null && log "Sent SIGUSR1 to xray (pid=$XRAY_PID)" && return 0
    fi
    # Try x-ui cli
    if command -v x-ui &>/dev/null; then
        x-ui restart &>/dev/null && log "Restarted via x-ui CLI" && return 0
    fi
    # Fallback: systemctl restart x-ui
    systemctl restart x-ui &>/dev/null && log "Restarted via systemctl x-ui" && return 0
    log "WARNING: Could not restart xray core"
    return 1
}

check_and_enforce() {
    NOW_MS=$(date +%s%3N)
    NEED_XRAY_RESTART=0

    # Get all client_traffics rows that are currently enabled
    # Fields: id, inbound_id, email, up, down, total, expiry_time, enable
    while IFS='|' read -r rid iid email up down total expiry enable; do
        [ -z "$rid" ] && continue
        [ "$enable" = "0" ] && continue

        up=${up:-0}
        down=${down:-0}
        total=${total:-0}
        expiry=${expiry:-0}

        USED=$(( up + down ))
        EXPIRED_TRAFFIC=0
        EXPIRED_DATE=0

        # Check traffic expiry
        if [ "$total" -gt 0 ] && [ "$USED" -ge "$total" ]; then
            EXPIRED_TRAFFIC=1
        fi

        # Check date expiry
        if [ "$expiry" -gt 0 ] && [ "$NOW_MS" -ge "$expiry" ]; then
            EXPIRED_DATE=1
        fi

        if [ "$EXPIRED_TRAFFIC" = "1" ] || [ "$EXPIRED_DATE" = "1" ]; then
            # Disable in client_traffics
            sqlite3 "$DB_PATH" "UPDATE client_traffics SET enable=0 WHERE id=$rid;"

            # Disable in inbounds settings JSON using python3 if available
            if command -v python3 &>/dev/null; then
                python3 - "$iid" "$email" "$DB_PATH" << 'PYEOF'
import sys, sqlite3, json

iid = int(sys.argv[1])
email = sys.argv[2].strip()
db_path = sys.argv[3]

conn = sqlite3.connect(db_path, timeout=10)
conn.execute("PRAGMA busy_timeout = 3000")
cur = conn.cursor()
cur.execute("SELECT settings FROM inbounds WHERE id=?", (iid,))
row = cur.fetchone()
if row:
    try:
        s = json.loads(row[0])
    except:
        s = {}
    changed = False
    for c in s.get("clients", []):
        if (c.get("email") or "").strip() == email:
            if c.get("enable", True) not in (False, 0, "0"):
                c["enable"] = False
                changed = True
    if changed:
        cur.execute("UPDATE inbounds SET settings=? WHERE id=?",
                    (json.dumps(s, ensure_ascii=False, separators=(",", ":")), iid))
        conn.commit()
conn.close()
PYEOF
            fi

            REASON=""
            [ "$EXPIRED_TRAFFIC" = "1" ] && REASON="traffic"
            [ "$EXPIRED_DATE" = "1" ] && REASON="${REASON:+$REASON+}date"

            log "Disabled: inbound_id=$iid email=$email reason=$REASON"

            # Only restart xray if expired by traffic
            if [ "$EXPIRED_TRAFFIC" = "1" ]; then
                NEED_XRAY_RESTART=1
            fi
        fi

    done < <(sqlite3 "$DB_PATH" \
        "SELECT id,inbound_id,email,up,down,total,expiry_time,enable FROM client_traffics WHERE enable=1;" \
        2>/dev/null)

    if [ "$NEED_XRAY_RESTART" = "1" ]; then
        restart_xray
    fi
}

log "Started. Interval=${INTERVAL}s DB=$DB_PATH"

while true; do
    check_and_enforce
    sleep "$INTERVAL"
done
