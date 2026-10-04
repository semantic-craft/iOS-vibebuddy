# Gemini 工单与依赖总览

日期：2026-10-04
阶段：用户已确认拆分，四张独立工单已落盘并登记施工清单；尚未实施。
依据：[PRD](PRD.md)、[官方研究](../../../research/gemini-provider-official-research-2026-10-04.md)。

## 拆分与依赖

| 工单 | 交付 | Blocked by | 对应 PRD 用户故事 |
| --- | --- | --- | --- |
| [GEM-01](issues/01-configuration-summary.md) | 配置 Gemini 并获得真实任务摘要 | None | 1–4、6–11、23–24 |
| [GEM-02](issues/02-read-aloud.md) | 在 Mac/iPhone 用 Gemini 朗读结果 | [GEM-01](issues/01-configuration-summary.md) | 2–3、5–8、12–15、20–21 |
| [GEM-03](issues/03-live-conversation.md) | 在 Mac/iPhone 用 Gemini 通话并操作任务 | [GEM-01](issues/01-configuration-summary.md) | 2–4、6–8、16–19、21–22 |
| [GEM-04](issues/04-integration-acceptance.md) | 三用途联合验收与现有供应商回归 | GEM-02、GEM-03 | 3–5、9、14–15、19–24及全部完成条件 |

GEM-01 → GEM-02 / GEM-03 → GEM-04。02、03 没有互相阻塞关系：分别沿用合成器与实时会话接口，可以独立实现和验收；两者都完成后，04 才验证 Gemini 通话与 Gemini 朗读的联动。实际并行时两端设置和供应商公共定义存在编辑交集，须由一个集成负责人协调，不为避开文件冲突制造业务依赖。

没有单独的“只加枚举”“只写 SDK 包装”“先重构”工单：每张能力工单包含设置入口、协议适配、真实体验和该能力的验证。现有三种接口足以承载本轮工作，尚无证据需要前置重构。

## 执行方式

当前唯一无前置依赖的工单是 GEM-01。01 完成后，02 与 03 可分别领取；04 等待 02、03 均完成。`ready-for-agent` 表示规格可实施，不表示前置依赖已经解除。

每张工单的独立文件是验收条目的维护位置；本页只记录已确认的拆分与依赖。实现用 implement-spec 按依赖推进；共享设置和供应商定义由集成负责人协调。按项目规则保留少量关键回归并完成真实验收。

本次仅落盘工单与索引，未提交 Git、未开始产品实现。父 PRD 保持原文。
