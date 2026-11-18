# rules_hydrophone — design notes

rules_hydrophone answers [collider-bazel-extensions/.github#5](https://github.com/collider-bazel-extensions/.github/issues/5): Kubernetes conformance as a Bazel test against an existing cluster, so that a CI job which creates a managed cluster can run conformance alongside its other tests.

Its structure follows rules_gitleaks, the closest sibling that runs pinned upstream release binaries as tests:
- a per-platform binary toolchain pinned from published checksums;
- an extension whose root-module tag overrides the default (as rules_argocd, which also accepts SHA pins for unlisted versions);
- analysis tests;
- a maintainer script with `--check`;
- the README / DESIGN / CLAUDE.md set.

How a test consumes a rules_kind cluster comes from rules_kind v0.5.0: each `kind_cluster` writes `$TEST_TMPDIR/<name>.env`, whose `KUBECONFIG` names `$TEST_TMPDIR/<name>.kubeconfig`.

## Decisions

| Decision | Choice | Alternatives considered | Why |
|---|---|---|---|
| Reading the cluster's version | The pinned kubectl (`get --raw /version`), in the same per-platform repo as hydrophone | rules_kubectl; host kubectl; hydrophone itself; a Python HTTP client | See [The version check](#the-version-check). |
| kubectl version | 1.36.6: one minor behind the newest pinned conformance minor | the newest (1.37) | kubectl supports ±1 minor of skew, so 1.36 is in skew of every pinned minor (1.35-1.37). |
| Selecting the image | A pinned minor key (`"1.35"`), or a full `repo:tag@sha256:digest` | A separate `k8s_version` attribute next to the image; a digest-only reference | The minor comes from the reference's own tag, so it can't drift from the image. An unpinned tag, or no tag, is an analysis error. |
| Image digests | The manifest-list (index) digest | per-architecture digests | One pin works on amd64 and arm64 nodes (and ppc64le, s390x). `update_versions.sh` refuses a non-index digest. |
| busybox image | Pinned by index digest and passed as `--busybox-image` | hydrophone's default tag | It runs in the cluster too; the same reasoning as the conformance image. |
| Cleanup | A separate `hydrophone --cleanup` for the run's namespace, from a trap | `--conformance --cleanup` in one call (the request's wording) | hydrophone 0.8.0 marks `--conformance`, `--focus`, `--cleanup` and `--list-images` mutually exclusive, and it has no signal handling: SIGTERM kills it before its own end-of-run cleanup. |
| Namespace | `hydrophone-<8 random hex>` per run | hydrophone's default `conformance` | Cleanup can't delete another run's namespace (a fixed name would be deleted by a run that failed because another was using it), and concurrent runs don't collide. |
| Timeouts | `size = "enormous"`, `timeout = "eternal"` (3600 s) plus documented `--test_timeout=-1,-1,-1,7200`, and a watchdog at `$TEST_TIMEOUT` minus 10% (≤ 300 s) | a rule-level timeout above 3600 s (impossible) | A full run is about an hour; Bazel's maximum is borderline. The watchdog leaves cleanup time inside the test's timeout instead of relying on the 15 s SIGTERM grace. |
| Tags | `manual`, `external`, `no-remote` always; `block-network` is an analysis error | leaving tags to the caller | It needs a cluster named on the command line; its result depends on the cluster, not on inputs; the kubeconfig and credential plugins are local. |
| KUBECONFIG source | `--test_env` only (or `env_file`); no `inherited_environment` | inheriting KUBECONFIG from the shell | A developer's shell KUBECONFIG may name production. The cluster under test must be named explicitly. |
| rules_kind support | `env_file`: read KUBECONFIG from `$TEST_TMPDIR/<env_file>` | a `cluster` label attribute (a dependency on rules_kind) | Works with any service that writes an env file, and consumers don't depend on rules_kind. |
| Sandbox | Keep the sandbox; diagnose `/tmp` paths | `no-sandbox` by default | The sandbox shows the host filesystem read-only, so `$HOME` or workspace kubeconfigs work. Only the hermetic `/tmp` hides files, and the test explains that. Network is allowed unless `block-network`, which is refused. |
| JUnit | Parsed with `python3` (standard library `xml.etree`); copied to `$XML_OUTPUT_FILE` | grep on attributes | Ginkgo's report needs real parsing: suite nodes must be told from specs, and counts kept even when a suite's attributes disagree with its cases. `python3` is already a host requirement of siblings (rules_gitleaks). |
| Toolchain layout | One repo per platform, `hydrophone_<platform>`, holding hydrophone and kubectl | separate repos per binary | The two are always used together; one toolchain resolution fetches both, lazily, for one platform. |

## The version check

The test reads the server version before it creates anything, with the pinned kubectl: `kubectl --kubeconfig $KUBECONFIG get --raw /version`.

- **Why kubectl.** The kubeconfig can authenticate in any way client-go supports: exec credential plugins (`aws eks get-token`, `gke-gcloud-auth-plugin`, kubelogin), client certificates, tokens, auth providers, proxies. kubectl implements all of them, as hydrophone does (both are client-go), so whatever hydrophone could reach, the check can reach too.
- **The alternatives:**
  - **rules_kubectl** pins no binary: it uses `$KUBECTL` or the host's `kubectl`, which isn't hermetic.
  - **The host kubectl** isn't hermetic either, and its version is unknown.
  - **hydrophone itself** has no read-only mode. `--dry-run` and `--list-images` still create the namespace, RBAC and pod.
  - **A Python HTTP call to `/version`** would have to reimplement kubeconfig authentication.
- **Cost.** The pinned kubectl (about 60 MB) is downloaded with hydrophone (a 15 MB tarball), only for the platform a build needs.
- **Parsing.** The minor comes from `gitVersion`, read with `^v?([0-9]+)\.([0-9]+)`, so vendor suffixes don't matter: EKS `v1.35.4-eks-abcdef`, GKE `v1.35.2-gke.100` and OpenShift `v1.35.3+abc` all give `1.35`. Without a usable `gitVersion` it falls back to the `major` and `minor` fields with non-digits removed (`"35+"`). Leading zeros are normalised.
- **The image's minor** is computed at analysis time from the reference's tag (`private/image.bzl`: `v1.35.10` gives `1.35`; `v1.36.0-rc.1` gives `1.36`).
- **A mismatch** fails before hydrophone runs, so nothing is created on the cluster. The message names both versions and the fix: `conformance_image = "<minor>"` when that minor is pinned, otherwise a digest-pinned reference.

## The wrapper

`private/conformance_test.sh.tmpl` is bash; the rule substitutes shell-quoted values into it. Its steps:

1. **Resolve runfiles.** `$RUNFILES_DIR`, else `$TEST_SRCDIR`, else `$0.runfiles`, with paths computed in Starlark from `short_path`. The same wrapper therefore works in this repository, in a consumer (where rules_hydrophone's files are `rules_hydrophone+/…`), and when another test runs it as a child (this repository's e2e, or a rules_itest `service_test`).
2. **KUBECONFIG.** From `env_file` (sourced in a subshell, as rules_kind's own tests read env files) or the environment. It must be a single absolute path to a readable file. A path under `/tmp` that isn't visible gets the hermetic-tmp hint.
3. **Version check** (above).
4. **hydrophone, in the background.** `wait` is interruptible, so the TERM and INT traps run at once. A watchdog subshell sends hydrophone SIGTERM at the budget and leaves a marker, so the verdict can say why it stopped.
5. **Cleanup,** always. It is called explicitly after hydrophone, from the signal traps (10 s, inside Bazel's 15 s default grace), and from an EXIT trap as a safety net. It is idempotent. `with_timeout` is written in bash because macOS has no coreutils `timeout`.
6. **Verdict.** Every problem is reported, not just the first: watchdog fired, non-zero exit, JUnit not clean, cleanup failed.

`hydrophone_conformance_stubbed_test` is the same rule with `hydrophone` and `kubectl` replaceable. `//tests:wrapper_test` runs the real generated wrapper against stub scripts. It isn't exported from `defs.bzl`.

## JUnit

`private/junit_check.py` counts the `<testcase>`s of Ginkgo's `junit_01.xml`:
- **failures and errors:** cases with `<failure>`, and cases with `<error>` (Ginkgo reports panics and interrupts as errors). It takes the larger of these and the suites' `failures` / `errors` attributes;
- **skipped:** cases with `<skipped>` or `status="skipped"`;
- **suite nodes:** `[SynchronizedBeforeSuite]`, `[ReportAfterSuite] …`, `[DeferCleanup (Suite)]` and the like. They aren't specs: they pass even when the focus matched no spec, which would otherwise make a mistyped `focus` a vacuous pass. The kind e2e found this, since its report has 5 specs and 5 suite nodes;
- **specs run:** everything else.

The report fails when it is missing, empty, not XML, has no spec run, or has any failure or error. On success it is copied to `$XML_OUTPUT_FILE`, so CI test views list every spec.

## Version pins and the extension

- **`private/versions.bzl`** holds `HYDROPHONE_VERSIONS` (version → platform → SHA-256), `KUBECTL_VERSION` with `KUBECTL_SHA256`, `CONFORMANCE_IMAGES` (minor → `registry.k8s.io/conformance:v<patch>@sha256:<index>`) and `BUSYBOX_IMAGE`.
- **The `hydrophone` extension** creates `hydrophone_<platform>` repos. The root module's `hydrophone.version()` wins; otherwise rules_hydrophone's own tag applies (`DEFAULT_VERSION`). A version not in `HYDROPHONE_VERSIONS` needs `sha256 = {platform: sha}`, which also replaces a known version's pins (the rules_argocd pattern). Repos carry no version in their name, so `toolchain/BUILD.bazel` never changes.
- **`tools/update_versions.sh`** regenerates all of it:
  - hydrophone from the release's checksums file, and kubectl from dl.k8s.io's `.sha256` files. Both are cross-checked against the downloads.
  - The images:
    - the supported minors come from kubernetes/website's `data/releases/schedule.yaml` (end of life not passed), and the latest patch from `dl.k8s.io/release/stable-<minor>.txt`;
    - the digest comes from the registry v2 API (`Docker-Content-Digest`), verified against the hash of the body served;
    - it must be an index with linux/amd64 and linux/arm64.
  - `--check` fails on drift only. A newer patch or a changed set of supported minors is a NOTE, so new upstream patches don't break unrelated CI runs.

## End-to-end test

`//tests:kind_e2e_test` starts a rules_kind `kind_cluster` (1.35, `kindest/node:v1.35.8`) from its launcher, as rules_kind's `two_clusters_test` does, and runs two conformance targets as child processes:

1. **`kind_mismatch_conformance` (image `"1.36"`):** must fail naming 1.35 and 1.36, before hydrophone runs, leaving nothing on the cluster.
2. **`kind_focus_conformance` (image `"1.35"`, `env_file = "conformance_cluster.env"`):** five API-only `[Conformance]` specs, so there are no image pulls beyond the conformance and busybox images:
   - server version;
   - Discovery PreferredVersion;
   - ConfigMap lifecycle;
   - Secrets patch;
   - Services listing.

   It must pass with 5 specs in the JUnit report and `e2e.log` in the outputs. Afterwards no `hydrophone-*` namespace and no `conformance-serviceaccount*` ClusterRole or ClusterRoleBinding may remain.
3. **The same target again, sent SIGTERM** once the conformance pod exists. It must exit 143 after running cleanup, and the namespace and RBAC must be gone within 3 minutes.

## Not done

- **A full conformance run** is not part of CI; it is an hour of a real cluster. CI runs the focus subset.
- **Images the suite pulls at run time** (agnhost, nginx, …) by tag are upstream's choice. `--test-repo` / `--test-repo-list` (a private mirror) aren't exposed.
- **No `extra_args`** for hydrophone's `--extra-args`, `--extra-ginkgo-args`, `--startup-timeout` or `--verbosity`.
- **Windows** isn't supported (hydrophone ships a Windows binary, but the wrapper is bash).
- **Results aren't certified.** hydrophone runs the conformance suite; submitting results to the CNCF is outside this rule.
