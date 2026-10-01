# Live phone / cloud acceptance — 2026-10-01

The user authorized live phone notifications and cloud-account acceptance after
implementation commit `d6b012c5`. No production app was replaced. The installed
Mac app remained 1.3.39 and the physical iPhone app was 1.3.32 (66).

## Real notification transport

The paired physical iPhone 17 Pro Max was available. Existing APNs configuration
and signer were supplied explicitly to isolated runs. A private temporary copy
of the single paired-device registration preserved the phone's notification
preferences; production pairing and credential configuration were not changed.
No device token, signer, bearer token or API key is included in this report.

- Headless daemon, port 18819: a real Cursor persistent task
  `e57f88db-d12a-434e-aee4-445ca7af41f3` entered working and was followed through
  the public attention route. Its actual stop hook produced completion
  `B539D3CB-116C-44A2-8BE5-B4345A0ED957`. APNs accepted its `agent_done` reminder
  315.46 seconds after completion, consistent with the five-minute reminder and
  30-second scheduling pass. No failure or APNs reason was recorded.
- Isolated Mac GUI, port 18820, bundle `com.vibebuddy.e2e.phone-acceptance`:
  a second actual Cursor task `037f42d7-d2ef-4302-9194-5937721e0228` generated
  completion `2EEA9A45-4C6B-4CC0-8429-AFDA3875D38F`. The app recorded local
  `scheduled` and APNs `accepted` with no failure. APNs acceptance followed
  the observed completion by 1.58 seconds. This measures the local completion
  to Apple-acceptance path, not the time the phone displayed the banner.

The GUI used the final reviewed Debug build, copied to a separate bundle with
an explicit E2E root, notification opt-in, APNs signer environment and device
registry copy. Health and authenticated snapshot returned 200; the unauthenticated
snapshot returned 401. No fake completion event was posted. Only the real CLI
and its normal observation hooks/transcript supplied task events.

An initial one-shot `agent --print` probe ran successfully but emitted only
sessionStart, postToolUse and sessionEnd to this hook setup; no completion push
was observed, so it is not counted as a successful notification check. An early
suspicion that hook/transcript precedence swallowed the persistent task's stop
was disproved by the journal. The delay was the headless host's reminder policy;
no source-priority code was changed.

## Device display and requested resend

The user did not notice the first reminder and requested another notification.
The visible-banner check remains pending; APNs acceptance alone is not delivery
or user acceptance. A fresh real task marked `VB-PHONE-1003` is the requested
resend. Its second round produced completion
`371EB102-D085-46B9-B5C7-5EEC3E1F7615` in session
`b48777af-3cd8-49f5-a1ff-4ef7ec140567`; local notification was scheduled and
APNs accepted `agent_done` without an error. The user was immediately asked
to check that specific notification.
Its first short run completed successfully but earned no cue: the existing
`SoundPolicy.doneMinRuntime` is 30 seconds and the probe only slept eight
seconds. A second real 35-second round in the same session tests the resend
without changing notification policy or fabricating a lifecycle event.

## Cloud account

The production settings page and Keychain existence query both showed no saved
`cursorCloudAPIKey`. Cursor CLI authentication is distinct from the Cloud Agents
API key. The secure native settings field was opened and the user was asked to
save the key there, without sending it through chat. Until a configured key is
available, authenticated cloud list/run/SSE acceptance remains pending. Fixture
SSE results from the earlier report do not satisfy that missing live check.

Local sanitized evidence: `.scratch/live-acceptance/preflight.json`,
`confirmed-apns-reminder.json`, `confirmed-apns-immediate.json`,
`gui-phone-completion.json`, `confirmed-apns-resend.json`. Raw device registrations remain only in disposable
runtime state and are excluded from retained evidence.

Both isolated processes (daemon 98848, GUI 23421) exited; their runtime roots,
including copied registration tokens, were removed. Test persistent CLI sessions
were stopped. Sanitized evidence remains; no product code changed.
