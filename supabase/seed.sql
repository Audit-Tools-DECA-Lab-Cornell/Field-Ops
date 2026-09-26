-- Local synthetic identities only. The baseline migration owns the practice site and form.
INSERT INTO auth.users (id, instance_id, aud, role, email, email_confirmed_at)
SELECT id, '00000000-0000-0000-0000-000000000000'::uuid,
  'authenticated', 'authenticated', label || '@fieldmaps-test.invalid', now()
FROM (VALUES
  ('50000000-0000-4000-8000-000000000001'::uuid, 'observer'),
  ('50000000-0000-4000-8000-000000000002'::uuid, 'outsider'),
  ('50000000-0000-4000-8000-000000000003'::uuid, 'viewer'),
  ('50000000-0000-4000-8000-000000000004'::uuid, 'manager')
) AS fixtures(id, label)
ON CONFLICT (id) DO NOTHING;

INSERT INTO fieldmaps.profiles (user_id)
SELECT id FROM auth.users WHERE id IN (
  '50000000-0000-4000-8000-000000000001', '50000000-0000-4000-8000-000000000002',
  '50000000-0000-4000-8000-000000000003', '50000000-0000-4000-8000-000000000004')
ON CONFLICT (user_id) DO NOTHING;

INSERT INTO fieldmaps.project_memberships (user_id, organization_id, project_id, role)
SELECT id, '10000000-0000-4000-8000-000000000001'::uuid,
  '10000000-0000-4000-8000-000000000002'::uuid, role
FROM (VALUES
  ('50000000-0000-4000-8000-000000000001'::uuid, 'observer'),
  ('50000000-0000-4000-8000-000000000003'::uuid, 'viewer'),
  ('50000000-0000-4000-8000-000000000004'::uuid, 'manager')
) AS fixtures(id, role)
ON CONFLICT (user_id, project_id) DO NOTHING;
