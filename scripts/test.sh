#!/bin/sh
# 🐱 Run the unit tests with only the Command Line Tools installed (no Xcode).
# 🐱 With full Xcode installed, plain `swift test` works and the extra flags are harmless.
set -e
FW=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
LIB=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
cd "$(dirname "$0")/../LivePTVKit"
# 🐱 The CLT copy of _Testing_Foundation ships without its module files, so the Foundation cross-import
# 🐱 overlay is disabled (nothing here needs it).
exec swift test \
  -Xswiftc -F -Xswiftc "$FW" \
  -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays \
  -Xlinker -F -Xlinker "$FW" \
  -Xlinker -rpath -Xlinker "$FW" \
  -Xlinker -rpath -Xlinker "$LIB" \
  "$@"
