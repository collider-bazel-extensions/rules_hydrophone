"""Checks hydrophone's JUnit report (Ginkgo's junit_01.xml).

    python3 junit_check.py <junit_01.xml>

Exit 0 only for a clean run: the file exists, parses, at least one spec ran
(not skipped), and no test case has a <failure> or <error> (nor do the
suites' failures/errors counts say otherwise). A missing, empty or
unparsable report is a failure, never a pass. Prints a summary and the
names of failing specs. Python 3.8+, standard library only.
"""

import os
import re
import sys
import xml.etree.ElementTree as ET

_MAX_LISTED = 25

# Ginkgo reports its suite-level nodes as test cases too. They pass even
# when the focus matched no spec, so they don't count as specs run (their
# failures still count).
_SUITE_NODE = re.compile(r"^\[(Synchronized)?(Before|After)Suite\]|^\[Report(Before|After)Suite\]|^\[DeferCleanup \(Suite\)\]")


def _int(v):
    try:
        return int(v or 0)
    except ValueError:
        return 0


def check(path):
    """Returns (ok, lines)."""
    if not os.path.exists(path):
        return False, [f"JUnit: {path} is missing: hydrophone produced no report (counted as a failure)."]
    if os.path.getsize(path) == 0:
        return False, [f"JUnit: {path} is empty (counted as a failure)."]
    try:
        root = ET.parse(path).getroot()
    except ET.ParseError as e:
        return False, [f"JUnit: {path} is not valid XML: {e} (counted as a failure)."]

    suites = [root] if root.tag == "testsuite" else list(root.iter("testsuite"))
    if root.tag not in ("testsuite", "testsuites"):
        return False, [f"JUnit: {path}: root element <{root.tag}>, expected <testsuites> or <testsuite>."]

    ran, suite_nodes, skipped, failed, errored = 0, 0, 0, [], []
    for case in root.iter("testcase"):
        name = case.get("name", "?")
        status = (case.get("status") or "").lower()
        if case.find("failure") is not None:
            failed.append(name)
        elif case.find("error") is not None:
            errored.append(name)
        if case.find("skipped") is not None or status in ("skipped", "pending"):
            skipped += 1
        elif _SUITE_NODE.match(name):
            suite_nodes += 1
        else:
            ran += 1
    attr_failures = sum(_int(s.get("failures")) for s in suites)
    attr_errors = sum(_int(s.get("errors")) for s in suites)
    n_fail = max(len(failed), attr_failures)
    n_err = max(len(errored), attr_errors)

    lines = [f"JUnit: {ran} spec(s) run, {n_fail} failed, {n_err} error(s), {skipped} skipped, {suite_nodes} suite node(s) ({path})"]
    for kind, names in (("failed", failed), ("error", errored)):
        for n in names[:_MAX_LISTED]:
            lines.append(f"  {kind}: {n}")
        if len(names) > _MAX_LISTED:
            lines.append(f"  ... and {len(names) - _MAX_LISTED} more {kind}")
    ok = True
    if n_fail or n_err:
        ok = False
    if ran == 0:
        lines.append("JUnit: no spec ran: focus/skip matched nothing, or the suite stopped before any spec (counted as a failure).")
        ok = False
    return ok, lines


def main(argv):
    if len(argv) != 2:
        print("usage: junit_check.py <junit_01.xml>", file=sys.stderr)
        return 2
    ok, lines = check(argv[1])
    for line in lines:
        print(line, file=sys.stdout if ok else sys.stderr)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
