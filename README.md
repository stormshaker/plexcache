# PlexCache for Unraid

Warm your Unraid cache with Plex "Continue Watching" items. Optionally move watched items back to the array. Safe, Unraid-specific paths. No symlink tricks. Minimal knobs, sensible defaults.

This is a lightweight Docker container designed for **Unraid servers** that:

* Reads Plex's SQLite database directly to identify "On Deck" items from **all users**
* Copies those items from **/mnt/user0** (array only) to **/mnt/cache**
* Optionally moves watched items back from cache to array
* Honors Unraid permissions via `PUID=99` `PGID=100`
* Schedules daily runs or uses cron expressions
* Provides clean logging with startup/completion summaries

> Credit: Inspired by **[bexem/PlexCache](https://github.com/bexem/PlexCache)**. This implementation uses direct SQLite database access for performance and reliability, with Unraid-specific copy/move mechanics.

---

## Contents

* [What this does](#what-this-does)
* [Architecture](#architecture)
* [Requirements](#requirements)
* [Quick start](#quick-start)
* [Unraid template](#unraid-template)
* [Environment variables](#environment-variables)
* [Scheduling](#scheduling)
* [Permissions and ownership](#permissions-and-ownership)
* [Logging](#logging)
* [How On Deck selection works](#how-on-deck-selection-works)
* [Build script](#build-script)
* [Update workflow](#update-workflow)
* [Troubleshooting](#troubleshooting)

---

## What this does

* Reads Plex's SQLite database directly to gather **"Continue Watching"** items for **all users**
* Identifies:
  * Episodes you've started watching but haven't finished
  * Next unwatched episode of shows you're currently watching
  * Movies you've started but haven't finished
* Translates Plex media paths to Unraid host paths via `PLEX_PATH_MAP` (e.g. `/data=/mnt/user`)
* For each selected media file:
  * Plans copies that **fit** the cache free-space budget
  * **Copies** from `/mnt/user0/...` to `/mnt/cache/...`
  * Verifies sizes (optionally checksum on mismatch)
  * If `PLEXCACHE_WARM_MOVE=true` and not dry-run, **deletes the array source** after successful verify
  * Copies common sidecars (`srt`, `ass`, `sub`, `nfo`, `jpg`, `png`) if enabled
* Optional **move-back** phase: when `PLEXCACHE_MOVE_WATCHED_BACK=true`, watched items found on cache are copied back to the array and the cache copy is removed after verify
* Skips items already on cache on subsequent runs

---

## Architecture

```
Plex SQLite Database
   │
   ├─ selector_sqlite.py                   # Queries "Continue Watching" for all users
   ├─ selector_watched_back_sqlite.py      # Queries watched items for move-back
   └─ run_once.sh                          # Free-space planning → rsync warm/move → optional watched-back
        ├─ Safeguards: /mnt/user0 → /mnt/cache only
        ├─ PUID/PGID ownership
        ├─ Sidecars support
        └─ Clean logging with summaries

entrypoint.sh                              # Sets up scheduling (daily time or cron) + startup/completion summaries
Dockerfile                                 # Installs Python, rsync, and copies selector scripts
```

**Direct SQLite access:**
* Reads Plex's `com.plexapp.plugins.library.db` database
* No API authentication required
* Covers **all users** automatically
* Faster and more reliable than API-based selection

---

## Requirements

* Unraid with Docker
* Access to your Plex Media Server's database directory (typically `/mnt/user/appdata/plex/`)
* Your Plex container's library path mapping to build `PLEX_PATH_MAP` (e.g. Plex uses `/data` → host `/mnt/user`)

---

## Quick start

1. **Create directory structure:**

   ```bash
   mkdir -p /mnt/user/appdata/plexcache/build
   mkdir -p /mnt/user/appdata/plexcache/config
   mkdir -p /mnt/user/appdata/plexcache/logs
   ```

2. **Put these files in `/mnt/user/appdata/plexcache/build/`:**

   * `Dockerfile`
   * `entrypoint.sh`
   * `run_once.sh`
   * `selector_sqlite.py`
   * `selector_watched_back_sqlite.py`
   * `build.sh`

3. **Build the image:**

   ```bash
   cd /mnt/user/appdata/plexcache/build
   ./build.sh
   ```

4. **Add the container via Unraid GUI → Docker → Add Container**, set:

   * **Repository:** `plexcache:local` (or the versioned tag printed by the build script)
   * **Network:** Bridge (Host not required)
   * **Paths:**
     * `/mnt/user0` → `/mnt/user0` (Read/Write)
     * `/mnt/cache` → `/mnt/cache` (Read/Write)
     * `/config` → `/mnt/user/appdata/plexcache/config` (Read/Write)
     * `/logs` → `/mnt/user/appdata/plexcache/logs` (Read/Write)
     * **Required:** `/plexdb` → `/mnt/user/appdata/plex` (Read Only)
   * **Variables (minimum):**
     * `PLEX_PATH_MAP=/data=/mnt/user`
     * `PUID=99`
     * `PGID=100`
     * `PLEXCACHE_ONDECK=true`
     * `PLEXCACHE_WARM_MOVE=true`
     * `PLEXCACHE_TIME=03:15`

5. **Apply**, then check logs at `/mnt/user/appdata/plexcache/logs/plexcache.log`

---

## Unraid template

Save as `/boot/config/plugins/dockerMan/templates-user/my-PlexCache.xml`

Key template structure:

* `<Container version="2">`
* Each `<Config …/>` sits directly under `<Container>`
* Add an **Icon** path if you want a logo (e.g. `https://raw.githubusercontent.com/yourusername/plexcache/master/icon.png`)

Example minimal template:

```xml
<?xml version="1.0"?>
<Container version="2">
  <Name>PlexCache</Name>
  <Repository>plexcache:local</Repository>
  <Registry>local</Registry>
  <Network>bridge</Network>
  <Privileged>false</Privileged>
  <Support>https://github.com/yourusername/plexcache</Support>
  <Project>https://github.com/yourusername/plexcache</Project>
  <Overview>Warm Unraid cache with Plex Continue Watching items using direct SQLite database access.</Overview>
  <Category>MediaApp:Other MediaServer:Other</Category>
  
  <Config Name="Array Root" Target="/mnt/user0" Default="/mnt/user0" Mode="rw" Description="Source (array only)" Type="Path" Display="always" Required="true" Mask="false">/mnt/user0</Config>
  <Config Name="Cache Root" Target="/mnt/cache" Default="/mnt/cache" Mode="rw" Description="Destination (cache)" Type="Path" Display="always" Required="true" Mask="false">/mnt/cache</Config>
  <Config Name="Config" Target="/config" Default="/mnt/user/appdata/plexcache/config" Mode="rw" Description="Config directory" Type="Path" Display="advanced" Required="true" Mask="false">/mnt/user/appdata/plexcache/config</Config>
  <Config Name="Logs" Target="/logs" Default="/mnt/user/appdata/plexcache/logs" Mode="rw" Description="Log directory" Type="Path" Display="advanced" Required="true" Mask="false">/mnt/user/appdata/plexcache/logs</Config>
  <Config Name="Plex Database" Target="/plexdb" Default="/mnt/user/appdata/plex" Mode="ro" Description="Plex appdata root (for SQLite access)" Type="Path" Display="always" Required="true" Mask="false">/mnt/user/appdata/plex</Config>
  
  <Config Name="PLEX_PATH_MAP" Target="PLEX_PATH_MAP" Default="/data=/mnt/user" Mode="" Description="Path mapping from Plex to Unraid (e.g. /data=/mnt/user)" Type="Variable" Display="always" Required="true" Mask="false">/data=/mnt/user</Config>
  <Config Name="PUID" Target="PUID" Default="99" Mode="" Description="User ID (99=nobody)" Type="Variable" Display="advanced" Required="true" Mask="false">99</Config>
  <Config Name="PGID" Target="PGID" Default="100" Mode="" Description="Group ID (100=users)" Type="Variable" Display="advanced" Required="true" Mask="false">100</Config>
  
  <Config Name="PLEXCACHE_ONDECK" Target="PLEXCACHE_ONDECK" Default="true" Mode="" Description="Include On Deck items" Type="Variable" Display="always" Required="false" Mask="false">true</Config>
  <Config Name="PLEXCACHE_ONDECK_COUNT" Target="PLEXCACHE_ONDECK_COUNT" Default="10" Mode="" Description="Max On Deck items per user" Type="Variable" Display="always" Required="false" Mask="false">10</Config>
  <Config Name="PLEXCACHE_WARM_MOVE" Target="PLEXCACHE_WARM_MOVE" Default="true" Mode="" Description="Delete array source after copy (prevents duplicates)" Type="Variable" Display="always" Required="false" Mask="false">true</Config>
  <Config Name="PLEXCACHE_TIME" Target="PLEXCACHE_TIME" Default="03:15" Mode="" Description="Daily run time (HH:MM)" Type="Variable" Display="always" Required="false" Mask="false">03:15</Config>
  <Config Name="PLEXCACHE_LOG_LEVEL" Target="PLEXCACHE_LOG_LEVEL" Default="info" Mode="" Description="Log level (error, warn, info, debug)" Type="Variable" Display="advanced" Required="false" Mask="false">info</Config>
</Container>
```

---

## Environment variables

| Variable                           | Default           | Purpose                                                                                             |
| ---------------------------------- | ----------------- | --------------------------------------------------------------------------------------------------- |
| `PLEX_PATH_MAP`                    | `/data=/mnt/user` | Translate Plex paths to Unraid host paths. Format: `plex_path=host_path`. Comma-separated for multiple mappings. |
| `PLEX_LIBRARIES`                   | *(blank)*         | Comma list of library names to include (e.g. `Movies,TV Shows`). Blank = all libraries.            |
| `PLEXCACHE_PLEXDB_PATH`            | `/plexdb`         | Container path to Plex database root. Bind mount your Plex appdata here.                           |
| `PLEXCACHE_ONDECK`                 | `true`            | Include "Continue Watching" items (in-progress and next episodes).                                  |
| `PLEXCACHE_ONDECK_COUNT`           | `10`              | Max "Continue Watching" items per user.                                                             |
| `PLEXCACHE_MAX_ITEMS`              | `100`             | Hard cap for total items (across all users and sources).                                            |
| `PLEXCACHE_ARRAY_ROOT`             | `/mnt/user0`      | Source root (array only). Mirrors Unraid Mover behavior.                                            |
| `PLEXCACHE_CACHE_ROOT`             | `/mnt/cache`      | Destination cache root.                                                                             |
| `PLEXCACHE_WARM_MOVE`              | `true`            | Copy to cache then delete array source after verify. Prevents duplicates in user shares.           |
| `PLEXCACHE_WARM_SIDECARS`          | `true`            | Copy subtitle and metadata sidecars with the media during warm.                                     |
| `PLEXCACHE_MOVE_WATCHED_BACK`      | `false`           | Move fully watched items found on cache back to array and remove cache copy.                        |
| `PLEXCACHE_MOVE_BACK_MIN_AGE_DAYS` | `0`               | Only move back if last viewed older than N days. 0 = any age.                                       |
| `PLEXCACHE_MOVE_BACK_SIDECARS`     | `true`            | Move sidecars together with the media on move-back.                                                 |
| `PLEXCACHE_MIN_FREE_GB`            | `20`              | Leave at least this much free space on cache after the run.                                         |
| `PLEXCACHE_RESERVE_GB`             | `10`              | Extra buffer on top of MIN_FREE that's never touched.                                               |
| `PLEXCACHE_TRIM_PLAN`              | `true`            | If the plan doesn't fit, trim it to what fits; if `false`, abort the entire run instead.           |
| `PLEXCACHE_TIME`                   | `03:15`           | Daily time scheduler (HH:MM format). Leave blank if using CRON or RUN_IMMEDIATELY.                 |
| `PLEXCACHE_CRON`                   | *(blank)*         | Cron expression alternative (e.g. `0 */2 * * *` for every 2 hours).                                |
| `PLEXCACHE_RUN_IMMEDIATELY`        | `false`           | If `true`, run once immediately, wait for key press, then exit. Perfect for testing.               |
| `PLEXCACHE_LOG_LEVEL`              | `info`            | Log verbosity: `error`, `warn`, `info`, or `debug`. Use `debug` for troubleshooting rsync issues.  |
| `PLEXCACHE_LOG`                    | `/logs/plexcache.log` | Log file path.                                                                                  |
| `PUID`                             | `99`              | Owner UID (Unraid `nobody`).                                                                        |
| `PGID`                             | `100`             | Group GID (Unraid `users`).                                                                         |
| `RSYNC_DRY_RUN`                    | `false`           | If `true`, add `--dry-run` to rsync and don't modify files. Perfect for testing plans.             |

---

## Scheduling

**Three scheduling modes (use only one):**

1. **Daily time (recommended):** Set `PLEXCACHE_TIME=HH:MM` (e.g. `03:15`). The container logs "next run at..." and sleeps until that time daily.

2. **Cron expression:** Set `PLEXCACHE_CRON` to a standard expression (e.g. `0 */2 * * *` for every 2 hours). BusyBox `crond` is used.

3. **Run immediately (testing):** Set `PLEXCACHE_RUN_IMMEDIATELY=true`. Executes once, shows results in the console, waits for key press, then exits. Great for testing changes with `RSYNC_DRY_RUN=true`.

The container logs show:
* Startup summary with configuration
* Progress during execution (detail depends on `PLEXCACHE_LOG_LEVEL`)
* Completion summary with file counts

---

## Permissions and ownership

We honor `PUID`/`PGID` for Unraid compatibility:

* Directories created with `install -d -m 0775 -o $PUID -g $PGID`
* `rsync` uses `--chown=$PUID:$PGID`
* Default matches Unraid standards: `nobody:users` → `99:100`

All files copied to cache will have correct Unraid ownership.

---

## Logging

* **Detailed logs:** Written to `/logs/plexcache.log` (rotated on each run, previous log saved with timestamp)
* **Container logs:** Show startup and completion summaries only (not duplicated in detail log)

**Log levels** (set via `PLEXCACHE_LOG_LEVEL`):
* `error` - Only errors
* `warn` - Warnings and errors
* `info` (default) - High-level progress: start/end, summaries, file counts
* `debug` - Verbose details: every file, rsync commands, skip reasons, SQL queries

**Container log format:**
```
[plexcache] ===============================================
[plexcache] PlexCache run started: Sun Oct 13 03:15:00 UTC 2025
[plexcache] Log level: info
[plexcache] Detailed logs: /logs/plexcache.log
[plexcache] Dry run: 0 | Move warm: 1 | Move back: 0
[plexcache] Array: /mnt/user0 | Cache: /mnt/cache
[plexcache] ===============================================
...
[plexcache] Warm/copy phase complete: 15 copied
[plexcache] ===============================================
[plexcache] PlexCache run ended: Sun Oct 13 03:45:23 UTC 2025
[plexcache] ===============================================
```

**Detailed log format** (`/logs/plexcache.log`):
```
[INFO] Starting PlexCache run at 2025-10-13 03:15:00
[INFO] Querying Plex database for On Deck items...
[DEBUG] Using database: /plexdb/Library/Application Support/Plex Media Server/Plug-in Support/Databases/com.plexapp.plugins.library.db
[INFO] Selected 15 items for user stormshaker
[INFO] Planning copies...
[DEBUG] Planning: /mnt/user/media/TV Shows/Show Name/Season 01/S01E01.mkv (4.2 GB)
[INFO] Copying /mnt/user0/media/TV Shows/Show Name/Season 01/S01E01.mkv → /mnt/cache/media/TV Shows/Show Name/Season 01/S01E01.mkv
[DEBUG]   rsync -avh --progress --no-perms --chmod=ugo=rwX --chown=99:100 --size-only --inplace '/mnt/user0/media/TV Shows/Show Name/Season 01/S01E01.mkv' '/mnt/cache/media/TV Shows/Show Name/Season 01/S01E01.mkv'
[INFO] Verified: sizes match (4.2 GB)
[INFO] Deleted source: /mnt/user0/media/TV Shows/Show Name/Season 01/S01E01.mkv
...
[INFO] Warm/copy phase complete: 15 copied (15 moved - source deleted after verify)
```

---

## How On Deck selection works

The SQLite selector queries Plex's database (`com.plexapp.plugins.library.db`) to replicate Plex's "Continue Watching" algorithm:

1. **For each user account** in the Plex database:
   * Find episodes with `view_offset > 0` (in-progress episodes)
   * Find the **next unwatched episode** for each show currently being watched
   * Find movies with `view_offset > 0` (in-progress movies)

2. **Sorting:**
   * Items are sorted by most recent viewing activity
   * For shows, we use the **most recent viewing activity of the entire show** (not just that episode) to keep "currently watching" shows at the top

3. **Limits:**
   * Up to `PLEXCACHE_ONDECK_COUNT` items per user (default: 10)
   * Hard cap of `PLEXCACHE_MAX_ITEMS` total across all users (default: 100)

4. **Library filters:**
   * If `PLEX_LIBRARIES` is set (e.g. `Movies,TV Shows`), only those libraries are included
   * If blank, all Movie and TV libraries are included

5. **Path translation:**
   * Plex database stores paths like `/data/media/Movies/...`
   * We translate using `PLEX_PATH_MAP` to `/mnt/user/media/Movies/...`
   * We then check if the file exists on array (`/mnt/user0/...`) and copy to cache (`/mnt/cache/...`)

**Result:** The selector identifies exactly what Plex would show in each user's "Continue Watching" row, ensuring the most relevant content is warmed to cache.

---

## Build script

The included `build.sh` script:

1. Gets a version tag from git (`git describe --tags --always --dirty`)
2. Builds the Docker image with labels
3. Tags as both `plexcache:<version>` and `plexcache:local`
4. Prints the version tag for use in Unraid's template

```bash
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

# Version tag from git
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

echo ""
echo "Built tags: plexcache:$V and plexcache:local"
echo "Tip: set the Unraid template Repository to plexcache:$V for a visible version."
```

**Note:** The `-dirty` suffix appears if you have uncommitted changes. Commit your changes to get a clean version tag.

---

## Update workflow

1. Edit scripts or selectors
2. `git add -A && git commit -m "description of changes"`
3. `./build.sh`
4. In Unraid GUI:
   * Keep **Repository** as `plexcache:local` or switch to the new version tag
   * Click **Apply** to redeploy

The container will use the new image on next start.

---

## Troubleshooting

**"Plex database not found"**

* Ensure `/plexdb` mount is correct and points to your Plex appdata root (e.g. `/mnt/user/appdata/plex/`)
* The selector looks for `Library/Application Support/Plex Media Server/Plug-in Support/Databases/com.plexapp.plugins.library.db` under that mount
* Check: `docker exec <container_name> ls -la "/plexdb/Library/Application Support/Plex Media Server/Plug-in Support/Databases/"`

**"No items found"**

* Verify users have "Continue Watching" items in Plex UI
* Check `PLEX_LIBRARIES` filter - if set, only those libraries are included
* Verify `PLEX_PATH_MAP` is correct - paths must translate from Plex's paths to your Unraid paths
* Set `PLEXCACHE_LOG_LEVEL=debug` to see SQL queries and results

**"Missing on array" for warmed files**

* This is expected behavior after successful warm with `PLEXCACHE_WARM_MOVE=true`
* The file now exists only on cache (`/mnt/cache/...`), not array (`/mnt/user0/...`)
* User share (`/mnt/user/...`) will show the file from cache location

**Permissions show as root (orange in Unraid)**

* Ensure `PUID=99` and `PGID=100` are set in template
* For existing files with wrong ownership, run **Docker Safe New Perms** in Unraid

**Files copied multiple times / duplicates**

* Check that `PLEXCACHE_WARM_MOVE=true` (default)
* This deletes array source after successful copy, preventing user share duplicates
* If `false`, file exists in both array and cache, appearing twice in user shares

**Testing changes without modifying files**

* Set `PLEXCACHE_RUN_IMMEDIATELY=true` and `RSYNC_DRY_RUN=true`
* Container will run once, show what it would do, wait for key press, then exit
* No files are modified in dry-run mode

**Git "dirty" tag in build**

* The `-dirty` suffix means you have uncommitted changes
* Run `git status` and commit any changes: `git add -A && git commit -m "changes"`
* Rebuild with `./build.sh` to get a clean version tag

**Log file too large**

* Adjust `PLEXCACHE_LOG_LEVEL` to `warn` or `error` for less verbosity
* Debug level logs every file and rsync command, which can be very verbose for large libraries

---

## Future enhancements

Potential features for future versions:

* Support for multiple path mappings in `PLEX_PATH_MAP`
* Integration with Unraid Mover to coordinate cache operations
* Web UI for configuration and monitoring
* Push to Community Apps (requires hosting on Docker Hub/GHCR)

---

## Implementation comments

Personally, this was a good experience in learning how Docker containers are built, and my first time trying an almost fully
'vibe-coded' project, using Cursor. That was simultaneously enlightening and quite frustrating, but hopefully the codebase
is simple enough that it can be maintained by hand, later. A breakthrough was providing a backup copy of my Plex database to
Cursor during development, so it could query away as much as it liked, to search for the right tables and columns.

I'm considering renaming this project. Whereis it is effectively attempts similar outcomes as
[bexem/PlexCache](https://github.com/bexem/PlexCache), it's a new codebase and not a fork. So, it probably needs a new identity.

---

## Credits

* **Inspiration:** [bexem/PlexCache](https://github.com/bexem/PlexCache) - original cache warming concept
* **This implementation:** Unraid-specific containerization with direct SQLite database access and rsync-based operations

This project uses Python 3 and rsync to safely manage cache warming based on Plex viewing activity.
