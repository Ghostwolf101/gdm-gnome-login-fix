#!/bin/bash
# GDM PostSession cleanup script.
# Install to /etc/gdm/PostSession/Default and chmod +x.
# Fires automatically on every session end (logout or crash).
#
# NOTE: XDG_RUNTIME_DIR must be set explicitly — GDM runs this as root and
# the user's D-Bus session bus is not reachable without it. The original
# simpler form (su - "$USER" -c "systemctl --user ...") silently fails.
USER_ID=$(id -u "$USER" 2>/dev/null)
if [ -n "$USER_ID" ] && [ -d "/run/user/$USER_ID" ]; then
    XDG_RUNTIME_DIR="/run/user/$USER_ID" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$USER_ID/bus" \
    su "$USER" -s /bin/bash -c \
      "systemctl --user stop graphical-session.target graphical-session-pre.target 2>/dev/null; systemctl --user reset-failed 2>/dev/null"
fi
pkill -u "$USER" gnome-session 2>/dev/null
exit 0
