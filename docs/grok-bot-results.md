# Grok Bot result bridge

The Mac can automatically read new text notifications already synchronized by the
official Grok Bot desktop client, then summarize/read them in Japanese. This is
notification coverage, not a guarantee that every Bot task reaches a terminal
state. Keep Grok Bot running. Quota is separately enabled in Usage sources.
Notification cards are retained for the current app run; restarting starts a
fresh inbox without reading historical notifications aloud. Deduplication receipts
survive restart, so retrying an already received message will not reannounce it.

## Enable

From the repository, run `python3 tools/grok-bot-results.py enable`, then restart
the new VibeBuddy build. This creates an owner-only, ingest-only credential in
`~/Library/Application Support/vibebuddy/grok-bot-result-token`; never paste it
into a Bot conversation. `status` reports provisioning and receipt count.
To stop collection, move that token file aside and restart VibeBuddy.

No Bot instructions or per-task reminders are required for client-synchronized
text messages. Existing summary/read-aloud switches and quiet mode still apply.
Grok Bot reading uses Japanese regardless of the global summary language.

## Optional explicit collector

`POST /grok-bot/result` requires the separate token in the Authorization header.
It accepts JSON fields `version` (1), `evidence` (`notification` or `finalReply`),
`id`, `botID`, `conversationID`, `turnID`, `botName`, `title`, `text`, and
`completedAt` (ISO-8601). Keep identifiers stable on retries. Text is limited to
11,800 characters, HTTP bodies to 64 KiB, and receipts to seven days old.
The response acknowledges the ID and indicates whether it was a duplicate.

`python3 tools/grok-bot-results.py send --file receipt.json` sends one receipt;
`--url` selects the receiver. Use HTTPS or an encrypted private network. No
cloud collector is installed by this change. The phone token is deliberately
rejected by this endpoint. The receiver token cannot read or control sessions.

For isolated acceptance only, `--directory` selects another credential directory;
set `VIBEBUDDY_GROK_BOT_BRIDGE_DIRECTORY` to the same absolute directory on the
receiver. `VIBEBUDDY_GROK_BOT_HOME` selects the official client data root. The
ordinary phone-authenticated `GET /grok-bot/status` reports cache health without
returning messages or credentials.

## Validation on 2026-10-11

- An isolated daemon on port 18785 received a fresh notification from the real
  owner-operated Bot through the official Mac client's cache, without a callback
  or outbox instruction. Old messages were not replayed.
- An isolated Mac GUI on port 18786 replayed that notification through the result
  endpoint with a new test ID/time. Qwen generated Japanese; MiniMax audio was
  generated, started and completed. Global summary language was Chinese to test
  the Grok-specific override. Final wording verification is recorded separately
  in the task's local acceptance evidence.
- Regression checks cover direct messages without author, group-shaped text,
  active-account filtering, duplicate/conflicting receipts, credential separation
  and the numeric version field in the current account file.
- Real quota is **not yet accepted**: the official client displayed 78% used,
  while the old installed VibeBuddy reported not logged in. The parser defect is
  fixed, but an isolated native account probe then timed out in Keychain access.
  No access controls were changed and no secrets were printed.
- This does not establish installed-app or iPhone/Watch acceptance, comprehensive
  group/new-Bot coverage, all-task completion or offline backfill.

Local evidence is under `.scratch/verify-vibebuddy/grok-20261011/` and
`.scratch/grok-bridge/gui/`; these artifacts are not public source files.
