# 字幕翻译 API

在「设置 → 字幕与离线模型 → 翻译 API 管理」选择服务并保存配置。

- 默认使用 Apple 设备端翻译；所选第三方的对应凭证为空时仍使用 Apple。AK / SK 模式下仅填一项会提示配置不完整。
- 智谱：官方地址已内置，填写单个 API Key 即可使用默认模型 `glm-4-flash-250414`，可展开模型设置修改。智谱不使用 AK / SK。
- 火山方舟 API Key 模式：官方地址已内置，默认模型为 `doubao-seed-2-0-mini-260428`，也可修改为账号已开通的模型 ID。
- 火山方舟 AK / SK 模式：填写 Access Key ID、Secret Access Key 和接入点 ID（`ep-` 开头）。应用按官方签名算法调用 `GetApiKey`，换取有效期一天、仅绑定该接入点的临时 API Key，再执行字幕翻译。临时 Key 仅存于当前任务内存。
- 自定义服务：填写 HTTPS 基础地址或完整 `/chat/completions` 地址、API Key 和模型 ID，接口需兼容 OpenAI Chat Completions 协议。
- Key 保存在设备钥匙串。只有使用第三方翻译时字幕文本才发送到配置的地址。
- 第三方请求失败、超时、返回缺失或空译文时保留原字幕，不自动发送给另一家第三方服务。
- 转写完成后原字幕立即可播放；翻译失败后在字幕任务中心重试会复用原转写结果。
- 更改自定义 URL、模型或火山鉴权方式后，再次生成会重新翻译；每次任务使用固定配置快照，避免将旧任务的译文标记为新配置。

## Apple 翻译排查

旧实现从排队起统一等待最多 600 秒，包括语言包准备与全部批次；翻译会话仅挂载在媒体库首页。新实现分别处理会话启动（30 秒）、语言包准备（600 秒）和单批翻译（120 秒），批次推进会刷新翻译计时器。自动检测源语言时跳过无文本的 `prepareTranslation()`，首批允许 600 秒用于识别与下载；后续批次仍为 120 秒。首页和全屏播放器分别承载对应场景的翻译会话，同一请求只执行一次。

日志分类为 `com.hviper.lovortplayer / AppleTranslation`，记录排队、会话开始、语言包准备耗时、每批耗时和超时阶段，不记录字幕或密钥。

真机验收：

1. 不配置第三方 API，打开视频全屏播放，预览或生成字幕；首次使用时确认系统语言包下载，查看原字幕在译文之前出现。
2. 重复生成或预览相同语言，确认翻译再次启动；取消后重试，确认不再提示上一批仍在处理。
3. 保持前台完成翻译，再切换回媒体库运行字幕任务，确认两处会话都能工作。
4. 配置第三方 API 后生成字幕；再用无效 Key 验证失败后仍显示原字幕，清空 Key 保存后验证回到系统翻译。
5. 修改 URL 或模型后重试，确认调用新配置，并复用原转写结果。

本机验证：翻译核心源代码在 Swift 6 下独立编译，11 个回归场景通过（包含与火山官方 SDK 一致的签名测试向量、模拟 AK / SK 换取临时 Key 后翻译的完整链路）（仓库 `Tests/TranslationAPITests.swift`；由于本机没有 XCTest，将同一测试方法放入独立可执行程序运行断言）。完整工程的 macOS `swift test` 被现有 UIKit 引用及其他 Swift 6 并发问题阻断。本机没有完整 Xcode 和 iOS 模拟器，尚未进行 iOS UI、Apple 语言包下载或真实第三方付费 API 验证。

参考：[Apple translationTask](https://developer.apple.com/documentation/swiftui/view/translationtask(_:action:))、[Apple prepareTranslation](https://developer.apple.com/documentation/translation/translationsession/preparetranslation())、[火山方舟 Base URL 与鉴权](https://docs.volcengine.com/docs/ark/base-url-and-authentication?lang=en)。全屏承载调整来自本项目的视图生命周期风险分析，仍需真机验证。

凭证文档：[智谱 API 鉴权](https://docs.bigmodel.cn/cn/api/introduction)、[火山方舟鉴权](https://docs.volcengine.com/docs/ark/base-url-and-authentication?lang=en)、[GetApiKey](https://docs.volcengine.com/docs/ark/get-api-key-api?lang=zh)、[火山官方签名 SDK](https://github.com/volcengine/volcengine-python-sdk/blob/master/volcenginesdkcore/signv4.py)。

## 连接测试

翻译 API 管理与播放器的 GPT 模型选择区提供“测试连接”。使用当前输入的凭证、地址、鉴权方式与模型翻译固定短句 `Hello.`，不保存草稿、不切换服务、不读取视频或更新字幕缓存。配置为空会明确失败，测试不回退系统翻译。GPT 使用真实字幕翻译的 Responses 接口及代理设置，只测试当前选中的模型，不通过备用模型掩盖错误。

成功显示耗时及模型，失败提示鉴权、模型/地址、额度、网络或格式问题；不显示服务返回的原始错误正文。修改草稿、取消测试或离开页面会取消请求并丢弃旧结果。测试请求使用 30 秒请求/45 秒资源超时，火山 AK/SK 的换取临时凭证与翻译分别发出请求。真实 API 测试可能产生少量调用费用。

连接测试新增 4 个回归场景：指定 GPT 模型、不可用模型不得回退、空凭证/空结果与错误隐私、自定义草稿请求不落盘。
