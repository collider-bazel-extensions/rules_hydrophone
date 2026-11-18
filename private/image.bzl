"""Resolves `conformance_image` to a digest-pinned reference and the
Kubernetes minor its tag names.

Accepted forms:
  - a pinned minor, `"1.35"`: the CONFORMANCE_IMAGES entry;
  - a full reference, `"<repo>:<tag>@sha256:<64 hex>"`, whose tag is a
    Kubernetes version (`v1.35.10`). The digest pins the image; the tag is
    where the minor for the cluster version check comes from, so the two
    can't drift apart.

Anything else (no digest, no tag, a tag that isn't a version, an unpinned
minor) is an analysis error.
"""

load(":versions.bzl", "CONFORMANCE_IMAGES")

_HEX = "0123456789abcdef"
_DIGITS = "0123456789"

def _all_in(s, chars):
    if not s:
        return False
    for c in s.elems():
        if c not in chars:
            return False
    return True

def _looks_like_minor(s):
    parts = s.split(".")
    return len(parts) == 2 and _all_in(parts[0], _DIGITS) and _all_in(parts[1], _DIGITS)

def version_minor(version):
    """`v1.35.10`, `1.35.4-eks-abc`, `v1.35` -> `"1.35"`; None if it isn't a version."""
    v = version[1:] if version.startswith("v") else version
    parts = v.split(".")
    if len(parts) < 2 or not _all_in(parts[0], _DIGITS):
        return None

    # The minor runs up to the first non-digit (`35` in `35-rc.0`).
    minor = ""
    for c in parts[1].elems():
        if c not in _DIGITS:
            break
        minor += c
    if not minor:
        return None
    if len(parts) == 2 and minor != parts[1]:
        return None
    return "{}.{}".format(int(parts[0]), int(minor))

def _pinned():
    return ", ".join(['"{}"'.format(m) for m in sorted(CONFORMANCE_IMAGES.keys())])

def parse_conformance_image(value):
    """Returns (struct(ref, minor, key), None), or (None, error message)."""
    if value in CONFORMANCE_IMAGES:
        ref = CONFORMANCE_IMAGES[value]
        res, err = _parse_reference(ref)
        if err:
            return None, "pinned conformance image for {}: {}".format(value, err)
        return struct(ref = ref, minor = res.minor, key = value), None
    return _parse_reference(value)

def _parse_reference(value):
    if not value:
        return None, "conformance_image is empty. Use a pinned minor ({}) or \"<repo>:<tag>@sha256:<digest>\".".format(_pinned())

    if _looks_like_minor(value):
        return None, ("conformance_image \"{}\" is not a pinned Kubernetes minor. Pinned: {}. " +
                      "For another minor, give a full reference pinned by digest: " +
                      "\"registry.k8s.io/conformance:v{}.<patch>@sha256:<index digest>\".").format(value, _pinned(), value)

    if "@" not in value:
        return None, ("conformance_image \"{}\" is not pinned by digest. A tag can move, and the cluster would " +
                      "then run an image nobody reviewed. Use a pinned minor ({}) or \"<repo>:<tag>@sha256:<digest>\" " +
                      "(prefer the manifest-list digest, which covers every node architecture).").format(value, _pinned())

    name, _, digest = value.partition("@")
    if "@" in digest:
        return None, "conformance_image \"{}\": more than one '@'.".format(value)
    if not digest.startswith("sha256:") or len(digest) != 71 or not _all_in(digest[7:], _HEX):
        return None, "conformance_image \"{}\": the digest must be sha256: followed by 64 lowercase hex digits.".format(value)

    last = name.rpartition("/")[2]
    if ":" not in last:
        return None, ("conformance_image \"{}\" has no tag. The tag (v<major>.<minor>.<patch>) names the " +
                      "Kubernetes version the test compares with the cluster's, so it is required alongside the digest.").format(value)
    repo = name[:len(name) - len(last)] + last.rpartition(":")[0]
    tag = last.rpartition(":")[2]
    if not repo or repo.endswith("/"):
        return None, "conformance_image \"{}\": no repository before the tag.".format(value)
    minor = version_minor(tag)
    if not minor:
        return None, ("conformance_image \"{}\": the tag \"{}\" isn't a Kubernetes version (v<major>.<minor>.<patch>), " +
                      "so the test can't compare it with the cluster's version.").format(value, tag)
    return struct(ref = value, minor = minor, key = ""), None
