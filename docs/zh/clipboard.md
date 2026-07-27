# 剪贴板转发

本文说明 Linux/WSL2 宿主上剪贴板转发的挂载方式与安全注意事项，以及
WSL 下 `powershell.exe` shim 的作用与临时性质。需要关闭剪贴板转发、
或想了解容器内 Codex 为何能读取截图时阅读本文。

启动器默认转发剪贴板能力（`--disable-clipboard` 可关闭），容器内的
Codex 可以直接读取截图。挂载被限制为单个 socket 文件的只读挂载：
WSLg 下只挂载 Wayland socket（取图实际走 wl-paste，不需要 X11）；
原生 Linux 下挂载宿主 `XDG_RUNTIME_DIR` 中的 Wayland socket 以及 X11
socket（`XAUTHORITY` 存在时同样只读挂载）。注意容器内的任意进程都
可以读取宿主剪贴板，粘贴密码等敏感内容前请留意。

WSL 宿主上的 Codex 实际是通过 Windows PowerShell 回退读取剪贴板图像
的，而 Docker Desktop 容器无法使用 WSL interop 触达 Windows 会话。
镜像因此内置了一个 `powershell.exe` shim：它模拟 Codex 0.145.0 期望
的调用契约（包括 Windows 路径到 `/mnt/c` 的映射），通过转发进来的
WSLg Wayland 剪贴板取图并转成 PNG。shim 只处理剪贴板图像读取，其他
`powershell.exe` 调用一律失败。它与 Codex 内部实现耦合，属于临时
兼容层；上游提供正式的剪贴板读取接口后应移除。

---

返回 [README](../../README.md)
