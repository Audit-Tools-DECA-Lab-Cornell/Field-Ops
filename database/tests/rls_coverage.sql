SELECT pg_temp.assert_true(NOT EXISTS (
  SELECT FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'fieldmaps' AND c.relkind IN ('r', 'p') AND NOT c.relrowsecurity
), 'every application table enables RLS');
SELECT pg_temp.assert_true(NOT EXISTS (
  SELECT FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  CROSS JOIN (VALUES ('anon'), ('authenticated'), ('service_role')) r(name)
  WHERE n.nspname IN ('fieldmaps', 'fieldmaps_private', 'gis')
    AND c.relkind IN ('r', 'p', 'v', 'm')
    AND (has_any_column_privilege(r.name, c.oid, 'SELECT,INSERT,UPDATE,REFERENCES')
      OR has_table_privilege(r.name, c.oid, 'DELETE,TRUNCATE,TRIGGER'))
), 'browser and service roles have no application table grants');
SELECT pg_temp.assert_true(NOT EXISTS (
  SELECT FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname IN ('fieldmaps', 'fieldmaps_private', 'fieldmaps_auth_hooks', 'gis')
    AND (has_function_privilege('anon', p.oid, 'EXECUTE')
      OR has_function_privilege('authenticated', p.oid, 'EXECUTE')
      OR has_function_privilege('service_role', p.oid, 'EXECUTE')
      OR EXISTS (SELECT FROM aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
        WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE'))
), 'application functions are not publicly executable');
SELECT pg_temp.assert_true(
  (SELECT NOT rolbypassrls AND NOT rolsuper FROM pg_roles WHERE rolname = 'fieldmaps_api'),
  'API role cannot bypass row security'
);
CREATE FUNCTION fieldmaps.coverage_probe() RETURNS integer LANGUAGE sql AS 'SELECT 1';
SELECT pg_temp.assert_true(
  NOT has_function_privilege('anon', 'fieldmaps.coverage_probe()', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'fieldmaps.coverage_probe()', 'EXECUTE'),
  'new functions default to private'
);
DROP FUNCTION fieldmaps.coverage_probe();
