# Gemini 三用途接入验收 — 2026-10-04

阶段：三用途代码已接通；设备实听和任务操作验收尚未完成，工单保持开放。

## 来源与交付边界

集成分支 `codex/gemini-provider-suite`，基线 `5af77f161cd28386beeda8b6c98853811013f43e`。范围见 [PRD](../planning/backlog/gemini-provider-suite/PRD.md)，依赖与剩余项见 [工单总览](../planning/backlog/gemini-provider-suite/TICKET-PLAN.md)。所有变更在独立工作树实施，原始工作区未修改。实现已通过 [PR #346](https://github.com/semantic-craft/iOS-vibebuddy/pull/346) 合入 `main`（`e088a80f`）。Mac 1.3.45（63）已发布；iOS 1.3.36（71）于 2026-10-04 17:29 +0800 提交，提交时 Apple 显示 Waiting for Review，审核通过后自动发布。共享已安装 Mac 应用未替换，设备体验验收仍未完成。

持久证据根目录：`~/Projects/_shared-work/iOS-vibebuddy/gemini-suite-20261004/`。以下相对路径均指该目录。凭据通过项目 `.envrc` 的既有白名单显式注入有界测试/隔离应用；编译、回归和评审不加载凭据。Key 未回显、未写入 Keychain。音频产物与少量任务结果仅存于本机证据目录。

发布签名、公证、公开下载包与更新源核对记录见持久目录 `release/release-status.md`；iOS 提审截图为 `release/ios-review-submitted.jpg`。提交审核不等于公开上架。

## 摘要选择与协议

- 官方 Python SDK 固定 `google-genai==2.25.0`，仅安装在临时虚拟环境；产品没有新增 SDK 依赖。SDK 文本、TTS、Live 三条协议探针成功。JS SDK v2.24.0 类型定义作为补充对照。
- Swift 产品 HTTP 适配器使用同批 3 条本会话已完成 Codex 结果（原生 turn ID，移除本地 Markdown 路径）和 1 条明确标注的英文边界样本，交替请求两个候选。原文、结果与用量见 `native-acceptance/summary-input.json`、`summary-results.json`。
- 初轮发现 3.8 Flash 不支持 `thinking_level=minimal`；按照[官方文档](https://ai.google.dev/gemini-api/docs/latest-model?hl=en)改为 `low`，3.5 Flash-Lite 保留 `minimal`，回归 20 项通过。修复提交 `d112044d`。

| 模型 | 修正参数后的有效结果 | 中位耗时 | 输入/输出 token 总计 | 样本判断 |
| --- | --- | --- | --- | --- |
| `gemini-3.5-flash-lite` | 4/4 | 0.824 秒 | 5429 / 148 | 保留尚未实施/设备待验收等边界，未夸大为发布完成 |
| `gemini-3.8-flash` | 3/4 | 1.545 秒 | 5429 / 180 | 英文结果超过 180 字符而被拒绝；研究样本把文档核对概括成“技术验证”，措辞偏强 |

保留 3.5 Flash-Lite 为默认；用户可编辑模型并恢复默认。该小样本比较支持本次选择，不能作为普遍延迟/质量保证。无超时、无自动重试、无静默模型回退。`store=false`、无工具/历史、最终正文提取、字数及 12 秒通知期限继续生效。

## 原生调用与隔离应用

- Swift TTS：`gemini-3.8-flash-lite-tts` / Kore，中文、数字及 SwiftUI 标识符样例，3.59 秒返回 276786 字节 WAV；24000 Hz、单声道、16-bit PCM，5.64 秒。见 `native-acceptance/native-tts.log`、`native-tts.wav`。这是生成与格式验证，尚无设备实听结论。
- Swift Live：`gemini-3.8-live`，实际流入由本次 TTS 生成并转换的 16 kHz PCM 查询音频。17.55 秒内完成两轮、2 次 get_session_status 调用与同 ID 回执、254400 字节模型音频、4 次输入转写和 5 次输出转写。见 `native-acceptance/native-live.log`。回执是明确的隔离测试状态；没有麦克风输入、真实任务变更或设备播放证明。
- 原生 Mac 隔离 bundle `com.vibebuddy.e2e.gemini-suite`，端口 18864；`/health` 为 ok、无凭据 `/snapshot` 为 401，认证后可读取快照。使用独立状态目录与令牌，生产 9876 和已安装应用未改动。
- 以真实 Codex 结果正文构造有明确 fixture 身份/时间的原生 transcript + hook 回放。应用记录完成结果后，经生产 `/presentation` 接口得到 `generated=true` 的 Gemini 朗读文本，用时 1.295 秒；来源/完成身份与快照见 `native-acceptance/codex-hook-replay.json`、`snapshot-after-replay.json`、`app-presentation.json`。这证明应用呈现路径处理真实内容，不是配对手机或实时新任务通知证明。最初仅复制历史 transcript 不会重放完成通知；无 transcript 的 Claude hook 回放被 speech 证据门禁拒绝（409），没有绕过门禁。
- CUA 原生设置核对：Gemini 摘要、跟随摘要的 Gemini 朗读、独立 Gemini 通话均可选择，注入 Key 显示 Ready to test；生成样例明确说设备待验收、未部署；Live 连接检查显示 Connection confirmed，麦克风开关仍关闭。见 `native-acceptance/ui-observations.json`。

## 定向回归与构建

- GEM-01：配置/摘要/内容呈现 Mac 26 项、Kit 9 项；证据 `gem01-local-checks/`。参数修复后 CompletionSummaryTests 20 项通过。
- GEM-02：合成、目录、用途配置、风格、分段与队列共 46 项通过；后续增量目录检查通过。具体执行见工单历史。
- GEM-03：Live 协议、取消、连续轮次、协调器、目标核验和时限共 45 项；同步 TTS 后 18 项增量通过，网络测试默认跳过。
- GEM-04：Mac 设置凭据回归及 Kit 11 项通过；修复隔离设置无法识别环境 Key，缺失仍不回退个人 Keychain。证据 `gem04-local-checks/`，提交 `d0875937`。
- Mac、iOS 模拟器构建在 `cc57309a` 通过（`mac-build/`、`ios-build/`）；设置集成后在 `af85314c` 再构建通过（`mac-build-integrated/`、`ios-build-integrated/`）。各 results.json 保留源提交、差异指纹、命令与限制。

## 评审与长文本问题

针对固定基线到 `af85314c` 的两轴独立评审：Standards 没有硬性违反，提出将来按需要拆分 transport 的低置信度建议；当前单一适配器已含窄 transport 边界，不做额外抽象。Spec 初轮没有识别代码缺陷，明确保留设备验收缺口。

随后集成负责人沿真实长文本朗读路径发现 P1：已有分段器拼接 MP3 字节，不能直接拼 Gemini 的多个 WAV，否则后续段不会完整解码。Spec 复核确认；由同一实现代理补可重放帧数/解码回归和修复：`83458ab9`，合入 `c214facb`。两个 1 秒 WAV 的红阶段仅解码 24000 帧；绿阶段完整解码 48000 帧并核对第二段样本，定向 10 项通过，见 `gem02-local-checks/`。Spec 复核确认 P1 已修复，其他供应商仍走原 MP3 分支。

修复后真实应用呈现文本经生产 `SpeechSynthesis.synthesizer` 分段合成：手动重试用时 8.39 秒，得到 1184684 字节、单一 WAV，AVAudioFile 读到 EOF 共 592320 帧（24.68 秒，24 kHz mono PCM16），见 `native-acceptance/native-result-tts-retry.log`、`native-result-tts.wav`、`native-result-decode.log`。第一次工厂路径调用 4.26 秒返回通用 `.transport`；具体原因未定位，记录保留在 `native-result-tts-fixed.log`，产品没有添加自动重试。此前直接把长文传给单次适配器的验收脚本被长度检查拒绝，随后脚本改为实际工厂分段路径（`76a35bfc`），该脚本误用不是产品配置失败。

`c214facb` 上 Mac/iOS 两端修复后增量构建通过，见 `mac-build-wav-fix/`、`ios-build-wav-fix/`；二进制哈希见 `native-acceptance/artifact-wav-fix.json`。原生隔离应用已停止，临时偏好已清理。独立实现子工作树清理后，集成工作树和持久证据保留。

## 尚未验收

- Mac 与物理 iPhone 实听中文、英文标识符及数字；声音/风格、队列停止/跳过、朗读与通话互斥、挂断后不擅自恢复。
- 配对 iPhone 接收真实新完成轮次的摘要；两端重启后完整 Keychain/用途配置保持；失联与过期结果的设备表现。
- 两端实际麦克风短通话，查询并受控操作指定真实任务后拿到回执；目标歧义、取消、打断与音频恢复的设备体验。
- 供应商真实长时限、GoAway 后实际结束、蓝牙/路由切换；目前只有关键协议及既有协调器回归。
- 本次未对其他供应商发起收费真实调用；复用了受影响的配置、分段、队列和工具逻辑回归，不宣称所有供应商端到端通过。

缺口需可用设备/用户实听和明确的共享应用安装窗口。本次不替换生产应用来制造通过记录。
