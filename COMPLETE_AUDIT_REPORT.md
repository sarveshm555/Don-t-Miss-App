# Don't Miss — Complete Engineering Audit Report

## 1. Executive Summary & Scope

This report documents the end-to-end engineering audit, root-cause diagnosis, implemented repairs, and verification status of **Don't Miss** (`com.example.dont_miss`), an AI-powered personal reminder application following the core architectural invariant:

> **AI proposes. Human decides. Application executes.**

No reminder is persisted to PostgreSQL/local storage or dispatched via local notifications/WhatsApp prior to explicit user confirmation.

### Live Deployment vs. Local Workspace Parity (Observed)

Read-only inspection of the live production deployments against the local workspace established the following critical boundary:

- **Production Backend (`https://dont-miss-backend.onrender.com`)**:
  - Health endpoint (`GET /health`) returned HTTP `200`: `{"status":"healthy","ai_provider":"openai","model":"gpt-4o-mini","database":"connected","configured":true}` once warm. Cold start timed out at `30s` on first probe.
  - OpenAPI inspection (`/openapi.json`) verified live routes: `/action/confirm`, `/agent/reminder`, `/agent/reminders/batch`, `/agent/reminders/plan`, `/agent/voice/transcribe`, `/auth/me`, `/auth/signin`, `/auth/signout`, `/auth/signup`, `/auth/verify-phone`, `/health`, `/reminders`, `/reminders/{reminder_id}`, `/webhooks/twilio/whatsapp`.
  - **Gap**: `/auth/refresh` is implemented in the local workspace (`agent/routes/auth_routes.py`) and verified in tests, **but is NOT yet deployed on Render** (live requests return HTTP `404`). Likewise, local backend fixes in `agent/` are uncommitted/undeployed on Render (`render.yaml` deploys from branch `main`).
  - **Live Auth & AI Probing**: Unauthenticated `POST /agent/reminders/plan` and `POST /agent/reminder` returned valid structured `PROPOSED` JSON when warm. Sending an invalid/expired `Authorization: Bearer` header to `POST /agent/reminders/plan` returned **HTTP `401`** (`get_current_user_optional` strictly rejects malformed/expired Bearer tokens). Probing `POST /agent/voice/transcribe` with a synthetic 4-byte test file reached the endpoint and upstream OpenAI client (returning HTTP `502`).
- **Production Web (`https://dont-miss-five.vercel.app`)**:
  - Returned HTTP `200`. Inspecting compiled `main.dart.js` URLs confirmed it targets `https://dont-miss-backend.onrender.com`, was built from an older client snapshot referencing only `/agent/reminder`, `/auth/signin`, `/auth/signout`, and `/auth/signup` (without `/agent/reminders/plan`, `/auth/refresh`, or sending `Authorization` to `/agent/reminder`), explaining the divergence between Web and Mobile failures.

---

## 2. Root-Cause Findings by Subsystem

### 2.1 Why Mobile AI Text Input Failed While Web Worked

| Cause | Layer | Technical Mechanism | Evidence |
| :--- | :--- | :--- | :--- |
| **15-second TCP handshake timeout on Render Free cold starts** | Flutter IO HTTP Transport | `IoAgentHttpTransport._createClient` set `client.connectionTimeout = const Duration(seconds: 15)`. Render Free tier cold starts observed at `>30s` aborted TCP/TLS setup with `SocketException` before HTTP response, causing `StrandsAgentApiService` to fall back to `LocalAiReminderService` (which lacks weekday/clause/multi-reminder intelligence). Meanwhile `HtmlAgentHttpTransport` on Web delegates to browser XHR with the full `180s` timeout. | `lib/services/agent_http_transport_io.dart`, live Render `/health` `30s` timeout probe |
| **Unwired token refresh & stale JWT `401` loop on mobile** | Flutter Auth / AI / Dispatch | Backend `get_current_user_optional` returns HTTP `401` whenever any expired/invalid `Authorization: Bearer` header is sent. Local `AuthGate` / `TaskProvider` / `AiConfirmationSheet` / `AddEditTaskScreen` had never wired `tokenRefresher: auth.refreshSession` or `onSessionExpired: auth.handleSessionExpired` into `StrandsAgentApiService`, `BackendActionDispatchService`, or `ReminderSyncService`, and `ApiAuthService.getCurrentUser()` returned cached `UserProfile` without validating JWT `exp`. Meanwhile older deployed Web `main.dart.js` did not attach `Authorization` to `/agent/reminder`. | `lib/widgets/auth_gate.dart`, `lib/services/auth_service.dart`, `lib/providers/task_provider.dart`, live Render `401` probe |
| **Chunked transfer & missing response lifecycle timeout** | Flutter IO HTTP Transport | `IoAgentHttpTransport._send` used `request.write(jsonEncode(payload))` without explicit UTF-8 byte encoding or `Content-Length`, and `.timeout(timeout)` wrapped only `request.close()`, leaving body stream reads unguarded. `AuthService` and `ReminderSyncService` also used `15s` timeouts. | `lib/services/agent_http_transport_io.dart`, `lib/services/auth_service.dart`, `lib/services/reminder_sync_service.dart` |
| **Mobile multi-draft UI checked `draft.id` instead of `draft.draftId`** | Flutter UI | `AiConfirmationSheet` checked `_selectedDraftIds.contains(draft.id)`. Because AI proposals arrive with `id == null` (`_selectedDraftIds` stores `draft.draftId`), every extracted batch item visually rendered unchecked and struck-through despite being selected. | `lib/widgets/ai_confirmation_sheet.dart` |
| **Desktop batch dispatch omitted by `AuthGate` & local/cloud ID mismatch** | Flutter Integration | `AuthGate` did not construct or pass `actionDispatchService` to `HomeScreen`, causing desktop batch confirmations to bypass `/agent/reminders/batch`. Mobile/desktop confirmation assigned UUIDs inconsistently relative to cloud dispatch. | `lib/widgets/auth_gate.dart`, `lib/screens/home_screen.dart`, `lib/widgets/ai_confirmation_sheet.dart` |
| **Global `proposal_tracker` concurrency hazard** | Python AI Agent | `ReminderAgent.process_prompt_async` mutated module-global `proposal_tracker` (`agent/tools/reminder_tools.py`), risking proposal cross-contamination across overlapping async OpenAI calls. `_extract_fallback_proposal` also hardcoded `"Asia/Kolkata"` and bypassed `_is_in_past`. | `agent/tools/reminder_tools.py`, `agent/reminder_agent.py` |
| **OpenAI client missing explicit network timeout & CORS mismatch** | Backend Config | `OpenAI` / `AsyncOpenAI` lacked explicit `timeout=60.0`; FastAPI `CORSMiddleware` paired `allow_origins=["*"]` with `allow_credentials=True` (invalid wildcard+credential combination). | `agent/providers/openai_provider.py`, `agent/app.py` |

### 2.2 Why Voice Input Failed on Android

| Cause | Technical Mechanism | Evidence |
| :--- | :--- | :--- |
| **Unwritable temp path on Android (`Directory.systemTemp`)** | `path_provider` was absent from `pubspec.yaml`. `IoVoiceRecordingPlatformHelper.prepareRecordingPath` wrote to `Directory.systemTemp.path`, which resolves to non-writable `/data/local/tmp` on Android instead of app-private temporary cache (`getTemporaryDirectory()`). | `pubspec.yaml`, `lib/services/voice_recording_io.dart` |
| **Silent error masking in `stopRecording()`** | `AppVoiceRecordingService.stopRecording()` caught exceptions and returned `null`, masking capture/storage failures as a generic `"No audio recorded"` message. `startRecording()` lacked explicit `VoiceRecordingException` distinction. | `lib/services/voice_recording_service.dart` |
| **Base64 JSON overhead + short TCP handshake timeout** | `StrandsAgentApiService.transcribeAudio` always base64-encoded audio into JSON `postJson` even though FastAPI `/agent/voice/transcribe` supports `multipart/form-data`, and hit `15s` IO connect timeouts on cold starts without a client-side `25 MB` check or `401`/`404`/`413` differentiated error messages. | `lib/services/ai_agent_api_service.dart`, `lib/services/agent_http_transport_io.dart`, `lib/services/agent_http_transport_html.dart` |
| **Desktop AI centerpiece lacked transcribing banner** | `DesktopAiCenterpiece` had no `_isTranscribing` indicator banner and did not unwrap `VoiceRecordingException` / `AiParsingException` messages cleanly. | `lib/widgets/desktop/desktop_ai_centerpiece.dart` |

### 2.3 Backend, Database, Account Isolation & Notification Findings

| Area | Finding | Impact |
| :--- | :--- | :--- |
| **Schema drift (`reminders.completed_at`)** | `Reminder` ORM model defined `completed_at`, whereas `agent/database/schema.sql` omitted `completed_at` and `init_db()` performed no column migration for existing DBs. | Fresh schema SQL or legacy Postgres/SQLite tables could fail ORM queries referencing `completed_at`. |
| **Missing `PyJWT` in `requirements.txt`** | `agent/services/jwt_service.py` imported `jwt` (`PyJWT`), which was installed in `.venv` but omitted from `agent/requirements.txt`. | Clean Render / CI builds from `requirements.txt` risked `ModuleNotFoundError`. |
| **Missing `jti` on JWT tokens** | Access and refresh JWTs lacked unique `jti` claims, allowing identical tokens to be minted when two refreshes occurred within the same Unix second. | `agent/services/jwt_service.py` |
| **Duplicate `ReminderChannel` records** | `persist_confirmed_reminder_to_db` always inserted new `ReminderChannel` rows when updating an existing `reminder_id`. | Duplicate WhatsApp channel rows per reminder on update/confirm. |
| **Batch WhatsApp `SID` key & timezone priority** | `batch_reminder_service.py` read `wa_result.get("sid")` (ignoring `"message_sid"` returned by `TwilioWhatsAppService`) logging `SID: None`, and prioritized `ReminderDraft` default `"Asia/Kolkata"` over `request.timezone` / `current_user.timezone`. | Missing SID in audit logs and incorrect timezone selection when client sent explicit non-IST zone or omitted per-draft zone. |
| **Event-loop blocking & missing recurring rollover in Scheduler** | `ReminderScheduler._run_loop` ran synchronous SQLAlchemy + Twilio calls directly on the FastAPI asyncio event loop; recurring (`daily`/`weekly`/`monthly`) WhatsApp reminders stopped queuing after first `DISPATCHED`. | Event-loop stalls during WhatsApp dispatches and broken server-side recurring WhatsApp follow-ups. |
| **Twilio webhook timezone** | `twilio_routes.py` called `reminder_agent` without resolving `user.timezone`. | Relative dates for non-IST WhatsApp users defaulted to server date/IST. |
| **Cross-account local data leakage & notification drift** | Sign-out did not purge `dont_miss_saved_tasks_v1` / `dont_miss_deleted_task_ids_v1`; `TaskProvider.bindAuth` did not clear in-memory tasks, deleted tombstones, or local device notifications on logout or user switch, and did not reconcile device alarms after cloud sync. | Another account signing in on the same device could view or overwrite prior account's cached tasks, or fire stale alarms. |
| **Notification permission & `FlutterTimezone` quirks** | `HomeScreen.initState()` did not invoke `NotificationService.instance.requestPermissions()` on mobile; `NotificationService` and `StrandsAgentApiService` did not normalize legacy Android `'Asia/Calcutta'` to `'Asia/Kolkata'`, and unguarded `FlutterTimezone.getLocalTimezone()` caused widget tests to hang (`pumpAndSettle timed out`) when `flutter_timezone` platform channel received no reply. | Missing Android 13+/14+ permission prompt flow, alias mismatch, and test hang. |

---

## 3. Architecture & Verification Status Overview

- **Preserved Architecture**: `AuthGate` -> `HomeScreen` / `SignInScreen`, `TaskProvider` + `AuthProvider` (`ChangeNotifier`), `AiConfirmationSheet` (Mobile) / `DesktopAiCenterpiece` (Web/Desktop), FastAPI modular routers (`auth_routes.py`, `reminder_routes.py`, `twilio_routes.py`, `app.py`), SQLAlchemy ORM (`User`, `Reminder`, `ReminderChannel`, `PhoneVerification`, `ActionHistory`, `PendingWhatsAppConfirmation`).
- **Automated Verification**:
  - Backend: **135 / 135 pytest tests passing** (`pytest -v agent/tests/`).
  - Flutter Static Analysis: **0 issues** (`flutter analyze lib` and `flutter analyze test`).
  - Flutter Unit & Widget Tests: **160 / 160 tests passing** (`flutter test`).
  - Release APK Artifact: Built cleanly (`build/app/outputs/flutter-apk/app-release.apk`, `57,895,991` bytes, `55.2 MB`).
- **Explicitly Unverified Pending External Deployment / Hardware**:
  - Live Render deployment with uncommitted `agent/` fixes (including `/auth/refresh`).
  - Live Vercel redeploy with updated Web client (`web/`, `lib/`).
  - Physical-device verification on **Moto G32 (Android 13)**: marked **`UNVERIFIED`** until tested on device (`ANDROID_RELEASE_CHECKLIST.md`).
