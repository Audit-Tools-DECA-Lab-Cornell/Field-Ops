INSERT INTO auth.users (id, instance_id, aud, role, email)
SELECT id, '00000000-0000-0000-0000-000000000000'::uuid, 'authenticated', 'authenticated', id::text || '@test.invalid'
FROM (VALUES ('51000000-0000-4000-8000-000000000001'::uuid),
  ('51000000-0000-4000-8000-000000000002'::uuid)) u(id);
INSERT INTO fieldmaps.profiles (user_id) SELECT id FROM auth.users
WHERE id IN ('51000000-0000-4000-8000-000000000001', '51000000-0000-4000-8000-000000000002');
INSERT INTO fieldmaps.organization_members (organization_id, user_id, role)
VALUES ('10000000-0000-4000-8000-000000000001', '51000000-0000-4000-8000-000000000001', 'admin');
INSERT INTO fieldmaps.project_memberships (user_id, organization_id, project_id, role)
VALUES ('51000000-0000-4000-8000-000000000002', '20000000-0000-4000-8000-000000000001',
  '20000000-0000-4000-8000-000000000002', 'manager');
SET LOCAL ROLE fieldmaps_api;
SELECT set_config('fieldmaps.user_id', '', true);
SELECT pg_temp.assert_true((SELECT count(*) = 0 FROM fieldmaps.projects), 'no identity sees no projects');
SELECT set_config('fieldmaps.user_id', '51000000-0000-4000-8000-000000000002', true);
SELECT pg_temp.assert_true(NOT fieldmaps_private.has_project_role(
  '10000000-0000-4000-8000-000000000002', ARRAY['manager']), 'manager in B is not manager in A');
SELECT pg_temp.assert_rejected($q$INSERT INTO fieldmaps.site_packages
  (id,organization_id,project_id,site_id,form_version_id,version,state,manifest,archive,archive_sha256,prepared_by)
  VALUES ('51000000-0000-4000-8000-000000000010','10000000-0000-4000-8000-000000000001',
  '10000000-0000-4000-8000-000000000002','10000000-0000-4000-8000-000000000003',
  '10000000-0000-4000-8000-000000000004',99999,'ready','{}','\x01',repeat('a',64),fieldmaps.request_user_id())$q$,
  '42501', 'manager in B cannot insert a package in A');
SELECT pg_temp.assert_true((SELECT count(*) = 1 FROM fieldmaps.projects), 'manager reads only its project');
SELECT pg_temp.assert_true((SELECT count(*) = 1 FROM fieldmaps.sites), 'manager reads only its sites');
SELECT pg_temp.assert_true((SELECT count(*) = 1 FROM fieldmaps.form_versions), 'manager reads only its forms');
SELECT set_config('fieldmaps.user_id', '51000000-0000-4000-8000-000000000001', true);
SELECT pg_temp.assert_true((SELECT count(*) = 1 FROM fieldmaps.projects), 'org admin reads project without project membership');
SELECT pg_temp.assert_true((SELECT count(*) = 1 FROM fieldmaps.sites), 'org admin reads site without project membership');
SELECT pg_temp.assert_true(fieldmaps_private.has_project_role(
  '10000000-0000-4000-8000-000000000002', ARRAY['manager']), 'org admin acts as manager');
SELECT pg_temp.assert_true((SELECT count(*) = 1 FROM fieldmaps.organizations), 'org member reads its organization');
SELECT pg_temp.assert_true((SELECT count(*) = 3 FROM fieldmaps.project_memberships), 'manager sees project memberships');
SELECT pg_temp.assert_true((SELECT count(*) = 4 FROM fieldmaps.profiles), 'manager sees own profile and collaborators');
SELECT set_config('fieldmaps.user_id', '50000000-0000-4000-8000-000000000003', true);
SELECT pg_temp.assert_true(NOT fieldmaps_private.has_project_role(
  '10000000-0000-4000-8000-000000000002', ARRAY['observer', 'manager']), 'viewer cannot borrow another member role');
SELECT pg_temp.assert_true((SELECT count(*) = 1 FROM fieldmaps.profiles), 'viewer reads own profile only');
SELECT pg_temp.assert_rejected($q$INSERT INTO fieldmaps.observations
  (id,organization_id,project_id,site_id,form_version_id,observer_code,observed_at,geom,answers,created_by,upload_hash)
  VALUES ('51000000-0000-4000-8000-000000000011','10000000-0000-4000-8000-000000000001',
  '10000000-0000-4000-8000-000000000002','10000000-0000-4000-8000-000000000003',
  '10000000-0000-4000-8000-000000000004','QA',now(),fieldmaps.make_point(1,2),'{}',fieldmaps.request_user_id(),repeat('a',64))$q$,
  '42501', 'viewer cannot insert observations on a project with a manager');

SELECT pg_temp.assert_rejected($q$UPDATE fieldmaps.projects SET is_training = true$q$, '42501', 'API cannot change protected flags');
SELECT pg_temp.assert_rejected($q$INSERT INTO fieldmaps.organization_members (organization_id, user_id, role)
  VALUES ('10000000-0000-4000-8000-000000000001', fieldmaps.request_user_id(), 'owner')$q$,
  '42501', 'API cannot grant membership directly');
RESET ROLE;
SELECT pg_temp.assert_rejected($q$UPDATE fieldmaps.projects SET is_training = true
  WHERE id = '10000000-0000-4000-8000-000000000002'$q$, '23514', 'trigger protects project identity even for owner');
SELECT pg_temp.assert_rejected($q$UPDATE fieldmaps.organizations SET is_platform = true
  WHERE id = '10000000-0000-4000-8000-000000000001'$q$, '23514', 'trigger protects platform organization flag');
INSERT INTO fieldmaps.projects (id, organization_id, name, code, is_training)
VALUES ('60000000-0000-4000-8000-000000000002', '20000000-0000-4000-8000-000000000001', 'Test training', 'test-training', true);
INSERT INTO fieldmaps.project_memberships (user_id, organization_id, project_id, role)
SELECT user_id, '20000000-0000-4000-8000-000000000001'::uuid,
  '60000000-0000-4000-8000-000000000002'::uuid, 'observer'
FROM fieldmaps.profiles WHERE user_id IN ('50000000-0000-4000-8000-000000000002', '50000000-0000-4000-8000-000000000003');
SET LOCAL ROLE fieldmaps_api;
SELECT set_config('fieldmaps.user_id', '50000000-0000-4000-8000-000000000002', true);
SELECT pg_temp.assert_true((SELECT count(*) = 1 FROM fieldmaps.profiles), 'trainee cannot enumerate profiles');
SELECT pg_temp.assert_true((SELECT count(*) = 1 FROM fieldmaps.project_memberships), 'trainee cannot enumerate training memberships');
RESET ROLE;
SELECT set_config('fieldmaps.user_id', '', true);
