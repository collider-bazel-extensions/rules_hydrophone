"""Providers exposed by rules_hydrophone."""

HydrophoneInfo = provider(
    doc = "The hydrophone toolchain: hydrophone, and the kubectl that reads the cluster's version.",
    fields = {
        "version": "string: pinned hydrophone version",
        "hydrophone": "File: the hydrophone executable",
        "kubectl": "File: the pinned kubectl executable",
        "kubectl_version": "string: its version",
    },
)
