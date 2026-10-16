#!/bin/sh
# Compiles the app's pure-logic files with small test programs and runs them.
set -e
cd "$(dirname "$0")/.."
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

swiftc -swift-version 5 -parse-as-library \
  Sources/Language.swift Sources/NowPlaying.swift Sources/Whisper.swift Sources/FastGemini.swift Tests/LogicTests.swift \
  -o "$OUT/logic-tests"
"$OUT/logic-tests"
