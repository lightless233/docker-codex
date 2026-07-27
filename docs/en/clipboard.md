# Clipboard forwarding

This page explains how clipboard forwarding is mounted on Linux/WSL2 hosts,
the security considerations, and the role and temporary nature of the
`powershell.exe` shim on WSL. Read it when you want to disable clipboard
forwarding or understand how the in-container agent can read screenshots.

The launcher forwards clipboard access by default (`--disable-clipboard`
opts out) so the in-container agent can read pasted screenshots. Mounts are
narrowed to single read-only socket file binds: on WSLg only the Wayland
socket (image reads actually go through wl-paste; X11 is not mounted);
on native Linux the Wayland socket from the host `XDG_RUNTIME_DIR` and the
X11 socket (`XAUTHORITY` is also mounted read-only when present). Note that
any process in the container can read the host clipboard — be careful what
you copy while a session is running.

On a WSL host Codex actually reads clipboard images through a Windows
PowerShell fallback, and WSL interop cannot reach the Windows session from
a Docker Desktop container. The image therefore ships a `powershell.exe`
shim that emulates the exact call contract Codex 0.145.0 expects (including
the Windows-path-to-`/mnt/c` mapping), fetching the image through the
forwarded WSLg Wayland clipboard and converting it to PNG. The shim only
handles clipboard image reads; every other `powershell.exe` call fails. It
is coupled to Codex internals and is a temporary compatibility layer —
remove it once Codex offers an official clipboard reader interface.

---

Back to [README](../../README.en.md)
