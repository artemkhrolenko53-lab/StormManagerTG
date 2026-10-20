-- Storm Manager: PostgreSQL schema. Idempotent: safe to run repeatedly.
-- Every table is keyed by chat_id, so one deployment serves any number of chats.

CREATE TABLE IF NOT EXISTS chats (
    chat_id          BIGINT PRIMARY KEY,
    title            TEXT        NOT NULL DEFAULT '',
    chat_type        TEXT        NOT NULL DEFAULT 'supergroup',
    username         TEXT,
    active           BOOLEAN     NOT NULL DEFAULT TRUE,
    lang             TEXT        NOT NULL DEFAULT 'ru',
    rules_text       TEXT        NOT NULL DEFAULT '',   -- single source of truth: AI + public Codex read this
    faq_text         TEXT        NOT NULL DEFAULT '',   -- same: edited in the AI & Rules tab
    settings         JSONB       NOT NULL DEFAULT '{}'::jsonb,
    admin_ids        BIGINT[]    NOT NULL DEFAULT '{}',
    admins_synced_at TIMESTAMPTZ,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS members (
    chat_id       BIGINT      NOT NULL REFERENCES chats(chat_id) ON DELETE CASCADE,
    user_id       BIGINT      NOT NULL,
    username      TEXT,
    first_name    TEXT        NOT NULL DEFAULT '',
    status        TEXT        NOT NULL DEFAULT 'member',  -- member | muted | banned | left
    msg_count     INTEGER     NOT NULL DEFAULT 0,
    joined_at     TIMESTAMPTZ,                            -- only known if the bot saw the join event
    first_seen_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_seen_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (chat_id, user_id)
);
CREATE INDEX IF NOT EXISTS members_username_idx ON members (chat_id, lower(username));

-- Short-lived cache: context for the AI, flood detection, picking a message to report.
-- Purged by /cron/cleanup after MESSAGE_CACHE_HOURS.
CREATE TABLE IF NOT EXISTS messages (
    chat_id    BIGINT      NOT NULL,
    message_id BIGINT      NOT NULL,
    user_id    BIGINT      NOT NULL,
    text       TEXT        NOT NULL DEFAULT '',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    edited_at  TIMESTAMPTZ,
    PRIMARY KEY (chat_id, message_id)
);
CREATE INDEX IF NOT EXISTS messages_user_time_idx ON messages (chat_id, user_id, created_at DESC);

-- Moderation events (the "Logs" tab). message_text is wiped after LOG_TEXT_RETENTION_DAYS.
CREATE TABLE IF NOT EXISTS mod_log (
    id             BIGSERIAL PRIMARY KEY,
    chat_id        BIGINT      NOT NULL,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    action         TEXT        NOT NULL,   -- delete | ban | mute | unmute | unban | queue | error
    source         TEXT        NOT NULL,   -- rule | ai | admin
    target_user_id BIGINT,
    message_id     BIGINT,
    violation_type TEXT,
    confidence     INTEGER,
    reason         TEXT,
    message_text   TEXT
);
CREATE INDEX IF NOT EXISTS mod_log_chat_time_idx ON mod_log (chat_id, created_at DESC);

-- AI suspicions waiting for an admin decision (confirm = mute, dismiss = false positive).
CREATE TABLE IF NOT EXISTS ai_queue (
    id             BIGSERIAL PRIMARY KEY,
    chat_id        BIGINT      NOT NULL,
    message_id     BIGINT      NOT NULL,
    user_id        BIGINT      NOT NULL,
    message_text   TEXT        NOT NULL DEFAULT '',
    violation_type TEXT        NOT NULL,
    confidence     INTEGER     NOT NULL,
    reason         TEXT        NOT NULL DEFAULT '',
    status         TEXT        NOT NULL DEFAULT 'pending',  -- pending | confirmed | dismissed
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    resolved_by    BIGINT,
    resolved_at    TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS ai_queue_pending_idx ON ai_queue (chat_id, status, created_at DESC);

-- Anonymous reports. The reporter is stored ONLY as a salted hash (rate-limiting), never readable.
CREATE TABLE IF NOT EXISTS reports (
    id               BIGSERIAL PRIMARY KEY,
    chat_id          BIGINT      NOT NULL,
    message_id       BIGINT,
    reported_user_id BIGINT,
    message_text     TEXT,
    comment          TEXT        NOT NULL DEFAULT '',
    reporter_hash    TEXT        NOT NULL,
    status           TEXT        NOT NULL DEFAULT 'open',   -- open | closed
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    resolved_by      BIGINT,
    resolved_at      TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS reports_chat_status_idx ON reports (chat_id, status, created_at DESC);

CREATE TABLE IF NOT EXISTS warns (
    id         BIGSERIAL PRIMARY KEY,
    chat_id    BIGINT      NOT NULL,
    user_id    BIGINT      NOT NULL,
    by_admin   BIGINT      NOT NULL,
    reason     TEXT        NOT NULL DEFAULT '',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    revoked_at TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS warns_user_idx ON warns (chat_id, user_id);

-- Daily AI call counter per chat: protects the shared free Gemini quota.
CREATE TABLE IF NOT EXISTS ai_usage (
    chat_id BIGINT  NOT NULL,
    day     DATE    NOT NULL,
    calls   INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (chat_id, day)
);

-- Admin audit log: who confirmed a mute, banned a member, etc. Append-only (enforced below).
CREATE TABLE IF NOT EXISTS audit_log (
    id             BIGSERIAL PRIMARY KEY,
    chat_id        BIGINT      NOT NULL,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    admin_id       BIGINT      NOT NULL,
    admin_name     TEXT        NOT NULL DEFAULT '',
    action         TEXT        NOT NULL,
    target_user_id BIGINT,
    details        JSONB       NOT NULL DEFAULT '{}'::jsonb
);
CREATE INDEX IF NOT EXISTS audit_log_chat_time_idx ON audit_log (chat_id, created_at DESC);

CREATE OR REPLACE FUNCTION audit_log_append_only() RETURNS trigger AS $$
BEGIN
    RAISE EXCEPTION 'audit_log is append-only';
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS audit_log_no_change ON audit_log;
CREATE TRIGGER audit_log_no_change
    BEFORE UPDATE OR DELETE ON audit_log
    FOR EACH ROW EXECUTE FUNCTION audit_log_append_only();

DROP TRIGGER IF EXISTS audit_log_no_truncate ON audit_log;
CREATE TRIGGER audit_log_no_truncate
    BEFORE TRUNCATE ON audit_log
    FOR EACH STATEMENT EXECUTE FUNCTION audit_log_append_only();

-- User sessions for Mini App mode selection (member/admin/creator)
CREATE TABLE IF NOT EXISTS user_sessions (
    chat_id       BIGINT      NOT NULL REFERENCES chats(chat_id) ON DELETE CASCADE,
    user_id       BIGINT      NOT NULL,
    mode          TEXT        NOT NULL DEFAULT 'member',  -- member | admin | creator
    role_cached   TEXT        NOT NULL DEFAULT 'member',  -- cached from getChatMember
    role_synced_at TIMESTAMPTZ,
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (chat_id, user_id)
);
