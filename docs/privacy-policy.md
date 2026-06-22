# vibebuddy — Privacy Policy

_Last updated: 2026-06-06_

vibebuddy ("the app") is a companion to the vibebuddy Mac application. We designed it to keep your data on your own devices.

## What the app accesses

- **Local network:** the app connects directly to the vibebuddy Mac app running on your own Mac, over your local network, to display session status and send your approve/deny decisions. This data is exchanged only between your iPhone and your Mac.
- **Camera:** used solely to scan the pairing QR code shown by the Mac app. No images are stored or transmitted.
- **Push notifications:** if you enable notifications, Apple issues a device token that the app sends to your Mac app so it can notify you when a session needs attention. The token is used only for this purpose.
- **Microphone & voice (optional):** the voice companion is **off by default**. It only starts after you choose a provider — OpenAI, Google (Gemini), or Alibaba (DashScope / Qwen) — enter your own provider API key, accept the in-app disclosure, grant microphone permission, and tap again to start a voice conversation. When you use it, your microphone audio and selected session context (project names, agent type, status, and optional summaries) are streamed over an encrypted connection **directly to the provider you choose**, authenticated with **your own key**, which is stored only in your device Keychain. That data is processed by the chosen provider under **their** privacy policy and your account with them; it does **not** pass through any vibebuddy server. The app is fully usable without ever enabling voice.

## What we do NOT do

- We do not operate servers that receive your voice audio or voice-companion session context; there is no vibebuddy cloud account.
- We do not collect analytics, advertising identifiers, or location.
- We do not sell or share your data with third parties. (The optional voice companion sends your microphone audio and selected session context to the provider you choose, using your own key, at your initiative and to your own account — we never receive or store it.)
- We do not track you across apps or websites.

## Data retention

Pairing details (your Mac's address and access token) are stored locally on your device and removed when you disconnect.

## Contact

Open an issue at https://github.com/semantic-craft/iOS-vibebuddy/issues
