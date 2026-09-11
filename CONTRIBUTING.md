# Contributing to VibeBuddy

Thanks for helping make coding-agent workflows easier to follow across Mac,
iPhone and Apple Watch. Contributions in English or Simplified Chinese are welcome.

## Useful ways to help

- Reproduce a Claude Code, Codex or Grok Build issue with the actual agent, or
  improve Grok Bot observation and Cursor account-usage integration.
- Improve English or Chinese UI text and keep the two READMEs consistent.
- Document a device workflow, especially Watch interactions and reconnects.
- Fix a focused bug or improve an existing provider adapter.
- Share a concrete example of how VibeBuddy fits your development workflow.

## Before changing code

Read [AGENTS.md](AGENTS.md) for project rules and
[getting started](docs/getting-started.md#build-from-source) for local setup.
Changes to behavior or architecture should also follow the
[domain guide](docs/agents/domain.md), [CONTEXT.md](CONTEXT.md) and relevant
[architecture decisions](docs/adr).

For work planning, this project uses local Markdown under `.scratch/<feature>/`,
as described in the [issue-tracker guide](docs/agents/issue-tracker.md). Those
local notes are not committed. Send reviewable changes as GitHub pull requests;
for a substantial proposal, explain the intended behavior before investing in a
large implementation.

## Make the change easy to review

Keep the diff focused and preserve existing uncommitted work. Explain what the
user experienced, what changes after the patch, and how you checked it. Include
the affected agent version and connection type when relevant: Codex CLI, a
daemon-owned app-server task and a Desktop-origin task are different test cases.

For app or daemon behavior, prefer a real end-to-end check of the affected flow.
Run relevant existing tests for shared logic and regressions. For documentation,
check links, images and the rendered page. A screenshot of Demo mode demonstrates
the interface; a real-device check demonstrates that specific device flow.

In your pull request, include:

- The problem and resulting behavior.
- The checks performed and their results.
- Screenshots for visible changes, labelled with their source.
- Any remaining device, provider or integration limitation.

## Keep private data out of contributions

Use sample tasks for public screenshots and reports. Remove pairing QR codes,
bearer tokens, API credentials, private project paths and transcript contents.
Never commit APNs signing keys or provisioning credentials. If a bug depends on
private data, describe the smallest sanitized reproduction instead.

## License

By submitting a contribution, you agree that it may be distributed under the
project's [MIT license](LICENSE).
