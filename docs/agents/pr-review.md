# Independent pull request review

`main` is PR-only. Before opening or merging a PR, obtain an independent review of the exact head and post the verdict and author triage. A Draft PR already opened without a completed review remains blocked; draft status, author self-review, tests, or a provider change do not satisfy the review gate.

## Reviewer and bounded execution

The owner selected **AGY CLI with Gemini** on 2026-10-05, replacing Grok Build for this repository. Do not invoke Grok or silently substitute Codex. Check `agy --help` and `agy models` for the installed CLI and currently available Gemini model; prefer the available Gemini Flash model the owner selected and record its exact slug. Do not hard-code a future model version as a permanent requirement.

Start one fresh, independent, read-only session. Reuse existing authorized login without placing credentials in the prompt; new login or access requirements are blockers. Verify isolation before sending material: no unrelated global/workspace instructions, hooks, plugins, MCP servers, or private history. A curated primary-agent profile and a self-contained public packet can minimize access, but verify the runtime toolset rather than assuming an empty `tools` list removes capabilities; terminal sandboxing alone does not prove read-only access or suppress inherited instructions. Verify supported flags and their compatibility; do not blindly combine `--mode plan` with `--disable-slash-commands`, or use permission bypass flags.

Use an explicit print timeout and retain terminal status, session/conversation identity, CLI trace, complete final report, exact base/head and input hash. Use bounded attempts, not repeated paid retries. After an incomplete run, check only that run's supported status/output/usage before retrying. Missing usage, hidden retries, or remote cancellation state remain unknown; no estimate is evidence of zero cost. A timeout, stream fragment, exit zero without a substantive final verdict, or a blocked tool is not a completed review.

## Review packet

Supply only the authorized public diff, ticket or ADR, necessary callers and neighbouring source, and a sanitized validation summary. Pin base and head commits, include the complete diff, and deduplicate surrounding context without dropping affected control flow. Never include private transcripts, logs, or credential contents. The reviewer does not edit, commit, push, comment, deploy, or spawn further agents. The author runs necessary local tests separately and labels those as author evidence.

Request each finding as `file:line`, severity (blocker / should-fix / nit), a concrete failure scenario and proposed fix, followed by MERGE / MERGE WITH FIXES / DO NOT MERGE. Request explicit gaps when context is insufficient. Provider selection does not weaken Standards/Spec or affected-interface verification.

## After the round

Validate findings against the spec and source. Fix valid findings, document deliberate non-fixes, run affected checks, and obtain a focused independent re-review of fixes and regressions on the new exact head. Post verdict, triage and evidence on the PR; keep local/private traces out of public comments. Historical failed-provider records remain evidence, not approvals. Merge only with explicit owner authorization covering that delivery; a review verdict alone is not merge permission.

Official references: [CLI reference](https://antigravity.google/docs/cli/reference/), [headless status and timeouts](https://antigravity.google/docs/cli/headless/), [agent tool restrictions](https://antigravity.google/docs/subagents/), [permissions](https://antigravity.google/docs/permissions/).
