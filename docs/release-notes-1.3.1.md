# VibeBuddy 1.3.1 — macOS

This update fixes Grok and Cursor account usage reporting.

- Grok usage recovers when the CLI returns a billing period without a percentage. Missing data is shown as unavailable, and an expired weekly reading no longer appears as the current quota.
- Cursor can use the existing Cursor app login. Cursor Models and Other Models remain separate included-usage pools; extra spending is not substituted for either pool.
- Browser-cookie import handles timeouts and manual fallback correctly, preserves existing Keychain values on failed writes, and matches cookie domains precisely.

Mac companion version 1.3.1 (8), for Apple Silicon Macs running macOS 14 or later. The download is Developer ID signed and notarized by Apple.

This release updates the Mac companion only. Existing iPhone and Watch compatibility gates remain in place, including the Cursor quota transport gate for shipped phone clients. It does not publish a new iPhone or Watch build. Public downloads do not include APNs provider credentials.
