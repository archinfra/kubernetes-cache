#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

# Select per-arch upstream URL/SHA/tag. The release lock is canonical for amd64;
# ARM64 variants (present in the lock as *_ARM64) are used when ARCH=arm64.
case "${ARCH:-amd64}" in
  arm64)
    DOCKER_URL="${DOCKER_URL_ARM64}"
    DOCKER_SHA256="${DOCKER_SHA256_ARM64}"
    CRI_DOCKERD_URL="${CRI_DOCKERD_URL_ARM64}"
    CRI_DOCKERD_SHA256="${CRI_DOCKERD_SHA256_ARM64}"
    REGISTRY_URL="${REGISTRY_URL_ARM64}"
    REGISTRY_SHA256="${REGISTRY_SHA256_ARM64}"
    CONNTRACK_URL="${CONNTRACK_URL_ARM64}"
    LSOF_URL="${LSOF_URL_ARM64}"
    DOCKER_CACHE_TAG="${DOCKER_CACHE_TAG_ARM64}"
    ;;
esac

component=docker-runtime
work="$WORK_DIR/$component"
context="$work/context"
cri="$context/cri"

rm -rf "$work"
mkdir -p "$cri" "$work/inspect" "$work/registry"
provenance_begin "$component"
write_release_summary

require_cmd curl sha256sum tar docker file

# Docker Engine static bundle.
download "$DOCKER_URL" "$cri/docker.tgz"
verify_sha256 "$DOCKER_SHA256" "$cri/docker.tgz"
record_file "$component" "docker-${DOCKER_VERSION}" "$DOCKER_URL" "$cri/docker.tgz"

# Kubernetes CRI adapter for Docker.
download "$CRI_DOCKERD_URL" "$cri/cri-dockerd.tgz"
verify_sha256 "$CRI_DOCKERD_SHA256" "$cri/cri-dockerd.tgz"
record_file "$component" "cri-dockerd-${CRI_DOCKERD_VERSION}" "$CRI_DOCKERD_URL" "$cri/cri-dockerd.tgz"

# OCI Distribution registry used by Sealos for offline image distribution.
registry_archive="$work/registry_${REGISTRY_VERSION}_linux_${ARCH}.tar.gz"
download "$REGISTRY_URL" "$registry_archive"
verify_sha256 "$REGISTRY_SHA256" "$registry_archive"
record_file "$component" "registry-${REGISTRY_VERSION}" "$REGISTRY_URL" "$registry_archive"
tar -xzf "$registry_archive" -C "$work/registry" registry
install -m 0755 "$work/registry/registry" "$cri/registry"
record_file "$component" "registry-binary" "$REGISTRY_URL#registry" "$cri/registry"

# Compatibility utilities used by the existing runtime rootfs. These are legacy inherited assets.
conntrack_archive="$work/conntrack-library-2.5-linux-${ARCH}.tar.gz"
download "$CONNTRACK_URL" "$conntrack_archive"
record_file "$component" "legacy-conntrack-bundle" "$CONNTRACK_URL" "$conntrack_archive"
tar -xzf "$conntrack_archive" -C "$work" --strip-components=2 library/bin/conntrack
install -m 0755 "$work/conntrack" "$cri/conntrack"
record_file "$component" "legacy-conntrack-binary" "$CONNTRACK_URL#library/bin/conntrack" "$cri/conntrack"
provenance_add "$component" "artifact.legacy-conntrack.status" "inherited-unversioned"

download "$LSOF_URL" "$cri/lsof"
chmod 0755 "$cri/lsof"
record_file "$component" "legacy-lsof" "$LSOF_URL" "$cri/lsof"
provenance_add "$component" "artifact.legacy-lsof.status" "inherited-unversioned"

# Inspect the exact Docker-owned runtime BOM that will land on target nodes.
# The build runner is x86_64, so execution-based version probes only work for
# amd64 bundles. For arm64 the bundle is pinned by the tarball digest recorded
# in provenance; execution is skipped (arm64 binaries cannot run on x86_64).
tar -xzf "$cri/docker.tgz" -C "$work/inspect"
if [[ "$ARCH" == "amd64" ]]; then
  for binary in docker dockerd containerd runc; do
    if [[ -x "$work/inspect/docker/$binary" ]]; then
      version="$($work/inspect/docker/$binary --version 2>&1 | head -n1 || true)"
      provenance_add "$component" "bundled.${binary}.version_output" "$version"
      printf '%s=%s\n' "$binary" "$version" >> "$OUT_DIR/docker-bundled-bom.txt"
    fi
  done

  if ! "$work/inspect/docker/runc" --version 2>&1 | grep -F "$DOCKER_BUNDLED_RUNC_VERSION" >/dev/null; then
    echo "ERROR: Docker bundle does not contain expected runc $DOCKER_BUNDLED_RUNC_VERSION" >&2
    "$work/inspect/docker/runc" --version >&2 || true
    exit 1
  fi
else
  provenance_add "$component" "bundled.runc.arch" "$ARCH"
  provenance_add "$component" "bundled.version_probes" "skipped (x86_64 runner cannot execute $ARCH binaries)"
fi

provenance_add "$component" docker_version "$DOCKER_VERSION"
provenance_add "$component" cri_dockerd_version "$CRI_DOCKERD_VERSION"
provenance_add "$component" registry_version "$REGISTRY_VERSION"
provenance_add "$component" bundled_runc_expected "$DOCKER_BUNDLED_RUNC_VERSION"
provenance_add "$component" scope "docker-only; no independent containerd/runc/crun payloads"

cat > "$context/Dockerfile" <<'EOF'
FROM scratch
COPY cri /cri
EOF

oci_build_push "$component" "$context" "$context/Dockerfile" "$DOCKER_CACHE_TAG"

log "done: $REGISTRY/$REPOSITORY:$DOCKER_CACHE_TAG"
