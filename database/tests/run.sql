\set ON_ERROR_STOP on
BEGIN;
GRANT fieldmaps_api, fieldmaps_sample_reader TO postgres WITH SET TRUE;
SET LOCAL search_path = fieldmaps, extensions, public;

CREATE FUNCTION pg_temp.assert_true(actual boolean, label text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF actual IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL: %', label;
  END IF;
  RAISE NOTICE 'PASS: %', label;
END;
$$;

CREATE FUNCTION pg_temp.assert_rejected(statement text, expected_state text, label text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE actual_state text;
BEGIN
  BEGIN
    EXECUTE statement;
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS actual_state = RETURNED_SQLSTATE;
  END;
  IF actual_state IS DISTINCT FROM expected_state THEN
    RAISE EXCEPTION 'FAIL: %, expected %, got %', label, expected_state, actual_state;
  END IF;
  RAISE NOTICE 'PASS: %', label;
END;
$$;
GRANT EXECUTE ON FUNCTION pg_temp.assert_true(boolean, text),
  pg_temp.assert_rejected(text, text, text) TO fieldmaps_api, fieldmaps_sample_reader;


-- Given the sample project and another organization with its own site and form.
\ir ../../supabase/seed.sql
INSERT INTO organizations (id, name, slug) VALUES ('20000000-0000-4000-8000-000000000001', 'Other team', 'other-team');
INSERT INTO projects (id, organization_id, name, code) VALUES (
  '20000000-0000-4000-8000-000000000002', '20000000-0000-4000-8000-000000000001', 'Other project', 'other-project'
);
INSERT INTO sites (id, organization_id, project_id, code, name) VALUES (
  '20000000-0000-4000-8000-000000000003', '20000000-0000-4000-8000-000000000001',
  '20000000-0000-4000-8000-000000000002', 'other-site', 'Other site'
);
INSERT INTO form_versions (id, organization_id, project_id, code, definition) VALUES (
  '20000000-0000-4000-8000-000000000004', '20000000-0000-4000-8000-000000000001',
  '20000000-0000-4000-8000-000000000002', 'other-v1', '{"fields":[]}'
);

-- When an observation is stored using the mobile contract's UUID and longitude/latitude.
INSERT INTO observations (
  id, organization_id, project_id, site_id, form_version_id,
  observer_code, observed_at, geom, answers
) VALUES (
  '30000000-0000-4000-8000-000000000001', '10000000-0000-4000-8000-000000000001',
  '10000000-0000-4000-8000-000000000002', '10000000-0000-4000-8000-000000000003',
  '10000000-0000-4000-8000-000000000004', 'QA', '2026-09-17T14:00:00Z',
  ST_SetSRID(ST_MakePoint(-76.485, 42.448), 4326), '{"people":3,"notes":"Database test"}'
);

-- Then GIS consumers get the same location, stable key, and typed answers.
SELECT pg_temp.assert_true(
  (SELECT longitude = -76.485 AND latitude = 42.448 AND people = 3
    AND notes = 'Database test' AND ST_SRID(geom) = 4326 AND fid > 0
   FROM gis.sample_observations WHERE observation_id = '30000000-0000-4000-8000-000000000001'), 'QGIS projection preserves coordinates and typed answers'
);
-- The exact ledger, in order: a replay adds nothing, and a new migration must be listed here.
SELECT pg_temp.assert_true(
  (SELECT array_agg(version ORDER BY version) FROM fieldmaps_meta.schema_migrations)
    = ARRAY['0001_initial', '0002_observation_uploads', '0003_spatial_interface',
            '0004_site_packages', '0005_package_policy_identity', '0006_default_privileges', '0007_identity_tenancy', '0008_tenancy_functions'],
  'migration replay records each version once'
);
\ir constraints.sql
\ir access.sql
\ir rls_coverage.sql
\ir tenancy.sql
\ir tenancy_functions.sql
ROLLBACK;
\echo All database scenarios passed; test records rolled back.
