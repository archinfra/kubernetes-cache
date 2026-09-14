#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

component=kubernetes
work="$WORK_DIR/$component"
context="$work/context"
sealos_dir="$work/sealos"
kube_version="v${KUBERNETES_VERSION}"

# Select per-arch tag. The sealos builder stays amd64 (executable on the x86_64 runner);
# the release lock is canonical for amd64.
case "${ARCH:-amd64}" in
  arm64)
    KUBERNETES_CACHE_TAG="${KUBERNETES_CACHE_TAG_ARM64}"
    ;;
esac

rm -rf "$work"
mkdir -p "$context/bin" "$context/images/shim" "$sealos_dir"
provenance_begin "$component"
write_release_summary

require_cmd curl sha256sum tar docker buildah

# Download Kubernetes node/bootstrap binaries and validate using Kubernetes' own adjacent checksum files.
for binary in kubeadm kubelet kubectl; do
  url="https://dl.k8s.io/release/${kube_version}/bin/linux/${ARCH}/${binary}"
  file="$context/bin/$binary"
  download "$url" "$file"
  checksum="$(verify_with_remote_sha256 "$file" "${url}.sha256")"
  chmod 0755 "$file"
  provenance_add "$component" "artifact.${binary}.source" "$url"
  provenance_add "$component" "artifact.${binary}.sha256" "$checksum"
  provenance_add "$component" "artifact.${binary}.bytes" "$(stat -c '%s' "$file")"
done

# Execution-based version probes only work for amd64 (the amd64 kubeadm/kubelet/kubectl
# binaries run on the x86_64 runner; arm64 ones cannot). The control-plane image list
# (DefaultImageList) is architecture-independent text produced by kubeadm, so it can be
# generated with the amd64 kubeadm for both arches.
if [[ "$ARCH" == "amd64" ]]; then
  "$context/bin/kubeadm" version -o short | tee "$OUT_DIR/kubeadm.version.txt"
  "$context/bin/kubelet" --version | tee "$OUT_DIR/kubelet.version.txt"
  "$context/bin/kubectl" version --client=true | tee "$OUT_DIR/kubectl.version.txt"
fi

# kubeadm is the source of truth for the control-plane dependency image set.
# The amd64 kubeadm generates an arch-independent image list (pause/etcd/coredns tags fixed).
if [[ ! -s "$context/images/shim/DefaultImageList" ]]; then
  "$context/bin/kubeadm" config images list --kubernetes-version "$kube_version" \
    > "$context/images/shim/DefaultImageList"
fi
cp "$context/images/shim/DefaultImageList" "$OUT_DIR/kubernetes.images.txt"

# Fail closed if kubeadm defaults differ from the release record.
grep -F "kube-apiserver:${kube_version}" "$context/images/shim/DefaultImageList" >/dev/null
grep -F "etcd:${KUBEADM_ETCD_VERSION}" "$context/images/shim/DefaultImageList" >/dev/null
grep -F "coredns:${KUBEADM_COREDNS_VERSION}" "$context/images/shim/DefaultImageList" >/dev/null
grep -F "pause:${KUBEADM_PAUSE_VERSION}" "$context/images/shim/DefaultImageList" >/dev/null

provenance_add "$component" version "$KUBERNETES_VERSION"
provenance_add "$component" kubeadm_etcd "$KUBEADM_ETCD_VERSION"
provenance_add "$component" kubeadm_coredns "$KUBEADM_COREDNS_VERSION"
provenance_add "$component" kubeadm_pause "$KUBEADM_PAUSE_VERSION"
provenance_add "$component" image_list_sha256 "$(sha256_of "$context/images/shim/DefaultImageList")"

# Use the exact locked Sealos release as the image-cache assembler. The build runner is
# x86_64, so we always use the amd64 sealos binary here (executable on the runner); the
# --platform flag plus QEMU binfmt handles arch-specific image materialization.
sealos_builder_archive="$work/sealos_${SEALOS_VERSION}_linux_amd64.tar.gz"
download "$SEALOS_URL" "$sealos_builder_archive"
verify_sha256 "$SEALOS_SHA256" "$sealos_builder_archive"
record_file "$component" "sealos-builder-${SEALOS_VERSION}" "$SEALOS_URL" "$sealos_builder_archive"
tar -xzf "$sealos_builder_archive" -C "$sealos_dir"
chmod +x "$sealos_dir/sealos"
"$sealos_dir/sealos" version | tee "$OUT_DIR/kubernetes.sealos-builder.version.txt"

cat > "$context/Kubefile" <<'EOF'
FROM scratch
EOF

# Sealos reads images/shim/DefaultImageList and materializes the referenced Kubernetes images
# into context/registry for offline delivery, matching the original Sealos cache architecture.
local_seed="archinfra-kubernetes-cache-seed:${kube_version}-${ARCH}"
log "materialize Kubernetes image registry with Sealos: $local_seed"
sudo "$sealos_dir/sealos" build \
  --platform "linux/$ARCH" \
  --label "io.archinfra.release=$RELEASE_VERSION" \
  --label "io.archinfra.component=kubernetes-seed" \
  -t "$local_seed" \
  "$context"

sudo chown -R "$(id -u):$(id -g)" "$context"

if [[ ! -d "$context/registry" ]]; then
  echo "ERROR: Sealos build did not materialize context/registry" >&2
  exit 1
fi

registry_files="$(find "$context/registry" -type f | wc -l | tr -d ' ')"
if [[ "$registry_files" == "0" ]]; then
  echo "ERROR: materialized Kubernetes registry is empty" >&2
  exit 1
fi
provenance_add "$component" offline_registry_files "$registry_files"

cat > "$context/Cachefile" <<'EOF'
FROM scratch
COPY bin /bin
COPY images /images
COPY registry /registry
EOF

oci_build_push "$component" "$context" "$context/Cachefile" "$KUBERNETES_CACHE_TAG"

log "done: $REGISTRY/$REPOSITORY:$KUBERNETES_CACHE_TAG"
