#!/usr/bin/env bash
# Consumer check against the commit's release archive (git archive honours
# .gitattributes export-ignore, as GitHub's tag tarballs do):
#   - tests/ and tools/ are not shipped, and @rules_hydrophone//... loads;
#   - a consumer's hydrophone_conformance_test analyzes and builds, both for
#     a pinned minor and a full reference, with only rules_hydrophone as a
#     dependency (rules_kind is dev-only);
#   - run without KUBECONFIG, it fails saying so: the wrapper found its
#     binaries in an external repository's runfiles;
#   - an unpinned tag fails analysis;
#   - the root module's hydrophone.version(version, sha256) replaces the
#     default with an unlisted version.
# Usage: .github/consumer/check.sh <scratch dir>
set -euo pipefail
module="rules_hydrophone"
ignored=(tests tools)
repo="$(cd "$(dirname "$0")/../.." && pwd)"
work="$1"
src="$work/$module"
c="$work/consumer"
rm -rf "$work"; mkdir -p "$src" "$c/bad"
git -C "$repo" archive HEAD | tar -x -C "$src"
for d in "${ignored[@]}"; do
    if [[ -e "$src/$d" ]]; then echo "FAIL: archive contains $d/" >&2; exit 1; fi
done
if [[ -f "$repo/.bazelversion" ]]; then cp "$repo/.bazelversion" "$c/"; fi
cat > "$c/MODULE.bazel" <<MOD
module(name = "consumer")
bazel_dep(name = "$module")
local_path_override(module_name = "$module", path = "$src")
MOD
cat > "$c/BUILD.bazel" <<'BUILD'
load("@rules_hydrophone//:defs.bzl", "hydrophone_conformance_test")

hydrophone_conformance_test(
    name = "conformance_test",
    conformance_image = "1.35",
)

hydrophone_conformance_test(
    name = "mirror_conformance_test",
    conformance_image = "registry.k8s.io/conformance:v1.36.6@sha256:fdbe358cf2d2900d2926a91dcb3ed67be37f766ae3c6a81aff35068f31ec4adf",
    focus = "ConfigMap",
    parallel = 2,
)
BUILD
cat > "$c/bad/BUILD.bazel" <<'BUILD'
load("@rules_hydrophone//:defs.bzl", "hydrophone_conformance_test")

hydrophone_conformance_test(
    name = "unpinned_test",
    conformance_image = "registry.k8s.io/conformance:v1.35.10",
)
BUILD
cd "$c"

bazel query "@$module//..." >/dev/null
echo "ok: @$module//... loads ($(bazel query "@$module//..." 2>/dev/null | wc -l) targets); ${ignored[*]} not shipped"

# Named explicitly: the macro tags every conformance test `manual`, so
# //:all would match none of them.
bazel build //:conformance_test //:mirror_conformance_test
echo "ok: hydrophone_conformance_test analyzes and builds (pinned minor, full reference)"

if bazel test //:conformance_test --test_output=errors > test.log 2>&1; then
    cat test.log; echo "FAIL: the conformance test passed without a cluster" >&2; exit 1
fi
grep -qF "KUBECONFIG is not set" test.log || { cat test.log; echo "FAIL: no 'KUBECONFIG is not set'" >&2; exit 1; }
echo "ok: without KUBECONFIG the test fails, saying so (runfiles resolved from the external repository)"

if bazel build //bad:unpinned_test > bad.log 2>&1; then
    echo "FAIL: an unpinned conformance image built" >&2; exit 1
fi
grep -qF "is not pinned by digest" bad.log || { cat bad.log; echo "FAIL: no 'is not pinned by digest'" >&2; exit 1; }
echo "ok: an unpinned tag fails analysis"

# The root module's version tag wins, and pins an unlisted version by sha.
cat >> MODULE.bazel <<'MOD'
hydrophone = use_extension("@rules_hydrophone//:extensions.bzl", "hydrophone")
hydrophone.version(
    version = "0.7.0",
    sha256 = {
        "linux_amd64": "15a6c09962f9bd4a1587af068b5edef1072327a77012d8fbb84992c7c87c0475",
        "linux_arm64": "7edf38be612c32a2ce8b77c293a5a61a22b0fc77ad9fe5c908fc9f73fb283550",
        "darwin_amd64": "72f4e12f103f3f0da6a6b38da764e924142242db6e1840b8e47b2c2a7aec8e21",
        "darwin_arm64": "e05bdd6e635cf1a4bc729139e569008734270391319bc447fa7c96c370355720",
    },
)
MOD
bazel build @rules_hydrophone//toolchain:current
hydrophone=$(bazel cquery --output=files @rules_hydrophone//toolchain:current 2>/dev/null | grep '/hydrophone$')
# The module version Go embeds in the binary: hydrophone 0.7.0 has no
# --version flag, and running it without one would try to reach a cluster.
version=$(python3 -I -c 'import re,sys; m=re.search(rb"mod\tsigs\.k8s\.io/hydrophone\t(v[0-9][^\t\n]*)", open(sys.argv[1],"rb").read()); print(m.group(1).decode() if m else "")' \
    "$(bazel info execution_root)/$hydrophone")
[[ "$version" == "v0.7.0" ]] || { echo "FAIL: the root's hydrophone.version(0.7.0) gave $version" >&2; exit 1; }
echo "ok: the root module's hydrophone.version(version = \"0.7.0\", sha256 = ...) fetched hydrophone $version"

echo "PASS: consumer check"
