# Release Plan — Autorota App Store

First ship target: **iOS/iPadOS** (macOS to follow later).

## Status — already in place ✓

| Item | State |
|------|-------|
| Bundle ID | `com.toadmountain.autorota` |
| Development Team | `34VGHNCG6J` (Apple Developer account exists) |
| Version / build | `1.0` / `1` |
| Signing | Automatic |
| App Sandbox | ON (required for Mac App Store) |
| Entitlements | iCloud + CloudKit, keychain access group |
| App icons | `AppIcon` + Jazz/Latte variants present |
| Privacy manifest | `PrivacyInfo.xcprivacy` — no tracking; UserDefaults (CA92.1) + FileTimestamp (C617.1) reasons declared |
| Export options | `ExportOptions-MacAppStore.plist` already written |

Build is release-shaped. Remaining work is App Store Connect + metadata + archive/upload.

## You must do (interactive — cannot be automated)

1. **Confirm Apple Developer Program active & agreements signed** — App Store Connect → Agreements, Tax, and Banking must show "Active." Nothing uploads otherwise.
2. **Register App ID + capabilities** — `com.toadmountain.autorota` needs iCloud + CloudKit matching entitlements. **Deploy CloudKit schema to Production** (CloudKit Dashboard → Deploy Schema Changes). #1 silent failure: dev schema works locally but prod sync breaks for real users.
3. **Create app record** in App Store Connect (name, language, bundle ID, SKU). iOS-only for now — don't enable macOS destination yet.
4. **Metadata & assets** — description, keywords, support URL, **hosted privacy policy URL** (required), category, age-rating questionnaire, App Privacy data-collection answers (collect none → trivial), **screenshots** (6.9" iPhone + 13" iPad minimum).
5. **Export compliance** — HTTPS-only (frankfurter API) qualifies for exemption.
6. **Bump build number, archive, validate, upload, submit for review.**

## I can do in repo

- Add `INFOPLIST_KEY_ITSAppUsesNonExemptEncryption = NO` (project uses generated Info.plist) — kills export-compliance prompt every upload.
- Bump `CURRENT_PROJECT_VERSION` per upload.
- Run **archive + validate dry-run** for iOS to catch signing/entitlement/icon errors before touching App Store Connect — highest-value early check.

## Notes / flags

- **No standalone `Info.plist`** — project uses `GENERATE_INFOPLIST_FILE`; encryption key goes in as a build setting (`INFOPLIST_KEY_*`), not a plist edit.
- **iOS+macOS unified target** under one bundle ID. Shipping iOS-only is fine — just leave the macOS destination off the App Store Connect record for now.

## Next action

Add the encryption key, then run the iOS archive + validate dry-run.
