#!/usr/bin/env sh
# Script to export a release
set -e
space /cmdline/ -e SPACE_MUTE_EXIT_MESSAGE=1 -d >./release/podc
chmod +x ./release/podc
space -f podman-runtime.yaml /podman/ -e SPACE_MUTE_EXIT_MESSAGE=1 -d >./release/podman-runtime
