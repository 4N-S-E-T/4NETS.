-- 000_roles.sql — run ONCE as a superuser (cluster-level objects).
-- nset_owner : owns the schema, runs migrations. Never used by the API at runtime.
-- nset_app   : the API's runtime role. Subject to RLS, no BYPASSRLS.
-- nset_platform : Super Admin operations only. No grants on any tenant-owned table.
-- Set passwords outside source control, e.g.  ALTER ROLE nset_app PASSWORD '...';
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'nset_owner') THEN
    CREATE ROLE nset_owner LOGIN NOBYPASSRLS;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'nset_app') THEN
    CREATE ROLE nset_app LOGIN NOBYPASSRLS;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'nset_platform') THEN
    CREATE ROLE nset_platform LOGIN NOBYPASSRLS;
  END IF;
END $$;

-- The database itself should be owned by nset_owner:
--   CREATE DATABASE nset OWNER nset_owner;
