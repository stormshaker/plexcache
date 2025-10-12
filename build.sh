#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

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
echo "Tip: set the Unraid template Repository to plexcache:$V for a visible version."
