# Native reader performance experiment

This harness compiles the production `SessionReaderView`, `HistoryMarkdownView`, and `MacTheme` with existing Xcode Debug package objects. It creates an isolated `ReaderQA-<label>.app` under `.scratch/mac-performance`; it does not launch VibeBuddy, bind a port, or read user transcripts. The fixture is 152 synthetic Markdown messages containing prose, mixed Chinese/English text, lists, code, quotes, and tables.

Build the existing Xcode Debug packages first. Save the original reader before editing it, then build both variants against the same package artifacts:

```sh
python3 tools/mac-performance-qa/reader-build.py baseline --reader-source .scratch/mac-performance/SessionReaderView-baseline.swift
python3 tools/mac-performance-qa/reader-build.py eager-window
```

Run each executable separately when compilation has finished. Without arguments, the first message is a search match, retaining all 152 messages. With `--tail`, it opens normally on the newest page. At timer ticks 3 through 8, one new message is appended; tick 12 exits. Logs contain cumulative process CPU time and actual elapsed wall time. The first timer can arrive late if initial rendering blocks the main thread. Compare both modes and the post-append idle interval; do not interpret a delayed timer as a one-second sample.

```sh
.scratch/mac-performance/ReaderQA-baseline.app/Contents/MacOS/ReaderQA
.scratch/mac-performance/ReaderQA-eager-window.app/Contents/MacOS/ReaderQA
.scratch/mac-performance/ReaderQA-baseline.app/Contents/MacOS/ReaderQA --tail
.scratch/mac-performance/ReaderQA-eager-window.app/Contents/MacOS/ReaderQA --tail
```

For native UI acceptance, run the candidate with `--interactive`. The First match, Middle match, Latest, and Append controls exercise search and appended rows. Verify: initial latest positioning; Earlier messages preserves the reading anchor; search lands on its row; appending at the bottom follows; scrolling away and appending preserves position and displays the new-message pill; clicking the pill returns to the newest message. Verify Markdown code/table content and copy controls. This synthetic experiment does not replace acceptance with an actual user conversation.

## Reproduced lazy sentinel regression

The first candidate made the entire outer stack lazy. In the native QA window:

1. Click **Middle match** and confirm Message 75 is visible.
2. Click **Append**. Message 75 stays in place and **1 new message** appears.
3. Click **1 new message** and wait for Markdown layout to settle.
4. Require the last message (Message 152 after one append) and **End of fixture** to be visible.

The first candidate stopped around Messages 145–146 (scrollbar approximately 0.888) and never reached the final row. A faster CPU result does not pass this check. The revised structure keeps the header, tail, and bottom geometry sentinel in an eager outer stack, with only message rows in a `LazyVStack`, so bottom measurements can continue correcting the scroll position as lazy row heights settle. Run this sequence again against the revised candidate, then verify a second append follows while already at the bottom.

## Reproduced earlier-page anchor regression

1. Click **First match**, then **Middle match**. Confirm Message 75.
2. Activate **Show earlier messages** without scrolling to another message.
3. Wait for Markdown layout to settle. Require Message 75 to remain at the same reading position.
4. Scroll to another visible message, append a message, and verify the reading position still stays put.

The nested lazy candidate initially drifted to Messages 66–67 after step 2. Its one-shot `scrollTo` ran before lazy row estimates settled. The next candidate registers message rows with `scrollTargetLayout` and binds the actual visible message through `scrollPosition(id:)`, allowing SwiftUI to preserve the reading position as earlier rows are inserted. The paging handler no longer issues the one-shot estimated scroll.

Reference: [Apple scrollPosition(id:anchor:) documentation](https://developer.apple.com/documentation/swiftui/view/scrollposition(id:anchor:)), available on macOS 14 and newer.

## Selected scope and rejected candidates

The product reader retains its original eager `VStack` and ScrollViewProxy navigation. Its `ReaderWindow` is now initialized before the first body renders, using the newest 30 rows or the requested search range. Previously the zero-sized initial window was immediately grown to the entire transcript before `onAppear` selected the newest page. This is a cold-open improvement; it does **not** solve rendering cost after a user deliberately expands a long conversation.

Rejected candidates:

- Outer `LazyVStack`: synthetic CPU improved, but the new-message pill failed to reach the final message.
- Lazy messages with eager sentinel: bottom navigation passed, but loading earlier messages lost Message 75 and landed around 66–67.
- Nested lazy plus native `scrollPosition`: earlier-page positioning passed, but subsequent append/pill navigation produced a persistent blank reader with only the end marker.

The shared premise was that lazy row heights could be introduced while retaining the existing proxy/geometry navigation. The native position binding added another controller and did not resolve the interaction. `reader-scroll-census.py` records the controllers present in saved candidate sources. None of these lazy candidates is product code.

Build the selected fallback with `reader-build.py eager-window`, compare normal `--tail` opening against baseline, and repeat search, earlier-page positioning, append, and bottom-pill acceptance. Keep the rejected-candidate CPU results labeled as experiments; they do not describe the selected product change.
