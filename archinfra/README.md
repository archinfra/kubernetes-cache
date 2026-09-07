# Archinfra Kubernetes Cache

This directory defines the release-oriented cache supply chain used by the Archinfra Kubernetes distribution.

The upstream `labring-actions/cache` scripts are retained for reference, but **they are not the production release path**. Archinfra release caches are built only from an explicit release lock and never resolve `latest` during a production build.

## Current release

`archinfra/releases/v1.36.4-r1.env`

| Component | Version / policy |
| --- | --- |
| Kubernetes | v1.36.4 |
| Sealos | v5.1.1 |
| Runtime profile | Docker |
| Docker Engine | v28.5.2 |
| cri-dockerd | v0.4.4 |
| crictl | v1.36.0 |
| Distribution Registry | v3.1.1 |
| etcd | 3.6.8-0 (kubeadm v1.36.4 default) |
| CoreDNS | v1.14.2 (kubeadm v1.36.4 default) |
| pause | 3.10.2 (kubeadm v1.36.4 default) |
| lvscare | v5.1.1 (follows Sealos) |
| Architecture | linux/amd64 |

Docker owns its bundled containerd and runc versions in this profile. They are recorded from the actual Docker static bundle during the build and are not independently replaced. `crun` and CRI-O are intentionally outside this release profile.

## Release cache images

The manual release workflow publishes:

```text
ghcr.io/archinfra/kubernetes-cache:sealos-v5.1.1-amd64
ghcr.io/archinfra/kubernetes-cache:kubernetes-v1.36.4-amd64
ghcr.io/archinfra/kubernetes-cache:cri-v1.36-amd64
ghcr.io/archinfra/kubernetes-cache:cri-docker-v28.5.2-cridockerd-v0.4.4-registry-v3.1.1-amd64
```

No floating production alias such as `cri-amd64` is published by the Archinfra release workflow. The consuming `kubernetes-runtime` repository must reference the versioned cache tag, and should be pinned to the resulting OCI digest for a released build.

## Build entrypoint

Use GitHub Actions workflow:

```text
Archinfra Kubernetes Cache Release
```

It is manual (`workflow_dispatch`) and supports:

```text
all
sealos
docker
crictl
kubernetes
```

The original upstream workflows remain manual-only reference workflows. Their periodic schedules are disabled in the Archinfra fork to prevent floating cache contents from changing without a release decision.

## Supply-chain policy

1. Release versions are declared in the release lock; build scripts do not discover latest versions.
2. Core downloaded artifacts are SHA256 verified before use.
3. Kubernetes binaries are verified against the adjacent checksums published by `dl.k8s.io`.
4. The kubeadm-generated image list is the source of truth for etcd/CoreDNS/pause and control-plane images.
5. A build fails if kubeadm defaults do not match the values recorded in the release lock.
6. OCI images include source/revision/release labels and BuildKit provenance/SBOM attestations.
7. Each job uploads text provenance containing source URLs, artifact hashes, Git SHA, OCI tags and resulting image digests.
8. Released runtime builds should consume cache images by OCI digest, not by a mutable/floating tag.

## Legacy compatibility utilities

`conntrack` and `lsof` are still obtained from the historical Sealos `cluster-image` dependency release in `v1.36.4-r1`. The build records their exact downloaded and extracted SHA256 values and explicitly marks them as `inherited-unversioned`.

They are not considered fully standardized dependencies yet. A later hardening release should replace them with independently versioned, checksummed sources under Archinfra control.

## Directory layout

```text
archinfra/
├── README.md
├── releases/
│   └── v1.36.4-r1.env
└── scripts/
    ├── common.sh
    ├── build-sealos.sh
    ├── build-docker.sh
    ├── build-crictl.sh
    └── build-kubernetes.sh
```

CI-generated provenance is written under `out/` and uploaded as a workflow artifact. It is not a source-of-truth replacement for the release lock; it records the exact result of a particular build invocation.
