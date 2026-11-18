#!/usr/bin/env bash
# End to end against a real kind cluster (rules_kind v0.5.0, Kubernetes 1.35):
#   1. a 1.36 conformance image is refused before hydrophone runs, naming
#      both versions, and nothing is created on the cluster;
#   2. a short focus subset of [Conformance] specs passes, reading KUBECONFIG
#      from the cluster's env file (env_file), with junit_01.xml and e2e.log
#      in the outputs, and cleanup leaves no hydrophone namespace,
#      ClusterRole or ClusterRoleBinding behind;
#   3. SIGTERM mid-run (what Bazel sends on a timeout) still cleans up.
# Argv: <kind_cluster launcher> <focus test> <mismatch test>
set -uo pipefail
r="${TEST_SRCDIR:?}/_main"
launcher="$r/$1"; focus_test="$r/$2"; mismatch_test="$r/$3"
t="${TEST_TMPDIR:?}"
outs="${TEST_UNDECLARED_OUTPUTS_DIR:-$t/outputs}"; mkdir -p "$outs"

lpid=""
stop_cluster() {
  if [[ -n "$lpid" ]]; then
    echo "stopping the cluster (launcher pid $lpid)"
    kill -TERM "$lpid" 2>/dev/null; wait "$lpid" 2>/dev/null; lpid=""
  fi
}
trap stop_cluster EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
elapsed() { echo "$(( $(date +%s) - start ))s"; }

start=$(date +%s)
"$launcher" > "$t/cluster.log" 2>&1 &
lpid=$!
echo "waiting for the kind cluster (launcher pid $lpid)..."
# Up to 900 s: includes waiting for a cluster slot (RULES_KIND_MAX_CLUSTERS).
deadline=$(( $(date +%s) + 900 ))
while [[ ! -f "$t/conformance_cluster.env" ]]; do
  if (( $(date +%s) > deadline )) || ! kill -0 "$lpid" 2>/dev/null; then
    tail -n 40 "$t/cluster.log" >&2; fail "the cluster's env file was not written"
  fi
  sleep 2
done
envvar() { (set -a; source "$t/conformance_cluster.env"; printenv "$1"); }
kc=$(envvar KUBECONFIG); KUBECTL=$(envvar KUBECTL)
k() { "$KUBECTL" --kubeconfig "$kc" "$@"; }
echo "cluster ready after $(elapsed): $(envvar KIND_CLUSTER_NAME), $(k version -o json | sed -n 's/.*"gitVersion": "\(v1[^"]*\)".*/\1/p' | tail -n 1)"

leftovers() {  # hydrophone's namespaces and cluster-scoped RBAC, if any
  k get namespaces -o name | grep '^namespace/hydrophone-'
  k get clusterroles,clusterrolebindings -o name | grep 'conformance-serviceaccount'
}

# inner <name> <test> [VAR=value ...]: runs a conformance test's wrapper the
# way bazel test would, with its own outputs dir and XML_OUTPUT_FILE.
inner() {
  local name="$1" bin="$2"; shift 2
  mkdir -p "$outs/$name"
  env XML_OUTPUT_FILE="$outs/$name/test.xml" TEST_UNDECLARED_OUTPUTS_DIR="$outs/$name" "$@" "$bin" \
    > "$outs/$name/log.txt" 2>&1
}

# ---- 1. mismatch ----------------------------------------------------------------
s=$(date +%s); rc=0
inner mismatch "$mismatch_test" KUBECONFIG="$kc" || rc=$?
cat "$outs/mismatch/log.txt"
(( rc != 0 )) || fail "the 1.36 image ran against a 1.35 cluster"
grep -qE "Kubernetes minor mismatch: the cluster runs 1\.35 \(v1\.35\.[0-9]+\) but the conformance image is for 1\.36 \(registry\.k8s\.io/conformance:v1\.36\." "$outs/mismatch/log.txt" \
  || fail "the refusal doesn't name both versions"
grep -q "API endpoint" "$outs/mismatch/log.txt" && fail "hydrophone ran"
[[ -z "$(leftovers)" ]] || fail "the refused run created: $(leftovers)"
echo "PASS: a 1.36 image is refused on the 1.35 cluster before hydrophone runs ($(( $(date +%s) - s ))s)"

# ---- 2. focus subset, KUBECONFIG from the env file -------------------------------
s=$(date +%s); rc=0
inner focus "$focus_test" KUBECONFIG= || rc=$?
cat "$outs/focus/log.txt"
(( rc == 0 )) || fail "the focus run failed (exit $rc)"
grep -qF 'KUBECONFIG='"$kc"' (from $TEST_TMPDIR/conformance_cluster.env)' "$outs/focus/log.txt" || fail "KUBECONFIG not read from the env file"
grep -qE "JUnit: 5 spec\(s\) run, 0 failed, 0 error\(s\)" "$outs/focus/log.txt" || fail "expected 5 specs run, none failed"
[[ $(grep -c '<testcase name="\[It\] .*\[Conformance\]" [^>]*status="passed"' "$outs/focus/junit_01.xml") == 5 ]] \
  || fail "junit_01.xml doesn't show 5 passed [Conformance] specs"
for f in junit_01.xml e2e.log test.xml; do [[ -s "$outs/focus/$f" ]] || fail "no $f in the outputs"; done
ns=$(sed -n 's/.*namespace \(hydrophone-[0-9a-f]*\),.*/\1/p' "$outs/focus/log.txt" | head -n 1)
[[ -n "$ns" ]] || fail "no namespace in the log"
grep -q "Deleted Namespace $ns" "$outs/focus/log.txt" || fail "hydrophone did not report deleting $ns"
left=$(leftovers)
[[ -z "$left" ]] || fail "left behind after the run: $left"
echo "PASS: 5 [Conformance] specs passed in $(( $(date +%s) - s ))s; namespace $ns, its ClusterRole and ClusterRoleBinding are gone"

# ---- 3. SIGTERM mid-run ----------------------------------------------------------
s=$(date +%s)
mkdir -p "$outs/sigterm"
env KUBECONFIG= TEST_UNDECLARED_OUTPUTS_DIR="$outs/sigterm" XML_OUTPUT_FILE="$outs/sigterm/test.xml" \
  "$focus_test" > "$outs/sigterm/log.txt" 2>&1 &
ipid=$!
ns=""
for _ in $(seq 1 300); do
  ns=$(k get pods -A -o jsonpath='{range .items[?(@.metadata.name=="e2e-conformance-test")]}{.metadata.namespace}{"\n"}{end}' 2>/dev/null | grep '^hydrophone-' | head -n 1)
  [[ -n "$ns" ]] && break
  kill -0 "$ipid" 2>/dev/null || break
  sleep 1
done
[[ -n "$ns" ]] || { cat "$outs/sigterm/log.txt" >&2; fail "the conformance pod never appeared"; }
sleep 5
echo "conformance pod running in $ns; sending SIGTERM to the test"
kill -TERM "$ipid"; rc=0; wait "$ipid" || rc=$?
cat "$outs/sigterm/log.txt"
(( rc == 143 )) || fail "exit $rc after SIGTERM, expected 143"
grep -q "received SIGTERM" "$outs/sigterm/log.txt" || fail "no SIGTERM handling in the log"
grep -q "cleanup: hydrophone --cleanup --namespace $ns" "$outs/sigterm/log.txt" || fail "no cleanup for $ns"
# The deletes are issued at once; the namespace then finishes terminating.
for _ in $(seq 1 180); do
  [[ -z "$(leftovers)" ]] && break
  sleep 1
done
left=$(leftovers)
[[ -z "$left" ]] || fail "left behind after SIGTERM: $left"
echo "PASS: SIGTERM mid-run cleaned up $ns ($(( $(date +%s) - s ))s)"

stop_cluster
echo "PASS ($(elapsed) in all)"
