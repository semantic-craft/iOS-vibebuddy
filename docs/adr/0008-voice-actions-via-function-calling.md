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
packets belonging to a known cancelled response are dropped.

### Doubao ordered media and read-only status after interruption (2026-09-11)

The real endpoint sends an identified `response.output_audio.started` followed
by `response.output_audio.delta` carrying only delta/event_id/type. Applying
mandatory per-packet response identity to this format disconnected normal new
speech after an interrupted tool wait. Media now follows that server segment:
only a fresh, non-retired started event opens the identity-free audio stream;
interruption and completion close it. Explicit retired identities still lose.
Identity-free deltas outside an open segment are discarded. This is an ordered
media association, not proof of a tool's origin; the protocol cannot distinguish
an untagged packet violating its segment order. Missing-identity partial text is
suppressed after interruption; identified final text remains available.

Unidentified tool batches after interruption may contain only get_session_status:
this reads the current selected scope and cannot mutate a coding task. Existing
batch validation and call-ID deduplication still apply. Mixed batches, approvals,
denials, answers and other unidentified tools still end the call explicitly;
local counters and an audio segment never authorize a task action. Completion
events do not reset this action restriction. This narrows the earlier blanket
missing-identity shutdown rule to retain ordinary speech and read-only queries.

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

## Pending action cancellation and final transcription (2026-09-12)

Qwen/OpenAI Realtime track response-to-call identity. Speech-start retires pending
old calls and cancels their coordinator tasks. Cancellation propagates through
async action execution to the last available boundary before approval resolution,
answer injection, HTTP submission or Codex RPC send. Current task/scope checks and
call-ID deduplication remain in place. Already submitted work is not rolled back,
replayed, or reported as cancelled successfully. Hardware recovery alone does not
invalidate a tool turn, and Live captions remain non-authoritative for cancelling
backend work.

Final user transcripts use only the explicit whole-call hangup matcher; there is
no farewell/substring fallback. Doubao final transcription selects nonblank
`transcript`, then nonblank `text`. Deltas remain partial and do not hang up. The
750 ms Live caption settling heuristic and structured end-call tool are retained.
Conditional response-ID reuse or nonconforming event reordering are documented
separately from reproduced failures; they do not justify weakening identity checks.

## Named target (2026-09-24, RV-03)

Synthetic-speech acceptance showed the model choosing a different waiting task:
the user said "reject grape", Qwen transcribed 高客 and sent
`deny_session(orange)`. Scope, unique matching and pending revalidation all
passed that call; only a hold timeout on orange stopped it. The target must be
checked against something the model does not choose.

A task action — approve, deny, answer, instruct — is sent only when the user's
own words in the current exchange name its target (`VoiceTargetCheck`). An
exchange starts when the user starts speaking (`speechStarted`) or speaks again
after the companion did, so an earlier mention never carries over. Final
transcripts accumulate within it; a partial transcript is the provider's
hypothesis for the utterance so far and replaces the previous one (Gemini's
increments are accumulated in its adapter); Live captions are read as their
latest group, since Live's continuous output audio is not a reply. Project name
or session title, ignoring case, spaces and punctuation; Latin names match whole
words only and need three letters; a distinct word of the project name counts
when it is not a common or command word and no other in-scope name contains it;
a name heard only inside a longer in-scope name does not count. Transcription
can follow the tool call (Qwen: 0.1–0.7 s later), so the check waits up to
2.5 s for it. iPhone resolves the action inside the voice scope, as the Mac
does, so the checked target is the one acted on.

Otherwise the action is held, not sent. The tool result tells the model which
name was heard (or that none was) and to ask the user to say the target's name;
the screen shows a short held notice. Confirmation is the user saying the name,
checked the same way — "yes" or "对" alone never releases it. Marking a result
read changes no task and is not held.

Residual gaps (accepted): Gemini emits `speechStarted` only on interruption,
so if its tool call arrives before the first transcription chunk of the new
utterance, the previous utterance's words still count; in every replay the
chunks came first. Live captions are not reset by the companion's reply, only
by a new caption group (a gap over 1.5 s), so the same holds for a backend tool
call that precedes the new captions. Marking words stale whenever the companion
spoke before the tool call was rejected: it would hold every action preceded by
a spoken filler. Doubao also maps `response.canceled` to `speechStarted`; if it
lands between the transcript and the tool call, the action is held, not sent —
check this first if Doubao holds a named action.

This does not relax "transcript fragments never authorize coding actions": the
transcript can only veto. The structured tool call, scope, unique matching and
current-request revalidation still decide what is sent.

Considered: a spoken yes/no confirmation for every action (slower, and a yes
misheard from a no would release it); holding only when several tasks are
waiting (the user can name a task that is not waiting, and the only waiting one
still receives it). Known cost: when ASR garbles a name every time (an English
name in Chinese speech, or Gemini transcribing a short Chinese reply as
Japanese), voice cannot act on that task; the card still can.
