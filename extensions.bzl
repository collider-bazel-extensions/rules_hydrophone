"""Bzlmod extension. Single `version` tag: fetches the hydrophone release
tarball (and the pinned kubectl) for each supported platform as
`hydrophone_<platform>`.

The root module's tag wins; without one, rules_hydrophone's own applies, so
consumers declare nothing unless they want another version. A version not
in private/versions.bzl needs its SHA-256s in the tag.
"""

load("//private:repositories.bzl", "hydrophone_binary_repo")
load("//private:versions.bzl", "DEFAULT_VERSION", "HYDROPHONE_VERSIONS", "PLATFORMS")

_version_tag = tag_class(attrs = {
    "version": attr.string(mandatory = True),  # e.g. "0.8.0"
    # platform -> SHA-256 of hydrophone_<Os>_<arch>.tar.gz, from the
    # release's hydrophone_<ver>_checksums.txt. Needed for a version not in
    # private/versions.bzl; replaces the pinned value for a known one.
    "sha256": attr.string_dict(),
})

def _pins(mod):
    pins = [struct(version = t.version, sha256 = dict(t.sha256)) for t in mod.tags.version]
    if len({p.version: True for p in pins}) > 1:
        fail("rules_hydrophone: {} names more than one hydrophone.version(): {}".format(
            "the root module" if mod.is_root else mod.name,
            [p.version for p in pins],
        ))
    return pins

def _impl(mctx):
    root, own = [], []
    for mod in mctx.modules:
        if mod.is_root:
            root = _pins(mod)
        elif mod.name == "rules_hydrophone":
            own = _pins(mod)

    # Only one module's tags apply: repos are named per platform, not per
    # version, so the root's choice replaces rules_hydrophone's own.
    pins = (root or own or [struct(version = DEFAULT_VERSION, sha256 = {})])[0]
    for plat in pins.sha256:
        if plat not in PLATFORMS:
            fail("rules_hydrophone: hydrophone.version(sha256 = ...) has unknown platform '{}'. Platforms: {}".format(
                plat,
                sorted(PLATFORMS.keys()),
            ))
    if pins.version not in HYDROPHONE_VERSIONS and not pins.sha256:
        fail(("rules_hydrophone: hydrophone {} is not pinned. Pinned: {}. For another version, " +
              "give its SHA-256s: hydrophone.version(version = \"{}\", sha256 = {{\"linux_amd64\": ..., ...}}) " +
              "from the release's hydrophone_{}_checksums.txt.").format(
            pins.version,
            ", ".join(sorted(HYDROPHONE_VERSIONS.keys())),
            pins.version,
            pins.version,
        ))
    for plat in PLATFORMS.keys():
        hydrophone_binary_repo(
            name = "hydrophone_" + plat,
            version = pins.version,
            platform = plat,
            sha256 = pins.sha256.get(plat, ""),
        )

hydrophone = module_extension(
    implementation = _impl,
    tag_classes = {"version": _version_tag},
)
