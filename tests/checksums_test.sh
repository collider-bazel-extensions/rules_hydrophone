#!/usr/bin/env bash
# Fails when a pin in private/versions.bzl is malformed: every hydrophone
# version and kubectl need a 64-hex SHA-256 for all 4 platforms, and every
# image a tag plus a sha256 digest. No network (tools/update_versions.sh
# --check compares them with upstream).
set -euo pipefail
f="${TEST_SRCDIR}/_main/private/versions.bzl"
block() { sed -n "/^$1 = {/,/^}/p" "$f"; }
versions=$(block HYDROPHONE_VERSIONS | grep -cE '^    "[0-9][^"]*": \{' || true)
hydro=$(block HYDROPHONE_VERSIONS | grep -cE '^        "(linux|darwin)_(amd64|arm64)": "[0-9a-f]{64}",$' || true)
kubectl=$(block KUBECTL_SHA256 | grep -cE '^    "(linux|darwin)_(amd64|arm64)": "[0-9a-f]{64}",$' || true)
images=$(block CONFORMANCE_IMAGES | grep -cE '^    "1\.[0-9]+": ' || true)
pinned=$(block CONFORMANCE_IMAGES | grep -cE '^    "1\.([0-9]+)": "registry\.k8s\.io/conformance:v1\.[0-9]+\.[0-9]+@sha256:[0-9a-f]{64}",$' || true)
busybox=$(grep -cE '^BUSYBOX_IMAGE = "[^"]+:[^"@]+@sha256:[0-9a-f]{64}"$' "$f" || true)
echo "hydrophone versions=$versions shas=$hydro kubectl shas=$kubectl images=$images pinned=$pinned busybox=$busybox"
status=0
if [[ "$versions" -eq 0 || "$hydro" -ne $(( versions * 4 )) ]]; then
  echo "FAIL: every hydrophone version needs 4 platforms, each a 64-hex SHA-256 (tools/update_versions.sh hydrophone <version>)" >&2; status=1
fi
[[ "$kubectl" -eq 4 ]] || { echo "FAIL: KUBECTL_SHA256 needs 4 platforms (tools/update_versions.sh kubectl <version>)" >&2; status=1; }
if [[ "$images" -eq 0 || "$pinned" -ne "$images" ]]; then
  echo "FAIL: every CONFORMANCE_IMAGES entry needs registry.k8s.io/conformance:v<minor>.<patch>@sha256:<64 hex> (tools/update_versions.sh images)" >&2; status=1
fi
# Each key's minor is its tag's minor.
while read -r key tag; do
  [[ "$tag" == "$key".* ]] || { echo "FAIL: CONFORMANCE_IMAGES[\"$key\"] has tag v$tag" >&2; status=1; }
done < <(block CONFORMANCE_IMAGES | sed -n 's/^    "\(1\.[0-9]*\)": "registry\.k8s\.io\/conformance:v\([^@]*\)@.*/\1 \2/p')
[[ "$busybox" -eq 1 ]] || { echo "FAIL: BUSYBOX_IMAGE must be pinned by digest" >&2; status=1; }
(( status == 0 )) && echo "PASS"
exit "$status"
