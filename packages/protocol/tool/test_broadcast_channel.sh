#!/bin/sh
# Headless BroadcastChannel integration test (see the harness header):
# compile to JS and run under Node, which provides a global BroadcastChannel.
#
# The `self` shim is required: dart2js's Timer implementation addresses the
# browser worker global `self`, which Node does not define.
set -e
cd "$(dirname "$0")/.."
dart pub get >/dev/null
dart compile js tool/broadcast_channel_harness.dart -o .dart_tool/bc/harness.js
node -e "globalThis.self = globalThis; require('./.dart_tool/bc/harness.js');"
