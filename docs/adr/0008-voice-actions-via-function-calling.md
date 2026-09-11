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
protocol and implemented for all four providers — OpenAI Realtime GA and Qwen
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

Doubao uses `response.function_call_arguments.done.items` and aggregates every
call ID's result into one `conversation.item.create` tool-items message. It
never sends OpenAI `response.create` or truncate events. ASR-start interrupts
local playback and cancels outstanding tool work. After a real interruption,
packets belonging to a known cancelled response are dropped. If the service
omits the identity needed to associate a later response or tool call safely,
the session ends with an explicit instruction to reopen the conversation;
local turn counters are not accepted as evidence of server response identity.

## GPT-Live Responses delegation (2026-09-11)

Live delegates tool selection to a Responses model. Collect complete function
items inside `response.event`; the terminal response's empty `output` array does
not mean there were no calls. Release calls only on successful response
completion, deduplicate their IDs, submit every required result, then send one
Live `response.create` continuation. Unknown tools, failed or overlapping response
rounds stop explicitly instead of guessing or replaying an action.

The app still resolves and revalidates actions. Voice scope is checked at
execution as well as in the prompt. Reading selected status and hanging up are
separate explicit tools; transcript fragments never authorize coding actions.
The narrow local hangup exception below supersedes the initial tool-only hangup
design. Closing voice suppresses late receipts without claiming to undo
work already performed. Mac's immediate action wording says a request was
submitted, rather than claiming confirmed execution before a receipt exists.

## Hangup receipt and transport finalization (2026-09-11)

The coordinator stops local audio immediately and passes the hangup function
receipt to the transport owner. Both platform controllers return that receipt
and close in the same asynchronous operation. Live allows bounded time for the
receipt continuation before sending session.close, then keeps its receiver alive
for finalization. This separates immediate user-facing hangup from backend and
usage completion; a timeout never establishes final usage.

## Explicit local voice hangup (2026-09-11 manual acceptance)

Manual AirPods acceptance exposed a frontend saying it had hung up without
emitting the tool. The microphone remained active and other audio stayed ducked.
The shared coordinator now recognizes only a whole explicit call-ending command
in accumulated user captions, then waits 750 ms without further text before
stopping local audio and closing the session. New text cancels and re-evaluates
that pending close. Negated, quoted and interrogative text does not match;
farewells alone do not match this Live path. This is a reversible local call
control, never approval, task cancellation or execution of a coding action.

The settle interval is an application heuristic, not an API turn-final event.
Both platform controllers return their visible state to idle even when closure
starts asynchronously from this local control. The existing tool route remains
available for other explicit phrasings and carries its receipt into close.

## Shared conversation capabilities (2026-09-11)

Doubao installed acceptance exposed a wiring gap: only GPT-Live received the
status and hangup tools, and final transcripts from Qwen/Doubao still used the
older short-command matcher. All realtime app entry points now pass
`VoiceTools.conversation`: status, approve, deny, answer, and end-call. Provider
adapters retain their own wire schemas. GPT-Live's backend and the directly
speaking providers share the task evidence and tool-use instructions; the latter
have a spoken-companion role. Task data is read on demand from the current scope
rather than embedded as a stale initial snapshot.

A complete final user transcript may invoke the same explicit whole-call hangup
matcher as settled Live captions. Partial final-transcript-provider results never
close the call. This controls local voice only; task mutations still require
structured calls and current target validation. Audio teardown remains immediate.

This common wiring also reaches Gemini and OpenAI Realtime, but the current
provider acceptance scope is Qwen and Doubao; shared code is not proof of the
other providers' runtime behavior.


## Receipt delivery before close (2026-09-11 release review)

The async tool-result contract requires socket delivery before return, or a
provider-owned drain during close (GPT-Live). Qwen, OpenAI Realtime and Gemini
wait for bounded socket completion; Doubao waits for the exact FIFO sequence.
A hangup completes Doubao's outstanding aggregate with known results retained
and pending results explicitly unconfirmed, because stopping the coordinator
cancels result collection but cannot undo a previously dispatched action.
Delivery failure terminates without replay. Socket completion is not proof of
server-side business acknowledgement.
