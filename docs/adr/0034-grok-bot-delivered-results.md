# ADR-0034: Grok Bot delivered results and Japanese reading

- Status: accepted
- Date: 2026-10-11
- Supersedes the quota-only scope in [ADR-0031](0031-grok-bot-is-account-usage-only.md)

## Context

The owner requested automatic Mac delivery, Japanese summaries/read-aloud and
quota verification, and authorized design collaboration with their Grok Bot.
The Bot's formal transcript reader did not establish comprehensive task terminal
states or group coverage. A model-driven periodic reader also spends allowance.
[yobiru](https://github.com/chekusu/yobiru) offers a useful receipt/transport
pattern, but not a verified Grok Bot terminal-state feed.

The official Mac client already synchronizes account-scoped roster and transcript
replicas. In version 0.68.1, `send-message` text entries have stable IDs and times;
direct chats omit `author`, while group entries may supply it. This is an
undocumented client cache and may change.

## Decision

Opt in to reading new user-facing text notifications from the active account's
local client replicas. Resolve direct-chat authors only through non-group roster
rows. Skip user prompts, streamed reasoning, attachments, secret requests and
explicitly addressed messages. No cloud polling, model calls or Bot reminder is
needed to collect a notification. Each message becomes one immutable result card.

A separate ingest-only bearer credential also protects `POST /grok-bot/result`
for owner-controlled collectors. It cannot authorize phone control routes.
Receipts validate shape, size and age; stable Bot/conversation/turn identity
reserves a durable deduplication file before projection. Identical retries are
acknowledged; conflicting retries fail. Receipts retain at most seven days/4096
files. A crash between reservation and projection can lose that one presentation;
we prefer this to reannouncing a dismissed receipt. This is not an exactly-once
transaction across the inbox and session journal.

Japanese summary and speech reuse the existing presentation and voice queues,
including manual replay. Notification wording attributes reported facts to the
Bot without inventing task completion, warnings or follow-up work. Quota remains
an independent authenticated account read. The account-file parser accepts the
current numeric `version` field without decrypting anything for cache selection.

## Boundaries

This reopens ADR-0031 only for delivered results. It does not restore the old
private gateway observer, approvals, replies or live task-state inference.
Automatic coverage means **new text notifications actually synchronized to this
Mac while the bridge runs**. There is no guarantee for silent tasks, cancellations,
attachments, unopened/unsynchronized conversations or every group. Startup and
account switches baseline at current time to avoid historical speech; offline
backfill across restart is not implemented. Notification cards are for the current
run; the minimal lifecycle journal cannot restore their account/sender metadata,
so restart drops those cards while retaining deduplication receipts. Account
switches retire prior cards.
The client must keep running and synchronizing. Unknown cache shapes produce no
messages, and `/grok-bot/status` exposes collector availability.

The `done` state on a result card means the notification was delivered. Its title
identifies it as a notification; the original text remains the result body.

See [setup and validation](../grok-bot-results.md).
