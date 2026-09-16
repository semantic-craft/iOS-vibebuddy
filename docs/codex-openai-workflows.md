# Codex and OpenAI workflows

VibeBuddy is an MIT-licensed native companion for Mac, iPhone and Apple Watch. It helps you follow coding tasks away from the terminal and respond when a supported connection needs your input. The apps, local daemon, shared Swift models and integration checks are public in this repository.

## Follow a Codex task

1. Install the [Mac companion](https://github.com/semantic-craft/iOS-vibebuddy/releases/latest) and follow [agent setup](getting-started.md#connect-an-agent-for-live-observation).
2. Start a small Codex task in a repository you control. Look for its working state in VibeBuddy on Mac.
3. Pair the [iPhone app](https://apps.apple.com/us/app/vibebuddy-agent-monitor/id6777469338) using the [connection instructions](getting-started.md). Keep the Mac running and reachable, then open the task on your phone.
4. If the connected app-server owns the task and exposes an answerable approval or question, inspect it and respond. If the request belongs to Codex Desktop and no answerable card is available, use its native Mac prompt.
5. After completion, review the result on Mac or iPhone. A paired Apple Watch can show task results through the iPhone; notification and background behavior depend on system settings.

This is a workflow to reproduce, not a report of a new device test. README screenshots use Demo data. Closed-app push needs additional [APNs configuration](apns-setup.md).

## Inspect the integration

| Capability | Public implementation and checks |
| --- | --- |
| Observe local Codex tasks and completions | [Rollout monitor](../VibeBuddyMac/Sources/VibeBuddyMacCore/CodexRolloutMonitor.swift), [completion reader](../VibeBuddyMac/Sources/VibeBuddyMacCore/CodexCompletionReader.swift) |
| Control tasks owned by a connected app-server | [App-server monitor](../VibeBuddyMac/Sources/VibeBuddyMacCore/CodexAppServerMonitor.swift), [client](../VibeBuddyMac/Sources/VibeBuddyMacCore/CodexAppServerClient.swift) |
| Display available account usage | [Usage provider](../VibeBuddyMac/Sources/VibeBuddyMacCore/CodexAppServerUsageProvider.swift) |
| Handle approvals and request boundaries | [Approval tests](../VibeBuddyMac/Tests/VibeBuddyMacCoreTests/CodexAppServerApprovalTests.swift), [integration contract](codex-integration.md) |
| Check compatibility after Codex upgrades | [Protocol probe instructions](../tools/codex-integration/README.md) |

The connected server must own the task. Steering requires an observed turn ID, and pending requests determine which responses are available. Codex Desktop may run a separate app-server; observing its rollout does not grant control of its native approvals. MCP elicitation remains read-only. The [integration contract](codex-integration.md) records the tested baseline and its limits.

These implementations and checks give other Swift developers concrete examples of Codex task observation, app-server communication and approval handling. The checks are bounded; passing a protocol audit does not prove installed-app or physical-device acceptance.

## Optional OpenAI audio

Task monitoring and button approvals do not require an OpenAI API key. To use voice, configure a supported provider in the app, review the disclosure and start a call. Voice conversation, completion summaries and Mac read-aloud have separate settings.

The shared Swift package includes [OpenAI Realtime](../VibeBuddyKit/Sources/VibeBuddyKit/OpenAIRealtimeSession.swift), [GPT-Live](../VibeBuddyKit/Sources/VibeBuddyKit/OpenAILiveSession.swift) and [speech synthesis](../VibeBuddyKit/Sources/VibeBuddyKit/OpenAISpeechSynthesizer.swift) adapters. Availability depends on your provider account and selected model. API charges apply to your own account.

The Mac and phone communicate over your network. Optional audio and task text go to the provider you select. See the [privacy policy](privacy-policy.md) for data handling.

## Try it, report a problem, or contribute

Download a [Mac release](https://github.com/semantic-craft/iOS-vibebuddy/releases), use the [iPhone listing](https://apps.apple.com/us/app/vibebuddy-agent-monitor/id6777469338), or [build from source](getting-started.md#build-from-source). For an integration problem, report the Codex version, connection type and reproducible steps without including credentials or private conversation content. See [contribution guidance](../CONTRIBUTING.md).

The [release history](https://github.com/semantic-craft/iOS-vibebuddy/releases) and [merged pull requests](https://github.com/semantic-craft/iOS-vibebuddy/pulls?q=is%3Apr+is%3Amerged) document ongoing maintenance. VibeBuddy is an independent community project, not affiliated with or endorsed by OpenAI.
