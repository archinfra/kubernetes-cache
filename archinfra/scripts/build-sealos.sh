#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

component=sealos
work="$WORK_DIR/$component"
context="$work/context"
archive="$work/sealos_${SEALOS_VERSION}_linux_${ARCH}.tar.gz"

rm -rf "$work"
mkdir -p "$context/sealos"
provenance_begin "$component"
write_release_summary

require_cmd curl sha256sum tar docker

download "$SEALOS_URL" "$archive"
verify_sha256 "$SEALOS_SHA256" "$archive"
record_file "$component" "sealos-${SEALOS_VERSION}" "$SEALOS_URL" "$archive"

tar -xzf "$archive" -C "$context/sealos"
chmod +x "$context/sealos/sealos" "$context/sealos/sealctl" "$context/sealos/image-cri-shim" 2>/dev/null || true

"$context/sealos/sealos" version | tee "$OUT_DIR/sealos.version.txt"
provenance_add "$component" version "$SEALOS_VERSION"
provenance_add "$component" cache_base_image "$SEALOS_CACHE_BASE_IMAGE"

cat > "$context/Dockerfile" <<EOF
FROM $SEALOS_CACHE_BASE_IMAGE
COPY sealos /sealos
EOF

oci_build_push "$component" "$context" "$context/Dockerfile" "$SEALOS_CACHE_TAG"

log "done: $REGISTRY/$REPOSITORY:$SEALOS_CACHE_TAG"
