# Voice acts on sessions via provider function calling, not transcript parsing

**Status:** Accepted (2026-06-06)

The realtime voice companion can approve / deny / answer sessions. Because
**approve runs real commands on the user's Mac**, the action must fire only on an
explicit, structured intent — never from a stray "批准 / 可以 / approve" in ordinary
conversation. So the realtime session is given **function tools** (`approve_session`
/ `deny_session` / `answer_session`); the model emits a structured tool call only
when clearly asked, we decode it, run it, and feed the result back so the model
speaks a confirmation.

This extends ADR-0001: the tools, a `.toolCall(name, arguments, callID)` event, and
`sendToolResult(callID:name:result:)` are added to the `RealtimeVoiceProvider`
protocol and implemented for all three providers — OpenAI Realtime GA and Qwen
(`session.tools` + `response.function_call_arguments.done` + `function_call_output`
→ `response.create`), and Gemini Live (`setup.tools.functionDeclarations` + top-level
`toolCall` + `toolResponse`; schema types are the uppercase proto enum).

Defense in depth, since the action is consequential:
- the decoder (`VoiceTools.action`) is strict — unknown tool, malformed JSON, or an
  empty/blank field all resolve to `.none`, so nothing runs from garbage;
- target resolution (`VoiceSessionMatch`) is exact-first, unique-substring, and
  refuses an ambiguous match rather than guessing the wrong real command;
- `performVoiceAction` re-validates that the session still has a pending approval;
- the system prompt refuses to disclose its own instructions (prompt-extraction).

## Considered options

- **B. Parse the user transcript for "批准 X"** (like `VoiceCloseIntent`) — rejected:
  fast and provider-uniform, but can false-trigger and approve a real Mac command
  from a passing mention of approval. Unacceptable for a consequential action.
- **C. Answer-only** (voice answers questions; approve/deny stay tap-only) — rejected:
  safest but doesn't meet the goal that voice can actually approve.
- **Reuse the turn-based `ACTION:` text directive** (`VoicePrompt.parse`) — not viable
  in speech-to-speech: the model won't speak an "ACTION:" line aloud, so there is no
  text channel to parse. Tools are the structured channel that fits realtime.
