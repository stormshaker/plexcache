FROM python:3.11-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    rsync ca-certificates tzdata busybox unzip curl \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/plexcache

# fetch upstream source without a fork
ADD https://codeload.github.com/bexem/PlexCache/zip/refs/heads/main /tmp/plexcache.zip
RUN unzip /tmp/plexcache.zip -d /tmp && \
    cp -r /tmp/PlexCache-main/* /opt/plexcache && \
    rm -rf /tmp/PlexCache-main /tmp/plexcache.zip

# python deps
RUN pip install --no-cache-dir plexapi requests

# our runtime helpers
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY run_once.sh   /usr/local/bin/run_once.sh
RUN chmod +x /usr/local/bin/*.sh

# keep upstream and use a launcher to generate settings from env, instead of replacing plexcache.py
COPY selector.py /opt/plexcache/selector.py
COPY selector_watched_back.py /opt/plexcache/selector_watched_back.py

# sane defaults for Unraid
ENV TZ=Australia/Sydney
ENV PLEXCACHE_ARRAY_ROOT=/mnt/user0
ENV PLEXCACHE_CACHE_ROOT=/mnt/cache
ENV PLEXCACHE_CONFIG=/config/plexcache_settings.json
ENV PLEXCACHE_LOG=/logs/plexcache.log
ENV PLEXCACHE_TIME=03:15
ENV PLEXCACHE_CRON=
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

