# 局域网 Mac 字幕服务

本文档说明 LovortPlayer 的局域网 Mac 字幕转写服务体系，包含**原生 macOS GUI 应用（推荐）**与**终端 CLI 模式（降级/无头模式）**两种运行方式，二者在底层存储、鉴权口令与 iOS 客户端 API 上保持 100% 互通兼容。

---

## 一、系统架构与运行机制

- **推理后端**：在 Apple Silicon Mac 本机运行 Python 服务，利用 Apple Silicon Metal 统一内存与 `mlx-whisper`（默认模型 `mlx-community/whisper-large-v3-turbo`）进行高速离线转写。
- **iOS 配合**：iPhone 在“设置 → 离线字幕与模型 → 局域网 Mac 字幕服务”中填写 Mac 局域网地址（如 `192.168.1.100:8765`）与访问口令。测试连接成功后，在视频播放界面的“AI 字幕选项”中选择“局域网 Mac 转写”。
- **任务持久化机制**：
  - 手机仅需将所选音轨上传至 Mac（单任务上限 512 MiB）。
  - Mac 接收完成后立即创建持久化任务记录，按 4 分钟切片在本机后台持续推理。
  - 界面提示“Mac 已接收音轨”后，iPhone 可自由锁屏或退出 App。
  - 手机再次打开或返回前台时，会凭原任务 ID 自动领取已转写完成的字幕片段，无缝衔接翻译、渲染与导出。
  - 转写记录保存于 `~/.local/share/lovort-mac-subtitles/jobs/`，默认保留 7 天。

---

## 二、原生 macOS GUI 应用：LovortMacSubtitleService（推荐）

为了免除常驻终端黑窗口、手动排查环境与复制口令的不便，项目提供了面向 macOS 15+ 的原生 SwiftUI 桌面管理应用 `LovortMacSubtitleService`。

### 1. 核心特性
- **状态感知**：清晰呈现五大核心服务状态——`未安装`、`已停止`、`启动中`、`运行中`、`异常`，并提供与状态精准对应的首要操作（一键配置、启动、停止、重试）。
- **一键环境安装**：
  - 自动检测 Apple Silicon 架构、Python 3 解释器、ffmpeg 与 ffprobe。
  - 遵循安全原则，**绝不私自静默安装 Homebrew**；若检测到缺失工具，会提供确切的安装指令说明（如 `brew install ffmpeg`）。
  - 满足基础工具后，可一键在 `~/Library/Application Support/LovortMacSubtitleService/venv` 中自动创建独立 Python 虚拟环境并安装 `mlx-whisper` 运行依赖。
- **无终端启停**：通过安全隔离的 `Process.executableURL` 与参数数组启动或停止服务，不拼接也不执行 shell 命令字符串。
- **局域网连接与安全口令**：
  - 自动检索本机当前活动局域网 IPv4 地址与端口（默认 `8765`），提供一键复制 `IP:8765`（适合 iPhone 填写）及完整 HTTP URL。
  - 访问口令默认以圆点掩码显示，支持显式眼睛按钮切换可见，支持一键安全复制到剪贴板。
- **持久化任务监视器**：
  - 自动监控 `~/.local/share/lovort-mac-subtitles/jobs/*.json`。
  - 页面处于前台时实时轮询，直观显示任务 UUID、转写状态、片段进度（如 `3 / 5 片段`）、百分比进度条、提取字幕条数、错误原因与最后更新时间。
  - 提供“在访达中显示”快捷操作，方便查看原始音轨与切片元数据。
- **静默日志查看器**：
  - 实时捕获子进程 stdout 与 stderr，具备精确到秒的时间戳。
  - **严格脱敏保证**：内置敏感信息过滤器，自动脱敏口令行（如 `Access token: [已隐藏口令 / REDACTED]`）、HTTP 鉴权头与 JSON 口令字段，避免口令泄露到屏幕或复制导出的日志文本中。
  - 采用有界内存队列（上限 1500 行），防止长时间运行导致内存膨胀。提供过滤搜索、清空、复制全部与自动滚动控制。
- **菜单栏组件 (MenuBarExtra)**：
  - 常驻顶部菜单栏，小图标实时反映服务状态。
  - 菜单包含：状态与地址展示、显示主窗口、启动/停止切换、“打开 App 时自动启动服务”偏好开关、彻底退出应用。
- **开机/启动偏好设置**：
  - 支持设置“打开 App 时自动启动服务”，方便日常随开随用。

### 2. 首次使用流程
1. 在 Xcode 中切换至 `LovortMacSubtitleService` Scheme 并编译运行。
2. 打开应用后，若界面提示“未安装”，切换至“环境配置”标签：
   - 确认硬件为 Apple Silicon（M1/M2/M3/M4 系列）。
   - 若提示缺少 `ffmpeg`，打开终端执行 `brew install ffmpeg`，安装完成后点击应用内的“重新检测”。
   - 点击“一键配置虚拟环境与依赖”，等待依赖构建完成（约 1~2 分钟）。
3. 环境就绪后，点击“启动服务”。
4. 在“概览”标签复制“iPhone 连接地址”与“访问口令”。
5. 打开 iPhone 上的 LovortPlayer，进入“设置 → 离线字幕与模型 → 局域网 Mac 字幕服务”，粘贴地址与口令，点击“测试连接”。

### 3. 从项目生成 macOS Scheme

项目使用 XcodeGen 维护 Xcode 工程配置。首次构建前，在仓库根目录执行 `xcodegen generate`，然后在 Xcode 中打开生成的 `LovortPlayer.xcodeproj`，选择 `LovortMacSubtitleService` Scheme 运行。没有 XcodeGen 时，安装后再执行同一命令：

```bash
brew install xcodegen
```

GUI 目标只把 `server.py`、`jobs.py` 与 `requirements.txt` 作为资源打包；虚拟环境、模型缓存、任务音频和口令始终保存在用户目录。

---

## 三、终端 CLI 模式（降级/无头模式）

若在无显示器的 Mac mini、远程 SSH 终端或不需要 GUI 的场景下，可继续使用原有的命令行方式运行：

### 1. 安装与启动
```bash
# 1. 安装系统依赖
brew install ffmpeg

# 2. 进入服务脚本目录
cd MacSubtitleService

# 3. 创建独立虚拟环境并安装依赖
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt

# 4. 启动服务（默认监听 0.0.0.0:8765）
.venv/bin/python server.py
```

### 2. 参数说明
```bash
.venv/bin/python server.py \
  --host 0.0.0.0 \
  --port 8765 \
  --token-file ~/.config/lovort-mac-subtitles/token \
  --jobs-dir ~/.local/share/lovort-mac-subtitles/jobs
```
- 启动终端将输出访问口令。按 `Ctrl-C` 优雅停止服务。

---

## 四、可选 Docker Compose 网关入口

若需要将 Mac 服务接入容器化网络入口层（如统一反向代理），可保持原生转写服务运行的同时执行：

```bash
cd MacSubtitleService
docker compose up -d
```

- Compose 将启动 Nginx 网关，监听宿主机的 `8766` 端口，并将请求反向代理到原生服务的 `8765` 端口。
- 此时手机填写 `Mac局域网IP:8766`，访问口令保持不变。
- 停止网关执行 `docker compose down`，不会中断正在转写的原生 Python 进程。
- **注意**：Docker Desktop 的 Linux 容器无法直接调用 macOS Metal/MLX，因此推理核心仍必须作为原生进程在 macOS 宿主机上运行。

---

## 五、持久化路径规范

- 首版使用局域网 HTTP，音频和口令没有传输加密。仅在可信家庭网络使用；iOS 只接受私网 IP、`.local` 或 localhost 地址。私密视频被禁止发送到 Mac。
- 无自动发现、TLS 配对或后台服务安装。Mac 转写时必须保持运行；手机上传完成后可以断开连接，返回前台时再领取结果。Mac 保存每个已完成的四分钟片段与任务进度；服务重启后可续做未完成片段。
- Mac 同时只运行一个推理任务，完整音轨上传限制为 512 MiB。首次调用会下载约 GB 级的 MLX 模型；请预留磁盘空间。Mac 完成或失败后删除上传的音频，任务结果保留七天供手机重新领取。
- 手机本机 Whisper 转写在锁屏时提交系统后台处理请求；系统授予后台时间后继续处理，否则回到前台从已保存检查点继续。iOS 不保证长时间锁屏推理。私密视频任务进入后台后仍保持用户暂停状态，不会自动恢复。
- 当前没有实测 iPhone 13 与不同 Apple Silicon Mac 的端到端耗时。传输、Mac 型号和 Wi-Fi 速度会影响收益。翻译服务仍按手机原有设置运行。手机锁屏后，Mac 任务继续在 Mac 上运行；iOS 会在回到前台或获得系统后台处理时间后领取结果。
为确保 GUI 应用、CLI 模式与 iOS 客户端协议高度一致，所有数据统一遵守以下规范路径：

| 数据类型 | 规范存储路径 | 权限要求 | 说明 |
| :--- | :--- | :--- | :--- |
| **访问口令** | `~/.config/lovort-mac-subtitles/token` | `0600` (仅属主读写) | 服务首次启动时自动生成 32 字节 urlsafe 口令 |
| **持久任务** | `~/.local/share/lovort-mac-subtitles/jobs/` | `0700` (仅属主访问) | 存放各任务音频分片及 JSON 进度状态 |
| **GUI 虚拟环境** | `~/Library/Application Support/LovortMacSubtitleService/venv` | 用户可读写 | GUI 管理的独立 Python 运行环境 |
| **CLI 虚拟环境** | `MacSubtitleService/.venv` | 用户可读写 | 终端本地开发虚拟环境（GUI 会自动识别） |
| **模型缓存** | `~/.cache/huggingface/hub/` | 用户可读写 | MLX Whisper 模型首次使用时自动下载保存 |

---

## 六、常见问题与排查指南

### 1. iPhone 测试连接失败（超时或连接被拒绝）
- **同一局域网**：确认 iPhone 与 Mac 连接在同一路由器 Wi-Fi 下。部分路由器开启了“AP 隔离”或“访客网络”，会导致局域网设备间无法互访，请连接普通主网络。
- **macOS 防火墙**：前往 Mac“系统设置 → 网络 → 防火墙”，确保未开启“阻止所有入站连接”。若防火墙已开启，请将 Python 或相关服务加入“允许传入连接”列表。
- **IP 变动**：Mac 重启路由器后局域网 DHCP IP 可能变动。打开 GUI 应用“概览”页或在 Mac“系统设置 → 网络”中查看最新 IPv4 地址。

### 2. 状态提示“未检测到 ffmpeg / ffprobe”
- GUI 应用在 `/opt/homebrew/bin`、`/usr/local/bin`、`/usr/bin` 以及系统 `PATH` 中查找相关工具。
- 若尚未安装，请在终端执行：
  ```bash
  brew install ffmpeg
  ```
- 安装完成后，在 GUI 应用的“环境配置”页面点击“重新检测”即可。

### 3. 口令文件权限报错 (`Token file must be readable only by this user`)
- 服务要求口令文件严格保护。若曾手动修改过文件权限，可在终端修复：
  ```bash
  chmod 700 ~/.config/lovort-mac-subtitles
  chmod 600 ~/.config/lovort-mac-subtitles/token
  ```

### 4. 端口 8765 被占用
- 若端口被其他进程占用，可在 GUI 应用的“偏好设置”中修改“服务监听端口”（例如改为 `8780`）。修改后重新启动服务，并在 iPhone 设置中相应更新端口。

### 5. 首次转写耗时较长
- 首次转写特定语言或首次运行任务时，MLX 会从 Hugging Face 下载 `whisper-large-v3-turbo` 权重（约 1.6 GB），请保持 Mac 正常联网。下载完毕后后续转写均为纯离线 Metal 本地计算。

---

## 七、安全与使用边界

1. **局域网明文 HTTP**：当前版本使用局域网 HTTP 传输音频与口令，没有传输层加密。请仅在家庭或受信任的私有网络中使用；私密视频请在 iPhone 本机使用本地离线 Whisper 模型。
2. **并发限制**：为避免显存争抢与过热降频，Mac 同时仅处理一个任务音频片段，并发上传的任务会在持久化队列中顺序排队转写。
