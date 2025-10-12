#!/bin/bash
set -Eeuo pipefail

ARRAY_ROOT="${PLEXCACHE_ARRAY_ROOT:-/mnt/user0}"
CACHE_ROOT="${PLEXCACHE_CACHE_ROOT:-/mnt/cache}"
LOG="${PLEXCACHE_LOG:-/logs/plexcache.log}"
PUID="${PUID:-99}"
PGID="${PGID:-100}"
umask 0002

# mirror stdout+stderr to log and terminal
mkdir -p "$(dirname "$LOG")"
exec > >(tee -a "$LOG") 2>&1

to_bool() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON)  echo 1 ;;
    0|false|FALSE|no|NO|off|OFF|'') echo 0 ;;
    *) echo 0 ;;
  esac
}

DRY="$(to_bool "${RSYNC_DRY_RUN:-}")"
WARM_MOVE="$(to_bool "${PLEXCACHE_WARM_MOVE:-true}")"             # <<— new: move during warm by default
WARM_SIDECARS="$(to_bool "${PLEXCACHE_WARM_SIDECARS:-true}")"     # <<— copy/move sidecars with media
SKIP_IF_PLAYING_WARM="$(to_bool "${PLEXCACHE_SKIP_IF_PLAYING_WARM:-true}")"

echo "[plexcache] run start $(date)"
echo "[plexcache] DRY mode: $DRY  move_warm: $WARM_MOVE  array=$ARRAY_ROOT  cache=$CACHE_ROOT"

# base rsync cmd
RSYNC_CMD=(rsync -ahvW --inplace --partial --numeric-ids --xattrs --acls)
RSYNC_CMD+=(--chown=${PUID}:${PGID})
[ "$DRY" = "1" ] && RSYNC_CMD+=(--dry-run)

#base mkdir cmd
MKDIR_CMD=(install -d -m 0775 -o "${PUID}" -g "${PGID}")

# -------------------------------
# Build the selection list (paths)
# -------------------------------
LIST_CMD='python /opt/plexcache/selector.py'
if id -u abc >/dev/null 2>&1; then
  LIST_OUT="$(su abc -s /bin/sh -c "$LIST_CMD" || true)"
else
  LIST_OUT="$(bash -lc "$LIST_CMD" || true)"
fi

# Optional: build a set of currently playing files to avoid moving out from under a stream
PLAYING_SET=""
if [ "$SKIP_IF_PLAYING_WARM" = "1" ]; then
  PLAYING_SET="$(python - <<'PY' 2>/dev/null || true
import os, requests
from plexapi.server import PlexServer
try:
  s=requests.Session(); s.verify=str(os.environ.get("PLEX_SSL_VERIFY","true")).lower() in ("1","true","yes","on")
  p=PlexServer(os.environ["PLEX_BASEURL"], os.environ["PLEX_TOKEN"], session=s)
  seen=set()
  for sess in p.sessions():
    for m in getattr(sess,"media",[]) or []:
      for part in getattr(m,"parts",[]) or []:
        if part.file: seen.add(part.file)
  # print as newline list
  for f in seen: print(f)
except Exception: pass
PY
)"
fi

# -----------------------------------------
# Free-space guard: size, trim, then copy
# -----------------------------------------
RESERVE_GB="${PLEXCACHE_RESERVE_GB:-10}"
KEEP_FREE_GB="${PLEXCACHE_MIN_FREE_GB:-20}"
TRIM_PLAN="$(to_bool "${PLEXCACHE_TRIM_PLAN:-true}")"

# Collect existing sources with sizes first
declare -a ALL=()
TOTAL_NEED=0
while IFS= read -r src; do
  [ -z "$src" ] && continue
  [[ "$src" != "$ARRAY_ROOT"/* ]] && { echo "[skip] not under array root: $src"; continue; }
  [[ "$src" == "$CACHE_ROOT"/* ]] && { echo "[skip] already on cache: $src"; continue; }
  if [ -n "$PLAYING_SET" ] && grep -Fqx "$src" <(printf "%s\n" $PLAYING_SET); then
    echo "[skip] playing: $src"
    continue
  fi

  if [ ! -f "$src" ]; then
    # if the same file already exists on cache, it's already warm
    cache_equiv="${src/$ARRAY_ROOT/$CACHE_ROOT}"
    if [ -f "$cache_equiv" ]; then
      echo "[skip] already on cache: $cache_equiv"
      continue
    fi
    echo "[skip] missing on array: $src"
    continue
  fi

  size=$(stat -c%s "$src" 2>/dev/null || stat -f%z "$src" 2>/dev/null || echo 0)
  ALL+=("$src|$size")
  TOTAL_NEED=$((TOTAL_NEED + size))
done < <(printf "%s\n" "$LIST_OUT")

FREE=$(df -PB1 "$CACHE_ROOT" | awk 'NR==2{print $4}')
RESERVE=$(( (RESERVE_GB + KEEP_FREE_GB) * 1024 * 1024 * 1024 ))
ALLOW=$(( FREE - RESERVE ))

echo "[plexcache] cache free=$(numfmt --to=iec $FREE) need=$(numfmt --to=iec $TOTAL_NEED) allow-after-reserve=$(numfmt --to=iec $ALLOW)"

if [ "$ALLOW" -le 0 ]; then
  echo "[plexcache] not enough free space even before copying. aborting."
  echo "[plexcache] run end   $(date)"; exit 0
fi

# Trim plan to what fits (or abort if trimming disabled)
declare -a PICKED=()
ACC=0
for rec in "${ALL[@]}"; do
  src="${rec%%|*}"; size="${rec##*|}"
  if [ $((ACC + size)) -le "$ALLOW" ]; then
    PICKED+=("$rec"); ACC=$((ACC + size))
  else
    if [ "$TRIM_PLAN" = "1" ]; then
      echo "[skip] out of space for: $src"
      continue
    else
      echo "[plexcache] plan exceeds cache allowance. aborting."
      echo "[plexcache] run end   $(date)"; exit 0
    fi
  fi
done
echo "[plexcache] will copy $((${#PICKED[@]})) items, total $(numfmt --to=iec $ACC)"

# ----------------
# Copy loop (warm)
# ----------------
IFS=$'\n'
for rec in "${PICKED[@]}"; do
  src="${rec%%|*}"
  dst="${src/$ARRAY_ROOT/$CACHE_ROOT}"

  # if the array source is gone but the cache copy exists, skip quietly
  if [ ! -f "$src" ] && [ -f "$dst" ]; then
    echo "[skip] already on cache: $dst"
    continue
  fi

  # create dest dir even in dry so rsync can resolve it
  "${MKDIR_CMD[@]}" "$(dirname "$dst")"

  echo "[rsync] ${RSYNC_CMD[*]} '$src' '$dst'"
  "${RSYNC_CMD[@]}" "$src" "$dst"

  # sidecars during warm
  if [ "$WARM_SIDECARS" = "1" ]; then
    base="${src%.*}"
    db="$(dirname "$dst")"
    for ext in srt ass sub nfo jpg png; do
      sc_src="${base}.${ext}"
      [ -f "$sc_src" ] || continue
      sc_dst="${db}/$(basename "$sc_src")"
      "${RSYNC_CMD[@]}" "$sc_src" "$sc_dst"
    done
  fi

  # verify + optional delete (turn copy into move) when NOT dry
  if [ "$DRY" != "1" ] && [ "$WARM_MOVE" = "1" ]; then
    src_sz=$(stat -c%s "$src" 2>/dev/null || stat -f%z "$src")
    dst_sz=$(stat -c%s "$dst" 2>/dev/null || stat -f%z "$dst" || echo 0)
    if [ "$src_sz" = "$dst_sz" ]; then
      rm -f -- "$src"
      # try to tidy empty dir on array (non-fatal)
      rdir="$(dirname "$src")"
      rmdir --ignore-fail-on-non-empty "$rdir" 2>/dev/null || true
    else
      # fall back to checksum pass once, then re-check
      rsync -ahvW --checksum "$src" "$dst"
      dst_sz2=$(stat -c%s "$dst" 2>/dev/null || stat -f%z "$dst" || echo 0)
      [ "$src_sz" = "$dst_sz2" ] && rm -f -- "$src"
    fi
  fi
done

# -------------------------------------------
# Optional: Move watched items back (separate)
# -------------------------------------------
if [ "$(to_bool "${PLEXCACHE_MOVE_WATCHED_BACK:-false}")" = "1" ]; then
  echo "[plexcache] move-back phase start"
  BACK_LIST="$(python /opt/plexcache/selector_watched_back.py || true)"
  for cache_src in $BACK_LIST; do
    [ -z "$cache_src" ] && continue
    array_dst="${cache_src/$CACHE_ROOT/$ARRAY_ROOT}"
    "${MKDIR_CMD[@]}" "$(dirname "$array_dst")"

    echo "[back] ${RSYNC_CMD[*]} '$cache_src' '$array_dst'"
    "${RSYNC_CMD[@]}" "$cache_src" "$array_dst"

    if [ "$(to_bool "${PLEXCACHE_MOVE_BACK_SIDECARS:-true}")" = "1" ]; then
      base="${cache_src%.*}"
      for ext in srt ass sub nfo jpg png; do
        sc="${base}.${ext}"
        [ -f "$sc" ] && "${RSYNC_CMD[@]}" "$sc" "${array_dst%/*}/"
      done
    fi

    if [ "$DRY" != "1" ]; then
      s=$(stat -c%s "$cache_src" 2>/dev/null || stat -f%z "$cache_src")
      d=$(stat -c%s "$array_dst" 2>/dev/null || stat -f%z "$array_dst" || echo 0)
      [ "$s" = "$d" ] && rm -f -- "$cache_src"
    fi
  done
  echo "[plexcache] move-back phase end"
fi

echo "[plexcache] run end   $(date)"
