#!/usr/bin/env bash
# Runs the test suite.
#
# The tests use Swift Testing. With a full Xcode install that works out of the
# box; with only the Command Line Tools the framework sits outside the default
# search paths and has to be pointed at explicitly, including rpaths, because SIP
# strips DYLD_FRAMEWORK_PATH from the test helper.
set -euo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

FRAMEWORKS=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
LIBRARIES=/Library/Developer/CommandLineTools/Library/Developer/usr/lib

if xcode-select -p 2>/dev/null | grep -q "Xcode.app"; then
  exec swift test "$@"
fi

if [ ! -d "$FRAMEWORKS/Testing.framework" ]; then
  echo "warning: Swift Testing not found under the Command Line Tools;" >&2
  echo "         trying the default search paths." >&2
  exec swift test "$@"
fi

exec swift test \
  -Xswiftc -F -Xswiftc "$FRAMEWORKS" \
  -Xlinker -F -Xlinker "$FRAMEWORKS" \
  -Xlinker -rpath -Xlinker "$FRAMEWORKS" \
  -Xlinker -rpath -Xlinker "$LIBRARIES" \
  "$@"
