# How the APNs provider key reaches the Mac

**Status:** Proposed (awaiting DEC-APNS)

**Ticket:** ready-for-human

**Executor:** cursor-grok-4.6 · 分支 claude/a-11-apns-key-delivery · 2026-09-06 04:12 +0800

DEC-APNS picks exactly one of A / B / C. This ADR compares them. It does not pick.

## Context

Vision Q8 wants the iPhone to get a cue after the app is killed, and wants **no vibebuddy relay**. Q4 is one week with zero missed `needsResponse`. Q1 / Q9 / Q28 then ask the same closed-app push to work for a stranger who downloaded the App Store iPhone app and a GitHub DMG, in ten minutes, without a terminal.

Today the Mac is already an APNs **provider**. `APNsConfig.load()` reads env vars, then `~/Library/Application Support/vibebuddy/apns.json` pointing at a local `.p8`. `APNsJWT` signs a one-hour ES256 JWT and `APNs` POSTs to Apple. Device tokens arrive only after pairing, on the bearer-gated `POST /device`, and live in `DeviceRegistry` (owner-only file, 16 newest). That path is verified for the first user. It is not a stranger path: a new Mac has no key, so `APNsConfig.load()` returns nil and every closed-app cue is `skipped` / `apnsNotConfigured`.

A provider key is team-scoped (or, since 2025, topic-scoped). It authenticates *this team's* apps to APNs. It is not a per-install secret and it is not a configuration value. Anyone who can sign a JWT with it can send a notification to any device token of that topic.

## Codex review on PR #40 — objection and reply

Codex P1 on `docs/planning/vision-2026-09.md` ([thread](https://github.com/semantic-craft/iOS-vibebuddy/pull/40#discussion_r3941010065)), quoted in full:

> Keep the APNs signing key out of the public app
>
> Once 1.2 is distributed publicly, any downloader can extract this bundled `.p8`; it is the private provider credential used to sign APNs JWTs (`VibeBuddyMac/Sources/VibeBuddyMacCore/APNsJWT.swift:4-23`), not configuration whose exposure can be addressed by a privacy notice. Anyone who obtains a target device token could then forge pushes, and containment would require revoking and replacing the shared key across every installation. Keep provider signing behind a trusted relay or require credentials controlled by each user rather than making the project key part of the app bundle.

Owner reply on that thread (ec49159): the bundled key is no longer treated as decided; A-11 must compare the three roads below.

**Reply to the P1, still without picking a road.** The extractability claim is correct. A `.p8` inside a signed Mac `.app` or a GitHub DMG is recoverable with `strings` / a resource dump; a privacy notice does not change that. The forge claim is also correct, and it is Apple's own model of the key: the holder can mint provider JWTs for the team's topics. The containment claim is correct: Apple's revoke is fleet-wide, then every Mac must pick up a replacement key. The two alternatives Codex names are roads B and C.

What the P1 does not say, and what a decision still needs:

1. The key alone cannot address a device. APNs requires the device token, an opaque variable-length value that APNs returns to the app (implementations must not validate its length or format). After pairing, that token lives on the owner's Mac in `DeviceRegistry`. It is not guessable. Forging a push therefore needs **key + a victim token**, not the key alone.
2. A forged push can show a banner (including Time Sensitive approval/question chrome). It cannot Approve, Deny, answer, steer, or dispatch. Those routes still need the pairing bearer and a reachable Mac (Q16).
3. Road B is not "each user types their own `.p8` into Settings" for an App Store binary. A stranger's Team ID cannot push to `com.vibebuddy.app`. See B.
4. Apple's docs describe the signer as **your provider server** and say the key must remain private. They do not contain a sentence that bans shipping a `.p8` inside a Mac app. They also do not bless it. See citations.

## What Apple says

Apple's token-auth article is written for a **provider server**, not a distributed client ([Establishing a token-based connection to APNs](https://developer.apple.com/documentation/usernotifications/establishing-a-token-based-connection-to-apns)):

> You need an APNs authentication token signing key to generate the tokens that **your server** uses.
>
> Secure both pieces of information carefully. You use the authentication token signing key to encrypt your JSON tokens, so **this key must remain private to prevent anyone else from generating those tokens**.

The same page: refresh the JWT no more than once per 20 minutes and no less than once per 60; APNs rejects an `iat` older than one hour. That is JWT hygiene, not key-storage guidance.

[Create a private key](https://developer.apple.com/help/account/keys/create-a-private-key) / [Revoke, edit, and download keys](https://developer.apple.com/help/account/keys/revoke-edit-and-download-keys):

> Save this file in a secure place because the key is not saved in your developer account and you won’t be able to download it again.

[Communicate with APNs using authentication tokens](https://developer.apple.com/help/account/capabilities/communicate-with-apns-using-authentication-tokens):

> The signing key doesn’t expire, but can be revoked.
>
> If you suspect a private key is compromised, first create a new private key with APNs enabled. Then, after transitioning to the new key, revoke the old private key.

[Communicating with APNs](https://developer.apple.com/library/archive/documentation/NetworkingInternet/Conceptual/RemoteNotificationsPG/CommunicatingwithAPNs.html) adds that after revoke you should close every connection that used the old key and reconnect.

An Apple engineer on the Developer Forums ([APNS Key Vs Certificate Security](https://developer.apple.com/forums/thread/744412), Jan 2024):

> The concern over the "Key" would be if it escapes, then whomever has obtained it will be able to use it to send notifications to the apps under that team. It is the team's responsibility to protect it, and revoke it if there is a suspicion that it may have escaped.

That 2024 answer also said one key covered every topic on the team. In February 2025 Apple added **topic-specific** keys (one bundle / environment) and environment-restricted team-scoped keys ([announcement](https://developer.apple.com/news?id=wy4tb0uo); same token-auth article). A topic-specific key shrinks a leak to `com.vibebuddy.app` and one environment. It does not stop extraction from a DMG.

Apple's Program License Agreement puts safeguarding of authentication credentials on the team. It does not name `.p8`-in-app-bundle as an allowed exception.

**Read for DEC-APNS:** Apple's intended home for the `.p8` is a provider server the team controls. Shipping it in a public Mac app is a departure from that model. The official text is "keep it private" plus revoke-and-replace, not a Review Guideline that would reject the iPhone app for a Mac-side bundle.

## What similar open-source apps do

Closed-app iOS push always ends at APNs. The only question is who holds the `.p8`.

| Project | Who holds the `.p8` | What the stranger does | Notes |
|---|---|---|---|
| **Bark** (App Store iOS pager) | The Bark team. Self-hosters still sign as Bark's topic. | Install the app; the app registers its device token with `api.day.app` or a self-hosted `bark-server`. | Closest product analogue. The team **publishes** the AuthKey so anyone can reimplement the server: [deploy doc](https://day.app/2018/06/bark-server-document/) links `AuthKey_…p8` on GitHub and prints Team ID / Key ID / topic. Mitigation is a server-side `device_key` alias, not key secrecy. They warn that the raw APNs device token must not leak. Architecture: app → server → APNs. |
| **ntfy** | ntfy.sh / FCM, for the official iOS app. | Use ntfy.sh, or self-host and **upstream** iOS delivery through ntfy.sh. | [ntfy iOS getting-started](https://github.com/binwiederhier/ntfy-ios/blob/main/docs/GETTING_STARTED.md) and [develop](https://docs.ntfy.sh/develop/) treat the APNs AuthKey as something you upload to the push backend (FCM), not something you put in the iPhone app. A self-hosted ntfy without that upstream does not get native APNs for the official app. |
| **UnifiedPush / AeroGear** | The UnifiedPush server the operator configures. | Run or join a distributor. | [iOS variant setup](https://aerogear.github.io/aerogear-unifiedpush-server/docs/variants/ios) asks the **server** for the private key, Key ID, Team ID, Bundle ID. |
| Typical APNs SDK samples | A process the developer runs. | n/a | node-apn and Apple's HTTP/2 samples take a filesystem path to a `.p8` on the provider host. |

No surveyed Mac menu-bar companion ships a *secret* `.p8` and also claims it stays secret after public download. Bark is the mature "the key is public, the device token is the secret, a server sits in the middle" App Store precedent. ntfy / UnifiedPush are the mature "the key never leaves a server the operator runs" precedent. Neither is a LAN-paired Mac holding the key with no extra process.

## Options

### A — Bundled project key + rotation + paired-token-only send + privacy sentence

The Mac app ships a topic-specific (or team-scoped) `.p8` for `com.vibebuddy.app`. `APNsConfig.load()` grows a third source: env, then the Application Support file, then the bundle. Real key material is injected at package time and never committed. The sender only addresses tokens in `DeviceRegistry` (tokens that arrived on a paired `POST /device`). Settings shows the source. `docs/privacy-policy.md` says the Mac uses a project APNs key to notify paired devices via Apple.

**Rotation.** Keep two keys during a leak window (Apple allows two team-scoped keys per environment, or a topic-specific key plus its related key). Sparkle ships a Mac build with the new key; after the fleet has moved, revoke the old one. The iPhone binary does not carry the key and does not need an App Store resubmit for a Mac-only rotation.

**Security surface.** After the first public DMG, the `.p8` is a published credential (Bark's class). Paired-token-only sending is a *sender* filter: our code will not push to a token it did not register. It does not stop a third party who extracted the key and obtained a token elsewhere. Same-user processes on the Mac can already read `DeviceRegistry` and the pairing token (the residual ADR-0009 accepted). A LAN observer without the bearer cannot register a token, but registration itself travels in cleartext: `PushRegistration.upload()` posts the APNs token and the pairing bearer over plain HTTP to `/device` (`VibeBuddyApp/Sources/PushRegistration.swift`), so anyone who can inspect LAN traffic during pairing captures a valid token without needing the bearer. Bearer gating therefore protects the registry from writers, not the token from observers; road A must either accept that exposure or require protected transport for `/device`. A captured token + the published key → forged banners, including Time Sensitive chrome; no remote actions (Q16). Containment is fleet revoke + Mac update. A privacy sentence does not reduce extractability; it only discloses the Apple hop.

**Stranger UX.** Install Mac + iPhone, pair, grant notification permission. No Apple Developer account. Fits Q9 if packaging injects the key.

**Ops.** No server. Cost is a rotation runbook and the packaging secret (not in git). Every leak is a Sparkle event.

### B — Each user brings their own Apple Developer key

Settings (or a first-run file drop) takes the user's Team ID / Key ID / `.p8`. `APNsConfig.load()` stays env-then-file. The project never ships a key.

**Security surface.** Matches Apple's "your server / keep it private": the only `.p8` on a machine is one that user created. A leak is that user's problem; revoke is not fleet-wide. No new process.

**Stranger UX.** A stranger's key cannot push to the App Store / TestFlight binary `com.vibebuddy.app`. The JWT `iss` is *their* Team ID; APNs will not deliver that token to our topic. Making B work for a stranger means they rebuild and sideload the iPhone app under their team ($99/year Developer Program, Xcode, their own App ID and push entitlement). That misses Q1, Q9, and the 1.3 App Store submission. For the first user, B is what already works.

**Ops.** Docs and a file picker. No server. 1.3 cannot promise closed-app push to the public.

### C — Minimal relay

A tiny HTTPS service the project runs holds the `.p8`. The Mac, after pairing, POSTs `{deviceToken, payload}` (or a wake-only payload) with a project or per-install relay credential. The relay signs the JWT and talks to APNs. The Mac never sees the Apple key.

**Security surface.** Matches Apple's provider-server wording. A dumped Mac app no longer yields the `.p8`. The extractable client secret becomes a relay API key, which can be rate-limited, revoked per install, and rotated without Apple. Residual: the relay sees device tokens and, unless the push is a content-free wake, the banner text (project names, approval summaries). An open relay is an abuse / spam platform; it needs auth, quotas, and logs. A silent wake plus fetch-from-Mac does not reliably notify a killed app, so a useful C almost certainly carries cue text.

**Stranger UX.** Same as A if the relay is up: pair and go. If the relay is down, closed-app push is gone for everyone (Q4 risk concentrated on one host).

**Ops.** Contradicts Q8, Q16 ("no vibebuddy cloud"), and ADR-0002's "no vibebuddy server" privacy story. Needs uptime, TLS, a domain, abuse handling, a privacy-policy rewrite ("we operate a server that receives device tokens and notification text"), and someone on the hook when it breaks. A Cloudflare Worker is cheap. It is still a server.

## Comparison

| | A bundled key | B per-user Developer key | C minimal relay |
|---|---|---|---|
| Who holds the `.p8` | Every Mac install, after first public DMG | Only that user | Project-operated host |
| Matches Apple "provider server / keep private" | No. Mitigations limit use, not possession | Yes, for that user | Yes |
| Codex P1 | Objects; this is the road it rejected | One of the two roads it named | The other road it named |
| Forged push given a stolen device token | Yes, by anyone who dumped the DMG | Only with that user's key | Only with relay credentials or a relay breach |
| Revoke blast radius | All installs; Sparkle must land a new key | One user | Relay-only; Macs keep working after a key swap |
| Stranger, App Store iPhone, 10 minutes, no terminal (Q9) | Yes, if packaging injects the key | No — cannot push to our bundle ID | Yes, if the relay is up |
| Q8 "no vibebuddy relay" | Holds | Holds | Breaks; needs an explicit Q8 amendment |
| ADR-0002 / privacy story | Disclose Apple hop; still "no vibebuddy server" | Same as today | We operate a server |
| Ops cost | Packaging secret + rotation runbook | Docs / file picker | Host, TLS, auth, abuse, on-call |
| Closest cited precedent | Bark publishes the key (but still runs a server as token registry) | Current first-user setup | ntfy / UnifiedPush |

## Effect on 1.2 and 1.3

1.2 is GitHub / self-install, first user is the owner, success bar is Q4. 1.3 is the stranger path and the App Store submit (Q28).

| | 1.2 (owner, GitHub) | 1.3 (stranger + App Store) |
|---|---|---|
| **A** | Closed-app push works without a file drop. Owner file/env still overrides. A-12 is load-order + packaging + Settings source + one privacy sentence. Q8's *goal* holds; the *means* become "published key + paired tokens". | Q9 closed-app push is possible. App Store review sees an iPhone app that uploads a device token to the user's Mac; the `.p8` is not in the iPhone binary. |
| **B** | No product change. Owner keeps the existing file. 1.2 can still meet Q4 for the first user. | Closed-app push cannot be promised to the public. Q8's README line becomes "if you bring a Developer key and sideload", which fails Q9 and fights Q1. A-12 shrinks to a Settings file picker. |
| **C** | 1.2 either waits on standing up the relay, or the owner keeps the file and C slips to 1.3. A down relay during the zero-miss week is a Q4 miss for everyone. | Stranger path works without a Developer account, at the price of amending Q8 and rewriting the privacy policy before submit. |

A-12 implements whichever row DEC-APNS accepts. S-4 (`DeviceRegistry`) is already the token allow-list A relies on; it does not choose a key source.

## Migration sketches

Not implementation. A-12 writes the ticket and the code after DEC-APNS.

**A.** `APNsConfig.load()` = env → Application Support file → bundled key. Packaging script copies a CI/local secret into the `.app` Resources (or a sealed data file); repo keeps a placeholder and a "do not commit" note. Sender already iterates `DeviceRegistry`; keep that as the only destination, including after 410 / never-accepted 400. Settings APNs row prints `env` / `file` / `bundled`. Privacy policy: one sentence that the Mac uses a project APNs key to notify paired phones through Apple. Runbook: issue a topic-specific replacement key, ship Mac via Sparkle with both accepted, revoke the old. Never put the `.p8` in git.

**B.** Leave `load()` as env → file. Settings grows a `.p8` picker and Team / Key fields (Keychain or the existing json). README / first-run: this is for people who rebuild the iPhone app under their team; the App Store binary will not accept their JWT. No packaging secret.

**C.** New small service (Worker or single VPS): auth, rate limit, APNs forward, no accounts. Mac Settings: relay URL + API key, defaulting to the project host. `APNs` client talks to the relay, not to `api.push.apple.com`. `.p8` lives only on the host. Privacy policy and Q8 text change before 1.3 submit. Owner file-based send can remain as a "don't use the relay" escape.

## Decision

Not taken. DEC-APNS writes the choice and the reason here, sets **Status: Accepted**, and leaves exactly one option in force.

## Comments

- **Executor:** cursor-grok-4.6 · 分支 `claude/a-11-apns-key-delivery` · 2026-09-06 04:12 +0800 — claimed A-11; ADR written as Proposed, no implementation.
- 2026-09-06: research via Tavily + Apple / Bark / ntfy / UnifiedPush primary pages (URLs above). Did not read or print any project `.p8`. Docs only; Ticket `ready-for-human` because DEC-APNS is the owner decision. Not `done`: the ADR is Proposed until that decision.
