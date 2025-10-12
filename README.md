# PlexCache for Unraid (containerized wrapper)

Warm your Unraid cache with Plex “On Deck” and Watchlist items. Optionally move watched items back to the array. Safe, Unraid-specific paths. No symlink tricks. Minimal knobs, sensible defaults.

This repo/packages a lightweight wrapper around the upstream project **bexem/PlexCache** to make it **Unraid-native** and hands-off:

* Source reads from **/mnt/user0** (array only, excludes cache)
* Destination writes to **/mnt/cache**
* Copy-then-delete verification so user shares don’t show duplicates
* Honors Unraid permissions via `PUID=99` `PGID=100`
* Schedules like Kometa (daily time or cron)
* Simple selectors for **On Deck** and **Watchlist** using Plex API
* Optional “watched back to array” pass

> Credit where it’s due: this owes its existence to the original **[bexem/PlexCache](https://github.com/bexem/PlexCache)**. We’ve replaced the move/copy mechanics to match Unraid and trimmed features for a predictable container flow. Upstream license and attribution apply to upstream code; this wrapper intends to follow the same spirit.

---

## Contents

* [What this build does](#what-this-build-does)
* [Architecture](#architecture)
* [Requirements](#requirements)
* [Quick start (local only)](#quick-start-local-only)
* [Unraid template](#unraid-template)
* [Environment variables](#environment-variables)
* [Scheduling](#scheduling)
* [Permissions and ownership](#permissions-and-ownership)
* [Logging](#logging)
* [Build and restart helper](#build-and-restart-helper)
* [Update workflow](#update-workflow)
* [Troubleshooting](#troubleshooting)
* [Roadmap (SQLite enhancement)](#roadmap-sqlite-enhancement)
* [Credits and license](#credits-and-license)

---

## What this build does

* Talks to Plex to gather **On Deck** and **Watchlist** lists for the main user (`PLEX_TOKEN`).
* Translates Plex media paths to Unraid host paths via `PLEX_PATH_MAP` (e.g. `/data=/mnt/user`).
* For each selected media file:

  * Plans copies that **fit** the cache free-space budget.
  * **Copies** from `/mnt/user0/...` to `/mnt/cache/...`.
  * Verifies sizes (optionally a checksum pass on mismatch).
  * If `PLEXCACHE_WARM_MOVE=true` and not dry-run, **deletes the array source** after successful verify.
  * Copies common sidecars (`srt`, `ass`, `sub`, `nfo`, `jpg`, `png`) if enabled.
* Optional **move-back** phase: when `PLEXCACHE_MOVE_WATCHED_BACK=true`, watched items found on cache are copied back to the array and the cache copy is removed on verify.
* Skips items already on cache on subsequent runs.

---

## Architecture

```
Plex (API)
   │
   ├─ selector.py                 # builds a newline list of source file paths (array paths)
   ├─ selector_watched_back.py    # builds a list of watched items currently on cache
   └─ run_once.sh                 # free-space plan → rsync warm/move → optional watched-back
        ├─ safeguards: /mnt/user0 → /mnt/cache only
        ├─ PUID/PGID ownership
        ├─ sidecars
        └─ neat logs

entrypoint.sh                     # sets up scheduling (daily time or cron) + pretty “next run” logs
Dockerfile                        # pulls upstream, installs plexapi, drops our scripts
```

Upstream Python (`plexcache.py`) is **not** executed directly; we’re using selectors plus `rsync` to be Unraid-safe.

---

## Requirements

* Unraid with Docker
* Plex reachable from this container
* A Plex token for your main user
* Your Plex container’s library path mapping (to build `PLEX_PATH_MAP`), e.g. Plex uses `/data` → host `/mnt/user`

---

## Quick start (local only)

Put these files in:

```
/mnt/user/appdata/plexcache/build/
  Dockerfile
  entrypoint.sh
  run_once.sh
  selector.py
  selector_watched_back.py
  build-and-restart.sh   # helper script below
```

Build the image:

```bash
cd /mnt/user/appdata/plexcache/build
./build-and-restart.sh    # tags plexcache:local and a version tag
```

Add the container via **Unraid GUI → Docker → Add Container** using the template (see below), set:

* Repository: `plexcache:local` (or the versioned tag printed by the build script)
* Network: Bridge (Host not required)
* Paths:

  * `/mnt/user0` → `/mnt/user0` (rw)
  * `/mnt/cache` → `/mnt/cache` (rw)
  * `/config` → `/mnt/user/appdata/plexcache/config`
  * `/logs` → `/mnt/user/appdata/plexcache/logs`
* Variables (minimum):

  * `PLEX_BASEURL=http://<plex-lan-ip>:32400`
  * `PLEX_TOKEN=<your token>`
  * `PLEX_PATH_MAP=/data=/mnt/user`
  * `PUID=99` `PGID=100`
  * `PLEXCACHE_ONDECK=true` `PLEXCACHE_WATCHLIST=true`
  * `PLEXCACHE_WARM_MOVE=true`
  * `PLEXCACHE_TIME=03:15`  (or set CRON instead)

Apply, then check logs.

---

## Unraid template

Save as:

```
/boot/config/plugins/dockerMan/templates-user/my-PlexCache.xml
```

Use the XML you’ve already validated (with `Description="..."` on each field). Key points:

* `<Container version="2">`
* Each `<Config …/>` sits directly under `<Container>`
* Add an **Icon** path if you want a logo (e.g. `/mnt/user/appdata/plexcache/icon.png`)

---

## Environment variables

| Variable                           | Default           | Purpose                                                                                             |
| ---------------------------------- | ----------------- | --------------------------------------------------------------------------------------------------- |
| `PLEX_BASEURL`                     | *(none)*          | Plex server URL, e.g. `http://192.168.1.10:32400`. Use LAN IP, not `localhost`.                     |
| `PLEX_TOKEN`                       | *(none)*          | Plex token (main user). Find in Plex Web DevTools → Network (header `X-Plex-Token`).                |
| `PLEX_PATH_MAP`                    | `/data=/mnt/user` | Translate Plex paths to Unraid host paths. Comma-separated mapping pairs (for now we use one pair). |
| `PLEXCACHE_ONDECK`                 | `true`            | Include On Deck items.                                                                              |
| `PLEXCACHE_ONDECK_COUNT`           | `40`              | Max On Deck items.                                                                                  |
| `PLEXCACHE_WATCHLIST`              | `true`            | Include Watchlist (local only).                                                                     |
| `PLEXCACHE_WATCHLIST_COUNT`        | `40`              | Max Watchlist items.                                                                                |
| `PLEX_LIBRARIES`                   | *(blank)*         | Comma list of library names to include. Blank = all.                                                |
| `PLEXCACHE_MAX_ITEMS`              | `500`             | Hard cap after other filters.                                                                       |
| `PLEXCACHE_ARRAY_ROOT`             | `/mnt/user0`      | Source root (array only). Mirrors Unraid Mover behavior.                                            |
| `PLEXCACHE_CACHE_ROOT`             | `/mnt/cache`      | Destination cache root.                                                                             |
| `PLEXCACHE_WARM_MOVE`              | `true`            | Copy to cache then delete array source after verify. Prevents duplicates.                           |
| `PLEXCACHE_WARM_SIDECARS`          | `true`            | Copy sidecars with the media during warm.                                                           |
| `PLEXCACHE_MOVE_WATCHED_BACK`      | `false`           | Move watched items found on cache back to array and remove cache copy.                              |
| `PLEXCACHE_MOVE_BACK_MIN_AGE_DAYS` | `0`               | Only move back if last viewed older than N days.                                                    |
| `PLEXCACHE_MOVE_BACK_SIDECARS`     | `true`            | Move sidecars together with the media on move-back.                                                 |
| `PLEXCACHE_MIN_FREE_GB`            | `20`              | Leave at least this much free after the run.                                                        |
| `PLEXCACHE_RESERVE_GB`             | `10`              | Extra never-touch buffer on top of MIN_FREE.                                                        |
| `PLEXCACHE_TRIM_PLAN`              | `true`            | If the plan doesn’t fit, trim it; if `false`, abort instead.                                        |
| `PLEXCACHE_TIME`                   | `03:15`           | Daily time scheduler (HH:MM). Leave blank if using CRON.                                            |
| `PLEXCACHE_CRON`                   | *(blank)*         | Cron expression alternative (e.g. `0 */2 * * *`).                                                   |
| `PLEX_SSL_VERIFY`                  | `true`            | Set `false` for self-signed HTTPS.                                                                  |
| `PUID`                             | `99`              | Owner UID (Unraid `nobody`).                                                                        |
| `PGID`                             | `100`             | Group GID (Unraid `users`).                                                                         |
| `RSYNC_DRY_RUN`                    | `false`           | If `true`, add `--dry-run` to rsync and don’t modify files.                                         |

---

## Scheduling

* **Daily time**: set `PLEXCACHE_TIME=HH:MM`. The log prints “next run” and “sleeping until”.
* **Cron**: set `PLEXCACHE_CRON` to a standard expression. We log the expression; BusyBox `crond` doesn’t expose next-run times.

Only set one of these.

---

## Permissions and ownership

We honor `PUID`/`PGID`:

* Directories created with `install -d -m 0775 -o $PUID -g $PGID`
* `rsync` uses `--chown=$PUID:$PGID`
* Default matches Unraid (`nobody:users` → `99:100`)

---

## Logging

* All stdout/stderr is **tee’d** to `/logs/plexcache.log`.
* Start of run, free-space plan, copy/skip decisions, and the optional move-back phase are logged.
* Scheduler lines at container start:

  * Daily: `scheduler: daily at 03:15` + `next run: …`
  * Cron: `scheduler: cron '…'`

---

## Build and restart helper

Create `/mnt/user/appdata/plexcache/build/build-and-restart.sh`:

```bash
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

# Version tag for Unraid row, plus :local for development
V=$(git describe --tags --always --dirty 2>/dev/null || echo "v$(date +%Y%m%d-%H%M)")
R=$(git rev-parse --short HEAD 2>/dev/null || echo "local")
D=$(date -u +%Y-%m-%dT%H:%M:%SZ)

docker build \
  --build-arg VERSION="$V" \
  --build-arg VCS_REF="$R" \
  --build-arg BUILD_DATE="$D" \
  -t "plexcache:$V" \
  -t plexcache:local \
  .

echo "Built tags: plexcache:$V and plexcache:local"
echo "To see the version in Unraid, set the template Repository to plexcache:$V"
```

Make it executable:

```bash
chmod +x /mnt/user/appdata/plexcache/build/build-and-restart.sh
```

**Note:** Unraid’s “Update container” button pulls from registries and won’t run a local build. Use this script, then **Edit → Apply** in the GUI (or remove/re-add from the saved template).

---

## Update workflow

1. Edit scripts or selectors
2. `git commit -am "message"` (optional but helps stamp builds)
3. `./build-and-restart.sh`
4. In Unraid GUI:

   * Either switch **Repository** to the new printed tag (for a visible version), or keep `:local`
   * Click **Apply** to redeploy

---

## Troubleshooting

* **No env fields in Unraid form**
  Ensure your template is `version="2"` and each `<Config …/>` is directly under `<Container>`. Reopen Add-Container after saving.

* **“Missing on array” for warmed files**
  Fixed: we now treat `/mnt/user0/...` missing but `/mnt/cache/...` existing as “already on cache”.

* **Permissions show as root (orange)**
  Ensure `PUID=99 PGID=100` are set. For old files, run **Docker Safe New Perms**.

* **Plex unreachable**
  Don’t use `localhost` from inside the container. Use Plex’s LAN IP and mapped port.

* **Bridge vs Host**
  Bridge is fine (no inbound ports). Host not required.

---

## Roadmap (SQLite enhancement)

Upstream supports richer selection (per-user tokens, filters, sessions) we’ve intentionally deferred. A next step is to **read Plex’s SQLite database locally** (read-only) for:

* True **all-users On Deck** without collecting per-user tokens
* Faster queries and richer filters (age, play state, last viewed)
* Exact file paths without extra API calls

Plan:

1. Add an optional `/plexdb` bind mount to Plex’s database path (read-only).
2. Implement `selector_sqlite.py` that queries the DB:

   * Map metadata to media parts and on-disk paths
   * Respect `PLEX_PATH_MAP`
   * Expose selection flags similar to today’s envs
3. Gate it behind `PLEXCACHE_SELECTOR=sqlite|api` with `api` as default.

This README plus the current scripts provide enough context for a new assistant to implement that cleanly.

---

## Credits and license

* **Upstream:** [bexem/PlexCache](https://github.com/bexem/PlexCache) — original idea and Python script to warm cache based on Plex metadata.
* **This wrapper:** Unraid-specific containerization, selectors, and rsync-based warm/move logic.

Upstream licensing applies to upstream code. Wrapper scripts and Docker assets should follow a compatible permissive license (e.g. MIT) — include a LICENSE file mirroring upstream compatibility when you publish.

---

If you want this merged into Community Apps later:

* Push code to GitHub (Dockerfile + scripts)
* Build and push images to GHCR/Docker Hub
* Host the Unraid template in a feed repo
* Submit the feed URL to CA

Until then, this local build + template runs happily on your server with sane defaults.
