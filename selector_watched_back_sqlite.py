#!/usr/bin/env python3
"""
selector_watched_back_sqlite.py - Query Plex SQLite database for watched items on cache.
Supports all users without requiring per-user tokens.
"""
import os
import sys
import sqlite3
import datetime as dt
from typing import List, Set

# ---------- helpers ----------

def env_bool(key: str, default=False) -> bool:
    v = os.environ.get(key)
    if v is None:
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

# ---------- database queries ----------

def get_watched_items(db_path: str, include_libs: Set[str], only_libs: Set[str], 
                     min_age_days: int, cache_root: str, array_root: str) -> List[str]:
    """
    Query watched items for all users that are currently on cache.
    Returns list of cache file paths.
    """
    conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    cursor = conn.cursor()
    
    results = []
    
    try:
        # Calculate cutoff timestamp if age filter is enabled
        cutoff_timestamp = None
        if min_age_days > 0:
            cutoff_time = dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=min_age_days)
            cutoff_timestamp = int(cutoff_time.timestamp())
        
        # Query watched items across all users
        # An item is "watched" if ANY user has watched it (viewed_at IS NOT NULL)
        query = """
        SELECT DISTINCT
            mi.id as metadata_id,
            mi.title,
            ls.name as library_name,
            mp.file as file_path,
            MAX(miv.viewed_at) as last_viewed_at
        FROM metadata_items mi
        JOIN metadata_item_views miv ON mi.guid = miv.guid
        JOIN library_sections ls ON mi.library_section_id = ls.id
        JOIN media_items med ON mi.id = med.metadata_item_id
        JOIN media_parts mp ON med.id = mp.media_item_id
        WHERE miv.viewed_at IS NOT NULL
            AND mp.file IS NOT NULL
            AND mi.metadata_type IN (1, 4)  -- 1=Movie, 4=Episode
        GROUP BY mi.id, mp.file
        """
        
        # Add age filter if specified
        if cutoff_timestamp:
            query += f" HAVING last_viewed_at < {cutoff_timestamp}"
        
        cursor.execute(query)
        
        for row in cursor.fetchall():
            library_name = row['library_name']
            
            # Apply library filters
            if include_libs and library_name not in include_libs:
                continue
            if only_libs and library_name not in only_libs:
                continue
            
            file_path = row['file_path']
            
            # Map to host path
            host_path = apply_path_map(file_path)
            
            # Check if file exists on cache
            # Try multiple possible cache paths
            cache_root_clean = cache_root.rstrip("/")
            array_root_clean = array_root.rstrip("/")
            
            candidates = []
            if host_path.startswith(cache_root_clean + "/"):
                candidates.append(host_path)
            if host_path.startswith(array_root_clean + "/"):
                candidates.append(host_path.replace(array_root_clean, cache_root_clean, 1))
            if host_path.startswith("/mnt/user/"):
                candidates.append(host_path.replace("/mnt/user", cache_root_clean, 1))
            
            # Find first existing cache file
            cache_src = next((c for c in candidates if c.startswith(cache_root_clean + "/") and os.path.isfile(c)), None)
            if cache_src:
                results.append(cache_src)
        
    except Exception as e:
        print(f"[ERROR] Watched items query error: {e}", file=sys.stderr)
    finally:
        conn.close()
    
    return results

def get_playing_files(db_path: str) -> Set[str]:
    """
    Query currently playing files from sessions table.
    Note: This may not be available in SQLite - Plex stores active sessions in memory/redis.
    We'll return an empty set for now and rely on API fallback if needed.
    """
    # Plex doesn't store active playback sessions in the main SQLite database
    # They're in memory/redis, so we can't query them via SQLite
    # The API selector handles this better
    return set()

# ---------- main ----------

def main():
    # Database path
    plexdb_root = os.environ.get("PLEXCACHE_PLEXDB_PATH", "/plexdb")
    db_path = os.path.join(plexdb_root, "Library/Application Support/Plex Media Server/Plug-in Support/Databases/com.plexapp.plugins.library.db")
    
    if not os.path.exists(db_path):
        print(f"[ERROR] Plex database not found at: {db_path}", file=sys.stderr)
        print("[ERROR] Ensure PLEXCACHE_PLEXDB_PATH is set correctly and mounted", file=sys.stderr)
        sys.exit(2)
    
    # Configuration
    array_root = os.environ.get("PLEXCACHE_ARRAY_ROOT", "/mnt/user0").rstrip("/")
    cache_root = os.environ.get("PLEXCACHE_CACHE_ROOT", "/mnt/cache").rstrip("/")
    
    skip_if_playing = env_bool("PLEXCACHE_SKIP_IF_PLAYING", True)
    min_age_days = env_int("PLEXCACHE_MOVE_BACK_MIN_AGE_DAYS", 0)
    include_libs = set(env_list("PLEX_LIBRARIES"))
    only_libs = set(env_list("PLEXCACHE_LIBRARIES_ONLY"))
    
    # Get playing files (empty for SQLite, but keeping structure for consistency)
    playing_files = set()
    if skip_if_playing:
        # SQLite doesn't have session info, but we keep the structure
        # In practice, the main run_once.sh also checks for playing files
        playing_files = get_playing_files(db_path)
    
    # Get watched items on cache
    watched_items = get_watched_items(db_path, include_libs, only_libs, 
                                     min_age_days, cache_root, array_root)
    
    # Deduplicate and filter out playing files
    seen = set()
    for cache_path in watched_items:
        if cache_path in seen:
            continue
        if skip_if_playing and cache_path in playing_files:
            continue
        seen.add(cache_path)
        print(cache_path)

if __name__ == "__main__":
    main()


