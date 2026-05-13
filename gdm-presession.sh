#!/bin/bash
# GDM PreSession cleanup script.
# Install to /etc/gdm/PreSession/Default and chmod +x.
# Fires before every login attempt — belt-and-suspenders if PostSession
# ever fails (power cut, hook misconfiguration, etc.).
USER_ID=$(id -u "$USER" 2>/dev/null)
if [ -n "$USER_ID" ] && [ -d "/run/user/$USER_ID" ]; then
    XDG_RUNTIME_DIR="/run/user/$USER_ID" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$USER_ID/bus" \
    su "$USER" -s /bin/bash -c \
      "systemctl --user stop graphical-session.target graphical-session-pre.target 2>/dev/null; systemctl --user reset-failed 2>/dev/null"
fi
exit 0
