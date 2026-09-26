-- Given a valid saved observation, invalid writes must leave it intact.
SELECT pg_temp.assert_rejected(
  $$INSERT INTO observations (id, organization_id, project_id, site_id, form_version_id,
    observer_code, observed_at, geom, answers)
    SELECT id, organization_id, project_id, site_id, form_version_id,
      observer_code, observed_at, geom, answers FROM observations WHERE id = '30000000-0000-4000-8000-000000000001'$$,
  '23505', 'duplicate observation IDs cannot create a second record'
);
SELECT pg_temp.assert_rejected(
  $$UPDATE observations SET site_id = '20000000-0000-4000-8000-000000000003' WHERE id = '30000000-0000-4000-8000-000000000001'$$,
  '23503', 'an observation cannot reference another organization site'
);
SELECT pg_temp.assert_rejected(
  $$UPDATE observations SET form_version_id = '20000000-0000-4000-8000-000000000004' WHERE id = '30000000-0000-4000-8000-000000000001'$$,
  '23503', 'an observation cannot reference another project form'
);
SELECT pg_temp.assert_rejected(
  $$UPDATE observations SET geom = ST_SetSRID(ST_MakePoint(181, 42), 4326) WHERE id = '30000000-0000-4000-8000-000000000001'$$,
  '23514', 'out-of-range longitude is rejected'
);
SELECT pg_temp.assert_rejected(
  $$UPDATE observations SET geom = ST_GeomFromText('POINT EMPTY', 4326) WHERE id = '30000000-0000-4000-8000-000000000001'$$,
  '23514', 'empty locations are rejected'
);
SELECT pg_temp.assert_rejected(
  $$UPDATE observations SET geom = ST_SetSRID(ST_MakePoint(1, 2), 3857) WHERE id = '30000000-0000-4000-8000-000000000001'$$,
  '22023', 'a projected CRS cannot be silently relabelled as WGS84'
);
SELECT pg_temp.assert_rejected(
  $$UPDATE observations SET answers = '[]' WHERE id = '30000000-0000-4000-8000-000000000001'$$,
  '23514', 'answers must be a JSON object'
);
SELECT pg_temp.assert_rejected(
  $$UPDATE form_versions SET definition = '{"fields":["changed"]}'$$,
  '23514', 'published form definitions cannot be rewritten'
);
SELECT pg_temp.assert_rejected(
  $$DELETE FROM form_versions$$,
  '23514', 'published form versions cannot be deleted'
);
SELECT pg_temp.assert_true(
  (SELECT count(*) = 1 AND min(revision) = 1 FROM observations WHERE id = '30000000-0000-4000-8000-000000000001'),
  'rejected writes preserve the original record and revision'
);
-- When an accepted edit supplies the expected current revision.
UPDATE observations SET answers = '{"people":4,"notes":"Revised"}' WHERE id = '30000000-0000-4000-8000-000000000001' AND revision = 1;
-- Then the database advances the revision, including tombstones for future sync.
SELECT pg_temp.assert_true(
  (SELECT revision = 2 AND updated_at >= received_at FROM observations WHERE id = '30000000-0000-4000-8000-000000000001'),
  'accepted edits advance the server revision'
);
UPDATE observations SET deleted_at = clock_timestamp() WHERE id = '30000000-0000-4000-8000-000000000001' AND revision = 2;
SELECT pg_temp.assert_true(
  NOT EXISTS (SELECT FROM gis.sample_observations WHERE observation_id = '30000000-0000-4000-8000-000000000001')
  AND (SELECT revision = 3 AND deleted_at IS NOT NULL FROM observations WHERE id = '30000000-0000-4000-8000-000000000001'),
  'deleted records remain as tombstones but disappear from the GIS layer'
);
UPDATE observations SET deleted_at = NULL WHERE id = '30000000-0000-4000-8000-000000000001';
