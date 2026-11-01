#!/bin/zsh
set -eu
cd "${0:A:h}"
output=${1:-"$PWD/.build/preview"}
if (( $# > 0 )); then shift; fi
preview_args=()
build_args=()
while (( $# > 0 )); do
  case "$1" in
    --lang|--theme)
      option=$1
      (( $# >= 2 )) || { print -u2 'Use --lang en|zh-Hans and --theme light|dark'; exit 1; }
      preview_args+=("$option" "$2")
      shift 2
      ;;
    *) build_args+=("$1"); shift ;;
  esac
done
swift build --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk --disable-keychain --disable-netrc "${build_args[@]}"
binary=$(swift build --show-bin-path --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk --disable-keychain --disable-netrc "${build_args[@]}")
"$binary/AISubGauge" --render-preview "$output" "${preview_args[@]}"
