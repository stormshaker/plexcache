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

# ---- pretty schedule logging ----
say_when () {
  if [ "${PLEXCACHE_RUN_IMMEDIATELY:-false}" = "true" ]; then
    echo "[plexcache] scheduler: run immediately (one-shot mode)"
  elif [ -n "${PLEXCACHE_CRON:-}" ]; then
    echo "[plexcache] scheduler: cron '${PLEXCACHE_CRON}' (busybox crond)"
    
    # Calculate next run time for common cron patterns
    next_run=""
    read -r minute hour day month weekday <<< "${PLEXCACHE_CRON}"
    
    # Handle simple patterns
    if [[ "$minute" =~ ^[0-9]+$ ]] && [[ "$hour" =~ ^[0-9]+$ ]] && [[ "$day" == "*" ]] && [[ "$month" == "*" ]] && [[ "$weekday" == "*" ]]; then
      # Fixed time daily (e.g., "0 3 * * *")
      now=$(date +%s)
      next=$(date -d "$(date -d @$now +%F) $hour:$minute" +%s 2>/dev/null || echo $((now+86400)))
      [ "$next" -le "$now" ] && next=$(date -d "tomorrow $hour:$minute" +%s 2>/dev/null || echo $((now+86400)))
      next_run=$(date -d @$next +'%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || echo "unknown")
    elif [[ "$minute" =~ ^[0-9]+$ ]] && [[ "$hour" =~ ^\*/[0-9]+$ ]] && [[ "$day" == "*" ]] && [[ "$month" == "*" ]] && [[ "$weekday" == "*" ]]; then
      # Every N hours (e.g., "0 */4 * * *")
      interval="${hour#*/}"
      now=$(date +%s)
      current_hour=$(date -d @$now +%H)
      # Remove leading zeros to avoid octal interpretation
      current_hour=$((10#$current_hour))
      next_hour=$(( (current_hour / interval + 1) * interval ))
      if [ $next_hour -ge 24 ]; then
        next_hour=0
        next_date=$(date -d "tomorrow" +%F)
      else
        next_date=$(date -d @$now +%F)
      fi
      next=$(date -d "$next_date $next_hour:$minute" +%s 2>/dev/null || echo $((now+3600)))
      next_run=$(date -d @$next +'%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || echo "unknown")
    fi
    
    if [ -n "$next_run" ] && [ "$next_run" != "unknown" ]; then
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
say_when

# run immediately mode (like Kometa) - execute once, wait for input, exit
if [ "${PLEXCACHE_RUN_IMMEDIATELY:-false}" = "true" ]; then
  echo "[plexcache] Running immediately (one-shot mode)..."
  
  # Show startup summary in container logs
  echo "[plexcache] ==============================================="
  echo "[plexcache] PlexCache run started: $(date)"
  echo "[plexcache] Log level: ${PLEXCACHE_LOG_LEVEL:-info}"
  echo "[plexcache] Detailed logs: ${PLEXCACHE_LOG:-/logs/plexcache.log}"
  echo "[plexcache] Dry run: ${RSYNC_DRY_RUN:-0} | Move warm: ${PLEXCACHE_WARM_MOVE:-1} | Move back: ${PLEXCACHE_MOVE_WATCHED_BACK:-0}"
  echo "[plexcache] Array: ${PLEXCACHE_ARRAY_ROOT:-/mnt/user0} | Cache: ${PLEXCACHE_CACHE_ROOT:-/mnt/cache}"
  echo "[plexcache] ==============================================="
  
  # Run the script (output goes to log file)
  /usr/local/bin/run_once.sh >> "$PLEXCACHE_LOG" 2>&1
  
  # Show completion summary in container logs (parse from log file)
  if [ -f "$PLEXCACHE_LOG" ]; then
    copied_count=$(tail -20 "$PLEXCACHE_LOG" | grep "Warm/copy phase complete" | tail -1 | sed 's/.*: \([0-9]*\) copied.*/\1/' || echo "0")
    back_count=$(tail -20 "$PLEXCACHE_LOG" | grep "Move-back phase complete" | tail -1 | sed 's/.*: \([0-9]*\) items moved.*/\1/' || echo "0")
    moved_count=$(tail -20 "$PLEXCACHE_LOG" | grep "moved - source deleted" | tail -1 | sed 's/.*(\([0-9]*\) moved.*/\1/' || echo "0")
    
    if [ "$back_count" != "0" ] && [ -n "$back_count" ]; then
      echo "[plexcache] Warm/copy phase complete: $copied_count copied"
      echo "[plexcache] Move-back phase complete: $back_count items moved back to array"
    elif [ "$moved_count" != "0" ] && [ -n "$moved_count" ]; then
      echo "[plexcache] Warm/copy phase complete: $copied_count copied ($moved_count moved - source deleted after verify)"
    else
      echo "[plexcache] Warm/copy phase complete: $copied_count copied"
    fi
    echo "[plexcache] ==============================================="
    echo "[plexcache] PlexCache run ended: $(date)"
    echo "[plexcache] ==============================================="
  fi
  
  echo ""
  echo "[plexcache] Run complete. Press any key to exit..."
  read -n 1 -s -r
  echo "[plexcache] Exiting."
  exit 0
fi

# cron mode if PLEXCACHE_CRON is set
if [ -n "${PLEXCACHE_CRON:-}" ]; then
  env | grep -E '^(PLEXCACHE|PLEX|TZ|PUID|PGID)=' > /etc/environment
  CRON_DIR="/etc/crontabs"
  [ -d "$CRON_DIR" ] || CRON_DIR="/var/spool/cron/crontabs"
  mkdir -p "$CRON_DIR"
  echo "$PLEXCACHE_CRON . /etc/environment; /usr/local/bin/run_once.sh >> $PLEXCACHE_LOG 2>&1" > "$CRON_DIR/root"
  exec busybox crond -f -l 2 -c "$CRON_DIR"
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
  
  # Show startup summary in container logs
  echo "[plexcache] ==============================================="
  echo "[plexcache] PlexCache run started: $(date)"
  echo "[plexcache] Log level: ${PLEXCACHE_LOG_LEVEL:-info}"
  echo "[plexcache] Detailed logs: ${PLEXCACHE_LOG:-/logs/plexcache.log}"
  echo "[plexcache] Dry run: ${RSYNC_DRY_RUN:-0} | Move warm: ${PLEXCACHE_WARM_MOVE:-1} | Move back: ${PLEXCACHE_MOVE_WATCHED_BACK:-0}"
  echo "[plexcache] Array: ${PLEXCACHE_ARRAY_ROOT:-/mnt/user0} | Cache: ${PLEXCACHE_CACHE_ROOT:-/mnt/cache}"
  echo "[plexcache] ==============================================="
  
  # Run the script (output goes to log file)
  /usr/local/bin/run_once.sh >> "$PLEXCACHE_LOG" 2>&1
  
  # Show completion summary in container logs (parse from log file)
  if [ -f "$PLEXCACHE_LOG" ]; then
    copied_count=$(tail -20 "$PLEXCACHE_LOG" | grep "Warm/copy phase complete" | tail -1 | sed 's/.*: \([0-9]*\) copied.*/\1/' || echo "0")
    back_count=$(tail -20 "$PLEXCACHE_LOG" | grep "Move-back phase complete" | tail -1 | sed 's/.*: \([0-9]*\) items moved.*/\1/' || echo "0")
    moved_count=$(tail -20 "$PLEXCACHE_LOG" | grep "moved - source deleted" | tail -1 | sed 's/.*(\([0-9]*\) moved.*/\1/' || echo "0")
    
    if [ "$back_count" -gt 0 ]; then
      echo "[plexcache] Warm/copy phase complete: $copied_count copied"
      echo "[plexcache] Move-back phase complete: $back_count items moved back to array"
    elif [ "$moved_count" -gt 0 ]; then
      echo "[plexcache] Warm/copy phase complete: $copied_count copied ($moved_count moved - source deleted after verify)"
    else
      echo "[plexcache] Warm/copy phase complete: $copied_count copied"
    fi
    echo "[plexcache] ==============================================="
    echo "[plexcache] PlexCache run ended: $(date)"
    echo "[plexcache] ==============================================="
  fi
done
