# 局域网 Mac 字幕服务

## 当前实现

Mac 运行 `MacSubtitleService/server.py`，使用 Apple Silicon 的 MLX Whisper Large V3 Turbo 识别音频。iPhone 在“设置 → 离线字幕与模型 → 局域网 Mac 字幕服务”填写地址与访问口令，测试连接后，在视频的“AI 字幕选项”里选择“局域网 Mac 转写”。手机仅导出所选音轨，完成上传后 Mac 创建持久任务并在本机按四分钟切片转写。界面显示“Mac 已接收音轨”后可以锁屏；重新打开 App 会按同一任务 ID 领取原文并继续翻译、显示与导出。上传尚未完成时需要保持 App 前台。

Mac 安装与启动（需要 macOS Apple Silicon、Python 3.10+、FFmpeg；首次转写需联网下载模型）：

```bash
brew install ffmpeg
cd MacSubtitleService
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
.venv/bin/python server.py
```

启动终端显示访问口令。默认监听 `8765` 端口；在 Mac 的“系统设置 → 网络”查看同一 Wi-Fi 下的局域网 IP，手机填写 `IP:8765`。Mac 防火墙需要允许 Python 接收入站连接。口令持久化于 `~/.config/lovort-mac-subtitles/token`，只有当前 Mac 用户可读；不要分享给其他人。按 Ctrl-C 停止服务。

## 可选 Docker Compose 入口

默认仍由上述 Mac 原生进程使用 Metal/MLX 推理。需要容器化入口层时，在原生服务运行的同时执行：

```bash
cd MacSubtitleService
docker compose up -d
```

Compose 启动 Nginx 网关，监听 Mac 的 `8766` 端口并转发到 Mac 原生服务的 `8765` 端口。此时手机可填 `Mac局域网IP:8766`，访问口令不变。网关不运行模型，也不保存音频；未来数据库或管理服务可作为独立 Compose 服务加入。Mac 防火墙需允许 `8766` 入站。停止网关使用 `docker compose down`，不会停止原生转写进程。

Docker Desktop 的 Linux 容器无法直接使用 macOS Metal/MLX。把推理进程本身放进容器通常只能使用 CPU，可能比 iPhone 端更慢，因此当前不提供 CPU 容器作为默认转写方案。网关和原生端口都仍是未加密 HTTP；网关不构成安全隔离。

## 当前边界

- 首版使用局域网 HTTP，音频和口令没有传输加密。仅在可信家庭网络使用；iOS 只接受私网 IP、`.local` 或 localhost 地址。私密视频被禁止发送到 Mac。
- 无自动发现、TLS 配对或后台服务安装。Mac 转写时必须保持运行；手机上传完成后可以断开连接，返回前台时再领取结果。Mac 保存每个已完成的四分钟片段与任务进度；服务重启后可续做未完成片段。
- Mac 同时只运行一个推理任务，完整音轨上传限制为 512 MiB。首次调用会下载约 GB 级的 MLX 模型；请预留磁盘空间。Mac 完成或失败后删除上传的音频，任务结果保留七天供手机重新领取。
- 手机本机 Whisper 转写在锁屏时由 App 主动暂停，回到前台从已保存检查点继续；iOS 不保证长时间锁屏推理。私密视频任务进入后台后仍保持用户暂停状态，不会自动恢复。
- 当前没有实测 iPhone 13 与不同 Apple Silicon Mac 的端到端耗时。传输、Mac 型号和 Wi-Fi 速度会影响收益。翻译服务仍按手机原有设置运行。

## 后续迭代

先用同一部两小时视频测量首条原文时间、总时长、准确率、发热和电量，再决定是否加入 Bonjour 自动发现、TLS 配对、分片内续传和后台驻留。TLS 配对完成前，不宜在共享网络中使用该服务。
