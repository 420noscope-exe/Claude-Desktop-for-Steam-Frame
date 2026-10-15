# Claude Desktop installer for Arch-based Linux (SteamOS, Steam Frame)

A single shell script that installs Anthropic's official Claude Desktop Linux beta on systems that can't use `apt`, such as SteamOS on the Steam Frame, Arch, and Manjaro.

Anthropic ships the app as a `.deb` for Debian and Ubuntu. This script downloads that `.deb`, unpacks it into your home folder, and sets up a launcher, a menu entry, and the `claude://` link handler that browser sign-in needs. It needs no root access and doesn't touch the system partition, so it works on SteamOS's read-only root.

> **Unofficial.** Anthropic only supports Debian and Ubuntu for this beta. The steps were verified by hand on a Steam Frame (SteamOS, arm64), where every library the app needs was already present.

## Quick start

```bash
./install-claude-desktop.sh
```

Then start **Claude** from your application menu (log out and back in if it doesn't appear yet). Signing in opens your browser, which hands back to the app through a `claude://` link.

To update later, run the script again.

## Usage

```
install-claude-desktop.sh [command] [options]
```

### Commands

| Command | What it does |
| --- | --- |
| `install` | Download and install the newest version. This is the default. |
| `update` | Same as `install`. It only replaces the app if a newer version exists. |
| `uninstall` | Remove everything the script installed. |
| `help` | Show the built-in help. |

### Options

| Option | What it does |
| --- | --- |
| `-f`, `--force` | Reinstall even if the newest version is already installed. |
| `--deb FILE` | Install from a `.deb` you already downloaded. The checksum can't be verified in this mode. |
| `--keep-download` | Keep the downloaded `.deb` in the cache folder instead of deleting it after install. |
| `-h`, `--help` | Show the built-in help. |

### Environment variables

| Variable | Default | Purpose |
| --- | --- | --- |
| `CLAUDE_INSTALL_DIR` | `~/.local/share/claude-desktop` | Where the app is unpacked. |
| `CLAUDE_BIN_DIR` | `~/.local/bin` | Where the launcher script goes. |

The script also respects `XDG_DATA_HOME`, `XDG_CONFIG_HOME`, `XDG_STATE_HOME`, and `XDG_CACHE_HOME`.

### Examples

```bash
./install-claude-desktop.sh                     # install or update
./install-claude-desktop.sh --force             # reinstall the current version
./install-claude-desktop.sh --deb ~/Downloads/claude-desktop_X.Y.Z_arm64.deb
./install-claude-desktop.sh uninstall
```

## Requirements

- `bash`, `curl`, `sha256sum`, `awk`, `sort`, `mktemp`
- `bsdtar`, or both `ar` and `tar`, to unpack the `.deb`
- About 1.2 GB of free space in your home folder
- A regular user account. The script refuses to run as root.

## How it works

The script runs these steps in order:

1. **Checks.** It confirms it isn't running as root, that the install folder is safe to use, that the unpacking tools exist, and that there's enough disk space. It won't replace a folder that doesn't look like one of its own installs.
2. **Finds the newest package.** It detects your CPU (`arm64` or `amd64`), downloads the repository index from `downloads.claude.ai`, and picks the highest version with `sort -V`. If that version is already installed, it stops, unless you passed `--force`.
3. **Downloads and verifies.** The `.deb` is saved to the cache folder, and its SHA-256 is compared with the value listed in the index. A mismatch deletes the download and aborts.
4. **Unpacks.** The `.deb` is an `ar` archive containing a `data.tar.*`. The script extracts both layers into a temporary folder next to the install folder, not in `/tmp`, which is a small RAM disk on SteamOS.
5. **Checks libraries.** It runs `ldd` on the app binary and warns about any missing shared libraries. This is a warning only: the install continues, and the message explains how to supply the missing libraries.
6. **Swaps the app in.** The previous version is moved aside, the new one is moved into place, and the old one is deleted. If the move fails, the previous version is restored.
7. **Sets up integration.** It writes the settings file (only if one doesn't exist), the launcher script, the icons, and the menu entry. The menu entry is the one shipped in the package with its `Exec` lines pointed at the launcher, which keeps the correct window class and the `claude://` handler. It then refreshes the desktop caches and registers `claude://` links with `xdg-mime`.

### Files it creates

| Path | Purpose |
| --- | --- |
| `~/.local/share/claude-desktop/` | The unpacked app, plus a `.installed-from` marker recording which `.deb` it came from. |
| `~/.local/bin/claude-desktop-launcher` | Launcher script. Reads the settings file and starts the app. |
| `~/.local/share/applications/claude-desktop.desktop` | Application menu entry and `claude://` handler. |
| `~/.local/share/icons/hicolor/*/apps/claude-desktop.png` | Icons from the package. |
| `~/.config/claude-desktop-linux/config` | Settings (see below). Never overwritten on update. |
| `~/.local/state/claude-desktop-linux/launch.log` | Launch output. Rotated at about 512 KB. |
| `~/.cache/claude-desktop-linux/` | Downloaded `.deb` files. |

### Settings

The launcher reads `~/.config/claude-desktop-linux/config`, a small file in shell syntax:

- `CLAUDE_FLAGS`: extra command-line flags for the app. The default is `--no-sandbox`. If the window is blank or glitchy, try adding `--ozone-platform=wayland` or `--disable-gpu`.
- `CLAUDE_EXTRA_LIBS`: a colon-separated list of folders with extra shared libraries, for when the installer reported missing ones.

## Notes and limitations

- **`--no-sandbox` is on by default.** Chromium's sandbox helper must be setuid root, which isn't possible when running from a home folder. Running without the sandbox weakens the browser's process isolation. Remove the flag from the settings file if you want to try without it.
- **The checksum is not a signature check.** The index and the package are both fetched over HTTPS from Anthropic, and the SHA-256 guards against a corrupted or mismatched download. The script doesn't verify Anthropic's GPG signature on the repository.
- **No automatic updates.** Re-run the script to update.
- **Tested on arm64 only.** The `amd64` package is selected automatically on x86_64 machines, but that path hasn't been verified.
- **Cowork is untested.** The app's Cowork feature needs QEMU and KVM, which this script doesn't set up.
- **Uninstall leaves your data.** It removes everything listed above but not the app's own data in `~/.config/Claude` or any sign-in saved in your desktop keyring. Delete those yourself for a completely clean slate.
