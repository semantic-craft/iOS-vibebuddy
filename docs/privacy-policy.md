# vibebuddy — Privacy Policy

_Last updated: 2026-06-06_

vibebuddy ("the app") is a companion to the vibebuddy Mac application. We designed it to keep your data on your own devices.

> **Hosting note (delete before publishing):** drop this file on any public URL (e.g. GitHub Pages renders Markdown directly), then paste that URL into App Store Connect → App Privacy → Privacy Policy URL. Fill the **contact email** placeholder below first.

## What the app accesses

- **Local network:** the app connects directly to the vibebuddy Mac app running on your own Mac, over your local network, to display session status and send your approve/deny decisions. This data is exchanged only between your iPhone and your Mac.
- **Camera:** used solely to scan the pairing QR code shown by the Mac app. No images are stored or transmitted.
- **Push notifications:** if you enable notifications, Apple issues a device token that the app sends to your Mac app so it can notify you when a session needs attention. The token is used only for this purpose.
- **Microphone & voice (optional):** the voice companion is **off until you add your own API key**. When you use it, your speech is streamed over an encrypted connection **directly to the AI provider you choose** — OpenAI, Google (Gemini), or Alibaba (DashScope / Qwen) — authenticated with **your own key**, which is stored only in your device Keychain. That audio is processed by the chosen provider under **their** privacy policy and your account with them; it does **not** pass through any vibebuddy server. The app is fully usable without ever enabling voice.

## What we do NOT do

- We do not operate servers that receive your session data or your voice audio; there is no vibebuddy cloud account.
- We do not collect analytics, advertising identifiers, or location.
- We do not sell or share your data with third parties. (The optional voice companion sends your audio to the provider you choose, using your own key, at your initiative and to your own account — we never receive or store it.)
- We do not track you across apps or websites.

## Data retention

Pairing details (your Mac's address and access token) are stored locally on your device and removed when you disconnect.

## Contact

<your email — replace before publishing>
