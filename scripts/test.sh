#!/bin/sh
# 🐱 Run the unit tests. With full Xcode selected (`xcode-select -p` → Xcode.app), plain `swift test` is used.
# 🐱 With only the Command Line Tools, swift-testing lives in a separate framework folder that has to be passed in;
# 🐱 those flags must NOT be used with Xcode, whose Testing macros then meet the CLT's older library and fail to
# 🐱 compile ("module 'Testing' has no member named '__SourceBounds'").
set -e
cd "$(dirname "$0")/../LivePTVKit"
case "$(xcode-select -p 2>/dev/null)" in
  *CommandLineTools*) ;;
  *) exec swift test "$@" ;;
esac
FW=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
LIB=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
# 🐱 The CLT copy of _Testing_Foundation ships without its module files, so the Foundation cross-import
# 🐱 overlay is disabled (nothing here needs it).
exec swift test \
  -Xswiftc -F -Xswiftc "$FW" \
  -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays \
  -Xlinker -F -Xlinker "$FW" \
  -Xlinker -rpath -Xlinker "$FW" \
  -Xlinker -rpath -Xlinker "$LIB" \
  "$@"
