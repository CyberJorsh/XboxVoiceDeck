#!/bin/bash
# Shared by build/test/probe scripts; preserve an explicit Xcode selection.
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  deck_selected_xcode="$(xcode-select -p 2>/dev/null || true)"
  if [[ "$deck_selected_xcode" == *.app/Contents/Developer && -x "$deck_selected_xcode/usr/bin/xcodebuild" ]]; then
    export DEVELOPER_DIR="$deck_selected_xcode"
  elif [[ -x /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  else
    echo "A full Xcode installation is required. Set DEVELOPER_DIR to Xcode.app/Contents/Developer." >&2
    return 1
  fi
  unset deck_selected_xcode
fi
