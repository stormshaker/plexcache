#!/bin/bash
set -euo pipefail

# run provided command verbatim (don't touch users)
if [ "$#" -gt 0 ]; then
  exec "$@"
fi

# create runtime user to match Unraid defaults if needed
if id -u abc >/dev/null 2>&1; then :
else
  addgroup -g "${PGID:-100}" abc >/dev/null 2>&1 || true
  adduser  -D -H -u "${PUID:-99}" -G abc abc >/dev/null 2>&1 || true
fi
chown -R ${PUID:-99}:${PGID:-100} /config /logs 2>/dev/null || true
touch "$PLEXCACHE_LOG" || true

# ---- helper functions ----
get_next_run_time() {
  if [ -n "${PLEXCACHE_CRON:-}" ]; then
    python3 -c "
from croniter import croniter
from datetime import datetime
import sys
try:
    cron = croniter('${PLEXCACHE_CRON}', datetime.now())
    next_time = cron.get_next(datetime)
    print(next_time.strftime('%Y-%m-%d %H:%M:%S'))
except Exception as e:
    print('unknown', file=sys.stderr)
" 2>/dev/null || echo "unknown"
  fi
}

# ---- pretty schedule logging ----
say_when () {
  if [ "${PLEXCACHE_RUN_IMMEDIATELY:-false}" = "true" ]; then
    echo "[plexcache] scheduler: run immediately (one-shot mode)"
  elif [ -n "${PLEXCACHE_CRON:-}" ]; then
    echo "[plexcache] scheduler: cron '${PLEXCACHE_CRON}' (busybox crond)"
    
    # Calculate next run time using Python croniter library
    next_run=$(get_next_run_time)
    
    if [ "$next_run" != "unknown" ]; then
      echo "[plexcache] next run: $next_run"
    else
      echo "[plexcache] note: next-run calculation not available for this cron pattern; run 'docker logs -f' to watch executions."
    fi
  elif [ -n "${PLEXCACHE_TIME:-}" ]; then
    # compute next run like the daily loop does
    TARGET="${PLEXCACHE_TIME:-03:15}"
    now=$(date +%s)
    next=$(date -d "$(date -d @$now +%F) $TARGET" +%s 2>/dev/null || echo $((now+86400)))
    [ "$next" -le "$now" ] && next=$(date -d "tomorrow $TARGET" +%s 2>/dev/null || echo $((now+86400)))
    echo "[plexcache] scheduler: daily at ${TARGET}"
    echo "[plexcache] next run: $(date -d @$next +'%Y-%m-%d %H:%M:%S %Z')"
  else
    echo "[plexcache] scheduler: none (one-shot only)"
  fi
}

# ---- unified run execution ----

say_when

# run immediately mode (like Kometa) - execute once, wait for input, exit
if [ "${PLEXCACHE_RUN_IMMEDIATELY:-false}" = "true" ]; then
  echo "[plexcache] Running immediately (one-shot mode)..."
  # Source the functions file to access execute_plexcache_run
  if [ -f "/usr/local/bin/plexcache_functions.sh" ]; then
    . /usr/local/bin/plexcache_functions.sh
  fi
  execute_plexcache_run
  echo ""
  echo "[plexcache] Run complete. Press any key to exit..."
  read -n 1 -s -r
  echo "[plexcache] Exiting."
  exit 0
fi

# cron mode if PLEXCACHE_CRON is set
if [ -n "${PLEXCACHE_CRON:-}" ]; then
  # Export environment variables to /etc/environment
  env | grep -E '^(PLEXCACHE|PLEX|TZ|PUID|PGID|RSYNC)=' > /etc/environment
  
  # Create a functions-only file for cron to source
  cat > /usr/local/bin/plexcache_functions.sh <<'EOF'
# PlexCache functions (safe to source from cron)

to_bool() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON)  echo 1 ;;
    0|false|FALSE|no|NO|off|OFF|'') echo 0 ;;
    *) echo 0 ;;
  esac
}

get_next_run_time() {
  if [ -n "${PLEXCACHE_CRON:-}" ]; then
    python3 -c "
from croniter import croniter
from datetime import datetime
import sys
try:
    cron = croniter('${PLEXCACHE_CRON}', datetime.now())
    next_time = cron.get_next(datetime)
    print(next_time.strftime('%Y-%m-%d %H:%M:%S'))
except Exception as e:
    print('unknown', file=sys.stderr)
" 2>/dev/null || echo "unknown"
  fi
}

execute_plexcache_run () {
  # Show startup summary
  echo "[plexcache] ==============================================="
  echo "[plexcache] PlexCache run started: $(date)"
  echo "[plexcache] Log level: ${PLEXCACHE_LOG_LEVEL:-info}"
  echo "[plexcache] Detailed logs: ${PLEXCACHE_LOG:-/logs/plexcache.log}"
  echo "[plexcache] Dry run: ${RSYNC_DRY_RUN:-0} | Move warm: ${PLEXCACHE_WARM_MOVE:-1} | Move back: ${PLEXCACHE_MOVE_WATCHED_BACK:-0}"
  echo "[plexcache] Array: ${PLEXCACHE_ARRAY_ROOT:-/mnt/user0} | Cache: ${PLEXCACHE_CACHE_ROOT:-/mnt/cache}"
  
  # Run the script (output goes to log file)
  /usr/local/bin/run_once.sh >> "$PLEXCACHE_LOG" 2>&1
  
  # Show completion summary (parse from log file)
  if [ -f "$PLEXCACHE_LOG" ]; then
    echo "[plexcache] -------------------------------------------------"
    copied_count=$(tail -20 "$PLEXCACHE_LOG" | grep "Warm/copy phase complete" | tail -1 | sed 's/.*: \([0-9]*\) copied.*/\1/' || echo "0")
    back_count=$(tail -20 "$PLEXCACHE_LOG" | grep "Move-back phase complete" | tail -1 | sed 's/.*: \([0-9]*\) items moved.*/\1/' || echo "0")
    moved_count=$(tail -20 "$PLEXCACHE_LOG" | grep "moved - source deleted" | tail -1 | sed 's/.*(\([0-9]*\) moved.*/\1/' || echo "0")
    
    # Ensure variables are numbers (default to 0 if empty)
    copied_count=${copied_count:-0}
    back_count=${back_count:-0}
    moved_count=${moved_count:-0}
    
    # Check if move-back is enabled
    MOVE_BACK_ENABLED="$(to_bool "${PLEXCACHE_MOVE_WATCHED_BACK:-false}")"
    
    if [ "$MOVE_BACK_ENABLED" = "1" ]; then
      # Move-back is enabled, always show both phases
      if [ "$moved_count" -gt 0 ]; then
        echo "[plexcache] Warm/copy phase complete: $copied_count copied ($moved_count moved - source deleted after verify)"
      else
        echo "[plexcache] Warm/copy phase complete: $copied_count copied"
      fi
      echo "[plexcache] Move-back phase complete: $back_count items moved back to array"
    else
      # Move-back is disabled, only show warm/copy phase
      if [ "$moved_count" -gt 0 ]; then
        echo "[plexcache] Warm/copy phase complete: $copied_count copied ($moved_count moved - source deleted after verify)"
      else
        echo "[plexcache] Warm/copy phase complete: $copied_count copied"
      fi
    fi
    echo "[plexcache] -------------------------------------------------"
    echo "[plexcache] PlexCache run ended: $(date)"
    
    # Show next run time if cron is enabled
    if [ -n "${PLEXCACHE_CRON:-}" ]; then
      next_run=$(get_next_run_time)
      if [ "$next_run" != "unknown" ] && [ -n "$next_run" ]; then
        echo "[plexcache] next run: $next_run"
      fi
    fi
    
    echo "[plexcache] ==============================================="
  fi
}

EOF

  # Create wrapper script that sources environment and runs main script
  cat > /usr/local/bin/cron_wrapper.sh <<'EOF'
#!/bin/sh
# Lock file to prevent overlapping executions
LOCK_FILE="/tmp/plexcache_cron.lock"

# Check if another instance is already running
if [ -f "$LOCK_FILE" ]; then
    echo "[CRON] Another PlexCache run is already in progress, skipping this execution"
    exit 0
fi

# Create lock file
touch "$LOCK_FILE"

set -a
. /etc/environment 2>/dev/null || true
set +a

# Source the functions file (safe, no exec commands)
. /usr/local/bin/plexcache_functions.sh

# Execute the unified run function
execute_plexcache_run

# Remove lock file
rm -f "$LOCK_FILE"
EOF
  chmod +x /usr/local/bin/cron_wrapper.sh
  
  # Ensure log directory and file exist
  mkdir -p "$(dirname "${PLEXCACHE_LOG}")"
  touch "${PLEXCACHE_LOG}"
  
  # Create crontab
  mkdir -p /var/spool/cron/crontabs
  echo "${PLEXCACHE_CRON} /usr/local/bin/cron_wrapper.sh" > /var/spool/cron/crontabs/root
  chmod 0600 /var/spool/cron/crontabs/root
  
  
  # Start crond in foreground with verbose logging
  exec busybox crond -f -l 0 -c /var/spool/cron/crontabs
fi

# daily time mode like Kometa
TARGET="${PLEXCACHE_TIME:-03:15}"
while true; do
  now=$(date +%s)
  next=$(date -d "$(date +%F) $TARGET" +%s 2>/dev/null || echo $((now+60)))
  if [ "$next" -le "$now" ]; then
    next=$(date -d "tomorrow $TARGET" +%s 2>/dev/null || echo $((now+86400)))
  fi
  echo "[plexcache] sleeping until $(date -d @$next +'%Y-%m-%d %H:%M:%S %Z')"
  sleep $(( next - now ))
  
  # Source the functions file to access execute_plexcache_run
  if [ -f "/usr/local/bin/plexcache_functions.sh" ]; then
    . /usr/local/bin/plexcache_functions.sh
  fi
  execute_plexcache_run
done
