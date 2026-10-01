-- Don't Miss Assistant - PostgreSQL Production Database Schema
-- Compatible with PostgreSQL 14+ on Render / Neon / Supabase / AWS RDS

-- Enable UUID extension if needed
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- 1. USERS TABLE
CREATE TABLE IF NOT EXISTS users (
    id VARCHAR(36) PRIMARY KEY,
    email VARCHAR(255) UNIQUE NOT NULL,
    password_hash VARCHAR(255) NOT NULL,
    full_name VARCHAR(255),
    phone_number VARCHAR(32),
    phone_verified BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_users_email ON users(email);

-- 2. REMINDERS TABLE
CREATE TABLE IF NOT EXISTS reminders (
    id VARCHAR(36) PRIMARY KEY,
    user_id VARCHAR(36) NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    title VARCHAR(255) NOT NULL,
    description TEXT,
    due_date DATE,
    due_hour INTEGER,
    due_minute INTEGER,
    priority VARCHAR(16) NOT NULL DEFAULT 'medium',
    recurrence VARCHAR(32) NOT NULL DEFAULT 'none',
    url VARCHAR(1024),
    status VARCHAR(32) NOT NULL DEFAULT 'PROPOSED',
    raw_prompt TEXT,
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_reminders_user_id ON reminders(user_id);
CREATE INDEX IF NOT EXISTS idx_reminders_status ON reminders(status);
CREATE INDEX IF NOT EXISTS idx_reminders_due_date ON reminders(due_date);

-- 3. REMINDER CHANNELS TABLE
CREATE TABLE IF NOT EXISTS reminder_channels (
    id SERIAL PRIMARY KEY,
    reminder_id VARCHAR(36) NOT NULL REFERENCES reminders(id) ON DELETE CASCADE,
    channel VARCHAR(32) NOT NULL,
    status VARCHAR(32) NOT NULL DEFAULT 'PENDING',
    dispatched_at TIMESTAMP WITH TIME ZONE
);

CREATE INDEX IF NOT EXISTS idx_reminder_channels_reminder_id ON reminder_channels(reminder_id);

-- 4. PHONE VERIFICATIONS TABLE
CREATE TABLE IF NOT EXISTS phone_verifications (
    id SERIAL PRIMARY KEY,
    user_id VARCHAR(36) NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    phone_number VARCHAR(32) NOT NULL,
    verification_code VARCHAR(16) NOT NULL,
    expires_at TIMESTAMP WITH TIME ZONE NOT NULL,
    verified BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_phone_verifications_user_id ON phone_verifications(user_id);

-- 5. ACTION HISTORY (AUDIT LOG) TABLE
CREATE TABLE IF NOT EXISTS action_history (
    id SERIAL PRIMARY KEY,
    user_id VARCHAR(36) REFERENCES users(id) ON DELETE SET NULL,
    reminder_id VARCHAR(36) REFERENCES reminders(id) ON DELETE SET NULL,
    action_type VARCHAR(64) NOT NULL,
    details TEXT,
    success BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_action_history_user_id ON action_history(user_id);
CREATE INDEX IF NOT EXISTS idx_action_history_reminder_id ON action_history(reminder_id);

-- 6. PENDING WHATSAPP CONFIRMATIONS TABLE
CREATE TABLE IF NOT EXISTS pending_whatsapp_confirmations (
    id VARCHAR(36) PRIMARY KEY,
    user_id VARCHAR(36) NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    phone_number VARCHAR(32) NOT NULL,
    proposed_draft TEXT NOT NULL,
    status VARCHAR(32) NOT NULL DEFAULT 'PENDING',
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
    expires_at TIMESTAMP WITH TIME ZONE NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_pending_confirmations_user_id ON pending_whatsapp_confirmations(user_id);
CREATE INDEX IF NOT EXISTS idx_pending_confirmations_phone ON pending_whatsapp_confirmations(phone_number);
CREATE INDEX IF NOT EXISTS idx_pending_confirmations_status ON pending_whatsapp_confirmations(status);
