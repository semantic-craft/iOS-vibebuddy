# vibebuddy 1.3.12

- Recover voice audio after device changes, with recovery status and audio-release failure messages.
- Prevent interrupted voice actions and late responses from submitting stale task decisions.
- Fix Doubao disconnecting on normal audio fragments after an interruption; keep unidentified task actions blocked.
- Strengthen instructions to refresh task status for repeated questions and follow-ups after interruption.

## 中文

- 改进音频设备切换后的通话恢复，显示恢复状态，并提示音频释放失败。
- 阻止被插话取消的语音操作和迟到响应提交过期任务决定。
- 修复豆包插话后接收正常音频分片时断线的问题，继续拦截身份不明的任务操作。
- 强化重复及插话后状态查询的重新读取指令。

## Known limitations / 已知限制

- Doubao task actions without a verifiable response identity after interruption still end the call safely; start a new call to retry.
- A long-response hangup test timed out once; two instrumented repeats passed, and the original cause remains unresolved.
- 豆包插话后的任务操作若缺少可验证的响应身份，仍会安全结束通话，需要重新通话后重试。
- 长篇汇报的一次挂断测试曾超时；两次带发送记录的复测通过，原超时原因仍未确定。

## iPhone rapid restart

- Serialize audio shutdown and startup across calls so an old call cannot finish its queued teardown after a replacement call activates.
- 将各通话的音频启停统一串行处理，避免旧通话已排队的释放操作越过新通话启动。

## Availability

Mac 1.3.12 (19) is available in the signed, notarized DMG below. iPhone/Watch 1.3.12 (25) has been uploaded but is awaiting the final physical rapid-restart check before App Store submission. Mobile availability is separate from this Mac release.

Mac 1.3.12（19）通过下方已签名、公证的 DMG 提供。iPhone／Watch 1.3.12（25）已上传，待完成最后的实体快速重拨检查后提交 App Store；手机版尚未公开。
