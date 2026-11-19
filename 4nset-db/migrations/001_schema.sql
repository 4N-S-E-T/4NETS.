-- 001_schema.sql — 4.N.S.E.T v1 core schema (platform phases 1–2)
-- Run as nset_owner.
--
-- Conventions
--  * UUID primary keys. Clients may supply their own (offline-created records), so
--    re-syncing the same record is idempotent.
--  * Every tenant-owned table has mine_id. Child tables reference their parent with a
--    COMPOSITE foreign key (mine_id, parent_id), so a row can never point at another
--    mine's data, even if application code has a bug.
--  * Rows are deactivated (is_active), not deleted.

CREATE SCHEMA IF NOT EXISTS app;

-- ---------------------------------------------------------------------------
-- Platform-level tables (not tenant-owned)
-- ---------------------------------------------------------------------------
CREATE TABLE mines (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name        text        NOT NULL,
  slug        text        NOT NULL UNIQUE CHECK (slug ~ '^[a-z0-9-]+$'),
  status      text        NOT NULL DEFAULT 'onboarding'
              CHECK (status IN ('onboarding','active','read_only','suspended')),
  branding    jsonb       NOT NULL DEFAULT '{}',
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE platform_users (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email         text        NOT NULL,
  display_name  text        NOT NULL,
  password_hash text,
  is_active     boolean     NOT NULL DEFAULT true,
  created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX platform_users_email_uq ON platform_users (lower(email));

-- ---------------------------------------------------------------------------
-- Tenant-owned: users, structure, employees, devices
-- ---------------------------------------------------------------------------
CREATE TABLE mine_users (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  mine_id       uuid        NOT NULL REFERENCES mines(id),
  email         text        NOT NULL,
  display_name  text        NOT NULL,
  role          text        NOT NULL CHECK (role IN ('mine_admin','supervisor')),
  password_hash text,
  is_active     boolean     NOT NULL DEFAULT true,
  created_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (mine_id, id)
);
CREATE UNIQUE INDEX mine_users_email_uq ON mine_users (mine_id, lower(email));

CREATE TABLE sites (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  mine_id    uuid        NOT NULL REFERENCES mines(id),
  name       text        NOT NULL,
  is_active  boolean     NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (mine_id, id),
  UNIQUE (mine_id, name)
);

CREATE TABLE sections (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  mine_id    uuid        NOT NULL REFERENCES mines(id),
  site_id    uuid        NOT NULL,
  name       text        NOT NULL,
  department text,
  is_active  boolean     NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (mine_id, id),
  UNIQUE (mine_id, site_id, id),
  UNIQUE (mine_id, site_id, name),
  FOREIGN KEY (mine_id, site_id) REFERENCES sites (mine_id, id)
);

-- Shifts are fully configurable. talk_cycle_minutes is the configurable "template refresh"
-- rule (spec §10); NULL = one talk per shift.
CREATE TABLE shifts (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  mine_id            uuid        NOT NULL REFERENCES mines(id),
  name               text        NOT NULL,
  start_time         time        NOT NULL,
  duration_minutes   integer     NOT NULL CHECK (duration_minutes BETWEEN 1 AND 1440),
  talk_cycle_minutes integer     CHECK (talk_cycle_minutes > 0),
  is_active          boolean     NOT NULL DEFAULT true,
  created_at         timestamptz NOT NULL DEFAULT now(),
  UNIQUE (mine_id, id),
  UNIQUE (mine_id, name)
);

-- One combined register for employees and contractors (spec §7.4).
CREATE TABLE employees (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  mine_id            uuid        NOT NULL REFERENCES mines(id),
  employee_number    text        NOT NULL,
  full_name          text        NOT NULL,
  employee_type      text        NOT NULL DEFAULT 'employee'
                     CHECK (employee_type IN ('employee','contractor')),
  contractor_company text,
  section_id         uuid,
  is_active          boolean     NOT NULL DEFAULT true,
  created_at         timestamptz NOT NULL DEFAULT now(),
  UNIQUE (mine_id, id),
  UNIQUE (mine_id, employee_number),
  FOREIGN KEY (mine_id, section_id) REFERENCES sections (mine_id, id)
);

CREATE TABLE devices (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  mine_id           uuid        NOT NULL REFERENCES mines(id),
  name              text        NOT NULL,
  device_identifier text        NOT NULL,
  status            text        NOT NULL DEFAULT 'pending'
                    CHECK (status IN ('pending','active','revoked')),
  registered_by     uuid,
  created_at        timestamptz NOT NULL DEFAULT now(),
  UNIQUE (mine_id, id),
  UNIQUE (mine_id, device_identifier),
  FOREIGN KEY (mine_id, registered_by) REFERENCES mine_users (mine_id, id)
);

-- ---------------------------------------------------------------------------
-- Templates: reusable definition (templates) + immutable versions (template_versions)
-- ---------------------------------------------------------------------------
CREATE TABLE templates (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  mine_id    uuid        NOT NULL REFERENCES mines(id),
  code       text        NOT NULL,
  name       text        NOT NULL,
  is_active  boolean     NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (mine_id, id),
  UNIQUE (mine_id, code)
);

CREATE TABLE template_versions (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  mine_id        uuid        NOT NULL REFERENCES mines(id),
  template_id    uuid        NOT NULL,
  version_number integer     NOT NULL CHECK (version_number > 0),
  definition     jsonb       NOT NULL CHECK (jsonb_typeof(definition) = 'object'),
  status         text        NOT NULL DEFAULT 'draft'
                 CHECK (status IN ('draft','pending_approval','approved','retired')),
  approved_by    uuid,
  approved_at    timestamptz,
  effective_from date,
  effective_to   date,
  created_at     timestamptz NOT NULL DEFAULT now(),
  UNIQUE (mine_id, id),
  UNIQUE (mine_id, template_id, version_number),
  FOREIGN KEY (mine_id, template_id) REFERENCES templates (mine_id, id),
  FOREIGN KEY (mine_id, approved_by) REFERENCES mine_users (mine_id, id),
  CHECK (status NOT IN ('approved','retired')
         OR (approved_by IS NOT NULL AND approved_at IS NOT NULL)),
  CHECK (effective_to IS NULL OR effective_from IS NULL OR effective_to >= effective_from)
);

-- ---------------------------------------------------------------------------
-- Toolbox talks and everything that hangs off them
-- ---------------------------------------------------------------------------
-- Server-side status is draft|submitted. "pending sync" exists only on the device.
-- Sync order (one transaction): insert talk as draft -> children -> UPDATE to submitted.
CREATE TABLE toolbox_talks (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  mine_id             uuid        NOT NULL REFERENCES mines(id),
  reference_number    text,
  template_version_id uuid        NOT NULL,
  site_id             uuid        NOT NULL,
  section_id          uuid        NOT NULL,
  shift_id            uuid        NOT NULL,
  supervisor_id       uuid        NOT NULL,
  device_id           uuid,
  topic               text,
  talk_date           date        NOT NULL,
  started_at          timestamptz NOT NULL,
  answers             jsonb       NOT NULL DEFAULT '{}',   -- answers to the template's fields
  supervisor_declared boolean     NOT NULL DEFAULT false,
  status              text        NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','submitted')),
  client_created_at   timestamptz,
  submitted_at        timestamptz,
  synced_at           timestamptz NOT NULL DEFAULT now(),
  UNIQUE (mine_id, id),
  UNIQUE (mine_id, reference_number),
  FOREIGN KEY (mine_id, template_version_id) REFERENCES template_versions (mine_id, id),
  FOREIGN KEY (mine_id, site_id, section_id) REFERENCES sections (mine_id, site_id, id),
  FOREIGN KEY (mine_id, shift_id)            REFERENCES shifts (mine_id, id),
  FOREIGN KEY (mine_id, supervisor_id)       REFERENCES mine_users (mine_id, id),
  FOREIGN KEY (mine_id, device_id)           REFERENCES devices (mine_id, id),
  CHECK (status = 'draft' OR (submitted_at IS NOT NULL AND supervisor_declared))
);
CREATE INDEX toolbox_talks_date_ix       ON toolbox_talks (mine_id, talk_date DESC);
CREATE INDEX toolbox_talks_section_ix    ON toolbox_talks (mine_id, section_id, talk_date DESC);
CREATE INDEX toolbox_talks_supervisor_ix ON toolbox_talks (mine_id, supervisor_id, talk_date DESC);

CREATE TABLE signatures (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  mine_id            uuid        NOT NULL REFERENCES mines(id),
  toolbox_talk_id    uuid        NOT NULL,
  signer_type        text        NOT NULL CHECK (signer_type IN ('supervisor','employee')),
  signer_user_id     uuid,
  signer_employee_id uuid,
  image_png          bytea       NOT NULL,   -- v1; move to object storage if volume demands
  signed_at          timestamptz NOT NULL,
  UNIQUE (mine_id, id),
  FOREIGN KEY (mine_id, toolbox_talk_id)    REFERENCES toolbox_talks (mine_id, id),
  FOREIGN KEY (mine_id, signer_user_id)     REFERENCES mine_users (mine_id, id),
  FOREIGN KEY (mine_id, signer_employee_id) REFERENCES employees (mine_id, id),
  CHECK (
    (signer_type = 'supervisor' AND signer_user_id IS NOT NULL AND signer_employee_id IS NULL) OR
    (signer_type = 'employee'   AND signer_employee_id IS NOT NULL AND signer_user_id IS NULL)
  )
);
CREATE UNIQUE INDEX signatures_one_supervisor_uq
  ON signatures (toolbox_talk_id) WHERE signer_type = 'supervisor';
CREATE UNIQUE INDEX signatures_one_per_employee_uq
  ON signatures (toolbox_talk_id, signer_employee_id) WHERE signer_type = 'employee';

CREATE TABLE attendance (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  mine_id             uuid        NOT NULL REFERENCES mines(id),
  toolbox_talk_id     uuid        NOT NULL,
  employee_id         uuid        NOT NULL,
  status              text        NOT NULL DEFAULT 'present' CHECK (status IN ('present','apology')),
  verification_method text        CHECK (verification_method IN ('biometric','manual')),
  verification_ref    text,       -- biometric transaction reference (no biometric data stored)
  device_id           uuid,
  attended_at         timestamptz NOT NULL,
  signature_id        uuid,
  created_at          timestamptz NOT NULL DEFAULT now(),
  UNIQUE (mine_id, id),
  UNIQUE (mine_id, toolbox_talk_id, employee_id),      -- no duplicate attendance (spec §8.3)
  FOREIGN KEY (mine_id, toolbox_talk_id) REFERENCES toolbox_talks (mine_id, id),
  FOREIGN KEY (mine_id, employee_id)     REFERENCES employees (mine_id, id),
  FOREIGN KEY (mine_id, device_id)       REFERENCES devices (mine_id, id),
  FOREIGN KEY (mine_id, signature_id)    REFERENCES signatures (mine_id, id),
  CHECK (status = 'apology' OR verification_method IS NOT NULL),
  CHECK (verification_method IS DISTINCT FROM 'biometric' OR verification_ref IS NOT NULL)
);
CREATE INDEX attendance_employee_ix ON attendance (mine_id, employee_id);

CREATE TABLE actions (
  id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  mine_id                 uuid        NOT NULL REFERENCES mines(id),
  toolbox_talk_id         uuid        NOT NULL,
  description             text        NOT NULL,
  responsible_employee_id uuid,
  responsible_name        text,
  due_date                date,
  status                  text        NOT NULL DEFAULT 'open' CHECK (status IN ('open','done')),
  created_at              timestamptz NOT NULL DEFAULT now(),
  UNIQUE (mine_id, id),
  FOREIGN KEY (mine_id, toolbox_talk_id)         REFERENCES toolbox_talks (mine_id, id),
  FOREIGN KEY (mine_id, responsible_employee_id) REFERENCES employees (mine_id, id),
  CHECK (responsible_employee_id IS NOT NULL OR responsible_name IS NOT NULL)
);

-- Corrections to submitted talks (spec §11). Append-only; the original row is never changed.
CREATE TABLE talk_amendments (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  mine_id         uuid        NOT NULL REFERENCES mines(id),
  toolbox_talk_id uuid        NOT NULL,
  amended_by      uuid        NOT NULL,
  reason          text        NOT NULL CHECK (length(btrim(reason)) > 0),
  changes         jsonb       NOT NULL,   -- {field: {"from": ..., "to": ...}}
  created_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (mine_id, id),
  FOREIGN KEY (mine_id, toolbox_talk_id) REFERENCES toolbox_talks (mine_id, id),
  FOREIGN KEY (mine_id, amended_by)      REFERENCES mine_users (mine_id, id)
);

CREATE TABLE audit_logs (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  mine_id     uuid        REFERENCES mines(id),     -- NULL = platform-level event
  actor_type  text        NOT NULL CHECK (actor_type IN ('mine_user','platform_user','device','system')),
  actor_id    uuid,
  action      text        NOT NULL,
  entity_type text,
  entity_id   uuid,
  details     jsonb       NOT NULL DEFAULT '{}',
  ip          inet,
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX audit_logs_mine_ix ON audit_logs (mine_id, created_at DESC);
