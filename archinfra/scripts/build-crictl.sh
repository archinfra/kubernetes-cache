#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

component=crictl
work="$WORK_DIR/$component"
context="$work/context"
archive="$context/cri/crictl.tar.gz"

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
"$work/inspect/crictl" --version | tee "$OUT_DIR/crictl.version.txt"

provenance_add "$component" version "$CRICTL_VERSION"
provenance_add "$component" kubernetes_minor "1.36"
provenance_add "$component" scope "crictl-only; CRI-O intentionally excluded"

cat > "$context/Dockerfile" <<'EOF'
FROM scratch
COPY cri /cri
EOF

oci_build_push "$component" "$context" "$context/Dockerfile" "$CRICTL_CACHE_TAG"

log "done: $REGISTRY/$REPOSITORY:$CRICTL_CACHE_TAG"
