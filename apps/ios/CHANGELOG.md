# OpenClaw iOS Changelog

## 2026.4.27 - 2026-04-27

Maintenance update for the current Iànua development release.

- Iànua Realtime now opens its session as soon as the voice screen appears instead of waiting for the microphone tap: the token mint and the OpenAI connection, about 2.3 seconds, are paid while you are still looking at the screen (build 10). The anticipated session never turns the microphone on early, expires on its own if unused, and is not reopened every time you switch apps.
- Iànua Realtime now shows a visible loading indicator while connecting and only reports itself as ready once the realtime session actually exists (build 9).
- Fixed the Iànua chat clearing itself after sending a message: the conversation now stays put instead of blanking out (build 9).
- Added CarPlay support: incoming and outgoing Iànua calls now appear on the car display, with the tenant directory and the Spock voice control.
- Chat channel separators now follow the layout the server sends, so the phone shows the same sections as the web panel.
- Removed the Groups section from chat, matching the web panel.
- The activation QR now delivers the SIP configuration together with the session, so a freshly activated device is ready to make calls.
- Added one-shot QR device activation: scan the activation code from any screen, in or out of the app, and Iànua opens the activation screen and waits for your confirmation before enabling anything (build 5).
- Fixed chat bubble alignment: your own messages are now identified by operator role instead of user id, so they no longer appear on the wrong side of the conversation (build 5).
- Completed the de-branding of the visible texts, including the system permission prompts (build 5).
- Reduced the Authenticator action-summary font for a more compact two-digit approval card.
- Restored the native Iànua SIP contract so the phone can retrieve its configuration and DND state through the authenticated mobile routes.
- Restored the tenant-bound internal directory and suppressed false “call failed” banners after a SIP call had already connected successfully.
- Routed Iànua Realtime through the authenticated public Iànua gateway, removing the iPhone dependency on a private Tailscale route.
- Added explicit connection feedback and startup timing telemetry to Iànua Realtime.
- Prevented Iànua Realtime from crashing while rebuilding or tearing down its audio graph by tracking microphone and playback taps explicitly.
- Recovered cleanly from revoked Iànua sessions returned as either 401 or 403: Chat now returns to login, SIP reports that access is required, and Realtime rejects stale private endpoint overrides instead of showing unrelated configuration errors.
- Redesigned the Authenticator approval card: the action summary and match-code entry are front and center, while technical context (tenant, environment, audience, initiator device, request hash) moved into a collapsed Details section (build 93).
- Tapping an Iànua "Sblocco richiesto" push now opens the Authenticator screen directly, including when the app is connected to the gateway and the push arrives as a local notification (build 90).
- Rebranded the mobile app experience as Iànua, including app and extension display names, Iànua app icons, and the phone screen mark.
- Added presence status in the native Linphone phonebook: registered and free, not registered, busy, and DND.
- Added the complete native Iànua chat, including agents, channels, groups, replies, reactions, pins, attachments, voice messages, and protected secrets.

## 2026.4.26 - 2026-04-26

Maintenance update for the current OpenClaw development release.

- Refreshed build hygiene for the iOS app, Share extension, Activity widget, Watch app, and curated shared Swift sources; relay registration now uses StoreKit app transaction JWS data instead of deprecated receipt APIs.

## 2026.4.25 - 2026-04-25

Maintenance update for the current OpenClaw development release.

## 2026.4.23 - 2026-04-23

Maintenance update for the current OpenClaw development release.

## 2026.4.22 - 2026-04-22

Maintenance update for the current OpenClaw development release.

## 2026.4.21 - 2026-04-21

Maintenance update for the current OpenClaw development release.

## 2026.4.20 - 2026-04-20

Maintenance update for the current OpenClaw release.

## 2026.4.19 - 2026-04-19

Maintenance update for the current OpenClaw beta release.

## 2026.4.18 - 2026-04-18

Maintenance update for the current OpenClaw release.

## 2026.4.15 - 2026-04-15

Maintenance update for the current OpenClaw beta release.

## 2026.4.14 - 2026-04-14

Maintenance update for the current OpenClaw beta release.

## 2026.4.12 - 2026-04-12

Maintenance update for the current OpenClaw release.

## 2026.4.10 - 2026-04-10

Maintenance update for the current OpenClaw release.

## 2026.4.6 - 2026-04-06

First App Store release of OpenClaw for iPhone. Pair with your OpenClaw Gateway to use chat, voice, sharing, and device actions from iOS.
