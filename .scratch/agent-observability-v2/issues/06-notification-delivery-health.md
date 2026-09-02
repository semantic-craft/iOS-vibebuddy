# 06: 显示本地通知和 APNs 投递健康度

**What to build:** 用户可以区分通知权限关闭、本地通知成功安排、APNs 被服务端接受和发送失败等状态；失败会按原因去抖并进入可诊断记录，不再把调用发送接口等同于设备已经收到。

**Blocked by:** 05: 增加隐私受控的生命周期事件日志.

**Status:** ready-for-human

- [x] Mac 设置显示本地通知授权状态以及 APNs 配置/最近尝试结果，并使用 attempted、scheduled、accepted、failed 等诚实措辞，不声称无法证明的 delivered。
- [x] Claude 与 Codex 的 approval、answer、done、stuck 通知都生成带会话和声音类别的发送记录，同时保持现有安静模式、前台抑制和防重复规则。
- [x] 同一失败原因在短时间内只提示一次，恢复成功后健康状态自动清除；诊断提示本身不会形成通知风暴。
- [x] 仅用少量快速回归测试保护投递措辞、失败去抖和恢复主路径；以实际 Mac 通知权限和真实本地通知完成端到端验收，APNs 实机验收在已配置账户时执行。

## Comments

- 实现：独立 `NotificationDeliveryLog`（250 / 7 天），不改 LifecycleJournal schema，不改 `SessionStore.appendJournal`。SoundPolicy 规则未改，只在其后再记录投递。
- 措辞：outcome 只有 attempted / scheduled / accepted / failed。本地成功安排 = scheduled；APNs HTTP 2xx = accepted；权限关闭或非 2xx = failed。从不把 API 返回写成设备已收到。
- 聚焦测试 13/13（NotificationCoordinatorTests + NotificationDeliveryTests）；VibeBuddyMac `swift test` 284/284；Mac Debug build succeeded。
- 正式 `/Applications` VibeBuddy 与 9876（PID 1013）全程未停。隔离 daemon（临时 HOME / 非 9876 端口 / 临时 journal + delivery log）用 dummy device token 打到已配置的 sandbox APNs：记录 `failed` / `apnsHTTP400` / `needs_answer`，日志中无 `delivered`。同一失败原因连续两次都写入 log，健康去抖只锁一次诊断。
- 隔离本地 helper（独立 bundle `com.vibebuddy.e2e06`）授权为 `notDetermined`，记录 `failed` / `permissionDenied`，无 `delivered`。未对正式 App 弹权限窗，也未替换已安装 App。
- **缺口：** 隔离实例没有已注册的真实 iPhone token，因此没有 APNs `accepted` 实机记录（dummy token 只能证明 `failed`）。隔离 helper 也没有 TCC 授权，本地 `scheduled` 横幅未在隔离 bundle 上弹出；该路径由授权状态下的 `UNUserNotificationCenter.add` + 单元测试覆盖。daemon 经 `VibeBuddyServer` 的 APNs 发送未带 session id（该文件本票禁止改动）；Mac App 的 `pushToPhones` 会带 session 与声音类别。
- Independent reviews PASS. Status → `ready-for-human`. Remaining gaps (no APNs `accepted` on a real device token; isolated helper had no TCC so no live `scheduled` banner) stay documented. Local commit `87005c5` is on `codex/agent-observability-v2`.
