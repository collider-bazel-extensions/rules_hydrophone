"""Analysis-time tests: how conformance_image resolves (pinned minor or full
reference, and the minor the version check uses), and the analysis errors
for bad attributes."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("//:defs.bzl", "CONFORMANCE_IMAGES", "hydrophone_conformance_test")
load("//private:image.bzl", "parse_conformance_image", "version_minor")

_DIGEST = "sha256:" + "0123456789abcdef" * 4

def _q(s):
    return "'" + s + "'"

def _substitutions(env):
    for a in analysistest.target_actions(env):
        if a.mnemonic == "TemplateExpand":
            return a.substitutions
    return {}

def _resolves_impl(ctx):
    env = analysistest.begin(ctx)
    subs = _substitutions(env)
    asserts.equals(env, _q(ctx.attr.image), subs.get("__IMAGE__"))
    asserts.equals(env, _q(ctx.attr.minor), subs.get("__IMAGE_MINOR__"))
    asserts.equals(env, str(ctx.attr.parallel), subs.get("__PARALLEL__"))
    target = analysistest.target_under_test(env)
    asserts.true(env, target[DefaultInfo].files_to_run.executable != None, "expected an executable")
    return analysistest.end(env)

_resolves_test = analysistest.make(
    _resolves_impl,
    attrs = {
        "image": attr.string(),
        "minor": attr.string(),
        "parallel": attr.int(default = 1),
    },
)

def _fails_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, ctx.attr.message)
    return analysistest.end(env)

_fails_test = analysistest.make(
    _fails_impl,
    expect_failure = True,
    attrs = {"message": attr.string()},
)

def _parse_impl(ctx):
    env = unittest.begin(ctx)
    for version, want in [
        ("v1.35.10", "1.35"),
        ("1.35.4-eks-abcdef", "1.35"),
        ("v1.35.4-eks-abcdef", "1.35"),
        ("v1.35.2-gke.100", "1.35"),
        ("v1.36.0-rc.1", "1.36"),
        ("v1.37", "1.37"),
        ("v01.035.1", "1.35"),
        ("latest", None),
        ("v1", None),
        ("v1.x", None),
        ("1.35x", None),
        ("", None),
    ]:
        asserts.equals(env, want, version_minor(version), "version_minor(\"{}\")".format(version))
    for minor, ref in CONFORMANCE_IMAGES.items():
        res, err = parse_conformance_image(minor)
        asserts.equals(env, None, err)
        asserts.equals(env, ref, res.ref)
        asserts.equals(env, minor, res.minor)
        asserts.true(env, "@sha256:" in ref, "{} is pinned by digest".format(minor))
    res, err = parse_conformance_image("localhost:5000/conformance:v1.35.1@" + _DIGEST)
    asserts.equals(env, None, err)
    asserts.equals(env, "1.35", res.minor)
    return unittest.end(env)

_parse_test = unittest.make(_parse_impl)

def analysis_test_suite(name):
    s = name + "_subject"
    full = "registry.example.com/conformance:v1.36.2@" + _DIGEST
    subjects = {
        "_pinned": "1.35",
        "_full": full,
        "_unpinned_tag": "registry.k8s.io/conformance:v1.35.10",
        "_unknown_minor": "1.30",
        "_no_tag": "registry.k8s.io/conformance@" + _DIGEST,
        "_bad_digest": "registry.k8s.io/conformance:v1.35.10@sha256:abc",
        "_not_version": "registry.k8s.io/conformance:latest@" + _DIGEST,
        "_empty": "",
    }
    for suffix, image in subjects.items():
        hydrophone_conformance_test(name = s + suffix, conformance_image = image, parallel = 3 if suffix == "_full" else 1)
    hydrophone_conformance_test(name = s + "_parallel0", conformance_image = "1.35", parallel = 0)
    hydrophone_conformance_test(name = s + "_block_network", conformance_image = "1.35", tags = ["block-network"])
    hydrophone_conformance_test(name = s + "_env_file_path", conformance_image = "1.35", env_file = "../k8s.env")
    hydrophone_conformance_test(name = s + "_focus_newline", conformance_image = "1.35", focus = "a\nb")

    _resolves_test(name = name + "_pinned", target_under_test = ":" + s + "_pinned", image = CONFORMANCE_IMAGES["1.35"], minor = "1.35")
    _resolves_test(name = name + "_full", target_under_test = ":" + s + "_full", image = full, minor = "1.36", parallel = 3)
    _parse_test(name = name + "_parse")

    fails = {
        "_unpinned_tag": "is not pinned by digest",
        "_unknown_minor": "conformance_image \"1.30\" is not a pinned Kubernetes minor",
        "_no_tag": "has no tag",
        "_bad_digest": "the digest must be sha256: followed by 64 lowercase hex digits",
        "_not_version": "the tag \"latest\" isn't a Kubernetes version",
        "_empty": "conformance_image is empty",
        "_parallel0": "parallel = 0: expected 1 or more",
        "_block_network": "the 'block-network' tag can't apply",
        "_env_file_path": "must be a file name in $TEST_TMPDIR",
        "_focus_newline": "focus contains a newline",
    }
    for suffix, message in fails.items():
        _fails_test(name = name + suffix, target_under_test = ":" + s + suffix, message = message)

    native.test_suite(
        name = name,
        tests = [":" + name + t for t in ["_pinned", "_full", "_parse"] + fails.keys()],
    )
