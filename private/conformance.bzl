"""hydrophone_conformance_test: Kubernetes conformance (hydrophone) against
the cluster named by KUBECONFIG, as a Bazel test.

The test:
  1. reads the cluster's version with the pinned kubectl and refuses a
     cluster whose minor differs from the conformance image's, before
     anything is created on it;
  2. runs `hydrophone --conformance` (or `--focus`) in a namespace of its own;
  3. always runs `hydrophone --cleanup` for that namespace afterwards (a
     trap, so failures, SIGTERM on timeout and SIGINT clean up too);
  4. passes only if hydrophone exited 0, the JUnit report exists, ran at
     least one spec and has no failures or errors, and cleanup succeeded.

e2e.log and junit_01.xml go to the test's undeclared outputs; the JUnit
report is also copied to $XML_OUTPUT_FILE.
"""

load("//toolchain:toolchain.bzl", "HYDROPHONE_TOOLCHAIN_TYPE")
load(":image.bzl", "parse_conformance_image")
load(":versions.bzl", "BUSYBOX_IMAGE", "CONFORMANCE_IMAGES")

def _shell_quote(s):
    return "'" + s.replace("'", "'\\''") + "'"

def _rlocation(ctx, f):
    # Runfiles path: `<repo>/<path>`. External files' short_path starts
    # with `../<repo>/`; the main repository's is `_main` (ctx.workspace_name).
    if f.short_path.startswith("../"):
        return f.short_path[3:]
    return ctx.workspace_name + "/" + f.short_path

def _label_text(label):
    # `//pkg:name` for the main repository (str() gives `@@//pkg:name`), so
    # the label in messages can be pasted into a bazel command.
    if not label.repo_name:
        return "//{}:{}".format(label.package, label.name)
    return str(label)

def _impl(ctx):
    image, err = parse_conformance_image(ctx.attr.conformance_image)
    if err:
        fail("{}: {}".format(ctx.label, err))
    if ctx.attr.parallel < 1:
        fail("{}: parallel = {}: expected 1 or more (hydrophone's --parallel, the number of Ginkgo processes).".format(
            ctx.label,
            ctx.attr.parallel,
        ))
    for name in ("focus", "skip"):
        v = getattr(ctx.attr, name)
        if "\n" in v:
            fail("{}: {} contains a newline; give one regular expression (use | for alternatives).".format(ctx.label, name))
    if "block-network" in ctx.attr.tags:
        fail("{}: the 'block-network' tag can't apply: the test talks to the cluster named by KUBECONFIG over the network.".format(ctx.label))
    env_file = ctx.attr.env_file
    if env_file and ("/" in env_file or env_file.startswith(".")):
        fail("{}: env_file \"{}\" must be a file name in $TEST_TMPDIR, such as \"k8s.env\" (rules_kind's kind_cluster writes <name>.env).".format(
            ctx.label,
            env_file,
        ))

    tc = ctx.toolchains[HYDROPHONE_TOOLCHAIN_TYPE].hydrophone
    hydrophone = getattr(ctx.file, "hydrophone", None) or tc.hydrophone
    kubectl = getattr(ctx.file, "kubectl", None) or tc.kubectl

    wrapper = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.expand_template(
        template = ctx.file._tmpl,
        output = wrapper,
        substitutions = {
            "__LABEL__": _shell_quote(_label_text(ctx.label)),
            "__HYDROPHONE__": _shell_quote(_rlocation(ctx, hydrophone)),
            "__HYDROPHONE_VERSION__": _shell_quote(tc.version),
            "__KUBECTL__": _shell_quote(_rlocation(ctx, kubectl)),
            "__KUBECTL_VERSION__": _shell_quote(tc.kubectl_version),
            "__JUNIT_CHECK__": _shell_quote(_rlocation(ctx, ctx.file._junit_check)),
            "__IMAGE__": _shell_quote(image.ref),
            "__IMAGE_MINOR__": _shell_quote(image.minor),
            "__PINNED_MINORS__": _shell_quote(" ".join(sorted(CONFORMANCE_IMAGES.keys()))),
            "__BUSYBOX_IMAGE__": _shell_quote(BUSYBOX_IMAGE),
            "__PARALLEL__": str(ctx.attr.parallel),
            "__FOCUS__": _shell_quote(ctx.attr.focus),
            "__SKIP__": _shell_quote(ctx.attr.skip),
            "__ENV_FILE__": _shell_quote(env_file),
        },
        is_executable = True,
    )
    runfiles = ctx.runfiles(files = [wrapper, hydrophone, kubectl, ctx.file._junit_check])
    # No inherited_environment: KUBECONFIG must come from an explicit
    # --test_env, never silently from the shell (it could name production).
    return [DefaultInfo(executable = wrapper, runfiles = runfiles)]

_ATTRS = {
    "conformance_image": attr.string(
        mandatory = True,
        doc = "A pinned Kubernetes minor (\"1.35\") or \"<repo>:<tag>@sha256:<digest>\" whose tag is a " +
              "Kubernetes version. The cluster's minor must match the tag's.",
    ),
    "parallel": attr.int(
        default = 1,
        doc = "Ginkgo processes (hydrophone --parallel). 1 or more.",
    ),
    "focus": attr.string(
        doc = "Regular expression of specs to run (hydrophone --focus). Empty: every [Conformance] spec " +
              "(hydrophone --conformance). A focus replaces the [Conformance] filter, so name conformance specs.",
    ),
    "skip": attr.string(
        doc = "Regular expression of specs to skip (hydrophone --skip).",
    ),
    "env_file": attr.string(
        doc = "Read KUBECONFIG from $TEST_TMPDIR/<env_file> instead of the environment: the env file a " +
              "cluster service in the same test writes (rules_kind's kind_cluster writes <name>.env).",
    ),
    "_tmpl": attr.label(default = "//private:conformance_test.sh.tmpl", allow_single_file = True),
    "_junit_check": attr.label(default = "//private:junit_check.py", allow_single_file = True),
}

_hydrophone_conformance_test = rule(
    implementation = _impl,
    test = True,
    doc = "Kubernetes conformance with hydrophone against the cluster named by KUBECONFIG.",
    attrs = _ATTRS,
    toolchains = [HYDROPHONE_TOOLCHAIN_TYPE],
)

# The same rule with the binaries replaceable: rules_hydrophone's own unit
# tests run the real wrapper against stub hydrophone and kubectl scripts.
# Not exported from defs.bzl.
hydrophone_conformance_stubbed_test = rule(
    implementation = _impl,
    test = True,
    attrs = dict(_ATTRS, **{
        "hydrophone": attr.label(allow_single_file = True, cfg = "target"),
        "kubectl": attr.label(allow_single_file = True, cfg = "target"),
    }),
    toolchains = [HYDROPHONE_TOOLCHAIN_TYPE],
)

# Tags every conformance test gets:
#   manual    - it needs a cluster named by --test_env=KUBECONFIG; `bazel test //...` skips it
#   external  - never cached: the result depends on the cluster, not on Bazel's inputs
#   no-remote - the kubeconfig and its credential plugin are on this machine
_TAGS = ["manual", "external", "no-remote"]

def hydrophone_conformance_test(
        name,
        conformance_image,
        parallel = 1,
        focus = "",
        skip = "",
        env_file = "",
        size = "enormous",
        timeout = "eternal",
        tags = [],
        **kwargs):
    """Kubernetes conformance (hydrophone) against the cluster named by KUBECONFIG.

    Args:
      name: target name.
      conformance_image: a pinned minor ("1.35") or "<repo>:<tag>@sha256:<digest>".
      parallel: Ginkgo processes (hydrophone --parallel).
      focus: regular expression of specs to run; empty runs every [Conformance] spec.
      skip: regular expression of specs to skip.
      env_file: read KUBECONFIG from $TEST_TMPDIR/<env_file> (rules_kind: "<cluster>.env").
      size: test size; default "enormous".
      timeout: test timeout; default "eternal" (3600 s). A full run needs more:
        pass --test_timeout (see README).
      tags: extra tags; "manual", "external" and "no-remote" are always added.
      **kwargs: passed to the rule (e.g. visibility, env, target_compatible_with).
    """
    _hydrophone_conformance_test(
        name = name,
        conformance_image = conformance_image,
        parallel = parallel,
        focus = focus,
        skip = skip,
        env_file = env_file,
        size = size,
        timeout = timeout,
        tags = tags + [t for t in _TAGS if t not in tags],
        **kwargs
    )
