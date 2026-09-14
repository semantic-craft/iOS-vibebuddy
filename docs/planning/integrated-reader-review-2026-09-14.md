# 本次整合改动的上游源码对照

审阅范围：PR #197 的 Mac 阅读器、通知与状态来源、Watch 路由，以及 PR #196 的连接设置。按本仓库已采用的设计来源与本次实际改动选取相关项目；这是有明确范围的源码审阅，不声称穷尽 GitHub。额度采集与真实账户验收留到下一步。

## 固定版本与采用结论

| 来源 | 读到的实现与本次决定 |
| --- | --- |
| [Wake `b4a189f`](https://github.com/iAmCorey/Wake/tree/b4a189fea4e5d39d12031202fac1fe167935726a) | 主要阅读器参照。其 [adapter 契约](https://github.com/iAmCorey/Wake/blob/b4a189fea4e5d39d12031202fac1fe167935726a/crates/wake-core/src/adapters/mod.rs#L30) 分离低成本枚举、索引解析与按需正文解析，并以 host/agent/native ID 区分身份；[详情加载](https://github.com/iAmCorey/Wake/blob/b4a189fea4e5d39d12031202fac1fe167935726a/crates/wake/src/workbench.rs#L4128) 后台解析，回写前核对选中 key，默认底部对齐，搜索按 seq 定位。VibeBuddy 保留独立 reader actor、精确 transcript key、generation 与取消检查；索引和正文都不能授予 live 控制能力。 |
| [Wake watcher](https://github.com/iAmCorey/Wake/blob/b4a189fea4e5d39d12031202fac1fe167935726a/crates/wake-core/src/watcher.rs#L146) | 目录事件在 800 ms 窗口收敛，处理文件移除与增量更新；[丢事件的后台分支](https://github.com/iAmCorey/Wake/blob/b4a189fea4e5d39d12031202fac1fe167935726a/crates/wake/src/workbench.rs#L3779) 请求补扫。我们只监听当前正文，并保留慢速索引刷新；文件缺失期间监听父目录，不能只尝试重开一次。 |
| [CodexBar `a5f2c58`](https://github.com/steipete/CodexBar/blob/a5f2c581ce2e859dab983e28af50c03351db7dd3/Sources/CodexBar/Sync/ConfigFileWatcher.swift#L53) | 文件不存在时转向父目录，rename/delete 后重新挂载，事件闭包弱引用 source。本次按这一恢复思路修复单文件 watcher，并把它放入可直接验证文件系统事件的 Core 模块。配置同步的 hash/自写抑制不是正文阅读需求，不照搬。其 [刷新策略](https://github.com/steipete/CodexBar/blob/a5f2c581ce2e859dab983e28af50c03351db7dd3/Sources/AdaptiveRefreshCore/AdaptiveRefreshPolicyCore.swift) 可供后续额度问题参照，本次不改额度采集。 |
| [AgentsView `9be7745`](https://github.com/kenn-io/agentsview/blob/9be7745ad1906ee24e04eb05bb86c872ef0939a1/frontend/src/lib/components/content/staged-scroll.ts) | 滚动以有效索引、当前请求、已渲染行和实际测量为依据，估算滚动不算完成；[最新边缘判断](https://github.com/kenn-io/agentsview/blob/9be7745ad1906ee24e04eb05bb86c872ef0939a1/frontend/src/lib/components/content/message-scroll.ts) 使用视口几何。我们修复缩短记录时的切片边界，并用 AppKit 用户滚动事件区分手动上翻与内容增高，删除两秒时间猜测。Svelte 的虚拟列表重试实现不移植到 SwiftUI。 |
| [Open Island `334c580`](https://github.com/Octane0411/open-vibe-island/blob/334c58073ec0ea8a1b34da0c71f969b1affd0959/Sources/OpenIslandApp/CodexAppServerCoordinator.swift#L95) | 已知任务不会被 app-server 的 loaded-thread 枚举重新创建；对照确认本次将 discovery/metadata 与实际执行进展分开，防止旧观察抢占新 hook。其 [Watch relay](https://github.com/Octane0411/open-vibe-island/blob/334c58073ec0ea8a1b34da0c71f969b1affd0959/Sources/OpenIslandCore/WatchNotificationRelay.swift#L22) 按 request/session 映射回执；我们继续使用 source/session/completion/request 的现有身份约束。 |
| [Notchi `e873da2`](https://github.com/sk-ruban/notchi/blob/e873da231340b3a5094c59ce7cb0ec2809d88ed1/notchi/notchi/Services/SessionStore.swift#L601) | 取消问题后是否恢复 working，取决于 broker 是否真的交付 deny。借鉴的是“派发意图不等于状态事实”；本次 Watch 展示/回执仍按 Mac 快照核对，不因点按或跳转推断执行完成。 |
| [m5-paper-buddy `c997570`](https://github.com/op7418/m5-paper-buddy/blob/c997570ba83111bddfe2796fbd96796be5bb5142/README.md) | 本仓库最初的硬件与 hook 参照。其 transcript token 数用于上下文窗口进度，不能作为 Codex/Claude 账户额度，也不能替代执行状态；本次继续保持这些概念分开。 |
| [SwiftNIO #3597](https://github.com/apple/swift-nio/pull/3597) | 使用包含 WebSocket 升级期间连接关闭修复的 2.102 版本；修复放在上游依赖中，不在 VibeBuddy 另写升级器补丁。 |

## 本次发现并修复

1. 两处后台正文投影在核对 generation 前写入 rows；另有已排队 refresh 可能晚于新选择启动。现在先检查选择代次和取消状态，再回写或启动刷新。
2. rows 缩短时，SwiftUI 渲染可能先于 onChange，旧窗口会越界。渲染使用当下行数约束的窗口，保留重放测试。
3. 原 watcher 删除文件后只在一秒后重开一次。延迟重建会永久失去后续追加事件。改成缺失时监听父目录，父目录也不存在时延迟重试；测试删除、等待 1.4 秒、重建、继续追加两个阶段。
4. 原滚动逻辑用两秒宽限区分布局增长与用户上翻，存在抢回滚动位置的窗口。AppKit 的 [didLiveScrollNotification](https://developer.apple.com/documentation/appkit/nsscrollview/didlivescrollnotification) 明确由用户事件触发，且支持没有 begin/end 成对事件的传统鼠标；本次以它控制跟随状态。Wake 的 GPUI 底部对齐不能直接当作 SwiftUI 行为已获验证。
5. 整合保留当前收件箱计数、下一项导航、读取后详情不消失、按完整 checkout 路径区分项目和每任务输入草稿。手动已读开关与结果卡共享完成 ID 守卫。
6. Headscale 帮助返回保留输入草稿；IP 输入使用可输入 ASCII 句点的 URL 键盘。旧额度弹窗的合并冲突保留 #195 的 Usage 导航和小组件入口。
7. 实际历史阅读验证发现 watcher 已收到追加事件，但历史入口仍读取旧索引正文缓存。历史入口也改为按精确 key 读取源文件或版本核验过的缓存，同时保留收藏、置顶和库内归档元数据；不再等待下一轮索引发布。

8. 实时入口的导出误依赖历史页的正文状态。现在导出使用 reader 已加载的完整正文，并核对会话 ID 与源路径；新启动的隔离 App 未进入历史页，也能保存真实对话的 Markdown。
9. 搜索命中原来在每次追加正文后重复定位。现在每个选定命中只揭示一次，后续正文追加遵循用户当前的跟随状态。

## 验证与边界

Kit 定向测试 161 项、Mac 定向测试 45 项（去除重复 watcher 执行）、iPhone 定向测试 20 项通过；另一次 iPhone 实时连接测试通过真实 WebSocket 接收隔离 Mac 的当前 Codex 任务，且拒绝错误令牌。Mac、iPhone、小组件、Watch 编译通过。新模拟器的 QA 通知回归保持通知权限未请求。隔离 Mac 读取当前任务真实 Codex 转录的副本，验证底部跟随、手动上翻后保留位置并显示新消息入口，以及实时入口 Markdown 导出；没有把演示或伪造 hook 当作真实任务。证据在 `.scratch/review-all/`，最终提交的 CI 结果以 PR #197 为准。

Open Island 的[默认通知点按处理](https://github.com/Octane0411/open-vibe-island/blob/334c58073ec0ea8a1b34da0c71f969b1affd0959/ios/OpenIslandMobile/Notifications/NotificationManager.swift#L237) 仍直接忽略默认点按，不能证明我们的 Watch 点击或 Live Activity 拉起已经正确。真机拉起、蜂窝 Headscale/Surge 连通、真实账户额度、终端原生跳转依旧各需自己的证据。以上仓库是经验来源，不替代本项目验收；本次不安装或发布应用。
