# VibeBuddy 1.3.2 — macOS

Cursor usage now supports the official Cursor CLI login without requiring the Cursor desktop app.

- Select **Cursor CLI login** in Settings → Usage → Login source to use the account signed in through `cursor-agent login`.
- Cursor Models and Other Models retain their separate usage percentages and billing reset date.
- CLI credential reads have an eight-second timeout and support cancellation. Missing or expired CLI credentials do not fall back to another account. Credentials are never refreshed, copied to storage, or logged.

Mac companion version 1.3.2 (9), for Apple Silicon Macs running macOS 14 or later. The download is Developer ID signed and notarized by Apple.

This release updates only the Mac companion; it does not publish an iPhone or Watch build or change their quota transport compatibility gates.
