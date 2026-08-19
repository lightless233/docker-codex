# 剪贴板转发

本文说明 Linux/WSL2 与 macOS 宿主上的剪贴板转发方式、安全注意事项，
以及平台兼容层的作用。需要关闭剪贴板转发、或想了解容器内
Codex/Claude 为何能读取截图时阅读本文。

启动器默认转发剪贴板能力（`--disable-clipboard` 可关闭）。Linux/WSL 下
容器内的 Codex 和 Claude 可以直接读取截图；下文的 macOS 桥接目前仅供
`docker-codex` 使用。Linux/WSL 挂载被限制为单个 socket 文件的只读挂载：
WSLg 下只挂载 Wayland socket（取图实际走 `wl-paste`，不需要 X11）；
原生 Linux 下挂载宿主 `XDG_RUNTIME_DIR` 中的 Wayland socket 以及 X11
socket（`XAUTHORITY` 存在时同样只读挂载）。注意容器内的任意进程都
可以读取宿主剪贴板，粘贴密码等敏感内容前请留意。

macOS Docker Desktop 无法把宿主 `NSPasteboard` 直接挂进 Linux 容器。
启动 `docker-codex` 时，启动器因此运行一个随会话退出的 `osascript`
监视器：它只在剪贴板发生变化时让 AppKit 解码它所支持的图片
表示，统一转换为 PNG，原子写入 data home 下的私有会话目录，再把该
目录只读挂载进容器。文本剪贴板不会写入。当前剪贴板不含图片时，旧快照会
被删除，避免误贴上一张图；容器退出后监视器与整个会话目录一并清理。

固定的 Codex 0.148.0 只会在判断为 WSL 后调用 PowerShell 图片 fallback，
所以 macOS 的 Codex 容器仅在宿主监视器成功启动时注入一个最小
`WSL_INTEROP` 标记。`powershell.exe` shim 随后从只读挂载复制当前快照到
容器自身、由运行 UID 持有的输出目录，并返回 Codex 预期的 Windows 形状
路径。标记不会传给其他 agent；监视器启动失败时启动器会警告并继续运行
Codex，只是贴图不可用。

WSLg 可能把 PNG 截图以 `image/bmp` 暴露给 Wayland 客户端。Claude Code
虽然会读取该 BMP 数据，但当前版本的后续图像处理可能无法接受它。镜像
因此在系统 `wl-paste` 前放置了一个窄兼容层：当剪贴板包含
`image/bmp`、但不包含 `image/png` 时额外声明 PNG，并在请求 PNG 时实时
转换；已有 PNG 以及其他调用仍原样交给系统 `wl-paste`。这在剪贴板格式
边界解决问题，同时可供 Claude 和 Codex 使用。

WSL 宿主上的 Codex 实际是通过 Windows PowerShell 回退读取剪贴板图像
的，而 Docker Desktop 容器无法使用 WSL interop 触达 Windows 会话。
镜像因此内置了一个 `powershell.exe` shim：它模拟 Codex 0.148.0 期望
的调用契约（包括 Windows 路径到 `/mnt/c` 的映射），通过转发进来的
WSLg Wayland 剪贴板取图并转成 PNG。shim 只处理剪贴板图像读取，其他
`powershell.exe` 调用一律失败。它与 Codex 内部实现耦合，属于临时
兼容层；上游提供正式的剪贴板读取接口后应移除。

`--disable-clipboard` 在 Linux/WSL 下跳过显示 socket，在 macOS 下不启动
`NSPasteboard` 监视器、不挂载快照目录，也不注入兼容标记。

---

返回 [README](../../README.md)
