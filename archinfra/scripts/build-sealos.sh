#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

component=sealos
work="$WORK_DIR/$component"
context="$work/context"
archive="$work/sealos_${SEALOS_VERSION}_linux_${ARCH}.tar.gz"

# Select per-arch upstream URL/SHA (release lock is canonical amd64; *_ARM64 variants used when ARCH=arm64).
case "${ARCH:-amd64}" in
  arm64)
    SEALOS_URL="${SEALOS_URL_ARM64}"
    SEALOS_SHA256="${SEALOS_SHA256_ARM64}"
    SEALOS_CACHE_TAG="${SEALOS_CACHE_TAG_ARM64}"
    ;;
esac

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

if [[ "$ARCH" == "amd64" ]]; then
  "$context/sealos/sealos" version | tee "$OUT_DIR/sealos.version.txt"
fi
# arm64 sealos binary cannot run on the x86_64 runner; the archive is pinned by sha256.
provenance_add "$component" version "$SEALOS_VERSION"
provenance_add "$component" cache_base_image "$SEALOS_CACHE_BASE_IMAGE"

cat > "$context/Dockerfile" <<EOF
FROM $SEALOS_CACHE_BASE_IMAGE
COPY sealos /sealos
EOF

oci_build_push "$component" "$context" "$context/Dockerfile" "$SEALOS_CACHE_TAG"

log "done: $REGISTRY/$REPOSITORY:$SEALOS_CACHE_TAG"
