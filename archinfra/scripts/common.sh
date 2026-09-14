#!/usr/bin/env bash
set -Eeuo pipefail

ARCHINFRA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RELEASE_FILE="${RELEASE_FILE:-$ARCHINFRA_ROOT/archinfra/releases/v1.36.4-r2.env}"

if [[ ! -f "$RELEASE_FILE" ]]; then
  echo "ERROR: release file not found: $RELEASE_FILE" >&2
  exit 1
fi

# Keep the arch the invoking job set (the BOM records the canonical amd64 value).
_ARCH="${ARCH:-}"
# shellcheck disable=SC1090
source "$RELEASE_FILE"
if [[ -n "$_ARCH" ]]; then ARCH="$_ARCH"; fi

REGISTRY="${REGISTRY:-ghcr.io}"
REPOSITORY="${REPOSITORY:-archinfra/kubernetes-cache}"
OUT_DIR="${OUT_DIR:-$ARCHINFRA_ROOT/out}"
RUNNER_TEMP_ROOT="${RUNNER_TEMP:-/tmp}"
WORK_DIR="${WORK_DIR:-$RUNNER_TEMP_ROOT/archinfra-kubernetes-cache}"

mkdir -p "$OUT_DIR" "$WORK_DIR"

log() {
  printf '[archinfra-cache] %s\n' "$*" >&2
}

require_cmd() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || {
      echo "ERROR: required command not found: $cmd" >&2
      exit 1
    }
  done
}

download() {
  local url="$1"
  local dest="$2"
  mkdir -p "$(dirname "$dest")"
  log "download: $url"
  curl --fail --location --show-error --silent \
    --retry 5 --retry-delay 2 --retry-all-errors \
    --output "$dest" "$url"
}

sha256_of() {
  sha256sum "$1" | awk '{print $1}'
}

verify_sha256() {
  local expected="$1"
  local file="$2"
  local actual
  actual="$(sha256_of "$file")"
  if [[ "$actual" != "$expected" ]]; then
    echo "ERROR: SHA256 mismatch for $file" >&2
    echo "  expected: $expected" >&2
    echo "  actual:   $actual" >&2
    exit 1
  fi
  log "sha256 OK: $(basename "$file") = $actual"
}

verify_with_remote_sha256() {
  local file="$1"
  local checksum_url="$2"
  local checksum_file="${file}.sha256.remote"
  local expected
  download "$checksum_url" "$checksum_file"
  expected="$(tr -d '[:space:]' < "$checksum_file")"
  verify_sha256 "$expected" "$file"
  printf '%s\n' "$expected"
}

provenance_file() {
  printf '%s/%s.provenance.txt\n' "$OUT_DIR" "$1"
}

provenance_begin() {
  local component="$1"
  local file
  file="$(provenance_file "$component")"
  cat > "$file" <<EOF
release=$RELEASE_VERSION
component=$component
arch=$ARCH
repository=$REGISTRY/$REPOSITORY
git_repository=${GITHUB_REPOSITORY:-local}
git_sha=${GITHUB_SHA:-local}
build_id=${GITHUB_RUN_ID:-local}
build_attempt=${GITHUB_RUN_ATTEMPT:-local}
built_at_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
}

provenance_add() {
  local component="$1"
  local key="$2"
  local value="$3"
  printf '%s=%s\n' "$key" "$value" >> "$(provenance_file "$component")"
}

record_file() {
  local component="$1"
  local name="$2"
  local source="$3"
  local file="$4"
  provenance_add "$component" "artifact.${name}.source" "$source"
  provenance_add "$component" "artifact.${name}.sha256" "$(sha256_of "$file")"
  provenance_add "$component" "artifact.${name}.bytes" "$(stat -c '%s' "$file")"
}

oci_image_digest() {
  local image="$1"
  docker buildx imagetools inspect "$image" 2>/dev/null | awk '/^Digest:/ {print $2; exit}' || true
}

oci_build_push() {
  local component="$1"
  local context="$2"
  local dockerfile="$3"
  shift 3
  local tags=("$@")
  local tag_args=()
  local tag image digest
  local existing=0

  require_cmd docker
  if [[ ${#tags[@]} -eq 0 ]]; then
    echo "ERROR: oci_build_push requires at least one tag" >&2
    exit 1
  fi

  # Release cache tags are immutable. If every requested tag already exists,
  # reuse the published digest and do not push again. If only part of a tag set
  # exists, fail closed rather than creating a mixed release.
  for tag in "${tags[@]}"; do
    image="$REGISTRY/$REPOSITORY:$tag"
    tag_args+=(--tag "$image")
    provenance_add "$component" "image.tag" "$image"
    digest="$(oci_image_digest "$image")"
    if [[ "$digest" == sha256:* ]]; then
      existing=$((existing + 1))
      provenance_add "$component" "image.digest.${tag}" "$digest"
      log "immutable tag exists; reuse: $image@$digest"
    fi
  done

  if (( existing > 0 )); then
    if (( existing != ${#tags[@]} )); then
      echo "ERROR: partial immutable tag set already exists for component=$component" >&2
      exit 1
    fi
    provenance_add "$component" "image.publish_mode" "reuse-existing"
    return 0
  fi

  provenance_add "$component" "image.publish_mode" "publish-new"
  log "build/push component=$component tags=${tags[*]}"
  docker buildx build \
    --platform "linux/$ARCH" \
    --pull \
    --provenance=mode=max \
    --sbom=true \
    --label "org.opencontainers.image.source=https://github.com/${GITHUB_REPOSITORY:-archinfra/kubernetes-cache}" \
    --label "org.opencontainers.image.revision=${GITHUB_SHA:-local}" \
    --label "org.opencontainers.image.version=$RELEASE_VERSION" \
    --label "io.archinfra.release=$RELEASE_VERSION" \
    --label "io.archinfra.component=$component" \
    "${tag_args[@]}" \
    --file "$dockerfile" \
    --push \
    "$context"

  for tag in "${tags[@]}"; do
    image="$REGISTRY/$REPOSITORY:$tag"
    digest="$(oci_image_digest "$image")"
    if [[ "$digest" != sha256:* ]]; then
      echo "ERROR: published image has no registry digest: $image" >&2
      exit 1
    fi
    provenance_add "$component" "image.digest.${tag}" "$digest"
    log "published immutable tag: $image@$digest"
  done
}

write_release_summary() {
  local file="$OUT_DIR/release-summary.txt"
  cat > "$file" <<EOF
release=$RELEASE_VERSION
arch=$ARCH
kubernetes=$KUBERNETES_VERSION
sealos=$SEALOS_VERSION
docker=$DOCKER_VERSION
cri_dockerd=$CRI_DOCKERD_VERSION
crictl=$CRICTL_VERSION
registry=$REGISTRY_VERSION
kubeadm_etcd=$KUBEADM_ETCD_VERSION
kubeadm_coredns=$KUBEADM_COREDNS_VERSION
kubeadm_pause=$KUBEADM_PAUSE_VERSION
lvscare=$LVSCARE_VERSION
EOF
}
