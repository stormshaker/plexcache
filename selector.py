# selector.py
import os
import sys
import requests
from plexapi.server import PlexServer

# ---------- helpers ----------

def env_bool(key: str, default: bool = False) -> bool:
    v = os.environ.get(key, "")
    if v == "" and default is not None:
        return default
    return str(v).lower() in ("1", "true", "yes", "on")

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
    Translate container-internal paths to host paths.
    Example env: PLEX_PATH_MAP="/data=/mnt/user,/media=/mnt/user"
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

def normalize_to_array_root(p: str, array_root: str) -> str:
    """
    Force anything under /mnt/user to the array-only root (/mnt/user0 by default).
    """
    array_root = array_root.rstrip("/")
    if p.startswith("/mnt/user/"):
        return p.replace("/mnt/user", array_root, 1)
    return p

def filter_by_libraries(item, include_names: set, only_names: set) -> bool:
    """
    Keep the item if it passes library filters.
    include_names = PLEX_LIBRARIES (optional inclusive filter)
    only_names    = PLEXCACHE_LIBRARIES_ONLY (hard restriction)
    """
    lib = getattr(item, "librarySectionTitle", None)
    if include_names and lib not in include_names:
        return False
    if only_names and lib not in only_names:
        return False
    return True

# ---------- main ----------

def main():
    baseurl = os.environ.get("PLEX_BASEURL")
    token   = os.environ.get("PLEX_TOKEN")
    if not baseurl or not token:
        # Fail quietly to stdout expectations
        print("[selector] PLEX_BASEURL and PLEX_TOKEN required", file=sys.stderr)
        sys.exit(2)

    # knobs
    ondeck_enabled      = env_bool("PLEXCACHE_ONDECK", True)
    ondeck_count        = env_int("PLEXCACHE_ONDECK_COUNT", 30)
    watchlist_enabled   = env_bool("PLEXCACHE_WATCHLIST", False)
    watchlist_count     = env_int("PLEXCACHE_WATCHLIST_COUNT", 20)
    max_items           = env_int("PLEXCACHE_MAX_ITEMS", 500)

    include_libs = set(env_list("PLEX_LIBRARIES"))               # names or section titles
    only_libs    = set(env_list("PLEXCACHE_LIBRARIES_ONLY"))     # hard restrict

    array_root = os.environ.get("PLEXCACHE_ARRAY_ROOT", "/mnt/user0")

    # Plex session (ssl verify can be disabled if needed)
    sess = requests.Session()
    ssl_verify = env_bool("PLEX_SSL_VERIFY", True)
    sess.verify = ssl_verify

    try:
        plex = PlexServer(baseurl, token, session=sess)
    except Exception as e:
        print(f"[selector] plex connect failed: {e}", file=sys.stderr)
        sys.exit(3)

    paths = []

    # ---- On Deck (current account) ----
    if ondeck_enabled:
        try:
            items = plex.library.onDeck()
            if ondeck_count > 0:
                items = items[:ondeck_count]
            for it in items:
                if not filter_by_libraries(it, include_libs, only_libs):
                    continue
                for media in getattr(it, "media", []) or []:
                    for part in getattr(media, "parts", []) or []:
                        if part.file:
                            paths.append(part.file)
        except Exception:
            # keep going
            pass

    # ---- Watchlist (current account) ----
    if watchlist_enabled:
        try:
            # watchlist may include items not in local libs; skip those without a file
            items = plex.watchlist()
            if watchlist_count > 0:
                items = items[:watchlist_count]
            for it in items:
                # Some watchlist entries are "remote" and have no media/parts locally
                if not filter_by_libraries(it, include_libs, only_libs):
                    # if it's not even in a library, lib filter will drop it; that's fine
                    pass
                for media in getattr(it, "media", []) or []:
                    for part in getattr(media, "parts", []) or []:
                        if part.file:
                            paths.append(part.file)
        except Exception:
            # not fatal if watchlist isn't available
            pass

    # de-duplicate preserving order
    seen = set()
    final = []
    for p in paths:
        if p in seen:
            continue
        seen.add(p)
        final.append(p)
        if len(final) >= max_items:
            break

    # apply mapping and force array root, then print
    for p in final:
        m = apply_path_map(p)                      # e.g. /data -> /mnt/user
        m = normalize_to_array_root(m, array_root) # /mnt/user -> /mnt/user0
        print(m)

if __name__ == "__main__":
    main()
