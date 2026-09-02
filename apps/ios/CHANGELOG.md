# OpenClaw iOS Changelog

## 2026.4.27 - 2026-04-27

Maintenance update for the current OpenClaw development release.

- Restored the native Iànua SIP contract so the phone can retrieve its configuration and DND state through the authenticated mobile routes.
- Restored the tenant-bound internal directory and suppressed false “call failed” banners after a SIP call had already connected successfully.
- Routed Iànua Realtime through the authenticated public Iànua gateway, removing the iPhone dependency on a private Tailscale route.
- Added explicit connection feedback and startup timing telemetry to Iànua Realtime.
- Redesigned the Authenticator approval card: the action summary and match-code entry are front and center, while technical context (tenant, environment, audience, initiator device, request hash) moved into a collapsed Details section (build 93).
- Tapping an Ianua "Sblocco richiesto" push now opens the Authenticator screen directly, including when the app is connected to the gateway and the push arrives as a local notification (build 90).
- Rebranded the mobile app experience as Ianua, including app and extension display names, Ianua app icons, and the phone screen mark.
- Added presence status in the native Linphone phonebook: registered and free, not registered, busy, and DND.
- Added the complete native Iànua chat, including direct conversations with tenant colleagues, agents, channels, groups, replies, reactions, pins, attachments, voice messages, and protected secrets.

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
