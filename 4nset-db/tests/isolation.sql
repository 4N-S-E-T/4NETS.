-- tests/isolation.sql — run as a superuser against a migrated database:
--   psql -v ON_ERROR_STOP=1 "$TARGET" -f tests/isolation.sql
-- Exits non-zero on the first failed check. Everything runs through the real runtime roles.
\set ON_ERROR_STOP on
\set QUIET on
SET client_min_messages = notice;

CREATE SCHEMA t;
GRANT USAGE ON SCHEMA t TO nset_app, nset_platform;

CREATE FUNCTION t.expect_error(p_sql text, p_state text, p_label text) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE failed boolean := false;
BEGIN
  BEGIN
    EXECUTE p_sql;
  EXCEPTION WHEN OTHERS THEN
    failed := true;
    IF SQLSTATE <> p_state THEN
      RAISE EXCEPTION 'FAIL: % (expected %, got % %)', p_label, p_state, SQLSTATE, SQLERRM;
    END IF;
  END;
  IF NOT failed THEN RAISE EXCEPTION 'FAIL: % (expected error %, none raised)', p_label, p_state; END IF;
  RAISE NOTICE 'PASS: %', p_label;
END $$;

CREATE FUNCTION t.expect_eq(p_actual bigint, p_expected bigint, p_label text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF p_actual IS DISTINCT FROM p_expected THEN
    RAISE EXCEPTION 'FAIL: % (expected %, got %)', p_label, p_expected, p_actual;
  END IF;
  RAISE NOTICE 'PASS: %', p_label;
END $$;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA t TO nset_app, nset_platform;

-- ---------------------------------------------------------------- seed via real roles
SET ROLE nset_platform;
SELECT app.create_mine_room('Mine A', 'mine-a', 'admin@a.test', 'A Admin') AS mine_a \gset
SELECT app.create_mine_room('Mine B', 'mine-b', 'admin@b.test', 'B Admin') AS mine_b \gset

SET ROLE nset_app;
SELECT set_config('app.mine_id', :'mine_a', false);
SELECT id AS admin_a FROM mine_users WHERE role = 'mine_admin' \gset
INSERT INTO mine_users (mine_id,email,display_name,role) VALUES (:'mine_a','sup@a.test','A Supervisor','supervisor') RETURNING id AS sup_a \gset
INSERT INTO sites (mine_id,name) VALUES (:'mine_a','Main') RETURNING id AS site_a \gset
INSERT INTO sections (mine_id,site_id,name,department) VALUES (:'mine_a',:'site_a','Plant','Processing') RETURNING id AS sec_a \gset
INSERT INTO shifts (mine_id,name,start_time,duration_minutes,talk_cycle_minutes) VALUES (:'mine_a','Day','06:00',720,720) RETURNING id AS shift_a \gset
INSERT INTO employees (mine_id,employee_number,full_name,section_id) VALUES (:'mine_a','12345','Thabo Nkosi',:'sec_a') RETURNING id AS emp_a1 \gset
INSERT INTO employees (mine_id,employee_number,full_name,employee_type,contractor_company) VALUES (:'mine_a','C-900','Lerato Dube','contractor','Acme Drilling') RETURNING id AS emp_a2 \gset
INSERT INTO templates (mine_id,code,name) VALUES (:'mine_a','TBT','Toolbox Talk') RETURNING id AS tpl_a \gset
INSERT INTO template_versions (mine_id,template_id,version_number,definition,status,approved_by,approved_at)
  VALUES (:'mine_a',:'tpl_a',1,'{"fields":[{"key":"objective","type":"text"}]}','approved',:'admin_a',now()) RETURNING id AS tv_a \gset
INSERT INTO template_versions (mine_id,template_id,version_number,definition)
  VALUES (:'mine_a',:'tpl_a',2,'{"fields":[]}') RETURNING id AS tv_a_draft \gset

SELECT set_config('app.mine_id', :'mine_b', false);
INSERT INTO sites (mine_id,name) VALUES (:'mine_b','Main') RETURNING id AS site_b \gset
INSERT INTO sections (mine_id,site_id,name) VALUES (:'mine_b',:'site_b','Plant') RETURNING id AS sec_b \gset
INSERT INTO employees (mine_id,employee_number,full_name) VALUES (:'mine_b','12345','Someone Else') RETURNING id AS emp_b1 \gset

-- ---------------------------------------------------------------- tenant isolation
RESET ROLE;
SET ROLE nset_platform;
SELECT t.expect_error('SELECT * FROM employees', '42501', 'platform role cannot read tenant tables');
SELECT t.expect_error('SELECT * FROM toolbox_talks', '42501', 'platform role cannot read talks');

SET ROLE nset_app;
SELECT set_config('app.mine_id', '', false);
SELECT t.expect_eq((SELECT count(*) FROM employees), 0, 'no tenant set -> zero rows (fail closed)');
SELECT t.expect_eq((SELECT count(*) FROM mines), 0, 'no tenant set -> no mines visible');

SELECT set_config('app.mine_id', :'mine_a', false);
SELECT t.expect_eq((SELECT count(*) FROM employees), 2, 'Mine A sees only its 2 employees');
SELECT t.expect_eq((SELECT count(*) FROM mines), 1, 'Mine A sees only its own mine row');
SELECT t.expect_eq((SELECT count(*) FROM employees WHERE id = :'emp_b1'), 0, 'Mine A cannot see Mine B employee by id');
SELECT t.expect_error(format($q$INSERT INTO employees (mine_id,employee_number,full_name) VALUES (%L,'999','x')$q$, :'mine_b'),
  '42501', 'Mine A cannot insert a row owned by Mine B');
UPDATE employees SET full_name = 'hacked' WHERE id = :'emp_b1';
SELECT set_config('app.mine_id', :'mine_b', false);
SELECT t.expect_eq((SELECT count(*) FROM employees WHERE full_name = 'hacked'), 0, 'Mine A cannot update Mine B rows');
SELECT set_config('app.mine_id', :'mine_a', false);

SELECT t.expect_error(
  format($q$INSERT INTO toolbox_talks (mine_id,template_version_id,site_id,section_id,shift_id,supervisor_id,talk_date,started_at)
            VALUES (%L,%L,%L,%L,%L,%L,current_date,now())$q$, :'mine_a', :'tv_a', :'site_b', :'sec_b', :'shift_a', :'sup_a'),
  '23503', 'composite FK blocks a talk pointing at Mine B''s section');

-- ---------------------------------------------------------------- workflow + integrity
SELECT t.expect_error(
  format($q$INSERT INTO toolbox_talks (mine_id,template_version_id,site_id,section_id,shift_id,supervisor_id,talk_date,started_at)
            VALUES (%L,%L,%L,%L,%L,%L,current_date,now())$q$, :'mine_a', :'tv_a_draft', :'site_a', :'sec_a', :'shift_a', :'sup_a'),
  '23001', 'talk cannot use an unapproved template version');

SELECT t.expect_error(
  format($q$INSERT INTO toolbox_talks (mine_id,template_version_id,site_id,section_id,shift_id,supervisor_id,talk_date,started_at,status,submitted_at,supervisor_declared)
            VALUES (%L,%L,%L,%L,%L,%L,current_date,now(),'submitted',now(),true)$q$, :'mine_a', :'tv_a', :'site_a', :'sec_a', :'shift_a', :'sup_a'),
  '23001', 'talk cannot be inserted already submitted');

INSERT INTO toolbox_talks (mine_id,template_version_id,site_id,section_id,shift_id,supervisor_id,topic,talk_date,started_at,answers)
  VALUES (:'mine_a',:'tv_a',:'site_a',:'sec_a',:'shift_a',:'sup_a','TMM & Pedestrian Safety',current_date,now(),'{"objective":"Walk safely"}')
  RETURNING id AS talk_a \gset

INSERT INTO attendance (mine_id,toolbox_talk_id,employee_id,verification_method,verification_ref,attended_at)
  VALUES (:'mine_a',:'talk_a',:'emp_a1','biometric','TXN-001',now());
SELECT t.expect_error(
  format($q$INSERT INTO attendance (mine_id,toolbox_talk_id,employee_id,verification_method,verification_ref,attended_at)
            VALUES (%L,%L,%L,'biometric','TXN-002',now())$q$, :'mine_a', :'talk_a', :'emp_a1'),
  '23505', 'duplicate attendance for same employee + talk is rejected');
SELECT t.expect_error(
  format($q$INSERT INTO attendance (mine_id,toolbox_talk_id,employee_id,verification_method,attended_at)
            VALUES (%L,%L,%L,'biometric',now())$q$, :'mine_a', :'talk_a', :'emp_a2'),
  '23514', 'biometric attendance requires a verification reference');
SELECT t.expect_error(
  format($q$INSERT INTO attendance (mine_id,toolbox_talk_id,employee_id,verification_method,attended_at)
            VALUES (%L,%L,%L,'manual',now())$q$, :'mine_a', :'talk_a', :'emp_b1'),
  '23503', 'attendance cannot reference another mine''s employee');

INSERT INTO attendance (mine_id,toolbox_talk_id,employee_id,status,attended_at)
  VALUES (:'mine_a',:'talk_a',:'emp_a2','apology',now());
INSERT INTO actions (mine_id,toolbox_talk_id,description,responsible_name,due_date)
  VALUES (:'mine_a',:'talk_a','Repair walkway','J. Mokoena',current_date+1);
INSERT INTO signatures (mine_id,toolbox_talk_id,signer_type,signer_user_id,image_png,signed_at)
  VALUES (:'mine_a',:'talk_a','supervisor',:'sup_a','\x89504e47',now());

SELECT t.expect_error(format($q$UPDATE toolbox_talks SET status='submitted' WHERE id=%L$q$, :'talk_a'),
  '23514', 'submit requires supervisor declaration');
UPDATE toolbox_talks SET supervisor_declared = true WHERE id = :'talk_a';
UPDATE toolbox_talks SET status = 'submitted' WHERE id = :'talk_a';
SELECT t.expect_eq((SELECT count(*) FROM toolbox_talks WHERE id = :'talk_a' AND status='submitted' AND submitted_at IS NOT NULL), 1,
  'draft -> submitted works and stamps submitted_at');

SELECT t.expect_error(format($q$UPDATE toolbox_talks SET topic='changed' WHERE id=%L$q$, :'talk_a'), '23001', 'submitted talk cannot be edited');
SELECT t.expect_error(format($q$DELETE FROM toolbox_talks WHERE id=%L$q$, :'talk_a'), '23001', 'submitted talk cannot be deleted');
SELECT t.expect_error(format($q$DELETE FROM attendance WHERE toolbox_talk_id=%L$q$, :'talk_a'), '23001', 'attendance locked after submit (delete)');
SELECT t.expect_error(format($q$UPDATE attendance SET status='apology' WHERE toolbox_talk_id=%L$q$, :'talk_a'), '23001', 'attendance locked after submit (update)');
SELECT t.expect_error(
  format($q$INSERT INTO actions (mine_id,toolbox_talk_id,description,responsible_name) VALUES (%L,%L,'late','x')$q$, :'mine_a', :'talk_a'),
  '23001', 'cannot add actions after submit');

INSERT INTO talk_amendments (mine_id,toolbox_talk_id,amended_by,reason,changes)
  VALUES (:'mine_a',:'talk_a',:'admin_a','Topic typo','{"topic":{"from":"TMM & Pedestrian Safety","to":"TMM and Pedestrian Safety"}}');
SELECT t.expect_error(
  format($q$INSERT INTO talk_amendments (mine_id,toolbox_talk_id,amended_by,reason,changes) VALUES (%L,%L,%L,'  ','{}')$q$, :'mine_a', :'talk_a', :'admin_a'),
  '23514', 'amendment requires a reason');
SELECT t.expect_error('UPDATE talk_amendments SET reason = ''x''', '42501', 'amendments cannot be updated by the API role');

-- templates
SELECT t.expect_error(format($q$UPDATE template_versions SET definition='{}' WHERE id=%L$q$, :'tv_a'), '23001', 'approved template version content is immutable');
SELECT t.expect_error(format($q$UPDATE template_versions SET status='draft' WHERE id=%L$q$, :'tv_a'), '23001', 'approved template cannot move back to draft');
SELECT t.expect_error(format($q$DELETE FROM template_versions WHERE id=%L$q$, :'tv_a'), '42501', 'API role cannot delete template versions');
UPDATE template_versions SET status = 'retired' WHERE id = :'tv_a';

-- audit
INSERT INTO audit_logs (mine_id,actor_type,actor_id,action,entity_type,entity_id)
  VALUES (:'mine_a','mine_user',:'sup_a','talk.submitted','toolbox_talk',:'talk_a');
SELECT t.expect_eq((SELECT count(*) FROM audit_logs WHERE action = 'talk.submitted'), 1, 'audit entry written and visible to its own mine');
SELECT t.expect_error('UPDATE audit_logs SET action = ''x''', '42501', 'API role cannot update audit logs');
SELECT t.expect_error('DELETE FROM audit_logs', '42501', 'API role cannot delete audit logs');
SELECT set_config('app.mine_id', :'mine_b', false);
SELECT t.expect_eq((SELECT count(*) FROM audit_logs WHERE action = 'talk.submitted'), 0, 'Mine B cannot see Mine A audit logs');

-- ---------------------------------------------------------------- cleanup
RESET ROLE;
DROP SCHEMA t CASCADE;
\echo ALL TESTS PASSED
