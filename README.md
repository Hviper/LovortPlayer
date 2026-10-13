# 📱 LovortPlayer (iPhone 私人视频播放器)

> 极致沉浸、黑灰微质感（Lovort 风格）、隐私保护、无损剪辑、局域网直传与 AI 双语字幕。

---

## 📌 当前开发进度仪表盘 (Progress Dashboard)

| 模块 | 功能项 | 当前状态 | 对应核心代码 | 详细说明 |
|---|---|:---:|---|---|
| **核心播放** | 硬件加速解码播放 | ✅ 已完成 | `Core/Player/PlayerViewModel.swift`<br>`Views/Player/NativeVideoPlayerView.swift` | 基于 AVFoundation 原生硬件解码，零卡顿低功耗 |
| **Lovort 交互** | 极简深色全屏手势 | ✅ 已完成 | `Views/Player/FullscreenVideoPlayerView.swift` | 左右滑屏调亮度/音量，双击快进快退，自动淡出悬浮控制 |
| **隐私保险箱** | Face ID + AES-GCM | ✅ 已完成 | `Core/Vault/VaultManager.swift` | 媒体库标题长按 1.2s 触发生物识别，解密隐藏视频沙盒 |
| **无损剪辑** | GOP Passthrough 剪裁 | ✅ 已完成 | `Core/Clip/LosslessClipManager.swift`<br>`Views/Player/InPlayerClipBar.swift` | 播放内标记 In/Out 毫秒点，秒级无损码流复制导出 |
| **局域网直传** | HTTP Server + 网页前端 | ✅ 已完成 | `Core/LANServer/`<br>`Views/Components/LANUploadSheet.swift` | 手机内嵌 Web Server，PC 浏览器拖拽即可上传大视频 |
| **媒体库** | 16:9 卡片瀑布流 | ✅ 已完成 | `Views/Main/MediaLibraryHomeView.swift`<br>`Views/Main/VideoCardView.swift` | 封面卡片流、时长/分辨率标签、分类 Tabs |
| **AI 字幕引擎** | 离线转写 + 分批翻译 | ✅ 已完成 | `Core/AISubtitle/LocalWhisperSubtitleService.swift`<br>`Core/AISubtitle/CloudAISubtitleService.swift` | WhisperKit 设备端转写、VAD 与时间戳；GPT 分批结构化翻译；双语 JSON/SRT 缓存 |
| **认证授权** | Keychain + OAuth PKCE | 🟡 基础框架完成 | `Core/Auth/AuthManager.swift` | Keychain 安全存取已就绪，待对接 Antigravity/ChatGPT 登录端点 |
| **CI / CD** | GitHub Actions 自动打包 | ✅ 已完成 | `.github/workflows/build-ipa.yml` | 提交代码自动触发云端 macOS 构建并发布到 Releases |

---

## 📂 项目工程目录说明

```text
├── App/                      # iOS 应用程序主入口 (LovortPlayerApp, Info.plist)
├── Core/                     # 核心业务逻辑与数据处理 (Swift Concurrency)
│   ├── AISubtitle/           # AI 语音识别 (Whisper) 与大模型双语翻译流水线
│   ├── Auth/                 # Keychain 密钥管理与 OAuth 2.0 PKCE 认证
│   ├── Clip/                 # AVAssetExportSession GOP 无损码流剪辑
│   ├── LANServer/            # 内嵌 HTTP Server (Network.framework) 与 Web 前端
│   ├── Models/               # 视频元数据与双语字幕实体模型
│   ├── Player/               # 播放器状态机与手势数据驱动
│   └── Vault/                # CryptoKit (AES-GCM) 与 Face ID 隐私加密保险箱
├── Views/                    # SwiftUI 页面与交互组件 (Lovort 风格)
│   ├── Components/           # 局域网直传抽屉等通用浮层
│   ├── Main/                 # 媒体库主页瀑布流、视频卡片
│   └── Player/               # 全屏手势播放器、AI 字幕渲染、无损剪辑工具条
├── docs/                     # 完整项目文档与规范
│   ├── PRD.md                # 产品需求文档 (PRD v0.2)
│   ├── UI_Design_Spec.md     # Lovort 风格 UI/UX 设计规范与手势系统
│   └── Interactive_Prototype.html # 交互式高保真 iPhone 原型 (浏览器直接运行)
├── .agents/skills/           # 项目级别定制开发 Skill 集合
├── .github/workflows/        # CI/CD 自动化流水线 (云端构建 iOS IPA)
├── project.yml               # XcodeGen 工程规范配置
└── Package.swift             # SPM 依赖管理与模块化定义
```

---

## 🛠️ 下一步开发计划 (Next Steps)

1. **真实影片回归集**：用日语动漫、英语美剧和多人对白样本持续评估字错率、时间轴和翻译一致性。
2. **多格式解码增强**：集成 FFmpeg 软解模块，扩充对高规格原生 MKV / FLAC 音轨的原生播放支持。
3. **局域网分片续传**：优化 `LANServerManager.swift` 中超大文件（如 4K 10GB+）的断点续传机制。

---

## 💻 换电脑继续开发指南 (How to Continue on Another Mac)

当你回到家在另一台电脑上时，直接执行：
```bash
git clone https://github.com/Hviper/LovortPlayer.git
cd LovortPlayer
```
- **查看交互效果**：直接双击 `docs/Interactive_Prototype.html` 在浏览器中即可体验高保真完整原型。
- **本地编译验证**：需要完整 Xcode（WhisperKit 使用 Core ML）；运行 `xcodegen generate` 后用 Xcode 或 `xcodebuild` 构建。
- **生成 Xcode 工程**：如果有安装 Xcode，运行 `brew install xcodegen && xcodegen generate` 即可生成 `LovortPlayer.xcodeproj`。
- **发布更新**：直接 `git push`，云端 GitHub Actions 会自动打包出最新的 `.ipa` 安装包并更新到 Releases。

## 🎬 离线字幕工作方式

1. 在播放器的“AI 字幕选项”中选择“离线 WhisperKit”。
2. 首次选择模型时需要联网下载 Core ML 模型；下载完成后，音频提取和原文转写无需联网。
3. “高精度”模型适合日语动漫和影视；旧设备可选择 Small 或 Base 降低内存占用。
4. 若已登录 ChatGPT 或填写 OpenAI API Key，转写后会联网分批翻译；没有凭据时仍会保存可离线观看的原文字幕。
5. 双语结果同时写入 `.lovort-subtitles.json`（保留原文/译文结构）和标准 `.srt`。云端 Whisper 选项会自动按 4 分钟切片，规避 25 MB 单文件限制。
