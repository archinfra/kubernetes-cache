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

require_cmd curl sha256sum tar docker file grep

download "$SEALOS_URL" "$archive"
verify_sha256 "$SEALOS_SHA256" "$archive"
record_file "$component" "sealos-${SEALOS_VERSION}" "$SEALOS_URL" "$archive"

tar -xzf "$archive" -C "$context/sealos"
chmod +x "$context/sealos/sealos" "$context/sealos/sealctl" "$context/sealos/image-cri-shim" 2>/dev/null || true

if [[ "$ARCH" == "amd64" ]]; then
  "$context/sealos/sealos" version | tee "$OUT_DIR/sealos.version.txt"
else
  # Do not execute arm64 binaries on the x86_64 GitHub runner. Verify the
  # extracted payload architecture instead so a mislabeled archive fails fast.
  for binary in sealos sealctl image-cri-shim; do
    if [[ -f "$context/sealos/$binary" ]]; then
      desc="$(file "$context/sealos/$binary")"
      printf '%s\n' "$desc" | tee -a "$OUT_DIR/sealos.arch.txt"
      printf '%s\n' "$desc" | grep -Eiq 'ARM aarch64|ARM64|aarch64' || {
        echo "ERROR: expected arm64 binary: $context/sealos/$binary" >&2
        exit 1
      }
    fi
  done
fi

provenance_add "$component" version "$SEALOS_VERSION"
provenance_add "$component" cache_base_image "scratch"

# This cache is only an artifact carrier for Sealos binaries. A runtime base
# image is unnecessary and, when pinned to an amd64-only Alpine manifest,
# corrupts the platform metadata of the arm64 cache image. Keep the cache
# platform-neutral at the filesystem layer and let buildx stamp linux/$ARCH.
cat > "$context/Dockerfile" <<'EOF'
FROM scratch
COPY sealos /sealos
EOF

oci_build_push "$component" "$context" "$context/Dockerfile" "$SEALOS_CACHE_TAG"

image="$REGISTRY/$REPOSITORY:$SEALOS_CACHE_TAG"
inspect_out="$OUT_DIR/sealos.imagetools.txt"
docker buildx imagetools inspect "$image" | tee "$inspect_out"

# buildx with provenance/SBOM produces an OCI index containing the target image
# plus attestation entries. Require the real target platform to be present.
if ! grep -Eq "Platform:[[:space:]]+linux/${ARCH}([[:space:]]|$)" "$inspect_out"; then
  echo "ERROR: published Sealos cache does not contain linux/$ARCH" >&2
  echo "  image: $image" >&2
  exit 1
fi

provenance_add "$component" verified_platform "linux/$ARCH"
log "verified platform: $image -> linux/$ARCH"
log "done: $image"
