#!/bin/bash
# Chooses the macOS SDK for command-line builds. Source this file; it exports SDKROOT when needed.
#
# In the macOS 27 SDK, SwiftUI's @State is implemented as a macro whose compiler plugin ships only
# with Xcode, not with the Command Line Tools. Without Xcode we therefore build against the newest
# macOS 26.x SDK that the Command Line Tools also install. With Xcode selected nothing is changed.
# Set SDKROOT yourself to override.

DEV_DIR="$(xcode-select -p 2>/dev/null || true)"
if [ -z "${SDKROOT:-}" ]; then
  if [[ "$DEV_DIR" == *CommandLineTools* ]]; then
    for candidate in MacOSX26.5.sdk MacOSX26.4.sdk MacOSX26.sdk; do
      if [ -d "$DEV_DIR/SDKs/$candidate" ]; then
        export SDKROOT="$DEV_DIR/SDKs/$candidate"
        break
      fi
    done
  fi
fi

# With the Command Line Tools' Swift Build, the test target's explicit-module build intermittently omits
# the swift-testing macro plugin ("plugin for module 'TestingMacros' not found"). Loading it explicitly
# makes `swift test` deterministic. Used by scripts/test.sh.
SWIFT_TEST_FLAGS=()
if [[ "${DEV_DIR:-}" == *CommandLineTools* ]]; then
  TESTING_PLUGIN="$DEV_DIR/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
  if [ -f "$TESTING_PLUGIN" ]; then
    SWIFT_TEST_FLAGS=(-Xswiftc -load-plugin-library -Xswiftc "$TESTING_PLUGIN")
  fi
fi
