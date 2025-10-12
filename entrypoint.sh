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
  if [ -n "${PLEXCACHE_CRON:-}" ]; then
    echo "[plexcache] scheduler: cron '${PLEXCACHE_CRON}' (busybox crond)"
    echo "[plexcache] note: next-run calculation not available from crond; run 'docker logs -f' to watch executions."
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

# cron mode if PLEXCACHE_CRON is set
if [ -n "${PLEXCACHE_CRON:-}" ]; then
  env | grep -E '^(PLEXCACHE|PLEX|TZ|PUID|PGID)=' > /etc/environment
  echo "$PLEXCACHE_CRON /usr/local/bin/run_once.sh >> $PLEXCACHE_LOG 2>&1" > /etc/crontabs/root
  exec busybox crond -f -l 2
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
  /usr/local/bin/run_once.sh >> "$PLEXCACHE_LOG" 2>&1
done
