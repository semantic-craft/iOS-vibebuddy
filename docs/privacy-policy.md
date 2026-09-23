# vibebuddy — Privacy Policy

_Last updated: 2026-09-15_

vibebuddy ("the app") is a companion to the vibebuddy Mac application. We designed it to keep your data on your own devices.

## What the app accesses

- **Local network:** the app connects directly to the vibebuddy Mac app running on your own Mac, over your local network, to display session status and send your approve/deny decisions. This connection is between your iPhone and your Mac. If you use the Apple Watch companion, the paired iPhone relays task status, supported approval requests, and usage information to the Watch through Apple WatchConnectivity. Supported Watch actions are relayed back through the iPhone; the Watch does not connect directly to your Mac or receive its pairing token.
- **Camera:** used solely to scan the pairing QR code shown by the Mac app. No images are stored or transmitted.
- **Push notifications:** if you enable notifications, Apple issues a device token that the app sends to your Mac app so it can notify you when a session needs attention. The token is used only for this purpose.
- **Microphone & voice (optional):** the voice companion is **off by default**. It only starts after you choose a provider — OpenAI, Google (Gemini), Alibaba (DashScope / Qwen), or Volcengine (Doubao) — enter your own provider API key, accept the in-app disclosure, grant microphone permission, and tap again to start a voice conversation. When you use it, your microphone audio and selected session context (project names, agent type, status, and optional summaries) are streamed over an encrypted connection **directly to the provider you choose**, authenticated with **your own key**, which is stored only in your device Keychain. That data is processed by the chosen provider under **their** privacy policy and your account with them; it does **not** pass through any vibebuddy server. The app is fully usable without ever enabling voice.

- **Summaries and read-aloud (optional):** your Mac sends the relevant task text and selected content-style prompt directly to its configured language-model provider to generate notifications, spoken scripts or recaps. iPhone can read and update the connected Mac's content style; it does not receive the Mac's provider key. For cloud read-aloud, the phone sends the spoken script directly to the speech provider configured on that phone and receives synthesized audio. System speech uses the operating system's speech engine without a cloud speech-provider request from VibeBuddy. Read-aloud does not start the microphone. Provider processing and retention follow your chosen providers' terms; provider charges may apply.

## What we do NOT do

- We do not operate servers that receive your voice audio or voice-companion session context; there is no vibebuddy cloud account.
- We do not collect analytics, advertising identifiers, or location.
- We do not sell your data. Enabled notifications use Apple's push service, and optional model and speech requests go directly to your configured providers. VibeBuddy operates neither service and receives neither payload.
- We do not track you across apps or websites.

## Data retention

Pairing details (your Mac's address and access token) are stored locally on your iPhone and removed when you disconnect. The Apple Watch companion stores its last received task snapshot locally so it can show the last known state after restarting, together with freshness and connection information. This snapshot is replaced as new state arrives and is not sent to a vibebuddy server.

## Contact

Open an issue at https://github.com/semantic-craft/iOS-vibebuddy/issues
