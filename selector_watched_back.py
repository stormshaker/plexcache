import os
import sys
import datetime as dt
import requests
from plexapi.server import PlexServer

def env_bool(key: str, default=False) -> bool:
    v = os.environ.get(key)
    if v is None:
        return default
    return str(v).lower() in ("1","true","yes","on")

def env_int(key: str, default: int) -> int:
    try:
        return int(os.environ.get(key, str(default)))
    except Exception:
        return default

def env_list(key: str):
    v = os.environ.get(key, "").strip()
    if not v:
        return []
    return [x.strip() for x in v.split(",") if x.strip()]

def apply_path_map(path: str) -> str:
    """
    Translate container-internal paths (e.g. /data/...) to host paths.
    PLEX_PATH_MAP example: "/data=/mnt/user,/media=/mnt/user"
    """
    maps = os.environ.get("PLEX_PATH_MAP", "")
    for pair in maps.split(","):
        pair = pair.strip()
        if not pair or "=" not in pair:
            continue
        src, dst = pair.split("=", 1)
        src = src.rstrip("/")
        dst = dst.rstrip("/")
        if src and path.startswith(src + "/"):
            return path.replace(src, dst, 1)
    return path

def filter_by_libraries(item, include_names: set, only_names: set) -> bool:
    lib = getattr(item, "librarySectionTitle", None)
    if include_names and lib not in include_names:
        return False
    if only_names and lib not in only_names:
        return False
    return True

def main():
    baseurl = os.environ.get("PLEX_BASEURL")
    token   = os.environ.get("PLEX_TOKEN")
    if not baseurl or not token:
        print("[selector_watched_back] PLEX_BASEURL and PLEX_TOKEN required", file=sys.stderr)
        sys.exit(2)

    # roots
    array_root = os.environ.get("PLEXCACHE_ARRAY_ROOT", "/mnt/user0").rstrip("/")
    cache_root = os.environ.get("PLEXCACHE_CACHE_ROOT", "/mnt/cache").rstrip("/")

    # knobs
    skip_if_playing = env_bool("PLEXCACHE_SKIP_IF_PLAYING", True)
    min_age_days    = env_int("PLEXCACHE_MOVE_BACK_MIN_AGE_DAYS", 0)
    include_libs    = set(env_list("PLEX_LIBRARIES"))
    only_libs       = set(env_list("PLEXCACHE_LIBRARIES_ONLY"))

    # Plex session
    sess = requests.Session()
    sess.verify = env_bool("PLEX_SSL_VERIFY", True)
    try:
        plex = PlexServer(baseurl, token, session=sess)
    except Exception as e:
        print(f"[selector_watched_back] plex connect failed: {e}", file=sys.stderr)
        sys.exit(3)

    # currently playing set (skip)
    playing = set()
    if skip_if_playing:
        try:
            for s in plex.sessions():
                for m in getattr(s, "media", []) or []:
                    for p in getattr(m, "parts", []) or []:
                        if p.file:
                            playing.add(p.file)
        except Exception:
            pass

    # cutoff time
    cutoff = None
    if min_age_days > 0:
        cutoff = dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=min_age_days)

    out = []

    # scan all sections and gather watched items whose file resides on cache
    for lib in plex.library.sections():
        try:
            for it in lib.all():
                # watched?
                if getattr(it, "viewCount", 0) < 1:
                    continue
                # library filtering
                if not filter_by_libraries(it, include_libs, only_libs):
                    continue
                # age filter
                lv = getattr(it, "lastViewedAt", None)
                if cutoff and isinstance(lv, dt.datetime):
                    # lastViewedAt from plexapi is tz-aware or naive local; make it UTC if needed
                    if lv.tzinfo is None:
                        lv = lv.replace(tzinfo=dt.timezone.utc)
                    if lv > cutoff:
                        continue

                # parts
                for m in getattr(it, "media", []) or []:
                    for p in getattr(m, "parts", []) or []:
                        if not p.file:
                            continue
                        if skip_if_playing and p.file in playing:
                            continue

                        # Map container path -> host
                        host_path = apply_path_map(p.file)

                        # We want the *cache* path as the source to move back
                        # Prefer direct cache_root if detectable, else derive from array/user path
                        candidates = []
                        if host_path.startswith(cache_root + "/"):
                            candidates.append(host_path)
                        if host_path.startswith(array_root + "/"):
                            candidates.append(host_path.replace(array_root, cache_root, 1))
                        if host_path.startswith("/mnt/user/"):
                            candidates.append(host_path.replace("/mnt/user", cache_root, 1))

                        # choose the first existing candidate under cache_root
                        cache_src = next((c for c in candidates if c.startswith(cache_root + "/") and os.path.isfile(c)), None)
                        if cache_src:
                            out.append(cache_src)
        except Exception:
            # ignore flaky sections and keep going
            continue

    # de-dup preserving order and print cache paths
    seen = set()
    for p in out:
        if p in seen:
            continue
        seen.add(p)
        print(p)

if __name__ == "__main__":
    main()
