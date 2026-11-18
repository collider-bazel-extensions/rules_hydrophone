#!/usr/bin/env bash
# The toolchain's hydrophone is DEFAULT_VERSION, which MODULE.bazel names
# too, and its kubectl is KUBECTL_VERSION.
# Argv: <versions.bzl> <MODULE.bazel> <hydrophone> <kubectl>
set -euo pipefail
r="$TEST_SRCDIR"
loc() { if [[ "$1" == ../* ]]; then echo "$r/${1#../}"; else echo "$r/_main/$1"; fi; }
default=$(sed -n 's/^DEFAULT_VERSION = "\(.*\)"/\1/p' "$(loc "$1")")
module=$(sed -n 's/^hydrophone.version(version = "\(.*\)")/\1/p' "$(loc "$2")")
binary=$("$(loc "$3")" --version | sed -n 's/^ *version: *v\(.*\)/\1/p')
want_kubectl=$(sed -n 's/^KUBECTL_VERSION = "\(.*\)"/\1/p' "$(loc "$1")")
kubectl=$("$(loc "$4")" version --client -o json | sed -n 's/.*"gitVersion": "v\([^"]*\)".*/\1/p')
echo "DEFAULT_VERSION=$default MODULE.bazel=$module hydrophone=$binary KUBECTL_VERSION=$want_kubectl kubectl=$kubectl"
[[ -n "$default" && "$module" == "$default" && "$binary" == "$default" ]] || { echo "FAIL: hydrophone versions differ" >&2; exit 1; }
[[ -n "$kubectl" && "$kubectl" == "$want_kubectl" ]] || { echo "FAIL: kubectl is $kubectl, not $want_kubectl" >&2; exit 1; }
echo "PASS"
