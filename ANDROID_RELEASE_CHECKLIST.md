# Android Release & Physical-Device Verification Checklist (Moto G32 — Android 13)

## 1. Build Verification (Completed on Host)

- **Artifact**: `build/app/outputs/flutter-apk/app-release.apk`
- **Build Command**:
  ```powershell
  flutter build apk --release --dart-define=AGENT_BASE_URL=https://dont-miss-backend.onrender.com
  ```
- **Size**: `57,895,991` bytes (`55.2 MB`)
- **SHA-1**: `4f8f00b886d1e7d87849fafb3b82200b48db4a4c`
- **Package ID / Signing (`android/app/build.gradle.kts`)**: `com.example.dont_miss`, signed with `debug` signingConfig (suitable for USB/sideload QA; replace with an upload/release keystore before Google Play distribution).
- **Manifest Permissions Declared (`android/app/src/main/AndroidManifest.xml`)**:
  - `android.permission.INTERNET`
  - `android.permission.RECEIVE_BOOT_COMPLETED`
  - `android.permission.VIBRATE`
  - `android.permission.POST_NOTIFICATIONS`
  - `android.permission.SCHEDULE_EXACT_ALARM`
  - `android.permission.USE_EXACT_ALARM`
  - `android.permission.RECORD_AUDIO`

---

## 2. Pre-Test Deployment Prerequisites (**CRITICAL**)

Before expecting full end-to-end token refresh and timezone parity against `https://dont-miss-backend.onrender.com`, ensure the updated `agent/` backend and Postgres migration are deployed:

1. **PostgreSQL Column Migration**: Verify `completed_at` exists on `reminders` (automatically handled idempotently by `init_db()` on boot, or via `ALTER TABLE reminders ADD COLUMN IF NOT EXISTS completed_at TIMESTAMP WITH TIME ZONE;` in `agent/database/schema.sql`).
2. **Render Environment Variables (`render.yaml`)**: Confirm `DATABASE_URL`, `JWT_ACCESS_SECRET`, `OPENAI_API_KEY`, `OPENAI_MODEL=gpt-4o-mini`, `TWILIO_ACCOUNT_SID`, `TWILIO_AUTH_TOKEN`, `TWILIO_WHATSAPP_NUMBER` are set in Render. Note `PyJWT>=2.9.0` is now listed in `agent/requirements.txt`.
3. **Verify `/auth/refresh` on Render**: After deploying backend changes, confirm `POST https://dont-miss-backend.onrender.com/auth/refresh` returns HTTP `400` (`Refresh token is required.`) rather than `404`.
4. **Cold-Start Awareness**: Render Free (`plan: free` in `render.yaml`) spins down after inactivity and was observed timing out at `30s` on first wake-up. The Android APK now allows up to `60s` TCP connect / `180s` total request timeout on AI endpoints and `60s` on auth/sync/dispatch.

---

## 3. Install APK on Moto G32 (Android 13)

```powershell
adb devices
adb install -r build\app\outputs\flutter-apk\app-release.apk
```

If an older APK with a different signing certificate was previously installed, run `adb uninstall com.example.dont_miss` first.

---

## 4. Physical-Device Acceptance Tests (**All Currently `UNVERIFIED` on Hardware**)

Mark each check `[x]` only after running on the physical Moto G32 (Android 13):

### A. Permissions & App Startup
- [ ] **Android 13 Notification Permission**: Launch app, sign in -> confirm system prompt asks `"Allow Don't Miss to send you notifications?"` (`POST_NOTIFICATIONS`) and accept.
- [ ] **Exact Alarm Permission (`SCHEDULE_EXACT_ALARM` / Alarms & Reminders)**: Verify exact alarm permission status in Android Settings -> Apps -> Don't Miss -> Alarms & reminders.
- [ ] **Cold-Start AI Wake Test**: After Render has been idle, submit an AI prompt and verify the app waits >15s cleanly without dropping into offline local fallback prematurely.

### B. Mobile AI Text Input
- [ ] Enter: `"Remind me tomorrow at 9 AM to send my resume to my lecturer."`
  - Expect: Tomorrow's date, `9:00 AM`, structured title & details in confirmation sheet, NO reminder saved until tapping `Confirm & Add`, reminder saved locally & synced to cloud after confirmation.
- [ ] Enter multi-task prompt: `"Today I have a hackathon at 10 AM. Tomorrow is my friend's birthday at 9 AM. Friday, submit my assignment at 6 PM."`
  - Expect: 3 independent reminder cards rendered **all visually checked by default**, toggling 1 unchecks only that card, tapping `Confirm Selected` saves chosen items once without duplicate cloud sync rows.

### C. Voice Recording & Transcription on Moto G32 Microphone
- [ ] Tap microphone icon -> verify Android 13 runtime `RECORD_AUDIO` permission dialog appears on first tap; grant permission.
- [ ] Verify Deny path -> cleanly shows `"Microphone permission is required..."` banner without crashing or falsely pretending audio succeeded.
- [ ] Speak: `"Remind me tomorrow at 9 AM to send my resume and mention my project experience."` -> stop recording -> verify `"Transcribing..."` loading indicator -> transcript populates editable text box -> edit if desired -> generate draft (`Title`: Send my resume, `Description`: Mention my project experience, `Date`: Tomorrow, `Time`: `9:00 AM`) -> confirm & save.
- [ ] Cancel recording mid-recording -> verify UI resets cleanly and no empty draft/error persists.

### D. Notifications, Sync & Account Isolation
- [ ] Schedule a reminder for 2 minutes in the future, lock screen / background app, and confirm local notification fires on Moto G32 at exact scheduled time (`FlutterTimezone` device local timezone, including `Asia/Calcutta` -> `Asia/Kolkata` normalization).
- [ ] Complete or delete a reminder on Web (or second device), trigger sync on Moto G32 -> confirm cloud state propagates and cancelled/completed reminder alarm does not fire.
- [ ] Sign out (`Account -> Sign Out`) and sign in with a second account -> verify zero tasks leak from the first account, local `SharedPreferences` task & tombstone caches are clean, and prior account notifications were cancelled.
- [ ] Wait for token expiry or test with invalid/expired stored access token (once Render `/auth/refresh` is deployed) -> verify seamless silent refresh or clean redirect to `SignInScreen` with session-expired banner (no stuck `401` loop).
