#!/usr/bin/env bash
# The hydrophone_conformance_test wrapper, with stub hydrophone and kubectl
# (tests/stubs): no cluster. Each case runs the real generated wrapper with
# the stubs' behaviour set through FAKE_* variables, and checks its exit
# status, its message, and what it ran ($FAKE_LOG lists every stub call).
# Argv: <stub_135> <stub_full> <stub_env_file>
set -uo pipefail
r="${TEST_SRCDIR:?}/_main"
stub_135="$r/$1"; stub_full="$r/$2"; stub_env_file="$r/$3"
t="${TEST_TMPDIR:?}"

kc="$t/cluster.kubeconfig"; echo "apiVersion: v1" > "$kc"
pinned_135=$(sed -n 's/^    "1.35": "\(.*\)",$/\1/p' "$r/private/versions.bzl")
busybox=$(sed -n 's/^BUSYBOX_IMAGE = "\(.*\)"$/\1/p' "$r/private/versions.bzl")
[[ -n "$pinned_135" && -n "$busybox" ]] || { echo "FAIL: could not read pins from versions.bzl" >&2; exit 1; }

failures=0
fail() { echo "FAIL [$case]: $*" >&2; echo "---- output:" >&2; cat "$t/$case.out" >&2; echo "---- stub calls:" >&2; cat "$FAKE_LOG" >&2; failures=$((failures + 1)); }
ok() { echo "ok   [$case] $*"; }

# run <case> <bin> [VAR=value ...]: runs the wrapper with a fresh stub log,
# undeclared outputs dir and XML_OUTPUT_FILE; sets $rc.
run() {
  case="$1"; local bin="$2"; shift 2
  export FAKE_LOG="$t/$case.calls"; : > "$FAKE_LOG"
  rm -rf "${t:?}/$case.outputs"; mkdir -p "$t/$case.outputs"
  rc=0
  env KUBECONFIG="$kc" TEST_UNDECLARED_OUTPUTS_DIR="$t/$case.outputs" XML_OUTPUT_FILE="$t/$case.xml" \
      FAKE_HYDROPHONE=pass FAKE_SERVER_VERSION=v1.35.4 "$@" "$bin" > "$t/$case.out" 2>&1 || rc=$?
}
has() { grep -qF -- "$1" "$t/$case.out"; }
called() { grep -qF -- "$1" "$FAKE_LOG"; }
runs() { grep -c -- "--conformance-image" "$FAKE_LOG"; }   # hydrophone test runs
cleanups() { grep -c -- "--cleanup" "$FAKE_LOG"; }
# Assertions for && chains: each records its own failure.
want() { has "$1" || { fail "no '$1' in the output"; return 1; }; }
no_run() { (( $(runs) == 0 && $(cleanups) == 0 )) || { fail "hydrophone ran"; return 1; }; }
no_calls() { [[ ! -s "$FAKE_LOG" ]] || { fail "kubectl or hydrophone was called"; return 1; }; }

expect_fail() {  # <message> : failed, with the message
  if (( rc == 0 )); then fail "passed; expected a failure"; return 1; fi
  has "$1" || { fail "no '$1' in the output"; return 1; }
}
expect_cleaned() {  # hydrophone ran once and --cleanup ran for its namespace
  local ns
  ns=$(sed -n 's/.*--namespace \(hydrophone-[0-9a-f]\{8\}\) .*/\1/p' "$FAKE_LOG" | head -n 1)
  [[ -n "$ns" ]] || { fail "no hydrophone-<8 hex> namespace passed"; return 1; }
  grep -q -- "--cleanup --kubeconfig $kc --namespace $ns " "$FAKE_LOG" || { fail "no --cleanup for $ns"; return 1; }
}

# ---- passes -------------------------------------------------------------------
run clean_eks "$stub_135" FAKE_SERVER_VERSION=v1.35.4-eks-abcdef
if (( rc != 0 )); then fail "exit $rc"
elif ! has "cluster: Kubernetes 1.35 (v1.35.4-eks-abcdef)"; then fail "EKS version not parsed"
elif ! called "--kubeconfig $kc --namespace hydrophone-"; then fail "kubeconfig/namespace not passed"
elif ! called "--conformance-image $pinned_135 --busybox-image $busybox --output-dir $t/clean_eks.outputs --parallel 1 --conformance"; then fail "arguments"
elif ! expect_cleaned; then :
elif [[ ! -f "$t/clean_eks.outputs/junit_01.xml" || ! -f "$t/clean_eks.outputs/e2e.log" ]]; then fail "reports not in the undeclared outputs"
elif ! cmp -s "$t/clean_eks.outputs/junit_01.xml" "$t/clean_eks.xml"; then fail "JUnit not copied to XML_OUTPUT_FILE"
elif ! has "JUnit: 2 spec(s) run, 0 failed, 0 error(s), 1 skipped, 1 suite node(s)"; then fail "summary"
else ok "clean run passes (EKS v1.35.4-eks-abcdef); reports in outputs; cleanup ran"
fi

run clean_gke "$stub_135" FAKE_SERVER_VERSION=v1.35.2-gke.100
if (( rc != 0 )); then fail "exit $rc"; elif want "cluster: Kubernetes 1.35 (v1.35.2-gke.100)"; then ok "GKE v1.35.2-gke.100 parsed"; fi

run minor_plus "$stub_135" FAKE_SERVER_VERSION= FAKE_SERVER_MINOR=35+
if (( rc != 0 )); then fail "exit $rc"; elif want "cluster: Kubernetes 1.35 ()"; then ok "no gitVersion: minor \"35+\" parsed"; fi

run full_ref "$stub_full" FAKE_SERVER_VERSION=v1.36.9
if (( rc != 0 )); then fail "exit $rc"
elif ! called "--conformance-image registry.example.com/mirror/conformance:v1.36.2@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"; then fail "image"
elif ! called "--parallel 4 --focus ConfigMap|Secrets --skip Serial"; then fail "parallel/focus/skip"
elif called "--conformance "; then fail "--conformance passed together with --focus"
else ok "full reference: minor 1.36 from its tag; parallel, focus (instead of --conformance) and skip passed"
fi

kc_env="$t/from_env_file.kubeconfig"; echo "apiVersion: v1" > "$kc_env"
printf 'KUBECONFIG=%s\nKIND_CLUSTER_NAME=kind-x\n' "$kc_env" > "$t/fake.env"
run env_file "$stub_env_file" KUBECONFIG=
if (( rc != 0 )); then fail "exit $rc"
elif ! called "--kubeconfig $kc_env "; then fail "KUBECONFIG not taken from \$TEST_TMPDIR/fake.env"
else ok "env_file: KUBECONFIG read from \$TEST_TMPDIR/fake.env"
fi
rm "$t/fake.env"
run env_file_missing "$stub_env_file"
expect_fail "\$TEST_TMPDIR/fake.env does not exist" && no_run && ok "env_file missing: fails, names the file"

# ---- version check ------------------------------------------------------------
run mismatch "$stub_135" FAKE_SERVER_VERSION=v1.36.3-eks-0123
if expect_fail "Kubernetes minor mismatch: the cluster runs 1.36 (v1.36.3-eks-0123) but the conformance image is for 1.35 ($pinned_135)"; then
  if (( $(runs) != 0 || $(cleanups) != 0 )); then fail "hydrophone ran"
  elif ! has 'Use conformance_image = "1.36"'; then fail "no pinned-minor suggestion"
  else ok "minor mismatch refused before hydrophone ran; names both versions"
  fi
fi

run mismatch_unpinned "$stub_135" FAKE_SERVER_VERSION=v1.34.1
expect_fail "the cluster runs 1.34" && want "registry.k8s.io/conformance:v1.34.<patch>@sha256:<digest>" \
  && no_run && ok "mismatch with an unpinned minor suggests a digest-pinned reference"

run kubectl_fails "$stub_135" "FAKE_KUBECTL_FAIL=getting credentials: exec: executable aws not found"
expect_fail "could not read the cluster's version" && want "executable aws not found" && want "--test_env=PATH" \
  && no_run && ok "unreachable cluster / missing credential plugin: kubectl's error and the --test_env hint"

# ---- KUBECONFIG ----------------------------------------------------------------
run no_kubeconfig "$stub_135" KUBECONFIG=
expect_fail "KUBECONFIG is not set" && want "--test_env=KUBECONFIG=" && no_calls \
  && ok "missing KUBECONFIG fails clearly, before any call"
run relative "$stub_135" KUBECONFIG=cluster.kubeconfig
expect_fail "is not an absolute path" && ok "relative KUBECONFIG refused"
run several "$stub_135" KUBECONFIG="$kc:$kc"
expect_fail "lists several files" && ok "KUBECONFIG list refused"
run tmp_missing "$stub_135" KUBECONFIG=/tmp/rules-hydrophone-no-such.kubeconfig
expect_fail "is not a readable file inside the test" && want "private /tmp" && ok "unreadable /tmp kubeconfig: sandbox hint"

# ---- results ----------------------------------------------------------------------
run junit_failure "$stub_135" FAKE_HYDROPHONE=junit_failure
expect_fail "failed: [sig-network] DNS should provide DNS for services [Conformance]" && expect_cleaned \
  && ok "a JUnit <failure> fails (hydrophone exited 0)"
run junit_error "$stub_135" FAKE_HYDROPHONE=junit_error
expect_fail "error: [sig-storage] EmptyDir should panic [Conformance]" && expect_cleaned \
  && ok "a JUnit <error> fails (hydrophone exited 0)"
run no_junit "$stub_135" FAKE_HYDROPHONE=no_junit
expect_fail "junit_01.xml is missing" && expect_cleaned && ok "a missing JUnit report fails"
run empty_junit "$stub_135" FAKE_HYDROPHONE=empty_junit
expect_fail "junit_01.xml is empty" && ok "an empty JUnit report fails"
run none_ran "$stub_135" FAKE_HYDROPHONE=none_ran
expect_fail "no spec ran" && ok "a report where no spec ran (only a suite node) fails"
run exit_nonzero "$stub_135" FAKE_HYDROPHONE=exit_nonzero
expect_fail "hydrophone exited 1." && expect_cleaned && ok "hydrophone's non-zero exit fails (clean JUnit)"
run cleanup_fails "$stub_135" FAKE_CLEANUP_RC=3
expect_fail "hydrophone --cleanup failed (exit 3)" && ok "a failed cleanup fails the test"

# ---- interruption --------------------------------------------------------------
case=sigterm
export FAKE_LOG="$t/$case.calls"; : > "$FAKE_LOG"
KUBECONFIG="$kc" TEST_UNDECLARED_OUTPUTS_DIR="$t/$case.outputs" FAKE_HYDROPHONE=hang \
  FAKE_SERVER_VERSION=v1.35.0 "$stub_135" > "$t/$case.out" 2>&1 &
pid=$!
for _ in $(seq 1 100); do (( $(runs) > 0 )) && break; sleep 0.1; done
sleep 0.3
kill -TERM "$pid"; rc=0; wait "$pid" || rc=$?
if (( rc != 143 )); then fail "exit $rc, expected 143"
elif ! has "received SIGTERM"; then fail "no SIGTERM message"
elif expect_cleaned; then ok "SIGTERM (Bazel's timeout): hydrophone stopped, --cleanup ran, exit 143"
fi

run deadline "$stub_135" FAKE_HYDROPHONE=hang TEST_TIMEOUT=6
expect_fail "hydrophone was stopped after 5s, 1s before the test's timeout (6s)" && expect_cleaned \
  && ok "TEST_TIMEOUT watchdog stops hydrophone in time to clean up"

if (( failures )); then echo "$failures case(s) failed" >&2; exit 1; fi
echo "PASS"
