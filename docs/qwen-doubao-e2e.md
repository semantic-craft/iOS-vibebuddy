# Qwen / Doubao 全双工验收

日期：2026-09-11。当前验收版：Mac 1.3.10 (17.4)，Hermes iPhone 1.3.10 (21)，均已签名安装。Mac 与 Hermes＋AirPods 的 Qwen、豆包指定通话流程已获用户确认；未提交或发布。

## 已发现的问题与修复

豆包 17.3 人工通话能回复、能在有待播放音频时响应插话，但用户报告模型说无法挂断。日志显示最后由点击宠物停止，`voiceProcessing=false`，随后收到 `session.closed`。挂断项判定失败。

代码核查发现 Qwen 和豆包均未获得状态查询、挂断工具，且旧的最终转写匹配不识别“请立即挂断这次语音通话”。这属于应用接入缺口，不是模型能力上限的证据。

17.4 使用公共 conversation 工具目录和任务证据规则。每次任务查询调用 `get_session_status` 读取当前选择范围；明确完整的挂断口令直接停止本地通话，也提供 `end_voice_call` 工具。编程任务操作仍只接受结构化工具调用，停止说话不停止编程任务。

## 验证状态

- 65 项相关测试通过；包括 Qwen/豆包实际配置序列化后的五项工具目录、最终转写本地挂断、否定和引用不挂断、重复停止不重复关闭，以及既有工具和插话边界。
- Mac / iPhone 构建通过，已安装。源码改动按需求、工具参数、作用域、异步关闭和现有未提交改动做本地差异复核，`git diff --check` 通过。
- 豆包现有凭据可用，17.3 设置页实际握手成功，模型 `1.2.6.1`，中文音色 `zh_female_vv_jupiter_bigtts`。
- 豆包 17.4 实际通话：08:09:32、08:09:45 两次调用 `get_session_status`；08:09:38、08:09:51 在 `playback pending=true` 时收到插话并清空播放；08:09:53 调用 `end_voice_call`，08:09:54.053 音频停止且 `voiceProcessing=false`，08:09:54.688 收到 `session.closed`。此轮没有点击挂断。用户反馈“豆包似乎是正常了”，本轮查询、插话、挂断及音量恢复按该整体反馈记录为正常。
- Qwen 17.4 实际通话：模型 `qwen-audio-3.0-realtime-plus`，音色 `longanqian`，08:11:04 连接及音频启动成功，08:11:08 调用 `get_session_status`；08:11:19 在待播放音频存在时触发插话清空；08:11:26 调用 `end_voice_call`，随后 `voiceProcessing=false`。用户反馈“好像也可以了”，本轮整体听感按该反馈记录为正常。日志只有一次查询工具调用，不宣称验证了第二次刷新。
- iPhone 两引擎复验：在要求分别测试 Hermes＋AirPods 上的查询、插话、挂断和音量恢复后，用户反馈“可以了”。按该整体反馈记录两引擎人工验收通过；没有逐项手机事件日志或定量声学测量，不外推到其他设备、长时通话或断连重连。

测试日志：`/tmp/vibebuddy-shared-voice-tests.log`。构建和安装日志：`/tmp/vibebuddy-shared-voice-mac.log`、`/tmp/vibebuddy-shared-voice-iphone.log`、`/tmp/vibebuddy-shared-voice-iphone-install.log`。真实应用事件：`.scratch/doubao-e2e/mac-live.log`，只记录事件类别及状态，不记录凭据或麦克风音频。
