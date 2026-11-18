#!/usr/bin/env bash
# Stand-in for kubectl in //tests:wrapper_test: `get --raw /version` prints
# a /version document for $FAKE_SERVER_VERSION (gitVersion; empty leaves it
# out) and $FAKE_SERVER_MINOR (the "minor" field, e.g. "35+"). With
# FAKE_KUBECTL_FAIL set, prints that to stderr and exits 1. Appends
# "kubectl <argv>" to $FAKE_LOG.
set -euo pipefail
printf 'kubectl %s\n' "$*" >> "${FAKE_LOG:?}"
if [[ -n "${FAKE_KUBECTL_FAIL:-}" ]]; then echo "$FAKE_KUBECTL_FAIL" >&2; exit 1; fi
v="${FAKE_SERVER_VERSION-v1.35.4}"
cat <<JSON
{
  "major": "1",
  "minor": "${FAKE_SERVER_MINOR:-35}",
  ${v:+\"gitVersion\": \"$v\",}
  "platform": "linux/amd64"
}
JSON
