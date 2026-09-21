# VibeBuddy 1.3.28 — macOS

- 修复 Cursor 会话多、`state.vscdb` 超过 1 GB 时 Mac 端整体卡顿：`/snapshot` 要等 20 秒到 2 分钟、iPhone 连上后半分钟才收到第一帧、空闲 CPU 常驻 20–37%。原因是读取 Cursor 会话索引的查询走了全表扫描；现在按键范围走索引，真实 1.4 GB 数据库一次读取 0.13 秒。
- Cursor 每写一条消息都会改动数据库文件；现在只重新解析内容真的变了的会话，其余沿用上次结果。

包含 1.3.27 的全部修复。iPhone 对应版本仍为 iOS 1.3.25（55），无需更新。

## English

- Fixes the Mac app bogging down once Cursor's `state.vscdb` grows past a gigabyte: `/snapshot` taking 20 s to 2 min, the phone waiting half a minute for its first frame, 20–37% CPU at idle. The read of Cursor's conversation index was a full table scan; it now walks the key index and reads a real 1.4 GB store in 0.13 s.
- Cursor rewrites its database for every message; only conversations whose stored bytes changed are decoded again, the rest are reused from the previous pass.

Mac build 46. Includes all fixes from Mac 1.3.27. The accompanying iPhone release remains iOS 1.3.25 (55); no phone update is needed.
