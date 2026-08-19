# Clipboard forwarding

This page explains clipboard forwarding on Linux/WSL2 and macOS hosts, the
security considerations, and the platform compatibility layers.
Read it when you want to disable clipboard forwarding or understand how the
in-container Codex and Claude agents can read screenshots.

The launcher forwards clipboard access by default (`--disable-clipboard`
opts out). On Linux/WSL, in-container Codex and Claude can read pasted
screenshots; the macOS bridge below currently applies only to `docker-codex`.
Linux/WSL mounts are narrowed to single read-only socket file binds: on WSLg
only the Wayland socket (image reads actually go through `wl-paste`; X11 is not mounted);
on native Linux the Wayland socket from the host `XDG_RUNTIME_DIR` and the
X11 socket (`XAUTHORITY` is also mounted read-only when present). Note that
any process in the container can read the host clipboard — be careful what
you copy while a session is running.

Docker Desktop on macOS cannot mount the host `NSPasteboard` directly into a
Linux container. When `docker-codex` starts, the launcher therefore runs an
`osascript` monitor that exits with the session. It reacts only to clipboard
changes, reads PNG, TIFF, JPEG, or an image file copied in Finder, converts the
image to PNG, and atomically writes it into a private session directory below
the data home. That directory is mounted into the container. Clipboard text is
never written. When the current clipboard has no image, the previous snapshot
is removed so it cannot be pasted accidentally; the monitor and session
directory are cleaned up when the container exits.

Pinned Codex 0.148.0 calls its PowerShell image fallback only after deciding it
is running under WSL. The macOS Codex container therefore receives a minimal
`WSL_INTEROP` marker only after the host monitor starts successfully. The
`powershell.exe` shim copies the current mounted snapshot and returns the
Windows-shaped path Codex expects. Other agents do not receive the marker. If
the monitor cannot start, the launcher warns and continues without image paste.

WSLg can expose PNG screenshots to Wayland clients as `image/bmp`.
Claude Code can read those BMP bytes, but the current release can fail during
its subsequent image processing. The image therefore puts a narrow wrapper
in front of the system `wl-paste`: when `image/bmp` is available but
`image/png` is not, it also advertises PNG and converts to it on demand.
Existing PNG data and all other calls are delegated unchanged. This solves
the issue at the clipboard-format boundary for both Claude and Codex.

On a WSL host Codex actually reads clipboard images through a Windows
PowerShell fallback, and WSL interop cannot reach the Windows session from
a Docker Desktop container. The image therefore ships a `powershell.exe`
shim that emulates the exact call contract Codex 0.148.0 expects (including
the Windows-path-to-`/mnt/c` mapping), fetching the image through the
forwarded WSLg Wayland clipboard and converting it to PNG. The shim only
handles clipboard image reads; every other `powershell.exe` call fails. It
is coupled to Codex internals and is a temporary compatibility layer —
remove it once Codex offers an official clipboard reader interface.

`--disable-clipboard` skips display sockets on Linux/WSL. On macOS it starts no
`NSPasteboard` monitor, mounts no snapshot directory, and injects no compatibility
marker.

---

Back to [README](../../README.en.md)
