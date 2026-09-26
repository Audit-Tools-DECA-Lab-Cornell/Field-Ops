-- Given a second organization's observation and the restricted sample GIS role.
INSERT INTO observations (
  id, organization_id, project_id, site_id, form_version_id,
  observer_code, observed_at, geom, answers
) VALUES (
  '30000000-0000-4000-8000-000000000002', '20000000-0000-4000-8000-000000000001',
  '20000000-0000-4000-8000-000000000002', '20000000-0000-4000-8000-000000000003',
  '20000000-0000-4000-8000-000000000004', 'OTHER', now(),
  ST_SetSRID(ST_MakePoint(0, 0), 4326), '{"people":9}'
);
SET LOCAL ROLE fieldmaps_sample_reader;
-- When that role queries its approved GIS layer, only the sample project is visible.
SELECT pg_temp.assert_true(
  (SELECT count(*) = 1 AND min(observer_code) = 'QA' FROM gis.sample_observations
   WHERE observation_id IN ('30000000-0000-4000-8000-000000000001', '30000000-0000-4000-8000-000000000002')),
  'sample GIS role cannot see another organization observations'
);
SELECT pg_temp.assert_rejected(
  $$SELECT * FROM fieldmaps.observations$$, '42501', 'GIS role cannot read raw observation tables'
);
SELECT pg_temp.assert_rejected(
  $$UPDATE gis.sample_observations SET observer_code = 'CHANGED'$$,
  '55000', 'GIS projection rejects edits'
);
SELECT pg_temp.assert_true(
  NOT has_table_privilege(current_user, 'gis.sample_observations', 'INSERT')
  AND NOT has_table_privilege(current_user, 'gis.sample_observations', 'UPDATE')
  AND NOT has_table_privilege(current_user, 'gis.sample_observations', 'DELETE'),
  'GIS role has no write privileges'
);
SELECT pg_temp.assert_true(
  NOT has_schema_privilege(current_user, 'public', 'CREATE'),
  'GIS role cannot create objects in the extension schema'
);
RESET ROLE;
