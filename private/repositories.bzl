"""Per-platform repo `hydrophone_<platform>`: downloads the hydrophone release
tarball and the pinned kubectl at their SHA-256s, and declares the
platform's toolchain implementation, so the repo name doesn't change with the
version. Toolchain resolution fetches only the repo a build needs.
"""

load(":versions.bzl", "ASSETS", "HYDROPHONE_URL", "HYDROPHONE_VERSIONS", "KUBECTL_SHA256", "KUBECTL_URL", "KUBECTL_VERSION")

_BUILD = """\
load("{toolchain_bzl}", "hydrophone_toolchain")

package(default_visibility = ["//visibility:public"])

exports_files(["hydrophone", "kubectl"])

hydrophone_toolchain(
    name = "toolchain_impl",
    version = "{version}",
    hydrophone = "hydrophone",
    kubectl = "kubectl",
    kubectl_version = "{kubectl_version}",
)
"""

def _impl(rctx):
    version = rctx.attr.version
    platform = rctx.attr.platform
    sha256 = rctx.attr.sha256 or HYDROPHONE_VERSIONS.get(version, {}).get(platform)
    if not sha256:
        fail(("rules_hydrophone: no SHA-256 for hydrophone {} on {}. Pinned versions: {}. " +
              "For another version, pin it in your MODULE.bazel: hydrophone.version(version = \"{}\", " +
              "sha256 = {{\"{}\": \"<sha256 from hydrophone_{}_checksums.txt>\", ...}}).").format(
            version,
            platform,
            sorted(HYDROPHONE_VERSIONS.keys()),
            version,
            platform,
            version,
        ))
    rctx.download_and_extract(
        url = HYDROPHONE_URL.format(version = version, asset = ASSETS[platform]),
        sha256 = sha256,
    )
    os, arch = platform.split("_")
    rctx.download(
        url = KUBECTL_URL.format(version = KUBECTL_VERSION, os = os, arch = arch),
        output = "kubectl",
        sha256 = KUBECTL_SHA256[platform],
        executable = True,
    )
    rctx.file("BUILD.bazel", _BUILD.format(
        toolchain_bzl = str(Label("//toolchain:toolchain.bzl")),
        version = version,
        kubectl_version = KUBECTL_VERSION,
    ))

hydrophone_binary_repo = repository_rule(
    implementation = _impl,
    attrs = {
        "version": attr.string(mandatory = True),
        "platform": attr.string(mandatory = True),
        # From the root module's hydrophone.version(sha256 = {...}); empty
        # means HYDROPHONE_VERSIONS' pin.
        "sha256": attr.string(),
    },
)
