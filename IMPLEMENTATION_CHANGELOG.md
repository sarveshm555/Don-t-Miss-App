# Implementation Changelog

All fixes preserve the existing application architecture (**AI proposes. Human decides. Application executes.**) and maintain backward compatibility with existing tests and API contracts.

---

## Backend (`agent/`)

1. **`agent/tools/reminder_tools.py`**
   - Added request-scoped `contextvars.ContextVar` tracker (`_active_tracker_var`, `set_active_tracker`, `reset_active_tracker`, `get_active_tracker`) while keeping module-level `proposal_tracker` fallback for direct synchronous tests.
2. **`agent/reminder_agent.py`**
   - Bound a per-request `ProposalTracker()` via `set_active_tracker`/`reset_active_tracker` inside `process_prompt_async` so concurrent async requests never clobber proposals.
   - Updated `_extract_fallback_proposal` to accept `cur_date`, `cur_time`, and `timezone_name` (removing hardcoded `"Asia/Kolkata"`) and enforce `_is_in_past`.
3. **`agent/providers/openai_provider.py`**
   - Configured explicit `timeout=60.0` on both `OpenAI` and `AsyncOpenAI` clients.
4. **`agent/models/reminder_schema.py`**
   - Added `max_length=4000` validation to `AgentRequest.prompt` and `ReminderPlanRequest.prompt`.
   - Changed `AgentRequest.timezone` and `ReminderPlanRequest.timezone` defaults to `None` so backend resolves client timezone -> user profile timezone -> `"Asia/Kolkata"`.
5. **`agent/app.py`**
   - Fixed CORS middleware configuration (`allow_origins=["*"]` with `allow_credentials=False` unless `CORS_ALLOW_ORIGINS` is explicitly set).
   - Resolved effective timezone across `request.timezone` -> `current_user.timezone` -> `"Asia/Kolkata"` in `/agent/reminder` and `/agent/reminders/plan`.
6. **`agent/database/schema.sql` & `agent/database/connection.py`**
   - Added `completed_at TIMESTAMP WITH TIME ZONE` to `reminders` DDL and appended idempotent `ALTER TABLE reminders ADD COLUMN IF NOT EXISTS completed_at TIMESTAMP WITH TIME ZONE;` in `schema.sql`.
   - Updated `init_db()` in `connection.py` to inspect `reminders` columns and apply an idempotent `ALTER TABLE` for both SQLite (`DATETIME`) and PostgreSQL (`TIMESTAMP WITH TIME ZONE`) when missing.
7. **`agent/requirements.txt`**
   - Added explicit `PyJWT>=2.9.0` dependency.
8. **`agent/services/jwt_service.py`**
   - Added unique `"jti": str(uuid.uuid4())` claims to both access and refresh JWT tokens so same-second refreshes always yield distinct tokens.
9. **`agent/services/batch_reminder_service.py`**
   - Fixed `wa_sid = wa_result.get("sid") or wa_result.get("message_sid")` when logging WhatsApp dispatch results.
   - Corrected timezone resolution priority so explicit non-default client timezone (`draft`/`request`) or user profile timezone takes precedence over `ReminderDraft` default `"Asia/Kolkata"`.
10. **`agent/services/reminder_persistence.py`**
    - Deduplicated `ReminderChannel` records when updating an existing `reminder_id` in `persist_confirmed_reminder_to_db` instead of inserting duplicate channel rows.
11. **`agent/services/reminder_scheduler.py`**
    - Offloaded synchronous DB polling and Twilio dispatch onto worker threads via `await asyncio.to_thread(self._execute_tick_sync)` in `_run_loop`.
    - Added `_schedule_next_occurrence_if_recurring` to advance `daily`/`weekly`/`monthly` recurring reminders (`due_date` and `due_timestamp_utc`) and enqueue the next `PENDING` WhatsApp `ReminderChannel` after dispatch.
    - Supported reading both `sid` and `message_sid` from `TwilioWhatsAppService` responses.
12. **`agent/routes/twilio_routes.py`**
    - Resolved `user.timezone` to compute user-local `current_date`/`current_time` and passed `timezone` via `inspect.signature` compatibility check to preserve test doubles.

---

## Flutter Frontend (`lib/`, `web/`, `pubspec.yaml`)

1. **`pubspec.yaml` & `pubspec.lock`**
   - Added `path_provider: ^2.1.4` (`path_provider 2.1.6` / `path_provider_android 2.3.1` resolved offline from local Pub cache).
2. **`lib/services/agent_http_transport.dart`, `agent_http_transport_io.dart`, `agent_http_transport_html.dart`**
   - Added `bool get supportsMultipart => false;` and default `postMultipart(...)` on `AgentHttpTransport`.
   - **`IoAgentHttpTransport`**: raised `connectionTimeout` from `15s` up to `60s` (`timeout < 60s ? timeout : 60s`) for Render Free cold starts; switched JSON requests to explicit UTF-8 `utf8.encode` + `Content-Length` + `content-type: application/json; charset=utf-8` + `accept: application/json`; applied `.timeout(timeout)` across the entire request+response lifecycle; implemented RFC-2046 `postMultipart` binary file upload (`supportsMultipart => true`).
   - **`HtmlAgentHttpTransport`**: added explicit `Accept: application/json` and `Content-Type: application/json; charset=utf-8` headers and implemented browser `FormData` + `Blob` `postMultipart` (`supportsMultipart => true`).
3. **`lib/services/voice_recording_io.dart` & `lib/services/voice_recording_service.dart`**
   - Replaced Android-unwritable `Directory.systemTemp` with `await getTemporaryDirectory()` (`path_provider`) with `Directory.systemTemp` fallback only for headless unit tests; ensured target directory creation and empty-byte guard.
   - Added `VoiceRecordingException` in `voice_recording_service.dart`, explicit permission error surfacing in `startRecording()`, and non-silent exception surfacing in `stopRecording()`.
4. **`lib/services/auth_service.dart`**
   - Raised auth timeouts from `15s` to `60s` (`_authTimeout`).
   - Added structural JWT `exp` verification (`_isJwtExpired`) in `getCurrentUser()`, attempting `refreshSession()` and clearing expired credentials if refresh fails (while leaving non-JWT synthetic test tokens intact).
   - Updated `signOut()` to also remove `dont_miss_saved_tasks_v1` and `dont_miss_deleted_task_ids_v1`.
5. **`lib/services/ai_agent_api_service.dart`**
   - Added `resolveDeviceTimezone()` and `cachedDeviceTimezone` using `FlutterTimezone.getLocalTimezone().timeout(const Duration(seconds: 1))`, normalizing `'Asia/Calcutta'` -> `'Asia/Kolkata'`.
   - Updated `parsePrompt` and `parseMultiPrompt` to pass resolved device timezone, optional `authToken`, handle HTTP `401` refresh + retry, and preserve AI clarification/auth errors when `/agent/reminders/plan` returns `404` unless `/agent/reminder` also returns `404` or unreachable.
   - Updated `transcribeAudio` with a `25 MB` client-side guard, binary `postMultipart` upload when `effectiveTransport.supportsMultipart == true` (with `UnimplementedError` / base64 JSON fallback for mocks), `401` refresh + retry, and specific `404`/`413`/timeout error handling.
6. **`lib/services/reminder_sync_service.dart`**
   - Raised `_defaultTimeout` to `60s`; included resolved device `timezone` in `taskToCloudPayload` (populated during `sync`, `createCloudReminder`, `updateCloudReminder`); added `clearAllDeletedIds()`.
7. **`lib/services/action_dispatch_service.dart`**
   - Raised timeouts to `60s` in `BackendActionDispatchService`, attached resolved device `timezone` in `dispatchConfirmedAction` and `dispatchBatchConfirmedActions`, and wired `401` `tokenRefresher` / `onSessionExpired` handling without altering the abstract `ActionDispatchService` signature.
8. **`lib/services/notification_service.dart`**
   - Normalized `'Asia/Calcutta'` -> `'Asia/Kolkata'` during `init()`, added a `1s` timeout guard on `FlutterTimezone.getLocalTimezone()`, wrapped `requestPermissions()` in `try/catch`, and added `requestExactAlarmsPermission()` alongside `requestNotificationsPermission()`.
9. **`lib/providers/task_provider.dart`**
   - Added `tokenRefresher`, `onSessionExpired`, `_activeSyncService`, logout/account-switch cache clearing (`_tasks`, repository, tombstones, local notifications), duplicate sync guard per user, and post-sync notification reconciliation (`_reconcileNotifications()`).
10. **`lib/widgets/auth_gate.dart`**
    - Constructed default `StrandsAgentApiService` and `BackendActionDispatchService` wired to `auth.refreshSession` and `auth.handleSessionExpired` and passed `actionDispatchService` into `HomeScreen`.
11. **`lib/widgets/ai_confirmation_sheet.dart`, `lib/widgets/desktop/desktop_ai_centerpiece.dart`, `lib/screens/home_screen.dart`, `lib/screens/add_edit_task_screen.dart`, `lib/screens/sign_in_screen.dart`**
    - Fixed multi-draft selection check (`draft.draftId` or `draft.id`) in `AiConfirmationSheet`.
    - Unified client UUID assignment across single and batch confirmations before local and cloud persistence; added explicit `idempotencyKey` on batch dispatch and accurate local vs. cloud snackbar messaging.
    - Added visible `"Transcribing your audio with AI..."` banner in `DesktopAiCenterpiece` and clean `VoiceRecordingException`/`AiParsingException` surfacing across mobile & desktop.
    - Added `NotificationService.instance.requestPermissions()` on non-web `HomeScreen.initState()`.
    - Wired `tokenRefresher` / `onSessionExpired` into fallback `BackendActionDispatchService` instances and added inline expired-session alert banner in `SignInScreen`.
12. **`web/index.html` & `web/manifest.json`**
    - Updated web app title, short name, and metadata description from placeholder `"dont_miss"` / `"A new Flutter project."` to `"Don't Miss"`.

---

## Automated Regression Tests Added & Updated

- **`agent/tests/test_audit_regressions.py`** (7 new backend tests): concurrent `process_prompt_async` isolation, fallback timezone & past-time rejection, legacy SQLite `init_db()` `completed_at` migration, duplicate `ReminderChannel` prevention, recurring daily WhatsApp scheduler rollover (`message_sid` + next `PENDING` channel), same-second JWT `jti` uniqueness, and `/agent/reminders/plan` user profile timezone fallback.
- **`test/audit_regressions_test.dart`** (10 new Flutter tests): real local `HttpServer` loopback `IoAgentHttpTransport` UTF-8 JSON & `postMultipart` binary streaming, `StrandsAgentApiService` `401` refresh retry / `onSessionExpired` / `404` clarification preservation / multipart voice upload, `AiConfirmationSheet` `id == null` checkbox selection + unified UUID batch sync, `DesktopAiCenterpiece` transcribing banner + `VoiceRecordingException` error rendering, `AuthGate` -> desktop `HomeScreen` batch dispatch, `TaskProvider` cross-account cache/tombstone/notification wipe + post-sync reconciliation, and `ApiAuthService` expired structural JWT cleanup.
- **`test/auth_flow_test.dart`, `test/desktop_web_ui_test.dart`, `test/history_flow_test.dart`, `test/voice_multi_reminder_test.dart`**: updated `FakeAuthService` mocks with `currentToken`, `currentRefreshToken`, and `refreshSession()`, and added `supportsMultipart => false` on `MockFailingTransport` and `MockRouteTransport`.
