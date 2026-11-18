"""Pins: the hydrophone release binaries, the kubectl that reads the
cluster's version, and the conformance images by digest.

hydrophone: one release tarball per platform from kubernetes-sigs/hydrophone,
holding the single `hydrophone` binary (upstream names amd64 `x86_64` and
capitalises the OS):

    https://github.com/kubernetes-sigs/hydrophone/releases/download/v<ver>/hydrophone_<Os>_<arch>.tar.gz

SHA-256s are the release's published `hydrophone_<ver>_checksums.txt`.

kubectl: the dl.k8s.io release binary, SHA-256s from its published
`<url>.sha256`. One minor behind the newest pinned conformance minor, so it
is within kubectl's +/-1 version skew of every pinned minor.

Conformance images: `registry.k8s.io/conformance` at the latest patch of
each upstream-supported Kubernetes minor, pinned by the manifest-list
(index) digest, which covers linux/amd64, arm64, ppc64le and s390x. The
busybox image is hydrophone's default output container, pinned the same way.

Maintainer flow:

    tools/update_versions.sh hydrophone <ver>   # add / re-pin a hydrophone release
    tools/update_versions.sh kubectl <ver>      # re-pin kubectl
    tools/update_versions.sh images             # re-pin each supported minor's latest patch
    tools/update_versions.sh --check            # verify every pin, no writes

//tests:checksums_test fails on an empty or malformed value.
"""

# The hydrophone version the `hydrophone` extension fetches when the root
# module names none.
DEFAULT_VERSION = "0.8.0"

HYDROPHONE_URL = "https://github.com/kubernetes-sigs/hydrophone/releases/download/v{version}/hydrophone_{asset}.tar.gz"

# platform -> the upstream asset suffix.
ASSETS = {
    "linux_amd64": "Linux_x86_64",
    "linux_arm64": "Linux_arm64",
    "darwin_amd64": "Darwin_x86_64",
    "darwin_arm64": "Darwin_arm64",
}

HYDROPHONE_VERSIONS = {
    "0.8.0": {
        "linux_amd64": "873f75a701d22f0f59c62fd0153101e7a37155984bf497ae035eab226949bdf4",
        "linux_arm64": "3ad340d2891decbdc1f2f460a85beaf4fa114a823eb415446b52f9aa021f066b",
        "darwin_amd64": "3e8902bb8d8e245e8963f87458ddf026794aea963ad8a68942ecf4c907ed0522",
        "darwin_arm64": "cc0c41f10dda7b31b449a89b5901f1d4d4bc6a298f9edd4a6d165514623f1200",
    },
}

KUBECTL_URL = "https://dl.k8s.io/release/v{version}/bin/{os}/{arch}/kubectl"

KUBECTL_VERSION = "1.36.6"

KUBECTL_SHA256 = {
    "linux_amd64": "29818b6729dc9262b692307470d0558d027725e738be5dd47c760261868a2634",
    "linux_arm64": "35507ef408c3d38849e5d3203e18f8e861db822aa664101a9ced0869edd06046",
    "darwin_amd64": "2e22d382f2423c88d9d076246f860bb3d5c743dd279ca63e113474bb88382426",
    "darwin_arm64": "1cf735c3d35ccfec28d0618784cb06a4614d2c42aade28b6be0eab76a2ffb623",
}

# Kubernetes minor -> conformance image, by index digest.
CONFORMANCE_IMAGES = {
    "1.35": "registry.k8s.io/conformance:v1.35.10@sha256:c1be3a9826603e29e6926d02e031833d9ae86b0d595cce28f1bd19a6bc859748",
    "1.36": "registry.k8s.io/conformance:v1.36.6@sha256:fdbe358cf2d2900d2926a91dcb3ed67be37f766ae3c6a81aff35068f31ec4adf",
    "1.37": "registry.k8s.io/conformance:v1.37.2@sha256:d503a15722ea23662c482b72ce01ee6e9efec1e8b9c2d3834aa0c51bb2d0832a",
}

# hydrophone's default --busybox-image (the pod's output container), by
# index digest.
BUSYBOX_IMAGE = "registry.k8s.io/e2e-test-images/busybox:1.36.1-1@sha256:a9155b13325b2abef48e71de77bb8ac015412a566829f621d06bfae5c699b1b9"

PLATFORMS = {
    "linux_amd64": ["@platforms//os:linux", "@platforms//cpu:x86_64"],
    "linux_arm64": ["@platforms//os:linux", "@platforms//cpu:arm64"],
    "darwin_amd64": ["@platforms//os:osx", "@platforms//cpu:x86_64"],
    "darwin_arm64": ["@platforms//os:osx", "@platforms//cpu:arm64"],
}
