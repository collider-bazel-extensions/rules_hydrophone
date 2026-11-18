# rules_hydrophone

Bazel rules for Kubernetes conformance with [hydrophone](https://github.com/kubernetes-sigs/hydrophone). `hydrophone_conformance_test` runs the upstream conformance suite as a Bazel test against an existing cluster, named by `KUBECONFIG`.

- **Version check first.** Before it creates anything, the test reads the cluster's version and refuses a cluster whose Kubernetes minor differs from the conformance image's. The message names both versions.
- **Pass means clean.** The test passes only if hydrophone exits 0 **and** its JUnit report shows at least one spec run and no failures or errors. A missing or empty report fails.
- **Always cleaned up.** hydrophone runs in a namespace of its own, and `hydrophone --cleanup` runs afterwards whatever happened: a failure, a Bazel timeout (SIGTERM) or Ctrl-C.
- **Reports in the test's outputs.** `junit_01.xml` and `e2e.log` go to `bazel-testlogs/<pkg>/<name>/test.outputs/`, and the JUnit report also becomes the test's `test.xml`.
- **Pinned.** hydrophone 0.8.0 release binaries, a kubectl for the version check, and `registry.k8s.io/conformance` by digest for each supported Kubernetes minor.

It is meant for a managed cluster created by your CI, such as a weekly EKS run, and also works against a [rules_kind](https://github.com/collider-bazel-extensions/rules_kind) cluster.

No host hydrophone or kubectl is needed: both are upstream release binaries for linux and darwin on amd64 and arm64, pinned by SHA-256 and downloaded only for the platform a build needs. The test needs `python3` (3.8+) on the host to read the JUnit report.

## Installation

Bzlmod only.

```python
bazel_dep(name = "rules_hydrophone", version = "0.1.0")
archive_override(
    module_name = "rules_hydrophone",
    urls = ["https://github.com/collider-bazel-extensions/rules_hydrophone/archive/refs/tags/v0.1.0.tar.gz"],
    strip_prefix = "rules_hydrophone-0.1.0",
    integrity = "INTEGRITY_AFTER_TAG",
)
```

That's all: rules_hydrophone registers its toolchain. The release archive leaves out `tests/` (whose packages load the dev-only rules_shell and rules_kind) and `tools/`, so `bazel query @rules_hydrophone//...` works for consumers. rules_kind is a dev dependency only; you don't need it unless you use it yourself.

To use another hydrophone version, name it in your own `MODULE.bazel`. Only the root module's tag counts. A version that rules_hydrophone doesn't pin needs its SHA-256s, from the release's `hydrophone_<version>_checksums.txt`:

```python
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
```

## `hydrophone_conformance_test`

```python
load("@rules_hydrophone//:defs.bzl", "hydrophone_conformance_test")

hydrophone_conformance_test(
    name = "conformance_test",
    conformance_image = "1.35",     # the cluster's Kubernetes minor
    parallel = 4,
    tags = ["eks-weekly"],
)
```

```sh
bazel test //:conformance_test \
    --test_env=KUBECONFIG=/abs/path/to/kubeconfig \
    --test_timeout=-1,-1,-1,7200
```

| Argument | Default | |
|---|---|---|
| `conformance_image` | required | A pinned minor (`"1.35"`), or `"<repo>:<tag>@sha256:<digest>"` (see [Choosing the image](#choosing-the-image)) |
| `parallel` | `1` | Ginkgo processes (`hydrophone --parallel`). 1 or more. |
| `focus` | every `[Conformance]` spec | Regular expression of specs to run (`hydrophone --focus`). It replaces the `[Conformance]` filter, so name conformance specs. |
| `skip` | none | Regular expression of specs to skip (`hydrophone --skip`) |
| `env_file` | none | Read `KUBECONFIG` from `$TEST_TMPDIR/<env_file>` instead of the environment: the env file a cluster service in the same test writes (rules_kind's `kind_cluster` writes `<name>.env`) |
| `size` | `"enormous"` | |
| `timeout` | `"eternal"` | 3600 s. A full run needs more; see [Timeouts](#timeouts). |
| `tags` | | `manual`, `external` and `no-remote` are always added |

- **`manual`:** the test needs a cluster named on the command line, so `bazel test //...` skips it. Run it by name, or select it by tag with `bazel query` (see the [weekly example](#example-a-weekly-managed-cluster-run-eks)).
- **`external`:** never cached. The result depends on the cluster, not on Bazel's inputs.
- **`no-remote`:** the kubeconfig and its credential plugin are on this machine.
- **No `block-network`:** the test talks to the cluster. The tag is an analysis error.

### What it runs

1. **KUBECONFIG.** It comes from `--test_env=KUBECONFIG=...` (or `env_file`), and is never inherited silently from your shell. It must be a single, absolute, readable path.
2. **Version check.** The pinned kubectl reads `/version` through that kubeconfig, and the cluster's minor is compared with the image's. On a mismatch the test fails before hydrophone runs:

   ```
   rules_hydrophone: //:conformance_test: FAIL: Kubernetes minor mismatch: the cluster runs 1.36 (v1.36.3-eks-0123) but the conformance image is for 1.35 (registry.k8s.io/conformance:v1.35.10@sha256:c1be…). Refusing to run: conformance is only meaningful with the cluster's own minor. Use conformance_image = "1.36".
   ```

3. **hydrophone:**

   ```
   hydrophone --kubeconfig $KUBECONFIG --namespace hydrophone-<8 hex> \
     --conformance-image <image> --busybox-image <pinned busybox> \
     --output-dir $TEST_UNDECLARED_OUTPUTS_DIR --parallel <n> \
     --conformance | --focus <focus>  [--skip <skip>]
   ```

4. **Cleanup:** `hydrophone --cleanup --namespace hydrophone-<8 hex>`, always (see [Cleanup](#cleanup)).
5. **Verdict.** The test passes only if hydrophone exited 0, the JUnit report exists, parses, has at least one spec run, and has no `<failure>` or `<error>`, and cleanup succeeded. Failing specs are listed by name:

   ```
   JUnit: 402 spec(s) run, 1 failed, 0 error(s), 6953 skipped, 5 suite node(s) (…/test.outputs/junit_01.xml)
     failed: [It] [sig-network] DNS should provide DNS for services [Conformance]
   rules_hydrophone: //:conformance_test: FAIL: the JUnit report (…/junit_01.xml) does not show a clean run (above).
   ```

   Ginkgo's suite nodes (`[SynchronizedBeforeSuite]`, `[ReportAfterSuite]`, …) aren't counted as specs, because they pass even when a `focus` matched nothing. Their failures still fail the test.

### Choosing the image

`conformance_image` takes one of two forms:

- **A pinned minor**, such as `"1.35"`: rules_hydrophone's digest-pinned image for that minor's latest patch.
- **A full reference**, `"<repo>:<tag>@sha256:<digest>"`, for another minor, another patch, or a mirror (for example a private ECR copy). The tag must be a Kubernetes version (`v1.35.10`), and the minor the version check uses comes from it. The digest is what the cluster pulls, so prefer the manifest-list (index) digest, which covers every node architecture.

Either way the minor comes from the image reference itself, so it can't drift from the image. These are analysis errors:

| `conformance_image` | Error |
|---|---|
| `"registry.k8s.io/conformance:v1.35.10"` | is not pinned by digest |
| `"1.30"` | is not a pinned Kubernetes minor (and lists the pinned ones) |
| `"registry.k8s.io/conformance@sha256:…"` | has no tag (the tag names the version to compare) |
| `"…/conformance:latest@sha256:…"` | the tag "latest" isn't a Kubernetes version |
| `"…:v1.35.10@sha256:abc"` | the digest must be sha256: followed by 64 lowercase hex digits |

`CONFORMANCE_IMAGES` in `defs.bzl` holds the pinned table.

### Managed-cluster versions

The version check takes the minor from `/version`'s `gitVersion`, so vendor suffixes don't matter:

| Cluster | `gitVersion` | Minor |
|---|---|---|
| EKS | `v1.35.4-eks-abcdef` | 1.35 |
| GKE | `v1.35.2-gke.100` | 1.35 |
| kind, kubeadm, AKS | `v1.35.8` | 1.35 |

If a server reports no usable `gitVersion`, the test falls back to the `major` and `minor` fields, ignoring a trailing `+` (`"35+"`).

## Running it

### KUBECONFIG, credentials and the sandbox

Bazel gives a test only the environment you pass with `--test_env`, and sets `HOME` to a fresh temporary directory. So pass:

- **`--test_env=KUBECONFIG=/abs/path`**: the cluster under test. Merge several files into one (`kubectl config view --flatten`) first.
- **`--test_env=PATH`**, when the kubeconfig runs a credential plugin (`users[].user.exec`): `aws eks get-token`, `gke-gcloud-auth-plugin`, `kubelogin`. Without it the test's `PATH` is Bazel's default, `.:/bin:/usr/bin:/usr/local/bin`, which may lack the plugin.
- **The plugin's own credentials**, because `~/.aws` and `~/.config/gcloud` aren't found under the test's `HOME`:
  - for EKS, `--test_env=AWS_ACCESS_KEY_ID --test_env=AWS_SECRET_ACCESS_KEY --test_env=AWS_SESSION_TOKEN --test_env=AWS_REGION`, as CI credential actions export them;
  - or `--test_env=AWS_PROFILE` together with `--test_env=AWS_CONFIG_FILE=$HOME/.aws/config --test_env=AWS_SHARED_CREDENTIALS_FILE=$HOME/.aws/credentials`;
  - for GKE, `--test_env=CLOUDSDK_CONFIG=$HOME/.config/gcloud`.

The test keeps Bazel's sandbox, which shows the host filesystem read-only, so a kubeconfig under `$HOME` or the CI workspace is readable. `/tmp` is the exception: each sandboxed test gets a private `/tmp` (`--incompatible_sandbox_hermetic_tmp`, the default), so a kubeconfig under the host's `/tmp` is invisible. The test says so. Put the file elsewhere, or run with `--strategy=TestRunner=local`.

If the version can't be read, the test fails with kubectl's own error (for example `exec: executable aws not found`) and these hints.

### Timeouts

The full conformance suite takes about an hour, more on a busy or small cluster. Bazel's longest timeout, `eternal`, is 3600 s, which is borderline, so raise it for a full run:

```sh
bazel test //:conformance_test --test_env=KUBECONFIG=… --test_timeout=-1,-1,-1,7200
```

`-1,-1,-1,7200` raises only the `eternal` timeout to two hours and keeps the defaults for other tests. `parallel` shortens a run; `[Serial]` specs still run one at a time.

The test reads `$TEST_TIMEOUT` and stops hydrophone a tenth of it (at most 300 s) before Bazel would, so that cleanup can finish. The failure then says hydrophone ran out of time. A `focus` subset needs no extra timeout.

### Cleanup

hydrophone 0.8.0 won't take `--cleanup` together with `--conformance` (the flags are mutually exclusive), and it has no signal handling. So the test runs `hydrophone --cleanup` as a separate step, for its own namespace, from a trap:

- **Normal end, pass or fail:** after hydrophone exits. hydrophone cleans up after a completed run itself too; the second pass finds nothing. It waits until the namespace is gone.
- **SIGTERM (Bazel's timeout) or SIGINT:** hydrophone is stopped, then cleanup runs for up to 10 s, inside Bazel's grace period (`--local_termination_grace_seconds`, default 15 s). The deletes are sent at once. If the namespace is still terminating when the 10 s are up, the log says so, and it finishes terminating on the cluster.
- **Cleanup fails:** the test fails, naming the namespace, ClusterRole and ClusterRoleBinding to remove by hand.

Each run uses its own namespace, `hydrophone-<8 hex>`, with ClusterRole `conformance-serviceaccount:<namespace>` and ClusterRoleBinding `conformance-serviceaccount-role:<namespace>`. Cleanup never touches another run's resources, and two runs against one cluster don't collide. If a run is SIGKILLed, the leftovers can be found with `kubectl get ns | grep '^hydrophone-'`.

### Outputs

| File | |
|---|---|
| `bazel-testlogs/<pkg>/<name>/test.outputs/junit_01.xml` | Ginkgo's JUnit report |
| `bazel-testlogs/<pkg>/<name>/test.outputs/e2e.log` | the e2e suite's log |
| `bazel-testlogs/<pkg>/<name>/test.xml` | the same JUnit report, for CI test-result views |

(With `--zip_undeclared_test_outputs`, `test.outputs/` is `outputs.zip`.)

## Example: a weekly managed-cluster run (EKS)

The cluster is created by CI, every test tagged for it runs, and the cluster is torn down.

```python
# conformance/BUILD.bazel
load("@rules_hydrophone//:defs.bzl", "hydrophone_conformance_test")

hydrophone_conformance_test(
    name = "eks_conformance_test",
    conformance_image = "1.35",       # keep in step with the cluster's version
    parallel = 4,
    tags = ["eks-weekly"],
)
```

```yaml
# .github/workflows/eks-weekly.yml
on:
  schedule: [{cron: "0 3 * * 1"}]
jobs:
  eks:
    runs-on: ubuntu-latest
    permissions: {id-token: write, contents: read}
    steps:
      - uses: actions/checkout@v4
      - uses: bazel-contrib/setup-bazel@0.15.0
      - uses: aws-actions/configure-aws-credentials@v4   # exports AWS_* to the job
        with: {role-to-assume: "${{ vars.EKS_ROLE }}", aws-region: eu-west-1}
      - name: Create the cluster
        run: |
          eksctl create cluster --name "weekly-$GITHUB_RUN_ID" --version 1.35 --nodes 3
          aws eks update-kubeconfig --name "weekly-$GITHUB_RUN_ID" \
            --kubeconfig "$GITHUB_WORKSPACE/eks.kubeconfig"
      - name: Conformance and the other eks-weekly tests
        run: |
          # manual tests aren't matched by //..., but `bazel query` lists them.
          bazel test $(bazel query 'attr(tags, "\beks-weekly\b", tests(//...))') \
            --test_env=KUBECONFIG="$GITHUB_WORKSPACE/eks.kubeconfig" \
            --test_env=PATH \
            --test_env=AWS_ACCESS_KEY_ID --test_env=AWS_SECRET_ACCESS_KEY \
            --test_env=AWS_SESSION_TOKEN --test_env=AWS_REGION \
            --test_timeout=-1,-1,-1,7200 \
            --test_output=errors
      - uses: actions/upload-artifact@v4
        if: always()
        with: {name: conformance, path: bazel-testlogs/conformance/}
      - name: Delete the cluster
        if: always()
        run: eksctl delete cluster --name "weekly-$GITHUB_RUN_ID" --wait
```

`aws eks update-kubeconfig` writes an exec entry that runs `aws eks get-token`, which is why the test needs `PATH` (to find `aws`) and the `AWS_*` variables (its credentials).

## Example: a rules_kind cluster

With [rules_kind](https://github.com/collider-bazel-extensions/rules_kind) and [rules_itest](https://github.com/dzbarsky/rules_itest), the cluster is a service of the test, and the test reads `KUBECONFIG` from the cluster's env file. rules_kind v0.5.0's `1.35` node image is `kindest/node:v1.35.8`, so `conformance_image = "1.35"` matches it.

```python
load("@rules_hydrophone//:defs.bzl", "hydrophone_conformance_test")
load("@rules_itest//:itest.bzl", "itest_service", "service_test")
load("@rules_kind//:defs.bzl", "kind_cluster", "kind_health_check")

kind_cluster(name = "k8s", k8s_version = "1.35", tags = ["manual", "no-sandbox", "requires-docker"])
kind_health_check(name = "k8s_health", cluster = ":k8s")
itest_service(name = "k8s_svc", exe = ":k8s", health_check = ":k8s_health")

hydrophone_conformance_test(
    name = "conformance_bin",
    conformance_image = "1.35",
    env_file = "k8s.env",                  # $TEST_TMPDIR/k8s.env, written by kind_cluster
    focus = "ConfigMap should run through a ConfigMap lifecycle|Secrets should patch a secret",
)

service_test(
    name = "kind_conformance_test",
    test = ":conformance_bin",
    services = [":k8s_svc"],
    size = "enormous",
    tags = ["manual", "no-sandbox", "requires-docker", "external"],
)
```

This repository's tests don't use rules_itest. Its e2e starts the `kind_cluster` launcher itself and runs the conformance test with `env_file` in the same `$TEST_TMPDIR`, which is what a `service_test` provides. rules_kind's own `kube_bench_test` is composed the same way.

On a kind cluster you started yourself, use the kubeconfig directly (outside `/tmp`, see above):

```sh
kind create cluster --name conformance --image kindest/node:v1.35.8 --kubeconfig "$HOME/kind-conformance.kubeconfig"
bazel test //:conformance_test --test_env=KUBECONFIG="$HOME/kind-conformance.kubeconfig" --test_timeout=-1,-1,-1,7200
```

This repository's own end-to-end test (`//tests:kind_e2e_test`) starts a rules_kind cluster, runs a five-spec `focus` subset through `env_file`, checks that a 1.36 image is refused, and checks that SIGTERM mid-run still cleans up.

## Pinned versions

| Component | Version | Pin | Source |
|---|---|---|---|
| hydrophone | `0.8.0` | SHA-256 per platform (linux, darwin; amd64, arm64) | the release's `hydrophone_0.8.0_checksums.txt` |
| kubectl (version check) | `1.36.6` | SHA-256 per platform | dl.k8s.io's published `.sha256` |
| conformance, Kubernetes 1.35 | `v1.35.10` | `sha256:c1be3a9826603e29e6926d02e031833d9ae86b0d595cce28f1bd19a6bc859748` | index digest, registry.k8s.io |
| conformance, Kubernetes 1.36 | `v1.36.6` | `sha256:fdbe358cf2d2900d2926a91dcb3ed67be37f766ae3c6a81aff35068f31ec4adf` | index digest, registry.k8s.io |
| conformance, Kubernetes 1.37 | `v1.37.2` | `sha256:d503a15722ea23662c482b72ce01ee6e9efec1e8b9c2d3834aa0c51bb2d0832a` | index digest, registry.k8s.io |
| busybox (hydrophone's output container) | `1.36.1-1` | `sha256:a9155b13325b2abef48e71de77bb8ac015412a566829f621d06bfae5c699b1b9` | index digest, registry.k8s.io |

The conformance images are the latest patch of each upstream-supported minor (1.34 reached end of life on 2026-10-27). Each digest is the manifest list for linux/amd64, arm64, ppc64le and s390x. kubectl is one minor behind the newest pinned conformance minor, which keeps it within kubectl's ±1 version skew of all three.

The conformance suite pulls further test images (agnhost, nginx, …) by tag at run time; those are upstream's choice and aren't pinned here.

To bump, run `tools/update_versions.sh` (it isn't in the release archive):

```sh
tools/update_versions.sh images             # each supported minor's latest patch, by index digest
tools/update_versions.sh hydrophone 0.9.0   # a hydrophone release, from its checksums file
tools/update_versions.sh kubectl 1.37.3     # the version-check kubectl
tools/update_versions.sh --check            # verify every pin against upstream; no writes
```

- **Verification:** every SHA-256 is cross-checked against the downloaded file. Every image digest must be an index whose body hashes to the digest the registry served, and it must include linux/amd64 and linux/arm64.
- **Supported minors** come from kubernetes/website's `data/releases/schedule.yaml` (end of life not yet passed), and the latest patch from `dl.k8s.io/release/stable-<minor>.txt`.
- **`--check`** fails on drift. It only notes a newer patch or a change in the supported minors.
- **After a hydrophone bump,** set `DEFAULT_VERSION` and `hydrophone.version()` in `MODULE.bazel` too (`//tests:version_test`).

## Development

```sh
bazel test //tests/...                   # analysis, wrapper (stubs), pins: no cluster
bazel test //tests:kind_e2e_test         # a real kind cluster (docker or podman)
.github/consumer/check.sh /tmp/consumer  # the release archive as a consumer sees it
tools/update_versions.sh --check
```

See [DESIGN.md](DESIGN.md) for the design and trade-offs, and [CLAUDE.md](CLAUDE.md) for the repo layout and test inventory.

## License

[Apache License 2.0](LICENSE) (SPDX: `Apache-2.0`).

---

## Requesting a new rules package

Want Bazel rules for another tool or service?
[Request a rules package](https://github.com/collider-bazel-extensions/.github/issues/new?template=request-a-rules-package.yml).
The [organization page](https://github.com/collider-bazel-extensions) lists every package.
