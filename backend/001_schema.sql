-- migrations/001_schema.sql
-- AdvoHQ — Full PostgreSQL schema for AWS RDS
-- Run once to create all tables, indexes, and RLS policies.

-- ─────────────────────────────────────────────────────────────────────────────
-- EXTENSIONS
-- ─────────────────────────────────────────────────────────────────────────────
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ─────────────────────────────────────────────────────────────────────────────
-- ENUMS
-- ─────────────────────────────────────────────────────────────────────────────
DO $$ BEGIN
  CREATE TYPE user_role   AS ENUM ('admin','advocate','paralegal','client');
  CREATE TYPE case_status AS ENUM ('active','pending','closed','archived');
  CREATE TYPE case_type   AS ENUM ('civil','criminal','family','corporate','property','labour','constitutional','other');
  CREATE TYPE file_type   AS ENUM ('brief','petition','order','evidence','correspondence','contract','other');
  CREATE TYPE event_type  AS ENUM ('hearing','meeting','deadline','filing','other');
  CREATE TYPE event_status AS ENUM ('scheduled','completed','cancelled','rescheduled');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- USERS
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS users (
  id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  email         TEXT UNIQUE NOT NULL,
  username      TEXT UNIQUE NOT NULL,
  password_hash TEXT NOT NULL,
  full_name     TEXT NOT NULL,
  role          user_role NOT NULL DEFAULT 'advocate',
  avatar_url    TEXT,
  phone         TEXT,
  bar_number    TEXT,                          -- Bar registration number
  firm_name     TEXT,
  is_active     BOOLEAN NOT NULL DEFAULT TRUE,
  last_login_at TIMESTAMPTZ,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_users_email    ON users(email);
CREATE INDEX IF NOT EXISTS idx_users_username ON users(username);
CREATE INDEX IF NOT EXISTS idx_users_role     ON users(role);

-- ─────────────────────────────────────────────────────────────────────────────
-- CASES
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS cases (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  case_number     TEXT UNIQUE NOT NULL,        -- e.g. "CRL/2024/001234"
  title           TEXT NOT NULL,
  description     TEXT,
  case_type       case_type NOT NULL DEFAULT 'civil',
  status          case_status NOT NULL DEFAULT 'active',
  court_name      TEXT,
  court_location  TEXT,
  judge_name      TEXT,
  client_name     TEXT NOT NULL,
  client_email    TEXT,
  client_phone    TEXT,
  opposing_party  TEXT,
  next_hearing_at TIMESTAMPTZ,
  filed_at        DATE,
  closed_at       TIMESTAMPTZ,
  owner_id        UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_cases_owner      ON cases(owner_id);
CREATE INDEX IF NOT EXISTS idx_cases_status     ON cases(status);
CREATE INDEX IF NOT EXISTS idx_cases_number     ON cases(case_number);
CREATE INDEX IF NOT EXISTS idx_cases_next_hrng  ON cases(next_hearing_at);

-- ─────────────────────────────────────────────────────────────────────────────
-- CASE MEMBERS (team members assigned to a case)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS case_members (
  case_id    UUID NOT NULL REFERENCES cases(id) ON DELETE CASCADE,
  user_id    UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  role       TEXT NOT NULL DEFAULT 'member',   -- 'lead','member','observer'
  added_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (case_id, user_id)
);

CREATE INDEX IF NOT EXISTS idx_case_members_user ON case_members(user_id);

-- ─────────────────────────────────────────────────────────────────────────────
-- CASE NOTES
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS case_notes (
  id         UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  case_id    UUID NOT NULL REFERENCES cases(id) ON DELETE CASCADE,
  author_id  UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  content    TEXT NOT NULL,
  is_private BOOLEAN NOT NULL DEFAULT FALSE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_notes_case ON case_notes(case_id);

-- ─────────────────────────────────────────────────────────────────────────────
-- FILES (metadata; actual bytes live in S3)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS case_files (
  id           UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  case_id      UUID NOT NULL REFERENCES cases(id) ON DELETE CASCADE,
  uploaded_by  UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  filename     TEXT NOT NULL,
  s3_key       TEXT NOT NULL,                  -- Full S3 object key
  mime_type    TEXT NOT NULL DEFAULT 'application/octet-stream',
  size_bytes   BIGINT NOT NULL DEFAULT 0,
  file_type    file_type NOT NULL DEFAULT 'other',
  description  TEXT,
  version      INTEGER NOT NULL DEFAULT 1,
  is_deleted   BOOLEAN NOT NULL DEFAULT FALSE,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_files_case    ON case_files(case_id) WHERE NOT is_deleted;
CREATE INDEX IF NOT EXISTS idx_files_uploader ON case_files(uploaded_by);
CREATE INDEX IF NOT EXISTS idx_files_s3      ON case_files(s3_key);

-- ─────────────────────────────────────────────────────────────────────────────
-- SCHEDULE / EVENTS
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS schedule_events (
  id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  case_id       UUID REFERENCES cases(id) ON DELETE SET NULL,
  owner_id      UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  title         TEXT NOT NULL,
  description   TEXT,
  event_type    event_type NOT NULL DEFAULT 'hearing',
  status        event_status NOT NULL DEFAULT 'scheduled',
  location      TEXT,
  starts_at     TIMESTAMPTZ NOT NULL,
  ends_at       TIMESTAMPTZ,
  all_day       BOOLEAN NOT NULL DEFAULT FALSE,
  reminder_mins INTEGER,                       -- minutes before event
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_events_owner    ON schedule_events(owner_id);
CREATE INDEX IF NOT EXISTS idx_events_case     ON schedule_events(case_id);
CREATE INDEX IF NOT EXISTS idx_events_starts   ON schedule_events(starts_at);
CREATE INDEX IF NOT EXISTS idx_events_status   ON schedule_events(status);

-- ─────────────────────────────────────────────────────────────────────────────
-- AUDIT LOG
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS audit_log (
  id         UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id    UUID REFERENCES users(id) ON DELETE SET NULL,
  action     TEXT NOT NULL,                    -- e.g. 'case.create', 'file.delete'
  entity     TEXT NOT NULL,                    -- table name
  entity_id  UUID,
  meta       JSONB,
  ip_address TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_audit_user   ON audit_log(user_id);
CREATE INDEX IF NOT EXISTS idx_audit_entity ON audit_log(entity, entity_id);
CREATE INDEX IF NOT EXISTS idx_audit_time   ON audit_log(created_at DESC);

-- ─────────────────────────────────────────────────────────────────────────────
-- AUTO-UPDATE updated_at TRIGGER
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DO $$ DECLARE
  t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY['users','cases','case_notes','schedule_events'] LOOP
    EXECUTE format(
      'CREATE TRIGGER trg_%s_updated_at
       BEFORE UPDATE ON %s
       FOR EACH ROW EXECUTE FUNCTION set_updated_at()',
      t, t
    );
  END LOOP;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
