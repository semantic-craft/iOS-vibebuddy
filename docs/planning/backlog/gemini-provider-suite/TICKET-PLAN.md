# Gemini 工单与依赖总览

日期：2026-10-04
阶段：四张工单已按用户要求结案；实现保留，自动部分补验，剩余设备/耳听及完整产品验收取消，不宣称全部通过。详见[验收记录](../../../qa/gemini-suite-20261004.md)。
依据：[PRD](PRD.md)、[官方研究](../../../research/gemini-provider-official-research-2026-10-04.md)。

## 拆分与依赖

| 工单 | 交付 | Blocked by | 对应 PRD 用户故事 |
| --- | --- | --- | --- |
| [GEM-01](../../../qa/acceptance-closeout-2026-10-12.md#gemini-provider-suite-01) | 配置 Gemini 并获得真实任务摘要 | None | 1–4、6–11、23–24 |
| [GEM-02](../../../qa/acceptance-closeout-2026-10-12.md#gemini-provider-suite-02) | 在 Mac/iPhone 用 Gemini 朗读结果 | [GEM-01](../../../qa/acceptance-closeout-2026-10-12.md#gemini-provider-suite-01) | 2–3、5–8、12–15、20–21 |
| [GEM-03](../../../qa/acceptance-closeout-2026-10-12.md#gemini-provider-suite-03) | 在 Mac/iPhone 用 Gemini 通话并操作任务 | [GEM-01](../../../qa/acceptance-closeout-2026-10-12.md#gemini-provider-suite-01) | 2–4、6–8、16–19、21–22 |
| [GEM-04](../../../qa/acceptance-closeout-2026-10-12.md#gemini-provider-suite-04) | 三用途联合验收与现有供应商回归 | GEM-02、GEM-03 | 3–5、9、14–15、19–24及全部完成条件 |

GEM-01 → GEM-02 / GEM-03 → GEM-04。02、03 没有互相阻塞关系：分别沿用合成器与实时会话接口，可以独立实现和验收；两者都完成后，04 才验证 Gemini 通话与 Gemini 朗读的联动。实际并行时两端设置和供应商公共定义存在编辑交集，须由一个集成负责人协调，不为避开文件冲突制造业务依赖。

没有单独的“只加枚举”“只写 SDK 包装”“先重构”工单：每张能力工单包含设置入口、协议适配、真实体验和该能力的验证。现有三种接口足以承载本轮工作，尚无证据需要前置重构。

## 执行方式

实现按 GEM-01 → GEM-02 / GEM-03 → GEM-04 推进，代码均已合入同一集成分支。四张工单从开放列表移除；链接指向逐项结案记录，保留原拆分及规格依据，取消不表示父规格全部验收通过。

各票原验收条目由 Git 和第一轮审计表保存，最新结果见结案记录；本页仅保留历史拆分与依赖。实现用 implement-spec 按依赖推进；共享设置和供应商定义由集成负责人协调。按项目规则保留少量关键回归并完成真实验收。

实现已通过 PR #346 合入 main，Mac 1.3.45 已发布，iOS 1.3.36（71）已提交审核；共享已安装 Mac 应用未替换。发布与设备验收边界见[验收记录](../../../qa/gemini-suite-20261004.md)。PRD 的半双工误读已按现行 ADR-0004 纠正为复用既有全双工/AEC，没有扩大音频改造范围。
