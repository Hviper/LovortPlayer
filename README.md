# 📱 LovortPlayer (iPhone 私人视频播放器)

> 极致沉浸、黑灰微质感（Lovort 风格）、隐私保护、无损剪辑、局域网直传与 AI 双语字幕。

---

## 📌 当前开发进度仪表盘 (Progress Dashboard)

| 模块 | 功能项 | 当前状态 | 对应核心代码 | 详细说明 |
|---|---|:---:|---|---|
| **核心播放** | 原生优先 + FFmpeg 兼容回退 | ✅ 已完成 | `Core/Player/PlayerViewModel.swift`<br>`Views/Player/NativeVideoPlayerView.swift` | MP4/MOV 走 AVFoundation；MKV/AVI/WebM 等由 KSPlayer 自动回退 FFmpeg |
| **Lovort 交互** | 极简深色全屏手势 | ✅ 已完成 | `Views/Player/FullscreenVideoPlayerView.swift` | 左右滑屏调亮度/音量，双击快进快退，自动淡出悬浮控制 |
| **隐私保险箱** | Face ID + AES-GCM | ✅ 已完成 | `Core/Vault/VaultManager.swift` | 媒体库标题长按 1.2s 触发生物识别，解密隐藏视频沙盒 |
| **无损剪辑** | GOP Passthrough 剪裁 | ✅ 已完成 | `Core/Clip/LosslessClipManager.swift`<br>`Views/Player/InPlayerClipBar.swift` | 播放内标记 In/Out 毫秒点，秒级无损码流复制导出 |
| **局域网直传** | 流式 HTTP Server + 网页前端 | ✅ 已完成 | `Core/LANServer/`<br>`Views/Components/LANUploadSheet.swift` | 一次性口令、流式落盘、空间/格式校验、自动入库，避免大文件驻留内存 |
| **媒体库** | 16:9 卡片瀑布流 | ✅ 已完成 | `Views/Main/MediaLibraryHomeView.swift`<br>`Views/Main/VideoCardView.swift` | 封面卡片流、时长/分辨率标签、分类 Tabs |
| **AI 字幕引擎** | 渐进式离线转写 + 多翻译服务 | ✅ 已完成 | `Core/AISubtitle/LocalWhisperSubtitleService.swift`<br>`Core/AISubtitle/SubtitleTranslationProvider.swift` | 播放点优先的 4 分钟分片、断点缓存；Apple/DeepL/Google/Azure/GPT 翻译；双语 JSON/SRT |
| **视频导出** | 分享 / 相册 / 文件 | ✅ 已完成 | `Core/Export/VideoExportManager.swift` | 系统分享面板、保存到系统相册、导出到“文件”App |
| **GPT 语境精修** | 可选字幕导演模式 | ✅ 已完成 | `Core/AISubtitle/CloudAISubtitleService.swift` | 在普通翻译后统一人物称谓、敬语、俚语和角色口吻；需要 OpenAI Platform API Key |
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
2. **真实设备性能测试**：评估高码率 MKV 的耗电、发热与后台内存峰值。
3. **局域网断点续传**：在现有流式落盘基础上加入可恢复的分片协议。

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
4. 翻译可选择 Apple 设备端语言包、DeepL、Google、Azure 或 GPT；没有网络凭据时仍会保存原文字幕。
5. ChatGPT Plus/Pro 订阅不等同于 OpenAI API 额度。GPT 翻译、语境精修和云端转写需要有效的 OpenAI Platform API Key。

### 全局离线字幕工作流

- 可在“设置 → 离线字幕与模型”提前下载、选择或删除 WhisperKit 模型，并查看真实下载进度与存储占用。
- 视频卡片菜单可直接创建双语字幕任务，无需先进入播放器。
- 字幕任务由 App 级串行队列管理；离开播放器后继续执行，每个 4 分钟分片完成后立即保存，异常退出后可从检查点恢复。
- 首页任务胶囊与“字幕任务”页面分别展示原文转写和中文翻译进度，支持暂停、继续、取消和失败重试。
- 正在观看的视频会即时接入已生成分片；完成后保存原文、中文、双语 SRT，并提供 App 内提示与可选系统通知。
6. 长视频按 4 分钟分片，优先处理当前播放点附近；每片完成立即显示并写入断点缓存。双语结果写入 `.lovort-subtitles.json` 和标准 `.srt`。
