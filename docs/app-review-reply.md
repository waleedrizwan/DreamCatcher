# App Review reply: Guideline 2.1 Information Needed (1.0.0 build 2)

Paste the text below into the App Store Connect reply. Also paste it into
App Review Information → Notes. Attach the screen recording to the reply.
Notes holds text only, so if you want the video available on later submissions too, add a link to it there.

---

Hello, and thank you for reviewing Dream Catcher. Here's the information you asked for.

**1. Screen recording**
The attached recording was made on an iPhone 17 running iOS 26.6. It starts at app launch and goes through onboarding and the microphone permission prompt. It then starts a sleep session, plays snoring near the phone, stops the session and opens the night report. After that it plays back a clip and shows History and Settings, then deletes all data from Settings.
Dream Catcher has no accounts, no login, no user-generated content shared with other people, and no paid content or in-app purchases.

**2. Purpose and target audience**
Dream Catcher is a free snore tracker for adults who want to know whether they snore, when, and how much. You put the iPhone on the nightstand, tap Start Sleep Session, and sleep. Snoring is detected overnight on the device. In the morning you get a report with total snoring time, the share of the night it covered, a timeline, an intensity breakdown, and short clips of the loudest episodes to listen to. History shows past nights on a calendar along with week and month trends.
Most people never hear their own snoring. Dream Catcher lets them find out without creating an account or sending any audio off the phone.

**3. Setup and main features**
- No login or demo account is needed.
- Open the app, go through the three onboarding screens, and allow microphone access.
- Tap "Start Sleep Session". Play snoring audio near the phone (any snoring video on another device works).
- Sessions shorter than 5 minutes are thrown away by design, so let it run for more than 5 minutes. Then tap Stop and confirm "End session".
- The night report opens automatically. Tap a clip to play it.
- The History tab has the calendar and trends. Settings has sensitivity (Low/Medium/High), a bedtime reminder, and "Delete all data".
- The app keeps recording while the screen is locked, which is why it declares the `audio` background mode. Recording overnight with the screen locked is the app's only job.

**4. External services**
None. The app makes no network calls. It has no analytics, no crash reporting, no authentication, no payments, no ads and no cloud services. Snore detection uses YAMNet, an open-source audio classification model from Google (Apache 2.0 license). The model is bundled in the app and runs entirely on the device's CPU through Core ML. All data is stored locally in the app's own container.

**5. Regional differences**
None. The app works the same way and has the same content in every region.

**6. Regulated industry / third-party material**
Not applicable. Dream Catcher is a personal sound log and not a medical device. It doesn't diagnose or treat any condition. A disclaimer appears in onboarding, on the Home screen, in the report footer and in Settings. The only third-party material is the YAMNet model, used under the Apache 2.0 license. Its attribution is in the NOTICE file of the app's public source repository (github.com/waleedrizwan/DreamCatcher).

Thank you,
Waleed Rizwan
