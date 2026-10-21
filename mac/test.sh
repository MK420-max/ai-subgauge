#!/bin/zsh
set -eu
cd "${0:A:h}"
level=$(pmset -g batt | sed -nE 's/.*[[:space:]]([0-9]+)%;.*/\1/p' | head -1)
if [[ -n "$level" && "$level" -le 20 ]]; then print '电量达到停止阈值。' >&2; exit 20; fi
# Keep test artifacts inside the checkout.
# Optional workaround if the default 27.0 SDK lacks the SwiftUIMacros plugin:
# zsh test.sh --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
swift test --scratch-path "$PWD/.build/test-build" "$@"
