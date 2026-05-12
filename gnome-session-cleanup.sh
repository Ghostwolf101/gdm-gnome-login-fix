#!/bin/bash
# Clears stale GNOME session state left by hard shutdowns and power cuts.
# Runs at boot before GDM via gnome-session-cleanup.service.
USER_HOME="/home/$(whoami)"
rm -rf "${USER_HOME}/.config/gnome-session/saved-session/"
rm -f  "${USER_HOME}/.local/share/gnome-shell/extension-errors"
rm -f  "${USER_HOME}/.local/share/recently-used.xbel.lock" 2>/dev/null
rm -f  "${USER_HOME}/.ICEauthority-c" "${USER_HOME}/.ICEauthority-l" 2>/dev/null
exit 0
