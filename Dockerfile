FROM python:3.11-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    rsync ca-certificates tzdata busybox unzip curl \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/plexcache

# install python dependencies (only what we need for SQLite)
RUN pip install --no-cache-dir requests croniter

# our runtime helpers
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY run_once.sh   /usr/local/bin/run_once.sh
RUN chmod +x /usr/local/bin/*.sh

# Copy our SQLite selector scripts (all users via database)
COPY selector_sqlite.py /opt/plexcache/selector_sqlite.py
COPY selector_watched_back_sqlite.py /opt/plexcache/selector_watched_back_sqlite.py

# sane defaults for Unraid
ENV TZ=Australia/Sydney
ENV PYTHONUNBUFFERED=1
ENV PLEXCACHE_ARRAY_ROOT=/mnt/user0
ENV PLEXCACHE_CACHE_ROOT=/mnt/cache
ENV PLEXCACHE_CONFIG=/config/plexcache_settings.json
ENV PLEXCACHE_LOG=/logs/plexcache.log
ENV PLEXCACHE_TIME=03:15
ENV PLEXCACHE_CRON=
ENV PLEXCACHE_RUN_IMMEDIATELY=false
ENV PLEXCACHE_LOG_LEVEL=info
ENV PLEXCACHE_PLEXDB_PATH=/plexdb
ENV PLEXCACHE_ONDECK_COUNT=10
ENV PLEXCACHE_MAX_ITEMS=100
ENV PLEXCACHE_MIN_FREE_GB=20
ENV PLEXCACHE_RESERVE_GB=10
ENV PLEXCACHE_WARM_MOVE=true
ENV PLEXCACHE_WARM_SIDECARS=true
ENV PLEXCACHE_MOVE_WATCHED_BACK=false
ENV PLEXCACHE_MOVE_BACK_MIN_AGE_DAYS=0
ENV PLEXCACHE_MOVE_BACK_SIDECARS=true
ENV PLEXCACHE_TRIM_PLAN=true
ENV PLEXCACHE_ONDECK=true
ENV PLEX_LIBRARIES="Movies,TV Shows"
ENV PUID=99
ENV PGID=100

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

ARG VERSION=dev
ARG VCS_REF=local
ARG BUILD_DATE
LABEL org.opencontainers.image.title="PlexCache"
LABEL org.opencontainers.image.version="${VERSION}"
LABEL org.opencontainers.image.revision="${VCS_REF}"
LABEL org.opencontainers.image.created="${BUILD_DATE}"

