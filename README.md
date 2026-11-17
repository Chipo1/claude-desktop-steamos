# Claude Desktop on SteamOS

Run Anthropic's **official** Claude Desktop app (Linux beta) on a Steam Machine, Steam Deck, or any device running SteamOS, without modifying the read-only system.

Tested on a Steam Machine in Desktop Mode in November 2026: **Chat, Code and Cowork all work**. The Steam Deck runs the same SteamOS, so it should work there too, but it hasn't been tested on one.

> **Unofficial guide.** Not affiliated with or supported by Anthropic or Valve. Claude Desktop for Linux is itself a beta.

## Why this is needed

- Anthropic ships Claude Desktop for Linux only as a `.deb` for **Ubuntu 22.04+ and Debian 12+** ([official docs](https://code.claude.com/docs/en/desktop-linux)).
- SteamOS is Arch-based and its root filesystem is read-only, so you can't install system packages on it.
- **Distrobox** solves this: it runs an Ubuntu container in your home folder, and apps inside it appear in the normal SteamOS app menu.

But there is a trap (see [The font problem](#the-font-problem-squares-instead-of-text)): with a default Distrobox setup, launching Claude makes **every app on SteamOS** show squares instead of text. The script below prevents that.

## Quick start

In **Desktop Mode** (Steam button → Power → Switch to Desktop), open **Konsole** and run:

```bash
git clone https://github.com/Chipo1/claude-desktop-steamos.git
cd claude-desktop-steamos
bash setup.sh
```

The script:

1. creates an Ubuntu 26.04 container named `claude` (or reuses an existing one)
2. installs fonts and gives the container **its own font cache**, before Claude ever runs
3. downloads Anthropic's signing key and **checks its fingerprint**
4. adds Anthropic's apt repository and installs `claude-desktop`
5. adds **Claude** to the SteamOS app menu, through a small launcher that keeps you signed in (see [Staying signed in](#staying-signed-in))

Then launch **Claude** from the app menu and sign in. Claude is meant to be used in Desktop Mode; if you ever want it in Gaming Mode too, see [Optional: Gaming Mode](#optional-gaming-mode).

Other options:

```bash
bash setup.sh --update               # update Claude Desktop now
bash setup.sh --enable-auto-update   # keep it updated in the background
bash setup.sh --fix-host-fonts       # fix squares-instead-of-text on SteamOS
bash setup.sh --uninstall            # remove the container and menu entry
bash setup.sh --help
```

## Staying signed in

On Linux, Claude encrypts your saved sign-in with your desktop's keyring, which on SteamOS is KDE Wallet. Out of the box, two things go wrong:

- **You have to sign in again after a reboot.** KDE Wallet only starts when an app asks for it, and Claude only checks whether it's already running. Right after you log in, nothing has asked for it yet, so Claude finds no keyring and can't read your saved sign-in. Dismissing a KDE Wallet prompt has the same effect.
- **KDE Wallet keeps asking for its password.** On a normal KDE desktop, the wallet unlocks with the password you type at login. SteamOS logs you in automatically, so every app that uses the wallet has to ask you instead.

**Fix part 1 (done by the script):** the menu entry starts Claude through a small launcher (`~/.local/bin/claude-desktop-steamos-launch`) that wakes KDE Wallet up first. It also passes `--password-store=kwallet6`, so Claude always uses KDE Wallet instead of guessing from the environment it was started in.

**Don't let KDE reopen Claude at login.** If Claude is still open when you shut down, Plasma reopens it by itself at the next login, bypassing the launcher and often before the wallet is running. Either quit Claude (tray icon → Quit) before shutting down, or go to **System Settings → Session → Desktop Session** and choose to start with an empty session. To have Claude open at every login, add it under **System Settings → Autostart** instead, which goes through the launcher.

**Fix part 2 (your choice):** the wallet has to be unlocked whenever Claude starts.

- **Blank wallet password (no prompts at all):** open **KDE Wallet Manager** from the app menu, select `kdewallet`, choose **Change Password**, enter your current wallet password, and leave both new-password fields empty. Then log out and back in. This also stops the prompts from other apps that use the wallet. *Trade-off:* everything in the wallet (app sign-ins, saved Wi-Fi passwords) is then stored without a password protecting it, so anyone with access to your files or your unlocked machine can read it. On a living-room console that's often acceptable.
  - If KDE Wallet Manager isn't installed, get it from Discover or run `flatpak install flathub org.kde.kwalletmanager`.
  - Forgot the wallet password? Start a fresh wallet instead. **This discards everything stored in it** (saved Wi-Fi passwords, app sign-ins). Quit Claude and other apps that use the wallet, then run:
    ```bash
    mkdir -p ~/kwallet-backup
    mv ~/.local/share/kwalletd/kdewallet.* ~/kwallet-backup/
    ```
    Log out and back in. The next time an app needs the wallet, KDE opens a "create wallet" wizard: choose **Blowfish** and leave the password empty. To restore the old wallet, move the files back and log out.
- **Keep the wallet password:** type it the first time an app needs the wallet after you switch to Desktop Mode. It then stays open until you log out or go back to Gaming Mode.

If Claude used a different password store before you ran the script, you'll have to sign in once more afterwards.

> **Don't disable KDE Wallet.** Many Steam Deck guides suggest setting `Enabled=false` in `~/.config/kwalletrc` to stop the pop-ups. That also removes the keyring Claude needs, so Claude stops saving your sign-in. Use a blank wallet password instead.

> `--password-store=basic`, the usual fix for other Electron apps, **does not work** for Claude. Claude then shows "No system keyring is available" and saves no sign-in at all.

> **Not fixable locally:** some Linux beta users are asked to sign in again every day or two even with a working keyring. Claude's log shows this as `session_stale_relogin`. It appears to come from the server, so nothing in this guide changes it.

## Automatic updates

The Linux beta doesn't update itself, and updates from Anthropic's apt repository arrive inside the container, where SteamOS's own updater can't see them. To have them installed automatically:

```bash
bash setup.sh --enable-auto-update
```

This adds a systemd **user** timer that checks for a new version every 6 hours. The timer lives in your home folder, so it survives SteamOS updates.

- **Never while you're using Claude:** if Claude is open, the check is skipped and retried at the next one, so the app is never replaced mid-use. If you keep Claude open all the time, close it now and then, or run `bash setup.sh --update`.
- **Missed checks** (machine off or asleep) run soon after it wakes up.
- The script keeps its own copy in `~/.local/share/claude-desktop-steamos/`, so moving or deleting the cloned repo doesn't break the timer.

```bash
systemctl --user list-timers claude-desktop-update.timer   # when is the next check?
journalctl --user -u claude-desktop-update                 # what happened last time?
bash setup.sh --disable-auto-update                        # turn it off
```

## Optional: Gaming Mode

Claude is most useful in Desktop Mode, but you can launch it from Gaming Mode if you want to. In Desktop Mode, right-click **Claude** in the app menu and choose **Add to Steam**; it then appears under **Non-Steam** in your library. You'll want a keyboard.

- Use a blank wallet password (see [Staying signed in](#staying-signed-in)). If the wallet has a password, the prompt may have nowhere to appear in Gaming Mode, and Claude starts signed out.
- If you added Claude to Steam before running the script, remove that shortcut and add it again so it goes through the launcher.

## Manual installation

If you'd rather run each step yourself:

```bash
# 1. Create and enter an Ubuntu container
distrobox create --name claude --image ubuntu:26.04
distrobox enter claude
```

Inside the container:

```bash
# 2. Fonts, and a separate font cache (do this BEFORE launching Claude)
sudo apt update
sudo apt install -y curl gpg fontconfig fonts-noto-core fonts-noto-color-emoji fonts-dejavu-core
sudo tee /etc/fonts/conf.d/00-separate-cache.conf <<'EOF'
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
<fontconfig>
  <cachedir prefix="xdg">fontconfig-ubuntu</cachedir>
</fontconfig>
EOF

# 3. Anthropic's signing key
sudo curl -fsSLo /usr/share/keyrings/claude-desktop-archive-keyring.asc https://downloads.claude.ai/claude-desktop/key.asc
gpg --show-keys /usr/share/keyrings/claude-desktop-archive-keyring.asc
# The fingerprint must be: 31DD DE24 DDFA B679 F42D 7BD2 BAA9 29FF 1A7E CACE

# 4. Repository and package
echo "deb [arch=amd64,arm64 signed-by=/usr/share/keyrings/claude-desktop-archive-keyring.asc] https://downloads.claude.ai/claude-desktop/apt/stable stable main" | sudo tee /etc/apt/sources.list.d/claude-desktop.list
sudo apt update && sudo apt install -y claude-desktop
fc-cache -f

# 5. Add to the SteamOS app menu, always using KDE Wallet
distrobox-export --app claude-desktop --extra-flags "--password-store=kwallet6"
exit
```

The manual route skips the launcher described in [Staying signed in](#staying-signed-in), so you may have to sign in again after a reboot. Running `bash setup.sh` afterwards adds it to the same container.

## The font problem: squares instead of text

**Symptom:** after launching Claude Desktop from the container, all text on SteamOS (Konsole, Dolphin, menus, window titles) turns into empty squares. Rebooting fixes it until the next time Claude starts.

**Cause:** Distrobox shares your home folder with the container, including `~/.cache/fontconfig`. Font cache files there are named after a hash of the font directory's path, so the container's `/usr/share/fonts` and SteamOS's `/usr/share/fonts` map to the **same cache file**. When Claude starts inside the container, it writes a cache describing the *container's* fonts (a bare Ubuntu image has none). SteamOS then reads that cache, finds no usable fonts, and draws squares.

**Fix used here:** an extra fontconfig rule inside the container (`/etc/fonts/conf.d/00-separate-cache.conf`) makes the container write its cache to `~/.cache/fontconfig-ubuntu` instead. SteamOS keeps `~/.cache/fontconfig` to itself.

**If you're already seeing squares:**

```bash
bash setup.sh                    # adds the fix to your existing container
bash setup.sh --fix-host-fonts   # clears SteamOS's broken cache
```

Then log out and back in, or reboot.

**Alternative fix:** set `XDG_CACHE_HOME` to a separate folder inside the container, which isolates *all* of its caches, not only fonts. This approach is described in the Cursor forum post linked below.

The same collision has been reported elsewhere: on a Fedora host, Cursor lost all its text after Claude Desktop had run in Distrobox, and a KDE bug report describes Plasma showing only boxes because of a bad font cache. On SteamOS it takes down the whole KDE desktop.

## Troubleshooting

**`distrobox: command not found`:** recent SteamOS versions include Distrobox. If yours doesn't, install it into your home folder:

```bash
curl -s https://raw.githubusercontent.com/89luca89/distrobox/main/install | sh -s -- --prefix ~/.local
curl -s https://raw.githubusercontent.com/89luca89/distrobox/main/extras/install-podman | sh -s -- --prefix ~/.local
```

Make sure `~/.local/bin` is on your `PATH`.

**Container fails on first start:** an older Distrobox may not handle a brand-new image. Update Distrobox with the commands above, or use `IMAGE=ubuntu:24.04 bash setup.sh`.

**Claude's own window shows squares (but SteamOS is fine):** the container has no fonts. Run `bash setup.sh` again to install them.

**KDE Wallet password prompts, or signed out after a reboot:** see [Staying signed in](#staying-signed-in). Claude's logs show which store it used: `find ~/.config/Claude -name "*.log" -exec grep -h "safeStorage\]" {} + | tail`. Lines with `preflight-unavailable` or `backend=basic_text` mean it started without the wallet.

**Claude's icon is blank in the taskbar or app menu while Claude is closed:** run `bash setup.sh` again. It copies Claude's icon out of the container so SteamOS can show it. (Uninstalling a *second* container with the same app can also remove the shared icon; the same command brings it back.)

**Sign-in doesn't come back to the app:** make sure a default web browser is set in KDE's System Settings.

**Automatic updates never seem to run:** check `journalctl --user -u claude-desktop-update`. "Claude is open; skipping" means Claude was open at every check; close it for a while, or run `bash setup.sh --update`.

**The Cowork tab says it needs KVM, `/dev/kvm` access or `vhost_vsock`:** Cowork runs its tasks in a small virtual machine, which uses SteamOS's kernel and devices, not the container's. Fix whatever the message names on the SteamOS side (in Konsole, outside the container), following Anthropic's [Cowork requirements](https://code.claude.com/docs/en/desktop-linux#cowork-requirements), then restart Claude. `sudo` on SteamOS needs a password; set one with `passwd` if you haven't.

**Chinese, Japanese or Korean text shows as boxes in Claude:** run `distrobox enter claude -- sudo apt install -y fonts-noto-cjk`.

## Limitations

These come from the Linux beta itself, not from SteamOS (see Anthropic's [current list](https://code.claude.com/docs/en/desktop-linux)):

- no Computer Use (app and screen control)
- no dictation (voice input)
- the Quick Entry global hotkey works on X11; on Wayland it needs your desktop's GlobalShortcuts portal
- the app doesn't update itself; see [Automatic updates](#automatic-updates)

## Credits and references

- [Claude Desktop on Linux](https://code.claude.com/docs/en/desktop-linux): official installation docs
- [Blank UI text when a containerised Electron app shares ~/.cache/fontconfig](https://forum.cursor.com/t/blank-ui-text-skfontmgr-fatal-on-linux-when-a-containerised-electron-app-shares-cache-fontconfig-root-cause-fix/171979): the same root cause with Claude Desktop in Distrobox on Fedora
- [KDE bug 504556: Fonts turned into boxes due to bad cache](https://bugs.kde.org/show_bug.cgi?id=504556)
- [Distrobox](https://github.com/89luca89/distrobox)
- [aaddrick/claude-desktop-debian](https://github.com/aaddrick/claude-desktop-debian): community packaging, including an AppImage if you prefer not to use a container

## License

MIT
