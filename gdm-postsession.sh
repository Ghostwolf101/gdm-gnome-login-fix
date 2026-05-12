#!/bin/bash
# GDM PostSession cleanup script.
# Install to /etc/gdm/PostSession/Default and chmod +x.
# Fires automatically on every session end (logout or crash).
su - "$USER" -c "systemctl --user stop graphical-session.target graphical-session-pre.target gnome-session.target" 2>/dev/null
pkill -u "$USER" gnome-session 2>/dev/null
exit 0
