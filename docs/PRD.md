# 📱 iPhone 视频播放器 — 产品需求文档（PRD）

> 版本 v0.2 · 2026-10-12 · 已确认关键决策

## 已确认决策

| 问题 | 决策 |
|---|---|
| 后端 | ✅ 纯本地，无服务器 |
| AI 字幕 | ✅ 可选开启，需配置 API Key 或 OAuth 登录 |
| OAuth 目的 | ✅ 解锁 AI 配额（ChatGPT / Antigravity） |
| iOS 版本 | ✅ iOS 25+ |
| 发布方式 | ✅ 个人本地使用，无需上架 App Store |
| Lovort 参考 | ✅ UI 风格 + 交互逻辑 均参考 |

---

## 一、产品概述

一款面向 iPhone 用户的**私人视频播放器**，设计风格参考 [Lovort](https://lovort.com)，主打隐私保护、无损剪辑、AI 字幕生成与局域网传输四大核心功能。

---

## 二、核心功能模块

### 2.1 🎬 视频播放器（核心播放能力）

| 功能点 | 描述 |
|---|---|
| 多格式支持 | MP4 / MKV / AVI / MOV 等主流格式 |
| 硬件解码 | 使用 VideoToolbox 硬解，低功耗高性能 |
| 手势控制 | 左右滑动进度 / 上下滑动音量亮度 |
| 后台播放 | 锁屏/后台继续播放，支持 AirPlay |
| 播放历史 | 记录上次播放位置，下次自动续播 |
| 播放列表 | 支持文件夹分组、自动连播 |

**UI 风格参考（Lovort）：**
- 深色极简风，毛玻璃卡片
- 封面缩略图自动提取
- 底部控制栏浮动于视频之上，手势触发显示/隐藏

---

### 2.2 🔒 隐私文件保险箱（Hidden Videos）

| 功能点 | 描述 |
|---|---|
| 隐藏模式入口 | 摇晃手机 / 特定手势 / 密码解锁进入隐藏空间 |
| 文件加密 | AES-256 加密存储，不被系统相册/文件 App 索引 |
| 假密码/诱导模式 | 输入假密码进入一个空的"干净"空间（反侦察） |
| Face ID / Touch ID | 生物识别解锁隐藏空间 |
| 截屏防护 | 进入隐藏空间时自动屏蔽截屏 |

---

### 2.3 ✂️ 无损视频剪辑（Lossless Clip）

| 功能点 | 描述 |
|---|---|
| 精彩片段标记 | 播放时一键打 In/Out 点 |
| 帧级精确裁切 | 精度到帧，不重编码，纯 GOP 切割保证无损 |
| 批量导出 | 多段同时导出，支持后台任务 |
| 导出格式 | 保留原始编码，不重压 |
| 预览对比 | 剪辑前可在时间轴上预览片段 |

> **技术选型**：iOS 使用 `AVAssetExportSession` + `AVAssetWriter` 实现无损 GOP 切割；或调用 `ffmpeg` 静态库（`FFmpegKit`）做帧精确裁切。

---

### 2.4 📡 局域网传输（LAN Upload）

| 功能点 | 描述 |
|---|---|
| WebDAV / HTTP 服务器 | App 内启动本地 HTTP Server，PC 浏览器直接拖拽上传 |
| 二维码快捷连接 | 显示本机 IP 二维码，手机扫码直接跳转上传页 |
| 多文件并发上传 | 支持断点续传 |
| Bonjour 发现 | 局域网内自动广播服务，AirDrop 级体验 |
| 进度显示 | 实时显示每个文件传输速度和进度 |

> **技术选型**：[GCDWebServer](https://github.com/swisspol/GCDWebServer) 或 [Swifter](https://github.com/httpswift/swifter) 作为内嵌 HTTP 服务；前端上传页面内嵌 HTML/JS。

---

### 2.5 🤖 AI 字幕生成（AI Subtitles）

参考项目：[earendil-works/pi-coding-agent](https://github.com/earendil-works/pi-coding-agent)

| 功能点 | 描述 |
|---|---|
| 自动语言识别 | 自动检测音轨语言（日语/英语/韩语/法语等） |
| 语音转文字 | 基于 Whisper 模型（本地 / 云端可选） |
| 多语言翻译 | 识别结果自动翻译为中文（或用户指定语言） |
| 双语字幕 | 支持原文 + 中文双行字幕同步显示 |
| 字幕导出 | 导出为 `.srt` / `.ass` 文件 |
| 字幕样式编辑 | 字号、颜色、位置可自定义 |
| 本地 / 云端切换 | 本地用 WhisperKit（on-device），云端用 OpenAI Whisper API |

**AI 字幕架构：**

```
音频提取（AVFoundation）
    ↓
语音识别（WhisperKit on-device / OpenAI Whisper API）
    ↓
时间戳对齐 → SRT/ASS 生成
    ↓
翻译（本地 Apple Translation / OpenAI GPT API）
    ↓
字幕渲染叠加（AVPlayerLayer + CATextLayer）
```

---

### 2.6 🔑 身份认证（Auth）

> 认证仅用于**解锁 AI 字幕功能**，本地播放/剪辑/传输无需登录。

#### OAuth 登录（使用第三方 AI 配额）

| 提供商 | 用途 |
|---|---|
| **ChatGPT（OpenAI）** | 使用用户自己的 OpenAI 账户额度 |
| **Antigravity** | 使用 Antigravity AI 配额 |

- 使用 OAuth 2.0 + PKCE 流程（ASWebAuthenticationSession）
- Token 本地加密存储（Keychain），无服务器转发

#### API Key 模式（高级用户）

- 手动输入 OpenAI API Key / 自定义 Base URL
- 支持兼容接口：DeepSeek、Qwen、本地 Ollama 等
- Key 存储在 iOS Keychain，绝不明文落盘

#### AI 功能解锁逻辑

```
用户首次使用 AI 字幕
    ↓
弹出引导页 → 选择：
    ├── OAuth 登录 ChatGPT / Antigravity
    └── 手动输入 API Key + Base URL
          ↓
验证成功 → 解锁 AI 字幕功能
AI 字幕开关在「设置」中可随时开启/关闭
```

---

## 三、技术架构总览

```
┌──────────────────────────────────────────────────────┐
│                    iPhone App (本地)                  │
│                                                      │
│  ┌──────────┐  ┌─────────────┐  ┌────────────────┐  │
│  │  Player  │  │  Lossless   │  │   LAN Server   │  │
│  │ AVKit/   │  │  Clip       │  │ GCDWebServer   │  │
│  │ FFmpegKit│  │ (FFmpegKit) │  │ + Bonjour      │  │
│  └──────────┘  └─────────────┘  └────────────────┘  │
│                                                      │
│  ┌───────────────────────────────────────────────┐   │
│  │           AI 字幕引擎（可选开启）               │   │
│  │                                               │   │
│  │  音频提取 → WhisperKit(本地) / Whisper API    │   │
│  │          → 时间戳对齐 → SRT 生成              │   │
│  │          → 翻译（GPT / Apple Translation）   │   │
│  │          → 字幕叠加渲染                       │   │
│  └───────────────────────────────────────────────┘   │
│                                                      │
│  ┌────────────────┐  ┌──────────────────────────┐   │
│  │  隐私保险箱     │  │  Auth（AI 解锁）          │   │
│  │  AES-GCM 加密  │  │  OAuth / API Key         │   │
│  │  Face ID 解锁  │  │  Keychain 存储            │   │
│  └────────────────┘  └──────────────────────────┘   │
└──────────────────────────────────────────────────────┘
              ↕（仅 AI 字幕功能需要网络）
┌──────────────────────────────────────────────────────┐
│   ChatGPT API / Antigravity API / 自定义 Endpoint    │
└──────────────────────────────────────────────────────┘
```

---

## 四、开发技术栈

| 层 | 技术 | 说明 |
|---|---|---|
| UI 框架 | **SwiftUI** | iOS 25+ 全面拥抱 SwiftUI |
| 播放引擎 | AVFoundation + AVKit | 原生硬解，低功耗 |
| 视频剪辑 | **FFmpegKit** | 帧级 GOP 无损裁切 |
| 局域网服务 | **GCDWebServer** / Swifter | 内嵌 HTTP + Bonjour |
| AI 字幕（本地） | **WhisperKit** | on-device，离线可用 |
| AI 字幕（云端） | OpenAI Whisper API | 速度快，需 API Key |
| 翻译 | Apple Translation Framework | iOS 17+ 原生，离线 |
| 文件加密 | **CryptoKit** AES-GCM | 苹果原生加密库 |
| 认证 | **ASWebAuthenticationSession** | OAuth PKCE 流程 |
| 安全存储 | **Keychain** | API Key / Token 存储 |
| 状态管理 | Swift Concurrency (async/await) | iOS 25 原生并发 |
| 数据持久化 | **SwiftData** | iOS 17+ 新一代 ORM |



---

## 五、MVP 功能范围建议

> [!TIP]
> 纯本地个人使用，建议分两个阶段迭代：先跑通核心播放体验，再叠加 AI 能力。

### Phase 1 — 核心播放器（2-4 周）
- [x] 多格式视频播放（AVKit）
- [x] Lovort 风格 UI（深色 / 毛玻璃 / 手势控制）
- [x] 局域网传输（HTTP 上传）
- [x] 隐私保险箱（Face ID + AES 加密）

### Phase 2 — 进阶功能（4-6 周）
- [x] 无损视频剪辑（FFmpegKit）
- [x] AI 字幕生成（WhisperKit 本地 + API 云端）
- [x] OAuth 登录（ChatGPT / Antigravity）
- [x] API Key 配置与管理

---

## 六、下一步计划

- [x] ✅ 确认关键决策
- [ ] 🎨 绘制 UI 线框图 / 参考 Lovort 交互设计
- [ ] 🏗️ 搭建 Xcode 项目骨架（SwiftUI + 模块化结构）
- [ ] 📦 Phase 1 逐模块开发
- [ ] 🤖 Phase 2 AI 字幕集成
