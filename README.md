# GDM Login Loop Fix — Fedora / GNOME

Fixes the "correct password, immediately kicked back to login screen" bug on Fedora with GDM.
No reinstall. No data loss. Survives hard power cuts.

Tested on: **Fedora 44, GNOME 47, GDM 47** — Intel + NVIDIA GTX 1050 Mobile (Optimus)

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

## Common co-culprit: ibus-typing-booster

If you're still hitting the loop after clearing the session targets, check whether `ibus-typing-booster` is installed:

```bash
rpm -q ibus-typing-booster
```

This package causes a second, stacked failure: it times out during `gnome-shell` init (`setCompletionEnabled → ibusManager.js → Gio.IOErrorEnum: Timeout`), which can mask the session-target error and make the loop appear to recur even after the fix.

If you're using a plain US keyboard layout (`xkb:us`) — the default for most English installs — you don't need it:

```bash
sudo dnf remove ibus-typing-booster
```

The two failures are independent and can coexist. Fix both.

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

### Layer 1 — GDM PostSession + PreSession scripts

Two hooks that bracket every login. PostSession fires on logout or session crash and clears stuck targets. PreSession fires before every login attempt as a fallback — if PostSession is ever skipped (power cut, misconfiguration), PreSession catches the stale state before the next login tries to use it.

**Important:** `XDG_RUNTIME_DIR` must be set explicitly. GDM runs these scripts as root, so the user's D-Bus session bus is unreachable without it. The simpler `su - "$USER" -c "systemctl --user ..."` form silently does nothing.

**PostSession:**

```bash
sudo mkdir -p /etc/gdm/PostSession
sudo tee /etc/gdm/PostSession/Default << 'EOF'
#!/bin/bash
USER_ID=$(id -u "$USER" 2>/dev/null)
if [ -n "$USER_ID" ] && [ -d "/run/user/$USER_ID" ]; then
    XDG_RUNTIME_DIR="/run/user/$USER_ID" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$USER_ID/bus" \
    su "$USER" -s /bin/bash -c \
      "systemctl --user stop graphical-session.target graphical-session-pre.target 2>/dev/null; systemctl --user reset-failed 2>/dev/null"
fi
pkill -u "$USER" gnome-session 2>/dev/null
exit 0
EOF
sudo chmod +x /etc/gdm/PostSession/Default
```

**PreSession:**

```bash
sudo mkdir -p /etc/gdm/PreSession
sudo tee /etc/gdm/PreSession/Default << 'EOF'
#!/bin/bash
USER_ID=$(id -u "$USER" 2>/dev/null)
if [ -n "$USER_ID" ] && [ -d "/run/user/$USER_ID" ]; then
    XDG_RUNTIME_DIR="/run/user/$USER_ID" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$USER_ID/bus" \
    su "$USER" -s /bin/bash -c \
      "systemctl --user stop graphical-session.target graphical-session-pre.target 2>/dev/null; systemctl --user reset-failed 2>/dev/null"
fi
exit 0
EOF
sudo chmod +x /etc/gdm/PreSession/Default
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

## NVIDIA / hybrid graphics (Intel + NVIDIA Optimus)

If your system has an Intel integrated GPU and a discrete NVIDIA GPU, there is an additional failure mode: the open-source `nouveau` driver (and its newer successor `nova_core`) can load alongside the proprietary NVIDIA driver and conflict, causing GDM to fail during graphics initialization — which produces the exact same login-loop symptom.

**Check if this applies to you:**

```bash
lspci | grep -i "vga\|3d\|display"
lsmod | grep nouveau
```

If you see two GPUs (Intel + NVIDIA) and `nouveau` is loaded while the proprietary driver is installed, that's the conflict.

**Fix — blacklist nouveau and nova_core in GRUB:**

Edit your GRUB defaults:

```bash
sudo nano /etc/default/grub
```

Add to `GRUB_CMDLINE_LINUX`:

```
rd.driver.blacklist=nouveau,nova_core modprobe.blacklist=nouveau,nova_core
```

Example result:

```
GRUB_CMDLINE_LINUX="rd.luks.uuid=<your-uuid> rhgb quiet rd.driver.blacklist=nouveau,nova_core modprobe.blacklist=nouveau,nova_core"
```

Then regenerate the GRUB config and reboot:

```bash
sudo grub2-mkconfig -o /boot/grub2/grub.cfg
sudo reboot
```

**Verify after reboot:**

```bash
lsmod | grep nouveau   # should return nothing
lsmod | grep nvidia    # should show nvidia modules
```

---

### nvidia-powerd error on GTX 10-series (expected, not a bug)

If `nvidia-powerd` is enabled but fails with:

```
ERROR! Allocate Root client failed 0x59
```

This is **expected** on GTX 10xx (Pascal) mobile GPUs. The `nvidia-powerd` daemon only supports Ampere (30xx) and newer. The failure is harmless — it exits cleanly and does not affect display output. You can disable it if the noise bothers you:

```bash
sudo systemctl disable nvidia-powerd
```

---

## Contributing

If this helped you, a star goes a long way. If you're on a different Fedora version or hit a variation of this bug, open an issue with your journal output and we can document it.
