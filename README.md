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
| **AI 字幕引擎** | 渐进式离线转写 + 多翻译服务 | ✅ 已完成 | `Core/AISubtitle/LocalWhisperSubtitleService.swift`<br>`Core/AISubtitle/SubtitleTranslationProvider.swift` | 播放点优先的 4 分钟分片、断点缓存；Apple/火山机器翻译/智谱/火山方舟/自定义 API/DeepL/Google/Azure/GPT 翻译；双语 JSON/SRT |
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
- 字幕任务由 App 级串行队列管理；离开播放器后继续执行，首片先处理 20 秒，后续按 4 分钟分片续做；原文和翻译分批保存，异常退出后可从检查点恢复。
- 首页任务胶囊与“字幕任务”页面分别展示原文转写和中文翻译进度，支持暂停、继续、取消和失败重试。
- 正在观看的视频会即时接入已生成分片；完成后保存原文、中文、双语 SRT，并提供 App 内提示与可选系统通知。
6. 长视频按 4 分钟分片，优先处理当前播放点附近；每片完成立即显示并写入断点缓存。双语结果写入 `.lovort-subtitles.json` 和标准 `.srt`。

### 导出带字幕视频

在播放器分享菜单、视频卡片的菜单或长按菜单中选择“导出带字幕视频”：

- **内嵌字幕（可开关）**：将原文、译文或双语字幕写入新 MP4 的 `tx3g` 字幕轨道，直接复用音视频编码。接收方需要支持字幕轨道；建议通过“文件”或 AirDrop 传原文件，聊天应用转码可能丢失字幕。
- **烧录字幕（固定在画面）**：重新编码为字幕直接出现在画面中的 MP4，适合分享观看；字幕不能关闭。

译文缺失时保留原文。导出保留原视频，提供进度和取消；字幕未生成完时会说明只导出当前已完成部分。导出文件在分享/保存期间保留，关闭页面或重新导出后清理；应用中断遗留的临时文件会在一天后清理。系统无法解码或写入 MP4 的格式会显示错误。

播放字幕按视频实际显示区域定位，自动适配横竖屏及刘海/底部安全区；控制栏显示时避开控制栏。导出字幕按短边计算字号，避免竖屏字号过大。

### 体验与可靠性

- 首页支持搜索、排序和继续观看；媒体 ID 在文件移动后保留，避免同名视频共用播放进度。
- 原文转写与翻译可并行推进。翻译失败保留原文和成功译文，重试复用已有转写；取消任务会拒绝旧任务继续写入。
- 字幕内容、字号、位置记住上次设置，时间偏移和原文语言按视频保存。分享菜单明确区分原视频与带字幕导出。
- 同名导入保留两份，先完成临时副本再提交。移动到私密空间前暂停字幕任务，将支持的旁字幕一起加密。
- 保险箱首次使用需设置 6–12 位密码，没有默认密码。已有保险箱首次设置新密码需设备身份验证；进入后台遮挡画面并锁定。新加密格式分块处理大视频，兼容旧密文读取。
- 清理缓存仅删除缩略图和过期导出，不移除播放、字幕处理、模型下载或分享正在使用的文件。

### 性能诊断与验证

“设置 → 字幕性能诊断”记录模型加载、转写和翻译的实际耗时及内存采样，可导出诊断 JSON。播放器的短片预览支持比较同一片段的模型/工作数；发热严重时降低工作数。工作数并非线性加速保证，iPhone 13 的最佳组合应以真机比较结果为准；已有高精度模型选择保持不变。

XcodeGen 将 Core 编译为独立框架，App 引用该模块。GitHub Actions 先运行 iOS 模拟器 XCTest，再构建设备 Release IPA；版本 build 使用工作流运行编号。完整验证命令：

```sh
xcodegen generate
xcodebuild test -project LovortPlayer.xcodeproj -scheme LovortPlayer -destination 'platform=iOS Simulator,name=iPhone 16' CODE_SIGNING_ALLOWED=NO SWIFT_ENABLE_EXPLICIT_MODULES=NO
```

模型下载完成后，离线转写无需网络；第三方翻译和 GPT 精修需要网络，Apple 翻译需已安装对应语言包。iOS 对后台运行时长有限制，长任务建议保持 App 前台，暂停后可从检查点继续。
