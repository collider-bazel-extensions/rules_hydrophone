#!/usr/bin/env bash
# Maintainer-time script: regenerate the pins in private/versions.bzl.
#
#   tools/update_versions.sh hydrophone <version>  # add / re-pin a hydrophone release
#   tools/update_versions.sh kubectl <version>     # re-pin the version-check kubectl
#   tools/update_versions.sh images [<minor>...]   # re-pin the conformance images
#   tools/update_versions.sh --check               # verify every pin; no writes
#
# hydrophone: SHA-256s from the release's hydrophone_<ver>_checksums.txt,
# each cross-checked by downloading the tarball. kubectl: dl.k8s.io's
# published <url>.sha256, cross-checked the same way.
#
# images: without minors, the upstream-supported ones (data/releases/
# schedule.yaml in kubernetes/website: endOfLifeDate not yet passed). Each
# minor's latest patch comes from dl.k8s.io/release/stable-<minor>.txt and
# its digest from the registry's v2 API. The digest must be the manifest
# list (index), must hash to the body the registry served, and the index
# must include linux/amd64 and linux/arm64. BUSYBOX_IMAGE's digest is
# re-resolved for its tag too.
#
# --check exits 1 on DRIFT (a pin that doesn't match upstream for the same
# version or tag). A newer patch, or a change in the supported minors, is
# printed as NOTE and doesn't fail: run `images` to take it.
#
# Any mismatch aborts without touching versions.bzl. After `hydrophone
# <ver>`, bump DEFAULT_VERSION and hydrophone.version() in MODULE.bazel to
# match (//tests:version_test).
set -euo pipefail

cd "$(dirname "$0")/.."
for tool in curl python3; do
    command -v "$tool" >/dev/null 2>&1 || { echo "update_versions: needs $tool" >&2; exit 1; }
done

work=$(mktemp -d)
trap 'rm -r -f -- "$work"' EXIT
versions=private/versions.bzl

plats=(linux_amd64 linux_arm64 darwin_amd64 darwin_arm64)
declare -A assets=(
    [linux_amd64]=Linux_x86_64
    [linux_arm64]=Linux_arm64
    [darwin_amd64]=Darwin_x86_64
    [darwin_arm64]=Darwin_arm64
)
hydrophone_base="https://github.com/kubernetes-sigs/hydrophone/releases/download"
accept="application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json"

sha256() { python3 -I -c 'import hashlib,sys; h=hashlib.sha256(); f=open(sys.argv[1],"rb"); [h.update(b) for b in iter(lambda: f.read(1<<20), b"")]; print(h.hexdigest())' "$1"; }
die() { echo "update_versions: $*" >&2; exit 1; }

# hydrophone_pins <ver>: "<platform> <sha256>" per platform, verified.
hydrophone_pins() {
    local ver="$1" plat asset sum actual
    curl -fsSL -o "$work/sums" "$hydrophone_base/v$ver/hydrophone_${ver}_checksums.txt" \
        || die "no checksums file for hydrophone $ver"
    for plat in "${plats[@]}"; do
        asset="hydrophone_${assets[$plat]}.tar.gz"
        sum=$(awk -v a="$asset" '$2 == a {print $1}' "$work/sums")
        [[ "$sum" =~ ^[0-9a-f]{64}$ ]] || die "no sum for $asset in hydrophone_${ver}_checksums.txt"
        curl -fsSL -o "$work/tgz" "$hydrophone_base/v$ver/$asset"
        actual=$(sha256 "$work/tgz")
        [[ "$actual" == "$sum" ]] || die "$asset hashes to $actual, published $sum"
        echo "$plat $sum"
    done
}

# kubectl_pins <ver>: "<platform> <sha256>" per platform, verified.
kubectl_pins() {
    local ver="$1" plat url sum actual
    for plat in "${plats[@]}"; do
        url="https://dl.k8s.io/release/v$ver/bin/${plat%_*}/${plat#*_}/kubectl"
        sum=$(curl -fsSL "$url.sha256" | awk '{print $1}') || die "no $url.sha256"
        [[ "$sum" =~ ^[0-9a-f]{64}$ ]] || die "bad sum at $url.sha256: $sum"
        curl -fsSL -o "$work/kubectl" "$url"
        actual=$(sha256 "$work/kubectl")
        [[ "$actual" == "$sum" ]] || die "$url hashes to $actual, published $sum"
        echo "$plat $sum"
    done
}

# index_digest <repo> <tag>: the tag's manifest-list digest, verified.
index_digest() {
    local repo="$1" tag="$2" host path digest actual
    host="${repo%%/*}"; path="${repo#*/}"
    curl -fsSL -D "$work/hdr" -o "$work/manifest" -H "Accept: $accept" "https://$host/v2/$path/manifests/$tag" \
        || die "cannot fetch $repo:$tag"
    digest=$(tr -d '\r' < "$work/hdr" | awk 'tolower($1) == "docker-content-digest:" {d = $2} END {print d}')
    actual="sha256:$(sha256 "$work/manifest")"
    [[ "$digest" == "$actual" ]] || die "$repo:$tag: the registry says $digest, its body hashes to $actual"
    python3 -I - "$work/manifest" "$repo:$tag" <<'PY' || exit 1
import json, sys
m = json.load(open(sys.argv[1]))
kinds = ("application/vnd.oci.image.index.v1+json", "application/vnd.docker.distribution.manifest.list.v2+json")
if m.get("mediaType") not in kinds and "manifests" not in m:
    sys.exit(f"update_versions: {sys.argv[2]} is a single-platform manifest, not an index")
have = {(p.get("platform", {}).get("os"), p.get("platform", {}).get("architecture")) for p in m["manifests"]}
for want in (("linux", "amd64"), ("linux", "arm64")):
    if want not in have:
        sys.exit(f"update_versions: {sys.argv[2]}: the index has no {want[0]}/{want[1]} image")
PY
    echo "$digest"
}

# supported_minors: upstream minors whose end of life hasn't passed.
supported_minors() {
    curl -fsSL -o "$work/schedule.yaml" https://raw.githubusercontent.com/kubernetes/website/main/data/releases/schedule.yaml \
        || die "cannot fetch kubernetes/website data/releases/schedule.yaml"
    python3 -I - "$work/schedule.yaml" <<'PY'
import datetime, re, sys
text = open(sys.argv[1]).read()
body = text.split("\nschedules:\n", 1)[1]
today = datetime.date.today().isoformat()
minors = []
for entry in re.split(r"\n- ", "\n" + body)[1:]:
    eol = re.search(r'^endOfLifeDate: "?([0-9-]+)"?', entry, re.M)
    rel = re.search(r'^  release: "?([0-9]+\.[0-9]+)"?\s*$', entry, re.M)
    if eol and rel and eol.group(1) >= today:
        minors.append(rel.group(1))
print(" ".join(sorted(set(minors), key=lambda v: tuple(map(int, v.split("."))))))
PY
}

latest_patch() {  # <minor> -> 1.35.10
    local v
    v=$(curl -fsSL "https://dl.k8s.io/release/stable-$1.txt") || die "no dl.k8s.io/release/stable-$1.txt"
    [[ "$v" =~ ^v$1\.[0-9]+$ ]] || die "stable-$1.txt says '$v'"
    echo "${v#v}"
}

# pinned_images: "<minor> <ref>" per CONFORMANCE_IMAGES entry.
pinned_images() { sed -n '/^CONFORMANCE_IMAGES = {/,/^}/s/^    "\([0-9.]*\)": "\(.*\)",$/\1 \2/p' "$versions"; }
busybox_ref() { sed -n 's/^BUSYBOX_IMAGE = "\(.*\)"$/\1/p' "$versions"; }

# write <python that edits `text`> : applies an edit to versions.bzl.
write() {
    python3 -I - "$versions" "$work" "$@" <<'PY'
import os, re, sys
path, work, what = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(path).read()
rows = [l.split() for l in open(os.path.join(work, "rows")) if l.strip()]
def block(name, body):
    global text
    pat = re.compile(r"^" + name + r" = \{\n.*?^\}\n", re.S | re.M)
    if not pat.search(text):
        sys.exit(f"update_versions: no {name} block in {path}")
    text = pat.sub(lambda m: f"{name} = {{\n{body}}}\n", text, count=1)
if what == "hydrophone":
    ver = sys.argv[4]
    entry = f'    "{ver}": {{\n' + "".join(f'        "{p}": "{s}",\n' for p, s in rows) + "    },\n"
    pat = re.compile(r'^    "' + re.escape(ver) + r'": \{\n.*?^    \},\n', re.S | re.M)
    if pat.search(text):
        text = pat.sub(lambda m: entry, text, count=1)
    else:
        text = text.replace("HYDROPHONE_VERSIONS = {\n", "HYDROPHONE_VERSIONS = {\n" + entry, 1)
elif what == "kubectl":
    ver = sys.argv[4]
    text = re.sub(r'^KUBECTL_VERSION = ".*"$', f'KUBECTL_VERSION = "{ver}"', text, count=1, flags=re.M)
    block("KUBECTL_SHA256", "".join(f'    "{p}": "{s}",\n' for p, s in rows))
elif what == "images":
    block("CONFORMANCE_IMAGES", "".join(f'    "{m}": "{r}",\n' for m, r in rows))
    busybox = sys.argv[4]
    text = re.sub(r'^BUSYBOX_IMAGE = ".*"$', f'BUSYBOX_IMAGE = "{busybox}"', text, count=1, flags=re.M)
open(path, "w").write(text)
PY
}

check() {
    local status=0 ver plat sum minor ref tag repo digest want
    for ver in $(sed -n '/^HYDROPHONE_VERSIONS = {/,/^}/s/^    "\([0-9][^"]*\)": {/\1/p' "$versions"); do
        # Not `< <(...)`: a failed download must stop the check, not read as no rows.
        hydrophone_pins "$ver" > "$work/pins"
        while read -r plat sum; do
            if sed -n "/^    \"$ver\": {/,/^    },/p" "$versions" | grep -qF "\"$plat\": \"$sum\""; then
                echo "OK    hydrophone $ver $plat"
            else
                echo "DRIFT hydrophone $ver $plat: published $sum" >&2; status=1
            fi
        done < "$work/pins"
    done
    ver=$(sed -n 's/^KUBECTL_VERSION = "\(.*\)"$/\1/p' "$versions")
    kubectl_pins "$ver" > "$work/pins"
    while read -r plat sum; do
        if sed -n '/^KUBECTL_SHA256 = {/,/^}/p' "$versions" | grep -qF "\"$plat\": \"$sum\""; then
            echo "OK    kubectl $ver $plat"
        else
            echo "DRIFT kubectl $ver $plat: published $sum" >&2; status=1
        fi
    done < "$work/pins"
    pinned_images > "$work/images"
    while read -r minor ref; do
        repo="${ref%%:*}"; tag="${ref#*:}"; tag="${tag%@*}"; want="${ref#*@}"
        digest=$(index_digest "$repo" "$tag")
        if [[ "$digest" == "$want" ]]; then echo "OK    conformance $minor $repo:$tag (index $digest)"
        else echo "DRIFT conformance $minor: $repo:$tag is $digest, pinned $want" >&2; status=1
        fi
        latest=$(latest_patch "$minor")
        [[ "v$latest" == "$tag" ]] || echo "NOTE  conformance $minor: newer patch v$latest (pinned $tag); run tools/update_versions.sh images"
    done < "$work/images"
    ref=$(busybox_ref); repo="${ref%%:*}"; tag="${ref#*:}"; tag="${tag%@*}"; want="${ref#*@}"
    digest=$(index_digest "$repo" "$tag")
    if [[ "$digest" == "$want" ]]; then echo "OK    busybox $repo:$tag (index $digest)"
    else echo "DRIFT busybox: $repo:$tag is $digest, pinned $want" >&2; status=1
    fi
    local supported pinned
    supported=$(supported_minors); pinned=$(pinned_images | awk '{print $1}' | xargs)
    [[ "$supported" == "$pinned" ]] || echo "NOTE  supported minors are now: $supported (pinned: $pinned); run tools/update_versions.sh images"
    return "$status"
}

case "${1:-}" in
    --check)
        check
        ;;
    hydrophone)
        ver="${2:?usage: tools/update_versions.sh hydrophone <version>}"
        ver="${ver#v}"
        hydrophone_pins "$ver" > "$work/rows"
        write hydrophone "$ver"
        echo "pinned hydrophone $ver for ${#plats[@]} platforms in $versions"
        echo "Now set DEFAULT_VERSION and hydrophone.version() in MODULE.bazel if it is the new default."
        ;;
    kubectl)
        ver="${2:?usage: tools/update_versions.sh kubectl <version>}"
        ver="${ver#v}"
        kubectl_pins "$ver" > "$work/rows"
        write kubectl "$ver"
        echo "pinned kubectl $ver in $versions"
        ;;
    images)
        shift
        minors="$*"
        [[ -n "$minors" ]] || minors=$(supported_minors)
        [[ -n "$minors" ]] || die "no supported minors found"
        : > "$work/rows"
        for minor in $minors; do
            [[ "$minor" =~ ^[0-9]+\.[0-9]+$ ]] || die "not a minor: $minor"
            patch=$(latest_patch "$minor")
            digest=$(index_digest registry.k8s.io/conformance "v$patch")
            echo "$minor registry.k8s.io/conformance:v$patch@$digest" | tee -a "$work/rows"
        done
        ref=$(busybox_ref); repo="${ref%%:*}"; tag="${ref#*:}"; tag="${tag%@*}"
        busybox="$repo:$tag@$(index_digest "$repo" "$tag")"
        echo "busybox $busybox"
        write images "$busybox"
        echo "pinned conformance images for: $minors in $versions"
        ;;
    *)
        sed -n '2,8p' "$0" >&2
        exit 2
        ;;
esac
