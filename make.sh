#!/usr/bin/env sh
# Script to export a release
set -e
mkdir -p ./release
space /_cmdline/ -e SPACE_MUTE_EXIT_MESSAGE=1 -d >./release/podc
chmod +x ./release/podc
space -f lib/podman-runtime.yaml /podman/ -e SPACE_MUTE_EXIT_MESSAGE=1 -d >./release/podc-podman-runtime
