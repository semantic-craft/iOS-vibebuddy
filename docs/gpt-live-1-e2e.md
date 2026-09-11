# GPT-Live 1 E2E 验收记录

2026-09-11，当前本地源码。**关闭修复后的三次自动化实测通过**：两次真实 API 对话，以及一次接入真实 Mac 音频引擎的对话。随后已安装 Mac 和 Hermes iPhone 验收版；人工验收发现挂断后音量未恢复，Mac 修复版已完成人工复验，用户随后确认 Hermes iPhone＋AirPods 也正常，本次指定设备与通话流程验收完成。未提交或发布。下方保留此前失败记录，不覆盖历史证据。

## 修复与复验

关闭时，本地立即停麦、停声；挂断工具结果随关闭请求传递，由同一异步操作依次回传结果并关闭，避免结果发送与关闭竞态。Live 适配器等待挂断后端响应排空（上限五秒），再发送 `session.close`；从实际发送完成后最多等待十秒接收最终事件。超时仍标记最终用量未确认，不伪造成功。

| 修复后实测 | 打断回复 | 挂断工具 | 最终关闭 | 其他证据 |
| --- | --- | --- | --- | --- |
| 原对话复验 | “好的，我先停在这里。蓝莓” | 一次 | 已确认，23 秒 | 无任务修改，无测试期限强制关闭 |
| 任务结果开始生成后的播报打断 | “蓝莓” | 一次 | 已确认，27 秒 | 相关测试共 23 项通过，包含挂断回执回归用例 |
| Mac 原生音频引擎对话 | “好，我停一下。蓝莓” | 一次 | 已确认，27 秒 | 631,102 个采集帧，30 次播放排空回调，最终 idle 且音频停止 |

第三次运行直接使用当前 `OpenAILiveSession`、`VoiceCallCoordinator` 和 Mac `RealtimeAudioIO`，真实播放模型输出，同时运行麦克风采集；发往云端的输入仍是同一组合成语音，麦克风只计数、不保存或上传。这覆盖本地实际音频队列，但不是人工声学回声抑制或 iPhone/蓝牙验收。

打断提示词和处理逻辑没有在此次关闭修复中变更。三次成功说明当前场景可通过，不证明早先两次打断失败的根因已找到或模型行为完全稳定；不得将关闭修复归因为打断修复。复验仍要求实际出现新回答，不放宽原断言。

Mac 与 iOS Simulator 修复版构建均通过。关闭改动按仓库规范与需求进行了本地差异复核；`git diff --check` 通过。新增的回归检查验证音频先停止、挂断回执只交付一次、重复关闭不重复提交。

新证据位于 `.scratch/gpt-live-1/e2e-fix/` 和 `.scratch/gpt-live-1/e2e-native/`。原生探针为 `e2e-fix/NativeDialogueProbe.swift`，会加载同目录编译的当前 Kit 和实际 Mac 音频源文件。

## 此前失败的范围与结果

真实 OpenAI Live WebSocket、现有凭据、实时节奏输入的合成中文语音、本项目新读取的真实任务快照、生产版 `VoiceCallCoordinator` 与工具回传；测试不允许任务修改。云端对话使用测试播放接收器，Mac 原生音频引擎另行实测，所以不能把两者拼称为完整麦克风到扬声器的人工通话验收。

| 验收项 | 结果 | 证据 |
| --- | --- | --- |
| 查询任务、委派、工具结果、语音回复 | 通过 | 两轮均调用一次状态工具，返回所选任务状态；任务修改调用均为零 |
| 说话中插入新指令 | 未通过，两轮复现 | 第一轮转写保留“不要继续汇报任务”“只说蓝莓两个字”，仍继续旧简报；第二轮也未切换，并出现转写漏掉否定词、将“只说”写成“直说”的情况 |
| 语音挂断本地控制 | 通过 | 第二轮 `end_voice_call` 恰好一次，协调器 idle，音频 stopped，没有超时强制触发挂断 |
| 语音挂断后服务端关闭确认 | 未通过 | 第二轮约 44.01 秒收到挂断工具，约 46.09 秒测试结束；未收到 `session.closed`，`finalized=false`，29 秒用量只是最后一次更新 |
| Mac 原生 24 kHz 采集与播放 | 通过 | 播放前采样 23,649 帧，播放期间采样 16,807 帧；播放清空、替换播放、检查点、静音队列排空、重复停止均通过 |

第一轮因打断失败，没有进入依赖该结果的挂断步骤；最终测试期限关闭得到 `finalized=true`，不能作为语音挂断通过的证据。第二轮改为打断等待 25 秒后独立发送挂断语音，完整暴露了关闭确认问题。没有通过放宽断言把失败改成通过。

首次编译期间主机 load average 超过 160，但第二轮增量构建约 3.92 秒，仍复现打断失败。当前记录不把原因归给机器负载、模型或适配器中的任何一方；根因尚未确定。

## 复现与证据

测试入口：`VibeBuddyKit/Tests/VibeBuddyKitTests/OpenAILiveConversationE2ETests.swift`。

```sh
VIBEBUDDY_LIVE_DIALOGUE_E2E=1 \
VIBEBUDDY_LIVE_DIALOGUE_ROOT="$PWD/.scratch/gpt-live-1/e2e" \
swift test --package-path VibeBuddyKit --jobs 2 --filter OpenAILiveConversationE2ETests
```

这是付费 API 测试；默认跳过。输入目录需要 `context.json`（所选 `[AgentSession]`）、`query.pcm`、`interrupt.pcm`、`goodbye.pcm`（单声道 PCM16 LE / 24 kHz）。凭据通过现有 Keychain 读取，不写入测试输入或日志。

本地证据位于 `.scratch/gpt-live-1/e2e/`：`dialogue-report-first.json`、`dialogue-report.json`、两轮日志、输出音频、`native-audio.log` 和 `tested-source-sha256.txt`。麦克风仅计数，不保存或上传；原生探针播放的是低音量合成音。该阶段尚未验收人工打断的听感、回声抑制质量、iPhone 真机或蓝牙路由；后续人工结果见下节。

这些历史失败仍作为回归样本保留。上述自动化阶段不涵盖人工通话听感和设备路由，其结果本身不等于发布或安装验收。

## 已安装版本与人工验收（2026-09-11）

- Mac 17.1：用户反馈通话听感正常，但模型口头说挂断后界面仍在通话。加入明确整句挂断指令的本地处理，静候 750 ms，排除疑问、引用和否定句；它只结束本地通话，不执行编码任务。
- Mac 17.2：实测收到 `end_voice_call`，界面返回 idle。用户反馈背景音量仍降低，**完全退出应用后才恢复**。因此这一轮音频释放验收失败，不能由工具或界面 idle 推定通过。
- Mac 17.3：停止引擎后显式关闭 voice processing，关闭路径释放协调器。已签名安装，保留 17.2 备份。人工复验时用户反馈“好像恢复了”；07:56:10.192 日志记录 `audio stopped voiceProcessing=false`，同一应用进程 43168 仍运行。此次未复现挂断后持续压低音量；听感是用户的初步确认，未做声压定量测量。
- Hermes iPhone 安装版为 1.3.10 (21)。最新两平台构建通过。用户在收到 Hermes＋AirPods 的任务查询、插话“只说蓝莓”、语音挂断、背景音量恢复测试步骤后反馈“手机上也正常”，本轮人工验收按用户反馈记录为通过；没有逐项手机日志或定量声学测量，不外推到未测试设备、长时通话或断连重连。

本次原生探针直接编译当前 Mac `RealtimeAudioIO`，在停止后仍保留对象两秒，验证 `isRunning=false`、`isVoiceProcessingEnabled=false`、采集帧数停止增长；重复 stop、播放清空、替换播放、静音排空均通过。没有保存或上传麦克风音频。证据：`.scratch/gpt-live-1/manual/AudioReleaseProbe.swift` 与 `audio-release-probe.log`。21 项相关协调器及关闭意图测试通过。此探针验证资源状态，不替代人耳确认背景音量恢复。

Mac 17.3 与 iPhone 21 的签名安装均成功，Mac `/health` 返回 `ok`。iPhone 最新安装位置已由 devicectl 确认；Hermes/AirPods 人工验收已获用户确认。安装日志为 `/tmp/vibebuddy-audio-release-iphone-install.log`，构建日志为 `/tmp/vibebuddy-audio-release-mac.log` 与 `/tmp/vibebuddy-audio-release-iphone.log`。本次指定 Mac、Hermes 与 AirPods 通话验收完成；未提交或发布，也不代表其他设备与路由场景通过。
