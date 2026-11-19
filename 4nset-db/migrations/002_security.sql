-- 002_security.sql — tenant isolation (RLS), grants, platform functions
-- Run as nset_owner, after 000 and 001.
--
-- How the API uses this: at the start of EVERY request/transaction, after authenticating
-- the user, run:   SELECT set_config('app.mine_id', '<mine uuid>', true);
-- (true = local to the transaction, so pooled connections never leak a tenant.)
-- If it is not set, every tenant query returns zero rows (fail closed).

CREATE OR REPLACE FUNCTION app.current_mine_id() RETURNS uuid
LANGUAGE sql STABLE AS
$$ SELECT NULLIF(current_setting('app.mine_id', true), '')::uuid $$;

GRANT USAGE ON SCHEMA app TO nset_app, nset_platform;
GRANT EXECUTE ON FUNCTION app.current_mine_id() TO nset_app, nset_platform;

-- --- RLS on all tenant-owned tables. FORCE applies it to the table owner too. ---
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'mine_users','sites','sections','shifts','employees','devices','templates',
    'template_versions','toolbox_talks','signatures','attendance','actions','talk_amendments'
  ] LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY', t);
    EXECUTE format(
      'CREATE POLICY tenant_isolation ON %I
         USING (mine_id = app.current_mine_id())
         WITH CHECK (mine_id = app.current_mine_id())', t);
  END LOOP;
END $$;

-- audit_logs: tenants read/insert their own rows; the platform may only insert.
ALTER TABLE audit_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_logs FORCE ROW LEVEL SECURITY;
CREATE POLICY audit_tenant_select ON audit_logs FOR SELECT
  USING (mine_id = app.current_mine_id());
CREATE POLICY audit_tenant_insert ON audit_logs FOR INSERT
  WITH CHECK (mine_id = app.current_mine_id());
CREATE POLICY audit_platform_insert ON audit_logs FOR INSERT TO nset_platform
  WITH CHECK (true);

-- mines: a tenant sees only its own row; the platform sees all. Not FORCEd, so the
-- owner (migrations, SECURITY DEFINER functions) can manage mines.
ALTER TABLE mines ENABLE ROW LEVEL SECURITY;
CREATE POLICY mines_tenant_select ON mines FOR SELECT
  USING (id = app.current_mine_id());
CREATE POLICY mines_platform_all ON mines FOR ALL TO nset_platform
  USING (true) WITH CHECK (true);

ALTER TABLE platform_users ENABLE ROW LEVEL SECURITY;
CREATE POLICY platform_users_platform_all ON platform_users FOR ALL TO nset_platform
  USING (true) WITH CHECK (true);

-- --- Grants (least privilege) ---
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM PUBLIC;

-- API runtime role
GRANT SELECT ON mines TO nset_app;
GRANT SELECT, INSERT, UPDATE ON
  mine_users, sites, sections, shifts, employees, devices, templates, template_versions
  TO nset_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON toolbox_talks, signatures, attendance, actions TO nset_app;
GRANT SELECT, INSERT ON talk_amendments, audit_logs TO nset_app;

-- Super Admin role: platform tables only. NO access to any tenant-owned table (spec §7.1).
GRANT SELECT, INSERT, UPDATE ON mines, platform_users TO nset_platform;
GRANT INSERT ON audit_logs TO nset_platform;

-- --- Login helper: resolve a mine from its slug before the tenant is known ---
CREATE OR REPLACE FUNCTION app.resolve_mine(p_slug text) RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS
$$ SELECT id FROM mines WHERE slug = lower(p_slug) AND status <> 'suspended' $$;
REVOKE ALL ON FUNCTION app.resolve_mine(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.resolve_mine(text) TO nset_app;

-- --- Mine Room creation: the only way the platform role touches tenant data ---
-- Creates the mine, its first Mine Administrator and an audit entry, atomically.
CREATE OR REPLACE FUNCTION app.create_mine_room(
  p_name text, p_slug text, p_admin_email text, p_admin_name text
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_mine uuid;
BEGIN
  INSERT INTO mines (name, slug) VALUES (p_name, lower(p_slug)) RETURNING id INTO v_mine;

  PERFORM set_config('app.mine_id', v_mine::text, true);
  INSERT INTO mine_users (mine_id, email, display_name, role)
    VALUES (v_mine, p_admin_email, p_admin_name, 'mine_admin');
  INSERT INTO audit_logs (mine_id, actor_type, action, entity_type, entity_id)
    VALUES (v_mine, 'platform_user', 'mine_room.created', 'mine', v_mine);
  PERFORM set_config('app.mine_id', '', true);

  RETURN v_mine;
END $$;
REVOKE ALL ON FUNCTION app.create_mine_room(text, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.create_mine_room(text, text, text, text) TO nset_platform;
