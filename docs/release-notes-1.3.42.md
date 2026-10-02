# VibeBuddy Mac 1.3.42

Grok Build monitoring now shows its connection status even when no task has
arrived. Agent setup reports whether monitoring is disabled, waiting for
activity, connected, or needs configuration repair, with a retry action and
Grok `/hooks` → `r` reload guidance.

Discovered Grok projects appear separately from real tasks, so they stay
visible without increasing the task count. The same status is sent to
VibeBuddy iPhone 1.3.34 and later through the existing WebSocket connection.
