# Don't Miss

> **Think it. Confirm it. Don't Miss it.**  
> *AI proposes. Human decides. Application executes.*

Don't Miss is an AI Personal Action Agent that transforms unstructured natural-language intentions into structured, user-confirmed, and actionable reminders. Designed with a strict human-in-the-loop philosophy, it bridges the gap between chaotic human thoughts and reliable task execution across mobile and web platforms.

---

## Table of Contents

- [Overview](#overview)
- [Key Features](#key-features)
- [How It Works](#how-it-works)
- [System Architecture](#system-architecture)
- [Architecture Diagram](#architecture-diagram)
- [Technology Stack](#technology-stack)
- [Project Structure](#project-structure)
- [Setup and Installation](#setup-and-installation)
  - [Prerequisites](#prerequisites)
  - [Backend Setup](#backend-setup)
  - [Frontend Setup (Flutter)](#frontend-setup-flutter)
  - [Environment Variables](#environment-variables)
- [Running the Application](#running-the-application)
- [API Overview](#api-overview)
- [Authentication and Security](#authentication-and-security)
- [Local Notifications and Alarms](#local-notifications-and-alarms)
- [Data Storage and Cloud Sync](#data-storage-and-cloud-sync)
- [History and Task Lifecycle](#history-and-task-lifecycle)
- [Testing and Verification](#testing-and-verification)
- [Deployment](#deployment)
- [Roadmap (Planned / Future)](#roadmap-planned--future)
- [Design Philosophy](#design-philosophy)
- [License](#license)

---

## Overview

Traditional task and reminder applications impose significant cognitive overhead:
- Manually typing titles and notes.
- Navigating nested calendar pickers and clock dials.
- Setting explicit priority dropdowns.
- Specifying recurring intervals.

Because of this friction, users frequently delay entering reminders or record vague, incomplete notes. Critical deadlines, interviews, meetings, and personal commitments slip through the cracks.

**Don't Miss** eliminates this manual configuration. Users express commitments in everyday language:

> *"Remind me tomorrow at 9 PM about my system design interview because I need to review distributed systems notes."*

The backend AI agent parses the temporal context, extracts priorities, formats structured parameters, and drafts a proposal. The application then places the proposal before the user for inspection and explicit approval. Once confirmed, the reminder is saved locally, synchronized to the cloud database, and scheduled as an exact device alarm.

---

## Key Features

- **Natural-Language Reminder Extraction**: Describe what, when, why, and how urgently in casual language. The AI agent extracts title, due date, 24-hour time, priority, recurrence, and URLs.
- **Human-in-the-Loop Confirmation**: AI never writes directly to your schedule without consent. A dedicated confirmation sheet lets you inspect, adjust, and approve every parsed detail.
- **Secure Authentication**: Phone-based account registration and sign-in backed by salted PBKDF2-HMAC-SHA256 password hashing and signed JWT access tokens.
- **Dedicated History Section**: Completed tasks are seamlessly moved out of the active list into a dedicated History screen, recording completion timestamps while preserving recurrence patterns.
- **Two-Way Cloud Synchronization**: Built-in background sync with Supabase PostgreSQL ensures data resilience across devices while preserving offline-first functionality.
- **Local-First Reliability**: Offline storage powered by `shared_preferences` guarantees access to reminders even without internet connectivity.
- **Exact Device Notifications**: Powered by `flutter_local_notifications` and `timezone` for battery-efficient, exact Android alarms (web push notifications are not supported).
- **Smart Filtering & Real-Time Search**: Instant search across titles and descriptions with quick filters: **All**, **Today**, **Overdue**, and **High Priority**.
- **Priority Tiers**: Color-coded visual badges (`High`, `Medium`, `Low`) for immediate focus management.
- **Recurrence Support**: Flexible recurring reminders supporting `Daily`, `Weekly`, and `Monthly` cadences.
- **Web Link Attachments**: Store external reference links and launch them directly in the browser with one tap.
- **Cross-Platform**: Production-ready for **Android** (with exact alarm scheduling) and **Web** (Chrome, active dashboard and cloud sync without native web push).

---

## How It Works

Don't Miss operates on a tripartite execution loop: **AI proposes, Human decides, Application executes.**

```
+-----------------------------------------------------------------------+
| 1. NATURAL-LANGUAGE PROMPT                                            |
|    User inputs: "Doctor appointment this Friday at 3:30 PM urgent"   |
+-----------------------------------------------------------------------+
                                  |
                                  v
+-----------------------------------------------------------------------+
| 2. AI PARSING & EXTRACTION (FastAPI + OpenAI)                         |
|    Extracts:                                                          |
|    - Title: "Doctor appointment"                                      |
|    - Date: 2026-10-09 | Time: 15:30                                   |
|    - Priority: High   | Recurrence: None                              |
|    Invokes `create_reminder` tool to draft a structured proposal.      |
+-----------------------------------------------------------------------+
                                  |
                                  v
+-----------------------------------------------------------------------+
| 3. HUMAN CONFIRMATION SHEET (Flutter UI)                              |
|    User inspects proposal, edits fields if desired, and confirms.     |
+-----------------------------------------------------------------------+
                                  |
                                  v
+-----------------------------------------------------------------------+
| 4. EXECUTION & SCHEDULING                                             |
|    - Stored in local offline persistence (SharedPreferences).         |
|    - Synchronized to Supabase PostgreSQL database via JWT auth.       |
|    - Scheduled via Android exact alarm notification manager.          |
+-----------------------------------------------------------------------+
```

---

## System Architecture

The Don't Miss architecture is separated into three primary tiers:

1. **Client Tier (Flutter)**:
   - State management via `Provider` pattern (`TaskProvider`, `AuthProvider`).
   - Local persistence with offline-first `shared_preferences`.
   - Native hardware integration for exact alarms via `flutter_local_notifications` and `timezone`.
   - HTTP transport abstraction with dynamic base URL routing and JWT authorization headers.

2. **Backend Services Tier (FastAPI)**:
   - High-performance asynchronous REST API powered by Starlette and Pydantic.
   - Authentication router handling phone-based sign-up, sign-in, verification, and profile endpoints.
   - Cloud synchronization router providing user-scoped CRUD endpoints (`/reminders`).
   - Action confirmation router routing confirmed proposals to appropriate notification and execution channels.
   - Health check probe (`GET /health`) reporting database connectivity and AI engine status.

3. **Intelligence & Persistence Tier**:
   - **OpenAI Engine**: Uses function/tool calling via `create_reminder` to deterministically parse temporal strings into typed JSON structures.
   - **Supabase PostgreSQL**: Scalable relational persistence with foreign-key relationships linking users, reminders, and action audit histories.

---

## Architecture Diagram

```mermaid
flowchart TD
    subgraph Client ["Flutter Client (Android & Web)"]
        UI["UI Screens<br/>(Home, Auth, History, Profile)"]
        TP["TaskProvider<br/>(State Management)"]
        AP["AuthProvider<br/>(Session & JWT)"]
        LocalStore[("Local Cache<br/>SharedPreferences")]
        NotifService["NotificationService<br/>(flutter_local_notifications)"]
        SyncService["ReminderSyncService<br/>(Cloud Sync)"]
        
        UI --> TP
        UI --> AP
        TP --> LocalStore
        TP --> NotifService
        TP --> SyncService
    end

    subgraph Backend ["FastAPI Backend (Render Web Service)"]
        AuthRouter["Auth Router<br/>/auth/signup, /auth/signin, /auth/me"]
        ReminderRouter["Reminder Router<br/>/reminders (CRUD & Sync)"]
        AgentRouter["Agent Router<br/>/agent/reminder"]
        ActionRouter["Action Router<br/>/action/confirm"]
        HealthRouter["Health Check<br/>GET /health"]
        
        SyncService -- "JWT Bearer Token" --> ReminderRouter
        AP -- "Credentials" --> AuthRouter
        UI -- "Natural Language Prompt" --> AgentRouter
        UI -- "User Approval" --> ActionRouter
    end

    subgraph Intelligence ["AI Engine"]
        ReminderAgent["ReminderAgent<br/>(Function Calling Orchestrator)"]
        OpenAI["OpenAI API<br/>(gpt-4o-mini / Configurable)"]
        Tool["create_reminder Tool<br/>(Draft Proposal Generator)"]
        
        AgentRouter --> ReminderAgent
        ReminderAgent --> OpenAI
        OpenAI --> Tool
        Tool --> AgentRouter
    end

    subgraph Database ["Supabase PostgreSQL"]
        DB[(PostgreSQL Database)]
        UsersTable["users"]
        RemindersTable["reminders"]
        AuditTable["action_history"]
        
        AuthRouter --> UsersTable
        ReminderRouter --> RemindersTable
        ActionRouter --> AuditTable
        UsersTable -.-> RemindersTable
        UsersTable -.-> AuditTable
    end
```

---

## Technology Stack

| Layer | Component / Library | Purpose |
| :--- | :--- | :--- |
| **Frontend Framework** | Flutter 3.x / Dart 3.x | Cross-platform UI development for Android and Web |
| **State Management** | Provider | Reactive state management across authentication and task lifecycles |
| **Local Persistence** | `shared_preferences` | High-speed local offline key-value storage and cache |
| **Hardware Notifications** | `flutter_local_notifications`, `timezone` | Exact Android device alarms and battery-conscious background scheduling (no web push) |
| **Backend Framework** | FastAPI (Python 3.11+) | Asynchronous RESTful API backend |
| **ASGI Server** | Uvicorn | Production-grade ASGI web server |
| **AI / LLM Orchestration** | OpenAI API (`gpt-4o-mini` default) | Natural-language extraction via deterministic tool/function calling |
| **Database & ORM** | PostgreSQL (Supabase), SQLAlchemy 2.0 | Relational schema storage, data relationships, and migrations |
| **Authentication & Crypto** | PyJWT, hashlib, hmac (PBKDF2-HMAC-SHA256) | Salted password hashing (100,000 iterations), constant-time digest verification, and signed JWT tokens |
| **Cloud Hosting** | Render Web Service | Continuous deployment and container hosting |
| **Testing** | `flutter_test`, `pytest` | Comprehensive unit, widget, and integration test suites |

---

## Project Structure

```
├── agent/                         # FastAPI backend service
│   ├── app.py                     # FastAPI application entry point & CORS
│   ├── reminder_agent.py          # AI agent orchestration & tool calling
│   ├── models.py                  # Pydantic request/response schemas
│   ├── requirements.txt           # Python backend dependencies
│   ├── database/                  # Database connectivity & models
│   │   ├── connection.py          # SQLAlchemy engine & session factory
│   │   └── models.py              # PostgreSQL table models (User, Reminder, etc.)
│   ├── routes/                    # API route controllers
│   │   ├── auth_routes.py         # Phone registration, sign-in, verification
│   │   ├── reminder_routes.py     # Cloud CRUD & two-way synchronization
│   │   └── twilio_routes.py       # Action confirmation & channel dispatch
│   ├── services/                  # Business logic services
│   │   ├── jwt_service.py         # JWT generation, validation & user dependency
│   │   └── password_service.py    # PBKDF2-HMAC-SHA256 hashing & verification
│   └── tests/                     # Backend automated tests
├── android/                       # Native Android configuration
│   ├── app/src/main/              # Android manifests, launcher icons, adaptive icons
│   └── gradle.properties          # Gradle memory & build parameters
├── lib/                           # Flutter application source code
│   ├── main.dart                  # Application entry point & provider bootstrapping
│   ├── models/                    # Data models
│   │   ├── task.dart              # Task model with serialization & completedAt tracking
│   │   └── user_model.dart        # Client user & auth state representation
│   ├── providers/                 # State management providers
│   │   ├── auth_provider.dart     # Authentication state, token storage, user session
│   │   └── task_provider.dart     # Task state, filtering, search, local/cloud sync
│   ├── screens/                   # User interface screens
│   │   ├── home_screen.dart       # Main active task dashboard & search
│   │   ├── history_screen.dart    # Dedicated completed tasks view
│   │   ├── auth_screen.dart       # Sign In & Sign Up interfaces
│   │   ├── profile_screen.dart    # User profile, history link, sign out
│   │   └── reminder_sheet.dart    # AI proposal confirmation modal sheet
│   ├── services/                  # Core client-side services
│   │   ├── auth_service.dart      # Remote authentication client
│   │   ├── notification_service.dart # Local Android alarm scheduling
│   │   ├── reminder_sync_service.dart# Two-way Supabase synchronization
│   │   └── agent_http_transport.dart # Dynamic base URL & HTTP transport
│   └── widgets/                   # Reusable UI components
│       ├── task_card.dart         # Interactive task item card
│       ├── task_filters.dart      # Category & status filter chips
│       └── logo_avatar.dart       # Brand logo representation
├── test/                          # Flutter unit and widget tests (117 tests)
│   ├── history_flow_test.dart     # Task completion & history lifecycle test
│   ├── task_provider_test.dart    # Local state & filter test suite
│   └── widget_test.dart           # Core UI smoke and interaction tests
├── render.yaml                    # Render Web Service deployment specification
└── pubspec.yaml                   # Flutter dependencies & asset declarations
```

---

## Setup and Installation

### Prerequisites

- **Flutter SDK**: Version 3.19.0 or higher ([Installation Guide](https://flutter.dev/docs/get-started/install))
- **Python**: Version 3.11 or higher
- **PostgreSQL Database**: An active instance (e.g., Supabase PostgreSQL)
- **OpenAI API Key**: Required for AI reminder extraction
- **Android Studio / Android SDK**: For Android builds (target SDK 34)

---

### Backend Setup

1. **Navigate to the agent directory**:
   ```bash
   cd agent
   ```

2. **Create and activate a virtual environment**:
   ```bash
   # Windows (PowerShell)
   python -m venv venv
   .\venv\Scripts\Activate.ps1

   # macOS / Linux
   python3 -m venv venv
   source venv/bin/activate
   ```

3. **Install dependencies**:
   ```bash
   pip install -r requirements.txt
   ```

4. **Configure environment variables** (see [Environment Variables](#environment-variables)).

5. **Start the development server**:
   ```bash
   uvicorn agent.app:app --host 0.0.0.0 --port 8000 --reload
   ```

6. **Verify server health**:
   ```bash
   curl http://localhost:8000/health
   ```

---

### Frontend Setup (Flutter)

1. **Return to the repository root**:
   ```bash
   cd ..
   ```

2. **Install Flutter packages**:
   ```bash
   flutter pub get
   ```

3. **Run code analysis**:
   ```bash
   flutter analyze lib test
   ```

4. **Run the test suite**:
   ```bash
   flutter test
   ```

---

### Environment Variables

#### Backend Environment Variables (`agent/.env` or Render Dashboard)

| Variable | Required | Description | Example |
| :--- | :--- | :--- | :--- |
| `DATABASE_URL` | Yes | PostgreSQL connection string (Supabase) | `postgresql://user:pass@host:5432/dbname` |
| `JWT_ACCESS_SECRET` | Yes | Secret key used to sign and verify JWT tokens | `<high-entropy-random-string>` |
| `OPENAI_API_KEY` | Yes | OpenAI API authentication key | `sk-...` |
| `OPENAI_MODEL` | No | OpenAI model identifier (defaults to `gpt-4o-mini`) | `gpt-4o-mini` |
| `TWILIO_ACCOUNT_SID` | No | Twilio Account SID (for notification dispatch) | `AC...` |
| `TWILIO_AUTH_TOKEN` | No | Twilio Auth Token | `<token>` |
| `TWILIO_WHATSAPP_NUMBER`| No | Twilio WhatsApp sender number | `whatsapp:+14155238886` |
| `PORT` | No | Port on which FastAPI binds (defaults to `8000`) | `8000` |

#### Frontend Configuration (`--dart-define`)

When building or running Flutter, point the app to your backend using `AGENT_BASE_URL`:

- **Android Emulator**: Defaults automatically to `http://10.0.2.2:8000`
- **Web / Localhost**: Defaults automatically to `http://localhost:8000`
- **Physical Device / Production**:
  ```bash
  flutter run --dart-define=AGENT_BASE_URL=https://your-backend-service.onrender.com
  ```

---

## Running the Application

### Running the Backend
```bash
cd agent
uvicorn agent.app:app --host 0.0.0.0 --port 8000 --reload
```

### Running on Android Device / Emulator
```bash
# Debug run with custom backend URL
flutter run --dart-define=AGENT_BASE_URL=http://<YOUR_LOCAL_IP>:8000

# Release APK build
flutter build apk --release --dart-define=AGENT_BASE_URL=https://your-backend-service.onrender.com
```

### Running on Flutter Web (Chrome)
```bash
flutter run -d chrome --dart-define=AGENT_BASE_URL=http://localhost:8000
```

---

## API Overview

The FastAPI backend exposes the following primary endpoints:

### System & Health
- `GET /health`: Returns service operational status, database connectivity, and OpenAI configuration state.

### Authentication (`/auth`)
- `POST /auth/signup`: Registers a new user with phone number, full name, and password.
- `POST /auth/signin`: Authenticates credentials and returns a signed JWT access token.
- `POST /auth/verify-phone`: Verifies phone number ownership with OTP.
- `GET /auth/me`: Retrieves current user profile from bearer token.
- `POST /auth/signout`: Terminates active session.

### AI Reminder Agent (`/agent`)
- `POST /agent/reminder`: Takes natural language prompt and temporal context (`current_date`, `current_time`) and returns a structured reminder proposal.

### Confirmation & Execution (`/action`)
- `POST /action/confirm`: Accepts user-approved proposal, logs execution audit record, and routes to selected notification channels.

### Cloud Synchronization (`/reminders`)
- `GET /reminders`: Lists all reminders for authenticated user.
- `POST /reminders`: Creates a new reminder in Supabase.
- `GET /reminders/{id}`: Retrieves specific reminder by ID.
- `PUT /reminders/{id}`: Updates reminder state (including completion status and `completed_at`).
- `DELETE /reminders/{id}`: Deletes a reminder.

---

## Authentication and Security

- **Password Security**: Passwords are never stored in plaintext. They are hashed using PBKDF2-HMAC-SHA256 with a unique 16-byte cryptographically secure random salt (generated via `secrets.token_hex`) and 100,000 iterations (`hashlib.pbkdf2_hmac`). Verification uses constant-time digest comparison (`hmac.compare_digest`) to protect against timing attacks.
- **Token Security**: Authorization is handled via cryptographically signed JWT access tokens (HS256) containing user claims and expiration times.
- **Tenant Isolation**: All cloud database queries explicitly filter by the authenticated user's ID, preventing unauthorized cross-user data access.
- **Zero Hardcoded Secrets**: All keys, database credentials, and signing secrets are managed strictly through environment variables.
- **ProGuard / R8 Obfuscation**: Android release builds employ ProGuard keep rules to safeguard reflection targets and local notification callbacks while stripping debug symbols.

---

## Local Notifications and Alarms

- **Exact Alarm Delivery**: Configured for native Android via `SCHEDULE_EXACT_ALARM` and `USE_EXACT_ALARM` permissions.
- **Timezone Awareness**: Schedules alarms using the `timezone` package with local zone calculation, ensuring on-time delivery across daylight saving changes.
- **Resilience**: Notification IDs are deterministically derived from task identifiers, preventing duplicate notifications.
- **Action Buttons**: Notifications include direct interactive actions to mark tasks as completed straight from the notification shade.
- **Platform Scope (No Web Push)**: Local scheduled notifications and exact alarms are exclusively implemented for native Android. Web push notifications are neither supported nor implemented on Flutter Web; reminders on Web are managed through the interactive dashboard and real-time cloud synchronization.

---

## Data Storage and Cloud Sync

Don't Miss implements a resilient **local-first, cloud-synchronized** data strategy:

1. **Immediate Local Responsiveness**:
   - Every creation, edit, completion, or deletion is instantly written to local `shared_preferences`.
   - The UI updates without waiting for network round-trips.

2. **Seamless Cloud Sync**:
   - If authenticated, `ReminderSyncService` transmits state changes to the Supabase PostgreSQL backend in the background.
   - On app startup, the client reconciles local tasks with remote cloud state, preventing data loss across app reinstalls or device changes.

3. **Offline Tolerance**:
   - If the network is unavailable, reminders function locally with zero disruption. Local notifications trigger regardless of internet connectivity.

---

## History and Task Lifecycle

1. **Active Tasks**: The primary dashboard displays only active, pending tasks.
2. **Completing a Reminder**:
   - Tapping the completion toggle instantly removes the task from the active list.
   - The task's `isCompleted` flag is set to `true`, and an ISO 8601 `completedAt` timestamp is recorded.
   - The updated state is synced to Supabase PostgreSQL.
3. **Dedicated History View**:
   - Accessible via the History icon in the top AppBar or through the Profile screen.
   - Shows all completed tasks sorted chronologically by completion time.
   - Completed tasks preserve all original metadata (priority, recurrence interval, original due date, context notes).
   - Allows users to delete history records or reactivate reminders if needed.

---

## Testing and Verification

The repository maintains strict quality control with 100% passing tests and zero lint warnings:

### Running Flutter Tests
```bash
flutter test
```
- **117 passing tests** covering:
  - Task model serialization, deserialization, and `completedAt` handling.
  - `TaskProvider` local state mutations, search indexing, and filtering logic.
  - History screen navigation, rendering, and completion lifecycles (`history_flow_test.dart`).
  - Notification scheduling calculations.
  - Authentication state transitions and token persistence.

### Static Code Analysis
```bash
flutter analyze lib test
```
- Passes cleanly with **0 issues found**.

### Running Backend Tests
```bash
pytest agent/tests/
```
- Verifies FastAPI route responses, Pydantic schema validation, and tool-calling output structures.

---

## Deployment

### Backend Deployment (Render Web Service)

The backend is configured for continuous zero-downtime deployment via `render.yaml`:
- **Runtime**: Python 3
- **Start Command**: `uvicorn agent.app:app --host 0.0.0.0 --port $PORT`
- **Health Check Path**: `/health`
- **Database**: External Supabase PostgreSQL instance referenced via `DATABASE_URL`.

### Android Release Build

```bash
flutter build apk --release --dart-define=AGENT_BASE_URL=https://your-backend-service.onrender.com
```
- Produces an optimized, ProGuard-minified APK located at `build/app/outputs/flutter-apk/app-release.apk`.
- Configured with high-resolution adaptive launcher icons and custom brand artwork.

---

## Roadmap (Planned / Future)

The following capabilities represent architectural extensions planned for upcoming iterations:

- **Two-Way Conversational WhatsApp Bot**: An interactive WhatsApp channel where users can converse directly with the agent, receive reminder alerts, and reply to reschedule or complete tasks.
- **Direct Voice Input & Transcription**: In-app audio capture and real-time speech-to-text processing for hands-free reminder creation on mobile devices.
- **Calendar Bi-Directional Synchronization**: Exporting and synchronizing confirmed reminders with Google Calendar and Apple Calendar.
- **Smart Location Geofencing**: Triggering reminder notifications upon arriving at or departing from specific geographic coordinates.

---

## Design Philosophy

- **Human Agency First**: Artificial intelligence should propose, organize, and assist—never usurp control. Every irreversible action requires explicit human confirmation.
- **Zero Friction**: Eliminate form fatigue. Translating unstructured thoughts into structured data is a machine's job; verifying intent is a human's job.
- **Offline Integrity**: A reminder app that fails when offline is fundamentally untrustworthy. Local state is primary; cloud state is supplementary.
- **Deterministic Tool Calling**: Prompt engineering is backed by typed function definitions (`create_reminder`), guaranteeing consistent schema outputs from LLM responses.

---

## License

No license is currently specified for this project. All rights reserved.
