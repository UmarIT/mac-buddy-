#!/bin/sh
# Removes Mac Buddy, its hooks from Claude Code settings, and its state.
set -e

for app in "/Applications/MacBuddy.app" "$HOME/Applications/MacBuddy.app"; do
  if [ -x "$app/Contents/MacOS/MacBuddy" ]; then
    "$app/Contents/MacOS/MacBuddy" --disconnect || true
    break
  fi
done

# Remove the Cursor bridge too, if it was installed.
if [ -f "$HOME/.cursor/hooks/mac-buddy-cursor.py" ] && [ -x /usr/bin/python3 ]; then
  /usr/bin/python3 "$HOME/.cursor/hooks/mac-buddy-cursor.py" uninstall || true
fi

pkill -x MacBuddy 2>/dev/null || true
rm -rf "/Applications/MacBuddy.app" "$HOME/Applications/MacBuddy.app" "$HOME/.mac-buddy"
echo "Mac Buddy removed."
