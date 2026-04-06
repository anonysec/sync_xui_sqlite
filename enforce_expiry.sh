#!/bin/bash
# ============================================
#  WinNet - Enforce Expiry (Bash / SQLite3)
#  Disables expired clients in all inbounds
#  and restarts xray core if traffic expired
# ============================================

DB_PATH="${1:-/etc/x-ui/x-ui.db}"
LOG_PREFIX="[enforce_expiry]"

log()  { echo "$(date '+%Y-%m-%d %H:%M:%S') ${LOG_PREFIX} $*"; }
info() { log "[INFO] $*"; }
warn() { log "[WARN] $*"; }
err()  { log "[ERROR] $*"; }

# ---- پیدا کردن xray ----
find_xray() {
    for p in \
        /usr/local/x-ui/bin/xray \
        /usr/local/bin/xray \
        /usr/bin/xray \
        /opt/xray/xray \
        $(find /usr/local/x-ui -name "xray" -type f 2>/dev/null | head -1)
    do
        [ -x "$p" ] && echo "$p" && return 0
    done
    return 1
}

restart_xray() {
    info "Restarting xray core..."
    XRAY_BIN=$(find_xray 2>/dev/null)
    if [ -n "$XRAY_BIN" ]; then
        # پیدا کردن PID xray و ارسال SIGHUP برای reload
        XRAY_PID=$(pgrep -f "xray run" 2>/dev/null | head -1)
        if [ -n "$XRAY_PID" ]; then
            kill -SIGHUP "$XRAY_PID" 2>/dev/null && \
                info "Sent SIGHUP to xray PID=$XRAY_PID (graceful reload)" && return 0
        fi
    fi
    # fallback: kill و restart از طریق x-ui
    if command -v x-ui >/dev/null 2>&1; then
        x-ui restart >/dev/null 2>&1 && info "xray restarted via x-ui restart" && return 0
    fi
    # fallback دوم: systemctl
    if systemctl is-active --quiet x-ui 2>/dev/null; then
        systemctl restart x-ui >/dev/null 2>&1 && info "xray restarted via systemctl restart x-ui" && return 0
    fi
    warn "Could not restart xray - no method succeeded"
    return 1
}

check_deps() {
    if ! command -v sqlite3 >/dev/null 2>&1; then
        err "sqlite3 not found! Install with: apt install sqlite3"
        exit 1
    fi
    if [ ! -f "$DB_PATH" ]; then
        err "Database not found: $DB_PATH"
        exit 1
    fi
}

now_ms() {
    echo $(( $(date +%s) * 1000 ))
}

# ---- خواندن همه کاربران فعال از client_traffics ----
# فیلد enable=1 یعنی فعاله
# expiry_time بر حسب میلی‌ثانیه (0 = بی‌نهایت)
# total بر حسب بایت (0 = بی‌نهایت)
# up+down = مصرف شده

run_check() {
    local NOW_MS
    NOW_MS=$(now_ms)

    # خواندن کاربران فعال
    # خروجی: inbound_id|email|up|down|total|expiry_time
    local QUERY="SELECT inbound_id, email, up, down, total, expiry_time
                 FROM client_traffics
                 WHERE enable = 1;"

    local RESULTS
    RESULTS=$(sqlite3 "$DB_PATH" "$QUERY" 2>/dev/null)

    if [ -z "$RESULTS" ]; then
        info "No active clients found."
        return 0
    fi

    local NEED_XRAY_RESTART=0
    local DISABLED_COUNT=0

    while IFS="|" read -r IID EMAIL UP DOWN TOTAL EXPIRY; do
        [ -z "$IID" ] && continue
        [ -z "$EMAIL" ] && continue

        UP=${UP:-0}
        DOWN=${DOWN:-0}
        TOTAL=${TOTAL:-0}
        EXPIRY=${EXPIRY:-0}

        local USED=$(( UP + DOWN ))
        local EXPIRED_TRAFFIC=0
        local EXPIRED_DATE=0

        # بررسی انقضای ترافیک
        if [ "$TOTAL" -gt 0 ] && [ "$USED" -ge "$TOTAL" ]; then
            EXPIRED_TRAFFIC=1
        fi

        # بررسی انقضای تاریخ
        if [ "$EXPIRY" -gt 0 ] && [ "$EXPIRY" -le "$NOW_MS" ]; then
            EXPIRED_DATE=1
        fi

        # اگه منقضی شده
        if [ "$EXPIRED_TRAFFIC" -eq 1 ] || [ "$EXPIRED_DATE" -eq 1 ]; then
            info "Disabling expired client: inbound=$IID email=$EMAIL" \
                 "traffic_expired=$EXPIRED_TRAFFIC date_expired=$EXPIRED_DATE" \
                 "used=${USED}B total=${TOTAL}B expiry=${EXPIRY}"

            # غیرفعال کردن در client_traffics
            sqlite3 "$DB_PATH" \
                "UPDATE client_traffics SET enable=0 WHERE inbound_id=$IID AND email='$EMAIL';" \
                2>/dev/null

            if [ $? -eq 0 ]; then
                DISABLED_COUNT=$(( DISABLED_COUNT + 1 ))
                info "Disabled in client_traffics: inbound=$IID email=$EMAIL"
            else
                err "Failed to disable in client_traffics: inbound=$IID email=$EMAIL"
            fi

            # غیرفعال کردن در inbounds settings (JSON)
            # باید توی JSON فیلد clients آرایه رو پیدا کنیم و enable رو false کنیم
            disable_in_settings "$IID" "$EMAIL"

            # فقط اگه ترافیک تموم شده بود flag ریستارت بزار
            if [ "$EXPIRED_TRAFFIC" -eq 1 ]; then
                NEED_XRAY_RESTART=1
            fi
        fi

    done <<< "$RESULTS"

    if [ "$DISABLED_COUNT" -gt 0 ]; then
        info "Total disabled: $DISABLED_COUNT client(s)"
        if [ "$NEED_XRAY_RESTART" -eq 1 ]; then
            restart_xray
        else
            info "No traffic expiry detected - xray restart not needed"
        fi
    else
        info "No expired clients found."
    fi
}

# ---- غیرفعال کردن کاربر در JSON settings اینباند ----
disable_in_settings() {
    local IID="$1"
    local EMAIL="$2"

    # python3 برای پردازش JSON استفاده می‌کنیم اگه موجود باشه
    # وگرنه از روش sqlite + sed استفاده می‌کنیم
    if command -v python3 >/dev/null 2>&1; then
        disable_in_settings_python "$IID" "$EMAIL"
    else
        disable_in_settings_sed "$IID" "$EMAIL"
    fi
}

disable_in_settings_python() {
    local IID="$1"
    local EMAIL="$2"

    python3 - "$DB_PATH" "$IID" "$EMAIL" << 'PYEOF'
import sys, sqlite3, json

db_path = sys.argv[1]
iid = int(sys.argv[2])
email = sys.argv[3]

conn = sqlite3.connect(db_path, timeout=30)
conn.execute("PRAGMA busy_timeout = 3000")
cur = conn.cursor()

cur.execute("SELECT settings FROM inbounds WHERE id=?", (iid,))
row = cur.fetchone()
if not row:
    print(f"[WARN] Inbound {iid} not found in inbounds table")
    conn.close()
    sys.exit(0)

try:
    settings = json.loads(row[0]) if row[0] else {}
except:
    settings = {}

changed = False
for client in settings.get("clients", []):
    if (client.get("email") or "") == email:
        if client.get("enable", True) not in (False, 0, "0", "false"):
            client["enable"] = False
            changed = True
            print(f"[INFO] Set enable=false for email={email} in inbound={iid} settings")

if changed:
    cur.execute("UPDATE inbounds SET settings=? WHERE id=?",
                (json.dumps(settings, ensure_ascii=False, separators=(",", ":")), iid))
    conn.commit()
    print(f"[INFO] Updated inbound={iid} settings in DB")
else:
    print(f"[INFO] No change needed in settings for email={email} inbound={iid}")

conn.close()
PYEOF

} 

disable_in_settings_sed() {
    local IID="$1"
    local EMAIL="$2"

    # روش جایگزین بدون python: مستقیم با sqlite3 و جایگزینی متنی ساده
    # این روش برای JSON ساده کار می‌کنه ولی ریسک داره روی JSON پیچیده
    warn "python3 not available - attempting text-based JSON patch for inbound=$IID email=$EMAIL"

    local SETTINGS
    SETTINGS=$(sqlite3 "$DB_PATH" "SELECT settings FROM inbounds WHERE id=$IID;" 2>/dev/null)

    if [ -z "$SETTINGS" ]; then
        warn "Could not read settings for inbound=$IID"
        return 1
    fi

    # جایگزینی "enable":true با "enable":false فقط برای این کاربر
    # این روش ساده‌ست و ممکنه روی JSON‌های پیچیده کامل نباشه
    # اما client_traffics.enable=0 کافیه برای جلوگیری از اتصال
    info "client_traffics.enable=0 already set for email=$EMAIL inbound=$IID (settings JSON patch skipped without python3)"
}

# ---- حلقه اصلی ----
main() {
    check_deps
    info "Starting enforce expiry check (DB: $DB_PATH)"

    local INTERVAL="${2:-60}"

    if [ "$INTERVAL" -le 0 ]; then
        run_check
    else
        info "Loop mode: interval=${INTERVAL}s"
        while true; do
            run_check
            sleep "$INTERVAL"
        done
    fi
}

main "$@"
