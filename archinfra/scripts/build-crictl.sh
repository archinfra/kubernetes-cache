#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

component=crictl
work="$WORK_DIR/$component"
context="$work/context"
archive="$context/cri/crictl.tar.gz"

# Select per-arch upstream URL/SHA (release lock is canonical amd64; *_ARM64 variants used when ARCH=arm64).
case "${ARCH:-amd64}" in
  arm64)
    CRICTL_URL="${CRICTL_URL_ARM64}"
    CRICTL_SHA256="${CRICTL_SHA256_ARM64}"
    CRICTL_CACHE_TAG="${CRICTL_CACHE_TAG_ARM64}"
    ;;
esac

rm -rf "$work"
mkdir -p "$context/cri"
provenance_begin "$component"
write_release_summary

require_cmd curl sha256sum tar docker

download "$CRICTL_URL" "$archive"
verify_sha256 "$CRICTL_SHA256" "$archive"
record_file "$component" "crictl-${CRICTL_VERSION}" "$CRICTL_URL" "$archive"

mkdir -p "$work/inspect"
tar -xzf "$archive" -C "$work/inspect" crictl
chmod +x "$work/inspect/crictl"
if [[ "$ARCH" == "amd64" ]]; then
  "$work/inspect/crictl" --version | tee "$OUT_DIR/crictl.version.txt"
fi
# arm64 crictl cannot run on the x86_64 runner; archive is pinned by sha256.

provenance_add "$component" version "$CRICTL_VERSION"
provenance_add "$component" kubernetes_minor "1.36"
provenance_add "$component" scope "crictl-only; CRI-O intentionally excluded"

cat > "$context/Dockerfile" <<'EOF'
FROM scratch
COPY cri /cri
EOF

oci_build_push "$component" "$context" "$context/Dockerfile" "$CRICTL_CACHE_TAG"

log "done: $REGISTRY/$REPOSITORY:$CRICTL_CACHE_TAG"
