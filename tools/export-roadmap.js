#!/usr/bin/env node
// Export docs/planning/roadmap-2026-09.json, claude-review.md and codex-handoff.md
// from the roadmap HTML (the single source of truth for nodes, deps, status and prompts).
// Usage: node tools/export-roadmap.js docs/planning/roadmap-2026-09.html docs/planning
const fs = require("fs"), vm = require("vm");
const [html, outDir] = process.argv.slice(2);
if (!html || !outDir) { console.error("usage: export-roadmap.js <roadmap.html> <outDir>"); process.exit(2); }
const h = fs.readFileSync(html, "utf8");
// The page's data block starts at `const VISION` and ends at the layout marker; no HTML parsing needed.
const start = h.indexOf("const VISION = {"), end = h.indexOf("// ----- graph layout -----");
if (start < 0 || end < 0) { console.error("roadmap markers not found"); process.exit(1); }
const src = h.slice(start, end);
const ctx = {}; vm.createContext(ctx);
vm.runInContext(src + ";this.T=T;this.LANES=LANES;this.VISION=VISION;this.SESSIONS=SESSIONS;this.REVIEW_PROMPT=REVIEW_PROMPT;this.COORD_PROMPT=COORD_PROMPT;this.CODEX_PROMPT=CODEX_PROMPT;this.promptFor=promptFor;", ctx);
const { T, LANES, VISION, SESSIONS } = ctx;
const gen = h.match(/generatedAt:"([^"]+)", main:"([^"]+)"/);
const done = new Set(T.filter(t => t.kind === "done").map(t => t.id));
const prOf = t => { const x = t.title.match(/#(\d+)/); return x ? +x[1] : null; };
// Workflow states: done | pr-open | in-progress | changes-requested (title prefix 退回修改) | ready | blocked
const statusOf = t => t.deferred ? "blocked" : t.kind === "done" ? "done" : t.kind === "running" ? (/^退回修改/.test(t.title) ? "changes-requested" : prOf(t) ? "pr-open" : "in-progress") : (t.deps.every(d => done.has(d)) ? "ready" : "blocked");
const control = new Set(["CODEX", "COORD", "REVIEW"]);
const data = {
  generatedAt: gen[1], main: gen[2],
  howToUse: "正本是 docs/planning/roadmap-2026-09.html；本文件由 tools/export-roadmap.js 导出，不要手改。status 是快照，以仓库事实为准：agent 节点 done = PR 已合并（描述第一行为节点 id）或票 Status done；pr-open = 有开放 PR（pr 字段）；in-progress = 有会话或未提交改动在做；可派 = deps 全 done 且自身非 done/in-progress/pr-open 且 owner A；并发上限 4；优先级 S > A > M > 其余 1.2 > 1.3。票的 Status 只用仓库规定的标签与 done；工作流状态只写 HTML（kind 与标题前缀）。每轮先 git fetch origin 再判断。合并顺序：#57 → #56 → #55（三者都改 Kit 通知类型与 Mac Settings / MenuBarModel，每合一个让下一个合 main）→ #59（Companion 三端，与 #56 的 iPhone 卡片、#55 的 Mac 设置页相碰）→ #62（W-1..3 草稿，先验证）。主工作区 ~/Projects/iOS-vibebuddy 的 main 上仍有 W-1..3 的未提交原件：不 reset、不在主工作区开发。codex/notification-dedup worktree 已被 #54 取代，删除不开 PR。",
  vision: VISION,
  lanes: LANES.map(l => ({ id: l[0], name: l[1], note: l[2] })),
  sessions: SESSIONS.map(s => ({ session: s[0], state: s[1], output: s[2], whenDone: s[3], nodes: s[4] })),
  nodes: T.filter(t => !control.has(t.id)).map(t => ({
    id: t.id, lane: t.lane, title: t.title, version: t.ver, owner: t.kind === "you" ? "U" : "A",
    status: statusOf(t), pr: (t.kind === "done" || t.kind === "running") ? prOf(t) : null,
    deps: t.deps, ticket: t.path, vision: t.q, spec: t.spec, prompt: ctx.promptFor(t),
  })),
};
fs.writeFileSync(outDir + "/roadmap-2026-09.json", JSON.stringify(data, null, 1) + "\n");
fs.writeFileSync(outDir + "/codex-handoff.md", "# Codex 接手提示词\n\n复制下面整段到一个 Codex 会话（仓库根目录）。它读仓库文件、合第一波 PR、验证 #62、按前沿派执行会话，并维护路线图正本 docs/planning/roadmap-2026-09.html。\n\n```\n" + ctx.CODEX_PROMPT() + "\n```\n");
fs.writeFileSync(outDir + "/claude-review.md", "# 审查与协调提示词\n\n审查会话（复制到一个 Codex 会话，仓库根目录）：审执行会话的 PR、合并合格的、把不合格的写成回给执行会话的修改提示词，并维护路线图正本。\n\n```\n" + ctx.REVIEW_PROMPT() + "\n```\n\n协调会话（只派工、不写代码）的提示词：\n\n```\n" + ctx.COORD_PROMPT() + "\n```\n");
const c = {}; for (const n of data.nodes) c[n.status] = (c[n.status] || 0) + 1;
console.log("exported", data.generatedAt, data.main, data.nodes.length, "nodes", JSON.stringify(c));
