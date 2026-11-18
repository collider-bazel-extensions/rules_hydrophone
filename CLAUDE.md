# rules_hydrophone

Bazel rules for Kubernetes conformance with hydrophone: `hydrophone_conformance_test` runs the conformance suite against the cluster named by `KUBECONFIG`, after refusing a cluster whose Kubernetes minor differs from the conformance image's.

See DESIGN.md.

## Commit requirements

- All tests must pass before any commit with code changes: `bazel test //tests/...`. Changes to the wrapper, the JUnit check or the cluster path also need `bazel test //tests:kind_e2e_test` (docker or podman) and `.github/consumer/check.sh <scratch dir>`.
- All documentation (`README.md`, `DESIGN.md`, `CLAUDE.md`) must be updated to reflect any code changes before committing: new rules, changed attributes, new public API surface, behaviour changes.
- Pins change only through `tools/update_versions.sh`; `--check` must pass.
- Delete every kind cluster a test run leaves (`kind get clusters`); the e2e deletes its own.

## Repo layout

```
rules_hydrophone/
├── MODULE.bazel              # module 0.1.0; hydrophone extension + toolchains; dev: rules_shell, rules_kind 0.5.0
├── .gitattributes            # tests/ and tools/ export-ignore: the release archive loads with //...
├── .github/consumer/check.sh # CI: the commit's git archive as a consumer module
├── defs.bzl                  # hydrophone_conformance_test, HydrophoneInfo, CONFORMANCE_IMAGES
├── extensions.bzl            # `hydrophone.version(version, sha256)` → hydrophone_<plat> repos (root tag, else ours)
├── private/
│   ├── versions.bzl          # DEFAULT_VERSION, HYDROPHONE_VERSIONS, KUBECTL_*, CONFORMANCE_IMAGES, BUSYBOX_IMAGE
│   ├── repositories.bzl      # per-platform repo: hydrophone tarball + kubectl + the toolchain impl
│   ├── providers.bzl         # HydrophoneInfo
│   ├── image.bzl             # conformance_image → digest-pinned ref + the minor from its tag
│   ├── conformance.bzl       # the rule, its stub-binary twin (tests), the macro (tags, size, timeout)
│   ├── conformance_test.sh.tmpl  # wrapper: KUBECONFIG, version check, hydrophone, trap cleanup, verdict
│   └── junit_check.py        # JUnit verdict (suite nodes aren't specs; missing/empty = fail)
├── toolchain/                # toolchain_type, per-platform toolchains, :current
├── tools/update_versions.sh  # hydrophone <ver> | kubectl <ver> | images [minors] | --check
└── tests/
    ├── BUILD.bazel, analysis_tests.bzl
    ├── stubs/                # fake_hydrophone.sh, fake_kubectl.sh (FAKE_* env)
    ├── wrapper_test.sh       # the generated wrapper with stubs: 22 cases
    ├── kind_e2e_test.sh      # real kind cluster: mismatch, focus subset via env_file, SIGTERM
    └── checksums_test.sh, version_test.sh
```

## Key concepts

- **Image selection.** `conformance_image` is a pinned minor or `repo:tag@sha256:digest`. The minor for the version check comes from the tag (`private/image.bzl`), never from a separate attribute. No digest, no tag, a non-version tag or an unpinned minor key is an analysis error.
- **Version check.** The pinned kubectl (1.36.6, within ±1 skew of 1.35-1.37) runs `get --raw /version`. The minor comes from `gitVersion` (`^v?(\d+)\.(\d+)`: EKS/GKE suffixes are fine), else `major`/`minor` without non-digits. A mismatch fails before hydrophone runs.
- **Cleanup.** hydrophone 0.8.0's `--cleanup` can't be combined with `--conformance`, and hydrophone ignores signals. So the wrapper runs `hydrophone --cleanup --namespace <its own hydrophone-<hex>>` after the run, from TERM/INT traps (10 s) and from EXIT. A watchdog stops hydrophone at `$TEST_TIMEOUT` minus 10% (≤ 300 s) so cleanup fits.
- **Verdict.** hydrophone exit 0, plus JUnit with ≥ 1 spec run and no `<failure>`/`<error>`, plus cleanup OK. Ginkgo suite nodes don't count as specs run.
- **Tags.** The macro always adds `manual`, `external`, `no-remote`; `block-network` is an analysis error. KUBECONFIG comes only from `--test_env` or `env_file` (no `inherited_environment`).
- **Toolchain.** Unversioned `hydrophone_<plat>` repos. Keep `DEFAULT_VERSION` and `hydrophone.version()` in `MODULE.bazel` equal (`//tests:version_test`).

## Public API

```python
load("@rules_hydrophone//:defs.bzl",
    "hydrophone_conformance_test",  # conformance_image, parallel, focus, skip, env_file (+ size/timeout/tags)
    "HydrophoneInfo",               # version, hydrophone, kubectl, kubectl_version
    "CONFORMANCE_IMAGES",           # {"1.35": "registry.k8s.io/conformance:v1.35.10@sha256:…", …}
)
```

## Development

```sh
bazel test //tests/...                       # no cluster
bazel test //tests:kind_e2e_test             # kind cluster (docker or rootless podman)
.github/consumer/check.sh /tmp/claude-consumer
tools/update_versions.sh --check
```

### Test results (last full run: 2026-11-18)

All 16 targets in `//tests/...` pass on Linux x86_64 (Fedora, Bazel 9.3.2), plus the manual e2e:

| Test target | What it verifies | Result |
|---|---|---|
| `//tests:analysis_tests_*` (13) | pinned minor and full reference resolve (image + minor in the wrapper); version parsing (EKS, GKE, rc, leading zeros); errors: unpinned tag, unknown minor, no tag, bad digest, non-version tag, empty, `parallel = 0`, `block-network`, `env_file` path, newline in `focus` | PASSED |
| `//tests:wrapper_test` | 22 cases with stub binaries: clean run (EKS / GKE / `"35+"` versions), full reference args, `env_file`; minor mismatch refused before hydrophone; JUnit failure, error, missing, empty, no spec run; hydrophone exit 1; cleanup failure; missing / relative / multi-path / `/tmp` KUBECONFIG; kubectl failure (credential plugin hint); SIGTERM cleanup (exit 143); `TEST_TIMEOUT` watchdog | PASSED |
| `//tests:checksums_test`, `//tests:version_test` | pins well-formed; hydrophone = DEFAULT_VERSION = MODULE.bazel; kubectl = KUBECTL_VERSION | PASSED |
| `//tests:kind_e2e_test` (manual) | rules_kind 0.5.0 cluster (`kindest/node:v1.35.8`, rootless podman): 1.36 image refused before hydrophone; 5-spec focus subset passes via `env_file` with JUnit + e2e.log in outputs and no namespace/RBAC left; SIGTERM mid-run cleans up | PASSED (169 s and 200 s; the first run found suite nodes counted as specs, since fixed) |

Other checks:
- **Mutations:** removing the minor comparison, ignoring JUnit `<error>`, or dropping the TERM trap each fail `wrapper_test`.
- **Pins:** `tools/update_versions.sh --check` passes. Regenerating every pin (`images`, `hydrophone 0.8.0`, `kubectl 1.36.6`) in a scratch copy gives a byte-identical `versions.bzl`. A corrupted digest is reported as DRIFT (exit 1).
- **Sandbox:** under the linux-sandbox, a `/tmp` kubeconfig fails with the hermetic-tmp hint and a `$HOME` one works. Inside a test, `HOME=$TEST_TMPDIR` and `PATH=.:/bin:/usr/bin:/usr/local/bin`.
- **Consumer:** `.github/consumer/check.sh` passes (about 18 s). The archive omits `tests/` and `tools/`, and `@rules_hydrophone//...` loads. Both conformance targets build (named explicitly, since they're `manual`). Run without KUBECONFIG, the test fails saying so, from the external repository's runfiles. An unpinned tag fails analysis. The root's `hydrophone.version(version = "0.7.0", sha256 = ...)` fetches v0.7.0 (read from the binary's Go build info).
- **Outputs:** on a passing run, `test.outputs/` holds `junit_01.xml` and `e2e.log`, and `test.xml` is the JUnit report.

## Known limitations

- `python3` (3.8+) on the host reads the JUnit report.
- A full conformance run needs `--test_timeout` above 3600 s (`-1,-1,-1,7200`).
- Credential plugins need `--test_env=PATH` and their credentials passed explicitly; the test's `HOME` is its temp dir.
- A kubeconfig under the host's `/tmp` is invisible in the sandbox (hermetic tmp).
- Images the suite pulls at run time aren't pinned; no `--test-repo` mirror support.
