"""hydrophone_toolchain: exposes the platform-resolved `hydrophone` and
`kubectl` binaries as a `ToolchainInfo`, so rules resolve them via
`ctx.toolchains["@rules_hydrophone//toolchain:hydrophone"]`.

`current_hydrophone_toolchain` forwards the resolved binaries as a plain
target (files + runfiles) for `data = [...]` use in tests.
"""

load("//private:providers.bzl", "HydrophoneInfo")

HYDROPHONE_TOOLCHAIN_TYPE = Label("//toolchain:hydrophone")

def _toolchain_impl(ctx):
    info = HydrophoneInfo(
        version = ctx.attr.version,
        hydrophone = ctx.file.hydrophone,
        kubectl = ctx.file.kubectl,
        kubectl_version = ctx.attr.kubectl_version,
    )
    files = [ctx.file.hydrophone, ctx.file.kubectl]
    return [
        platform_common.ToolchainInfo(hydrophone = info),
        DefaultInfo(files = depset(files), runfiles = ctx.runfiles(files = files)),
    ]

hydrophone_toolchain = rule(
    implementation = _toolchain_impl,
    attrs = {
        "version": attr.string(mandatory = True),
        "hydrophone": attr.label(allow_single_file = True, mandatory = True),
        "kubectl": attr.label(allow_single_file = True, mandatory = True),
        "kubectl_version": attr.string(mandatory = True),
    },
)

def _current_impl(ctx):
    info = ctx.toolchains[HYDROPHONE_TOOLCHAIN_TYPE].hydrophone
    files = [info.hydrophone, info.kubectl]
    return [
        info,
        DefaultInfo(files = depset(files), runfiles = ctx.runfiles(files = files)),
    ]

current_hydrophone_toolchain = rule(
    implementation = _current_impl,
    toolchains = [HYDROPHONE_TOOLCHAIN_TYPE],
    doc = "The resolved hydrophone and kubectl binaries, as files and runfiles.",
)
