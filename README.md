# GDM Login Loop Fix — Fedora / GNOME

Fixes the "correct password, immediately kicked back to login screen" bug on Fedora with GDM.
No reinstall. No data loss. Survives hard power cuts.

Tested on: **Fedora 44, GNOME 47, GDM 47**

---

## The symptom

You type your password at the GDM login screen. It accepts it. Then it dumps you straight back to the login screen. No error message. TTY login (`Ctrl+Alt+F3`) still works fine.

## What's actually happening

This is **not** a wrong password. It is **not** a security event. Here is what the journal shows:

```
session opened   <timestamp>
session closed   <timestamp + 2 seconds>
```

The GNOME session opens and dies within 2–3 seconds. The culprit is stale session state left over from a previous crash or hard shutdown:

1. `gnome-session-init-worker` hits a GLib assertion failure on startup
2. GDM logs `Session never registered, failing`
3. `graphical-session.target` is left **ACTIVE** in the user's systemd manager
4. Every subsequent login finds the target already active and aborts immediately

**Why power cuts make it worse:** GDM's PostSession cleanup script never fires on a hard shutdown. Stale state accumulates across every power cut until login breaks entirely.

---

## Instant fix

From any TTY (`Ctrl+Alt+F3`), log in and run:

```bash
systemctl --user stop graphical-session.target graphical-session-pre.target gnome-session.target
pkill -u "$USER" gnome-session 2>/dev/null
sudo systemctl restart gdm
```

Switch back to the login screen with `Ctrl+Alt+F1`.

---

## Permanent fix

Two layers. You want both.

### Layer 1 — GDM PostSession script

Cleans up stuck targets on every normal logout or session crash. Prevents the loop from forming in the first place.

```bash
sudo mkdir -p /etc/gdm/PostSession
sudo tee /etc/gdm/PostSession/Default << 'EOF'
#!/bin/bash
su - "$USER" -c "systemctl --user stop graphical-session.target graphical-session-pre.target gnome-session.target" 2>/dev/null
pkill -u "$USER" gnome-session 2>/dev/null
exit 0
EOF
sudo chmod +x /etc/gdm/PostSession/Default
```

### Layer 2 — Boot-time systemd service

The PostSession script only runs on clean session end. A hard power cut bypasses it entirely. This service runs **before GDM starts** on every boot and clears any leftover state.

**Step 1 — create the cleanup script:**

Write this to your home directory first (Fedora's SELinux blocks direct sudo execution from `~` — see note below):

```bash
cat > ~/gnome-session-cleanup.sh << 'EOF'
#!/bin/bash
USER_HOME="/home/$(whoami)"
rm -rf "${USER_HOME}/.config/gnome-session/saved-session/"
rm -f  "${USER_HOME}/.local/share/gnome-shell/extension-errors"
rm -f  "${USER_HOME}/.local/share/recently-used.xbel.lock" 2>/dev/null
rm -f  "${USER_HOME}/.ICEauthority-c" "${USER_HOME}/.ICEauthority-l" 2>/dev/null
exit 0
EOF
sudo cp ~/gnome-session-cleanup.sh /usr/local/bin/gnome-session-cleanup.sh
sudo chmod +x /usr/local/bin/gnome-session-cleanup.sh
```

**Step 2 — create the service unit:**

```bash
cat > ~/gnome-session-cleanup.service << 'EOF'
[Unit]
Description=Clean stale GNOME session state at boot
Before=gdm.service
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/gnome-session-cleanup.sh
RemainAfterExit=yes

[Install]
WantedBy=graphical.target
EOF
sudo cp ~/gnome-session-cleanup.service /etc/systemd/system/
```

**Step 3 — enable it:**

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now gnome-session-cleanup.service
```

**Verify:**

```bash
systemctl status gnome-session-cleanup.service
```

You should see `Active: active (exited)` and `status=0/SUCCESS`.

---

## SELinux note (Fedora-specific)

You cannot run scripts directly from your home directory under `sudo` on Fedora. The home directory has SELinux context `user_home_t`, which is not executable in a privileged domain. The workaround used above — write to `~`, then `sudo cp` to a system path — is the correct approach.

**This will fail:**
```bash
sudo bash ~/myscript.sh   # Permission denied — SELinux blocks it
```

**This works:**
```bash
sudo cp ~/myscript.sh /usr/local/bin/ && sudo bash /usr/local/bin/myscript.sh
```

---

## How I diagnosed this

Standard `sudo` and password advice didn't help. Digging into the journal:

```bash
journalctl --since "today" -g "session opened|session closed|keyring|gnome-session"
```

The keyring logs showed `gnome-keyring-daemon started properly and unlocked keyring` — password mismatch was ruled out immediately. The session open/close timestamps 2 seconds apart pointed directly to the session target state issue, not authentication.

---

## Contributing

If this helped you, a star goes a long way. If you're on a different Fedora version or hit a variation of this bug, open an issue with your journal output and we can document it.
