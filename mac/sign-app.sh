#!/bin/zsh
# Default ad hoc requirements bind each signed component to its code hash.
sign_app() {
  codesign --force --deep --sign - --identifier com.mike.aisubgauge "$1"
}
