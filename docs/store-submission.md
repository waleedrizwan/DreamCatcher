# App Store submission — Dream Catcher (iOS)

Everything App Store Connect will ask for, plus the repo-side settings that
back it. Drafted at M6; the account-side steps can only be done by the
account holder.

## Bundle facts

| Field | Value |
| --- | --- |
| Bundle ID | `com.waleedrizwan.DreamCatcher` |
| Display name | Dream Catcher |
| Category | Health & Fitness (`public.app-category.healthcare-fitness`) |
| Age rating | 4+ (no objectionable content; see the medical note below) |
| Deployment target | iOS 17.0, iPhone only |
| Version / build | `MARKETING_VERSION` 1.0.0 / `CURRENT_PROJECT_VERSION` 1 in `ios/project.yml` |
| Export compliance | `ITSAppUsesNonExemptEncryption = false` in the bundle — no networking, no custom crypto, so the upload question is pre-answered |
| Privacy label | **Data Not Collected** — backed by `PrivacyInfo.xcprivacy` and the absence of any analytics SDK |

## Listing copy

**Subtitle (30 char max)**

> Know how you slept — privately

**Promotional text (170)**

> Put your phone on the nightstand and sleep. In the morning: when you snored,
> how loud, and clips you can play back. All of it stays on your phone.

**Description**

> Dream Catcher turns your iPhone into a nightstand snore tracker. Tap
> Start, put the phone down, and sleep. Overnight it listens and detects
> snoring right on the device. In the morning you get a report of your night:
> total snore time, how much of the night it covered, a timeline of when it
> happened, an intensity breakdown, and short clips of the loudest episodes so
> you can hear it for yourself.
>
> **Everything stays on your phone.** No account, no cloud, no network calls at
> all. Only brief clips of detected snoring are saved — never whole-night
> audio — and those clips are excluded from your backups and deleted
> automatically after 90 days. You can erase everything at any time from
> Settings.
>
> **What you get**
> • Overnight detection that runs while the phone is locked
> • A morning report: snore time, percentage of the night, episode count
> • A timeline showing when snoring happened, and how loud relative to your room
> • Playback of the loudest episodes
> • History with a calendar and week/month trends
> • Low, Medium, and High sensitivity settings
>
> **Honest about what it can't do.** A microphone hears the whole room, so
> Dream Catcher can't tell who — or what — is snoring; a partner, a pet, or
> a fan can end up in your report. Loudness is shown relative to your own
> room's quiet level, not in calibrated decibels.
>
> Dream Catcher is not a medical device. It does not diagnose, treat, or
> monitor any medical condition, including sleep apnea. If you are concerned
> about your sleep or breathing, talk to a physician.

**Keywords (100 char max, comma-separated, no spaces)**

> snore,snoring,sleep,sleeptracker,recorder,nightstand,sleeprecorder,noise,private,offline

Note: never use "apnea", "diagnose", "monitor", or "treatment" in the listing
except inside the disclaimer sentence itself — the phrasing above is the one
approved wording.

## Review notes (paste into App Store Connect)

> Dream Catcher records audio overnight to detect snoring, which is why it
> declares the `audio` background mode: the microphone must keep running while
> the screen is locked for the app to do its only job. Nothing is transmitted —
> the app makes no network calls whatsoever, and all detection runs on-device.
>
> To test: open the app, complete the three onboarding screens, grant
> microphone access, and tap "Start Sleep Session". Play snoring audio near the
> device (any snoring video works). Sessions under two minutes are discarded
> by design, so let it run past two minutes before tapping Stop, then confirm
> the stop. The night report appears automatically.
>
> The medical disclaimer appears in onboarding, on the Home screen, in the
> report footer, and in Settings.

## Screenshots

Required: 6.9" (iPhone 17 Pro Max) and 6.5" display sizes, 3–5 shots each.
Capture from a simulator seeded with a realistic night:

1. Home mid-session ("Listening…", elapsed timer)
2. Night report — stat row and timeline
3. Night report — intensity breakdown and clip list
4. History — calendar month with colored nights
5. History — week trend chart

## Pre-submission checklist

Repo-side (done unless noted):

- [x] App icon (1024pt) in `ios/DreamCatcher/Assets.xcassets/AppIcon.appiconset`
- [x] Accent + launch background colors; `UILaunchScreen` uses `LaunchBackground`
- [x] `ITSAppUsesNonExemptEncryption = false`
- [x] `PrivacyInfo.xcprivacy` with empty collected-data types
- [x] Onboarding with mic-indicator disclosure, partner caveat, disclaimer
- [x] Spike 0 developer UI compiled out of Release (`#if DEBUG`)
- [x] Clips excluded from backup; file protection set to
      `completeUntilFirstUserAuthentication` on DB and clips
- [ ] `DEVELOPMENT_TEAM` filled in `ios/project.yml` (blank until the account exists)

Account-side (the account holder must do these):

- [ ] Apple Developer Program membership ($99/yr)
- [ ] Register bundle ID `com.waleedrizwan.DreamCatcher`, create the App Store
      Connect record
- [ ] **Privacy policy URL** — required even for a local-only app with no
      accounts. Host the text in `docs/privacy-policy.md`.
- [ ] Support URL
- [ ] Upload screenshots, description, keywords, review notes
- [ ] Age rating questionnaire → 4+
- [ ] TestFlight beta before submission (plan M8)
