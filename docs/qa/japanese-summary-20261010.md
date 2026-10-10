# 日语摘要与朗读验收（2026-10-10）

用户要求听到日语摘要，并覆盖 Gemini、豆包、Qwen、MiniMax。实现新增独立的摘要与朗读语言，选择「日本語」后生成日文摘要并使用兼容音色；实时通话语言可以继续保持中文。手机的 Reading language 可单独请求日文朗读文本，Mac 的语言偏好不随之改变。

基线为 `83220056c48b37c46121651e7e2d7249335bcc62`，本次验证工作区补丁。持久证据位于 `~/Projects/_shared-work/iOS-vibebuddy/japanese-summary-20261010/`。凭据只通过项目 `.envrc` 白名单注入实际验收子进程；构建与普通测试不加载凭据，未回写个人 Keychain。

## 服务商与实现选择

| 服务商 | 本次实际使用 | 日语接线 |
| --- | --- | --- |
| Gemini | `gemini-3.8-flash-lite-tts` / Kore | 原有多语言音色自动识别日文；无需另造日语 voice ID |
| Qwen | `qwen-audio-3.1-tts-flash` / `longanfengyue_v3.1` | 新增三个 3.1 多语言预设；自动绑定兼容模型，并发送 `language_hints: ["ja"]` |
| 豆包 | `seed-tts-2.0` / `zh_female_vv_uranus_bigtts` | 复用已支持日语的 2.0 音色；在 JSON 字符串 `additions` 内发送 `explicit_language: "ja"` |
| MiniMax | `speech-2.8-turbo` / `Japanese_CalmLady` | 新增六个日语系统音色，并发送 `language_boost: "Japanese"` |

Qwen 项目适配的是 Qwen-Audio 协议，不能把另一产品族 Qwen3-TTS 的音色直接塞入现有请求。豆包本次使用 2.0 多语言预设，没有混入 1.0 日语音色。已保存但不兼容日语的已知预设会选择日语默认项；自定义 voice ID 保留。Qwen 预设要求不同模型时，界面显示实际模型。

MiniMax 原本缺少项目环境白名单接线：本机 `.envrc` 已加入 `MINIMAX_API_KEY`，现有凭据可用。原生隔离运行的设置页与运行时也统一识别该变量；普通用户仍使用原有保存凭据方式。缺失环境变量不会在隔离验收中回退读取个人 MiniMax Keychain。

官方依据（本次已核对）：

- [Gemini speech generation](https://ai.google.dev/gemini-api/docs/speech-generation)：语言支持与预设音色。
- [Qwen-Audio 音色列表](https://help.aliyun.com/zh/model-studio/qwen-audio-tts-voice-list)、[客户端事件](https://help.aliyun.com/zh/model-studio/qwen-audio-tts-client-events)：3.1 多语言音色、兼容模型与语言提示。
- [豆包音色列表](https://docs.volcengine.com/docs/DoubaoVoice/Tonelist-1?lang=zh)、[单向流式 HTTP](https://docs.volcengine.com/docs/DoubaoVoice/unidirectional-streaming-text-to-speech-http?lang=zh)：2.0 音色语言范围与 additions 参数。
- [MiniMax 系统音色](https://platform.minimax.io/docs/faq/system-voice-id)、[同步语音合成](https://platform.minimax.io/docs/api-reference/speech-t2a-http)：日语预设与 language_boost。

## 真实调用与原生验收

同一条日文短摘要经生产 `SpeechSynthesis.synthesizer` 工厂实际调用四家服务，返回音频均通过 AVAudioFile 解码。一次调用的观测如下，仅用于证明当前配置可用，不代表稳定延迟或音质排名：

| 服务商 | 返回耗时 | 音频时长 |
| --- | ---: | ---: |
| Gemini | 4.22 秒 | 7.76 秒 |
| Qwen | 1.01 秒 | 7.47 秒 |
| 豆包 | 1.24 秒 | 8.26 秒 |
| MiniMax | 1.38 秒 | 7.63 秒 |

见 `short-samples/results.json` 与各家音频。音色目录依据官方文档；本次实际调用各家一个日语默认音色，没有逐一试听所有预设。

隔离原生 Mac bundle 为 `com.vibebuddy.e2e.ja-summary-20261010`，端口 18871，使用独立状态目录和令牌。健康检查通过，无令牌快照返回 401，认证快照正常。没有替换 `/Applications` 应用或使用生产端口 9876。

将已有真实 Codex 完成结果以明确的回放身份写入原生 transcript，并经 `/hook` 与 `/snapshot` 进入应用，再通过 `/presentation` 请求日语。结果为 `generated=true`、`language=ja`，返回 revision 与 Mac 快照一致；保留原任务「本轮尚未修改应用或调用真实模型」的限制。这证明真实内容的回放路径，不是新的实时 Codex 任务或配对手机验收。

初轮发现中文编辑提示会使模型返回中文或残留中文术语。已为日语使用完整日文编辑提示和明确的输出语言字段；主语言未识别为日语的输出被拒绝，降级为日文的摘要不可用提示。语言识别是保守门禁，不能证明每一句的母语自然度或专名发音。旧客户端不指定语言时保持原有协议；手机选择日语但连接旧 Mac 时不会接受忽略语言的响应。

原生设置界面成功生成日文样例，Gemini 试听显示播放完成。MiniMax 在原生 Inbox 的 Read pending 路径完成真实任务日文摘要的生成与播放；Calm Lady 音色正确显示，环境凭据被实际读取。播放日志和音频保留在持久证据目录。不会把播放完成记录当作用户已确认听感。

最终日文任务摘要还经四家工厂路径合成长音频，实际逐帧读至结尾：Gemini 61.64 秒、Qwen 64.03 秒、豆包 69.48 秒、MiniMax 68.62 秒，均无解码错误，见 `actual-audio/decoded-to-eof.json`。MiniMax 拼接 MP3 的长度元数据只报首段 22.72 秒，不能据此判断截断；实际解码覆盖 2195712 帧，原生独立生成版本的完整播放记录约 71.21 秒。初版探针的 `results.json` 中 seconds 是元数据时长，应以逐帧解码和原生播放证据解释。

## 检查与范围

- Kit 相关 41 项定向测试通过：日语默认项、模型匹配、供应商参数、旧协议、目录、风格与用途隔离。
- 最终 Mac 相关 30 项测试通过：语言覆盖与缓存隔离、Mac revision 保持、实际观察到的中文输出拒绝、摘要与证据约束。见 `checks/20261010T123411.467762Z-mac/`。
- 设置凭据回归脚本通过：保存值、取消、失败重试和注入凭据边界。
- 最终 Mac 原生构建通过；iOS 模拟器构建通过，见 `mac-build-final.log` 与 `checks/20261010T123450.099233Z-ios-build/`。
- 首轮 Mac 构建虽编译成功，但检查器发现 SwiftPM 裁剪 GUI-only Package.resolved 造成源漂移；核对后只恢复该已知裁剪，后续用仓库 `tools/with-resolved.py` 包装重新构建成功。

尚未完成物理 iPhone 播放、配对手机的端到端验收、用户听感确认或已安装版本更新。本次不据模拟器构建或音频解码声称这些已经完成。
