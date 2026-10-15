# 局域网 Mac 字幕服务

## 当前实现

Mac 运行 `MacSubtitleService/server.py`，使用 Apple Silicon 的 MLX Whisper Large V3 Turbo 识别音频。iPhone 在“设置 → 离线字幕与模型 → 局域网 Mac 字幕服务”填写地址与访问口令，测试连接后，在视频的“AI 字幕选项”里选择“局域网 Mac 转写”。手机仅导出所选音轨的四分钟 M4A 分片并逐片上传；Mac 返回相对时间轴的原文，手机负责合并、分片检查点、翻译、显示与导出。已完成的分片可以在重新运行任务时续做。

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
- 无自动发现、TLS 配对或后台服务安装。Mac 转写时必须保持运行，手机需保持与 Mac 连通。分片中断后可从已完成的四分钟检查点续做，但未完成分片会重新上传。
- Mac 同时只处理一个分片，上传大小限制为 32 MiB。首次调用会下载约 GB 级的 MLX 模型；请预留磁盘空间。Mac 只保留转写期间的临时音频，返回结果后删除。
- 当前没有实测 iPhone 13 与不同 Apple Silicon Mac 的端到端耗时。传输、Mac 型号和 Wi-Fi 速度会影响收益。翻译服务仍按手机原有设置运行。

## 后续迭代

先用同一部两小时视频测量首条原文时间、总时长、准确率、发热和电量，再决定是否加入 Bonjour 自动发现、TLS 配对、分片内续传和后台驻留。TLS 配对完成前，不宜在共享网络中使用该服务。
