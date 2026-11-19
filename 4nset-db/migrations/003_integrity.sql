-- 003_integrity.sql — immutability and workflow rules enforced in the database
-- Run as nset_owner, after 002.

-- --- Toolbox talks: always created as draft; frozen once submitted --------------------
CREATE OR REPLACE FUNCTION app.talk_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_tpl_status text;
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.status <> 'draft' THEN
      RAISE EXCEPTION 'Toolbox talks must be created as draft, then submitted'
        USING ERRCODE = 'restrict_violation';
    END IF;
    SELECT status INTO v_tpl_status FROM template_versions
      WHERE mine_id = NEW.mine_id AND id = NEW.template_version_id;
    IF v_tpl_status IS NULL OR v_tpl_status NOT IN ('approved','retired') THEN
      RAISE EXCEPTION 'Template version % is not approved', NEW.template_version_id
        USING ERRCODE = 'restrict_violation';
    END IF;
    RETURN NEW;
  END IF;

  IF OLD.status = 'submitted' THEN
    RAISE EXCEPTION 'Submitted toolbox talk % is immutable; record a talk_amendment instead', OLD.id
      USING ERRCODE = 'restrict_violation';
  END IF;
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;

  IF NEW.id <> OLD.id OR NEW.mine_id <> OLD.mine_id
     OR NEW.template_version_id <> OLD.template_version_id THEN
    RAISE EXCEPTION 'id, mine_id and template_version_id cannot change'
      USING ERRCODE = 'restrict_violation';
  END IF;
  IF NEW.status = 'submitted' THEN
    NEW.submitted_at := COALESCE(NEW.submitted_at, now());
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER toolbox_talks_guard
  BEFORE INSERT OR UPDATE OR DELETE ON toolbox_talks
  FOR EACH ROW EXECUTE FUNCTION app.talk_guard();

-- --- Children (attendance, signatures, actions): locked once the talk is submitted -----
CREATE OR REPLACE FUNCTION app.talk_child_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_talk uuid; v_status text;
BEGIN
  IF TG_OP = 'DELETE' THEN v_talk := OLD.toolbox_talk_id; ELSE v_talk := NEW.toolbox_talk_id; END IF;

  -- FOR SHARE serialises against a concurrent submit of the same talk.
  SELECT status INTO v_status FROM toolbox_talks WHERE id = v_talk FOR SHARE;
  IF v_status = 'submitted' THEN
    RAISE EXCEPTION 'Toolbox talk % is submitted; % is read-only', v_talk, TG_TABLE_NAME
      USING ERRCODE = 'restrict_violation';
  END IF;
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER attendance_guard BEFORE INSERT OR UPDATE OR DELETE ON attendance
  FOR EACH ROW EXECUTE FUNCTION app.talk_child_guard();
CREATE TRIGGER signatures_guard BEFORE INSERT OR UPDATE OR DELETE ON signatures
  FOR EACH ROW EXECUTE FUNCTION app.talk_child_guard();
CREATE TRIGGER actions_guard BEFORE INSERT OR UPDATE OR DELETE ON actions
  FOR EACH ROW EXECUTE FUNCTION app.talk_child_guard();

-- --- Template versions: content locks on approval; status only moves forward ----------
CREATE OR REPLACE FUNCTION app.template_version_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  v_rank constant jsonb :=
    '{"draft":0,"pending_approval":1,"approved":2,"retired":3}';
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.status <> 'draft' THEN
      RAISE EXCEPTION 'Only draft template versions can be deleted'
        USING ERRCODE = 'restrict_violation';
    END IF;
    RETURN OLD;
  END IF;

  IF OLD.status IN ('approved','retired') THEN
    IF NEW.definition     IS DISTINCT FROM OLD.definition
       OR NEW.version_number <> OLD.version_number
       OR NEW.template_id    <> OLD.template_id
       OR NEW.mine_id        <> OLD.mine_id
       OR NEW.approved_by IS DISTINCT FROM OLD.approved_by
       OR NEW.approved_at IS DISTINCT FROM OLD.approved_at THEN
      RAISE EXCEPTION 'Approved template version % is immutable; create a new version', OLD.id
        USING ERRCODE = 'restrict_violation';
    END IF;
    IF (v_rank ->> NEW.status)::int < (v_rank ->> OLD.status)::int THEN
      RAISE EXCEPTION 'Template version status cannot move backwards'
        USING ERRCODE = 'restrict_violation';
    END IF;
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER template_versions_guard
  BEFORE UPDATE OR DELETE ON template_versions
  FOR EACH ROW EXECUTE FUNCTION app.template_version_guard();

-- --- Append-only tables ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION app.append_only() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION '% is append-only', TG_TABLE_NAME USING ERRCODE = 'restrict_violation';
END $$;

CREATE TRIGGER audit_logs_append_only BEFORE UPDATE OR DELETE ON audit_logs
  FOR EACH ROW EXECUTE FUNCTION app.append_only();
CREATE TRIGGER audit_logs_no_truncate BEFORE TRUNCATE ON audit_logs
  FOR EACH STATEMENT EXECUTE FUNCTION app.append_only();
CREATE TRIGGER talk_amendments_append_only BEFORE UPDATE OR DELETE ON talk_amendments
  FOR EACH ROW EXECUTE FUNCTION app.append_only();
CREATE TRIGGER talk_amendments_no_truncate BEFORE TRUNCATE ON talk_amendments
  FOR EACH STATEMENT EXECUTE FUNCTION app.append_only();
