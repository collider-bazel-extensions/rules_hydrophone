#!/usr/bin/env bash
# Stand-in for hydrophone in //tests:wrapper_test. Appends its argv to
# $FAKE_LOG, then behaves as $FAKE_HYDROPHONE says:
#   pass          clean JUnit (2 specs run, 1 skipped, 1 suite node), exit 0
#   junit_failure JUnit with a <failure>, exit 0
#   junit_error   JUnit with an <error>, exit 0
#   no_junit      e2e.log only, exit 0
#   empty_junit   an empty junit_01.xml, exit 0
#   none_ran      every spec skipped (a suite node passed), exit 0
#   exit_nonzero  clean JUnit, exit 1
#   hang          sleeps (for SIGTERM and the TEST_TIMEOUT watchdog)
# `--cleanup` logs and exits $FAKE_CLEANUP_RC (default 0).
set -euo pipefail
printf '%s\n' "$*" >> "${FAKE_LOG:?}"
out=""; prev=""
for a in "$@"; do
  [[ "$prev" == "--output-dir" ]] && out="$a"
  prev="$a"
done
for a in "$@"; do
  if [[ "$a" == "--cleanup" ]]; then exit "${FAKE_CLEANUP_RC:-0}"; fi
done
mkdir -p "$out"
echo "fake e2e log" > "$out/e2e.log"
junit() {  # <testcase lines...>
  { echo '<?xml version="1.0" encoding="UTF-8"?>'
    echo '<testsuites tests="3" disabled="0" errors="0" failures="0" time="1">'
    echo '  <testsuite name="Kubernetes e2e suite" tests="3" skipped="0" errors="0" failures="0" time="1">'
    printf '    %s\n' "$@"
    echo '  </testsuite>'
    echo '</testsuites>'; } > "$out/junit_01.xml"
}
ok1='<testcase name="[sig-node] ConfigMap should run through a ConfigMap lifecycle [Conformance]" status="passed" time="1"></testcase>'
ok2='<testcase name="[sig-node] Secrets should patch a secret [Conformance]" status="passed" time="1"></testcase>'
suite='<testcase name="[SynchronizedBeforeSuite]" classname="Kubernetes e2e suite" status="passed" time="0"></testcase>'
skip='<testcase name="[sig-apps] skipped one [Conformance]" status="skipped" time="0"><skipped message="skipped"></skipped></testcase>'
case "${FAKE_HYDROPHONE:-pass}" in
  pass) junit "$suite" "$ok1" "$ok2" "$skip" ;;
  junit_failure) junit "$ok1" '<testcase name="[sig-network] DNS should provide DNS for services [Conformance]" status="failed" time="9"><failure message="timed out" type="failed">boom</failure></testcase>' ;;
  junit_error) junit "$ok1" '<testcase name="[sig-storage] EmptyDir should panic [Conformance]" status="panicked" time="1"><error message="panic" type="panicked">panic</error></testcase>' ;;
  no_junit) ;;
  empty_junit) : > "$out/junit_01.xml" ;;
  none_ran) junit "$suite" "$skip" ;;   # a focus that matched nothing: only suite nodes ran
  exit_nonzero) junit "$ok1" "$ok2"; exit 1 ;;
  hang) exec sleep 300 ;;
  *) echo "fake_hydrophone: unknown FAKE_HYDROPHONE=$FAKE_HYDROPHONE" >&2; exit 99 ;;
esac
