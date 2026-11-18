"""Public API for rules_hydrophone.

  hydrophone_conformance_test - Kubernetes conformance (hydrophone) against the
                                cluster named by KUBECONFIG, as a Bazel test
  HydrophoneInfo              - the toolchain's provider (hydrophone + kubectl)
  CONFORMANCE_IMAGES          - Kubernetes minor -> digest-pinned conformance image
"""

load("//private:conformance.bzl", _hydrophone_conformance_test = "hydrophone_conformance_test")
load("//private:providers.bzl", _HydrophoneInfo = "HydrophoneInfo")
load("//private:versions.bzl", _CONFORMANCE_IMAGES = "CONFORMANCE_IMAGES")

hydrophone_conformance_test = _hydrophone_conformance_test

HydrophoneInfo = _HydrophoneInfo

CONFORMANCE_IMAGES = _CONFORMANCE_IMAGES
