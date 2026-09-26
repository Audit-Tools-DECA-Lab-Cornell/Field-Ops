SET LOCAL ROLE fieldmaps_api;
SELECT set_config('fieldmaps.user_id', '', true);
SELECT pg_temp.assert_rejected($q$SELECT fieldmaps_private.ensure_profile(NULL)$q$, 'FM006', 'identity required');
SELECT set_config('fieldmaps.user_id', '59999999-0000-4000-8000-000000000099', true);
SELECT pg_temp.assert_rejected($q$SELECT fieldmaps_private.ensure_profile(NULL)$q$, 'FM005', 'missing Auth user cannot create profile');
RESET ROLE;
INSERT INTO auth.users(id, instance_id, aud, role, email, email_confirmed_at)
SELECT id, '00000000-0000-0000-0000-000000000000'::uuid, 'authenticated', 'authenticated',
  'MixedCase+' || n || '@test.invalid', CASE WHEN n = 4 THEN NULL ELSE now() END
FROM (VALUES (1, '52000000-0000-4000-8000-000000000001'::uuid),
 (2, '52000000-0000-4000-8000-000000000002'::uuid),
 (3, '52000000-0000-4000-8000-000000000003'::uuid),
 (4, '52000000-0000-4000-8000-000000000004'::uuid),
 (5, '52000000-0000-4000-8000-000000000005'::uuid)) u(n, id);
SET LOCAL ROLE fieldmaps_api;
SELECT set_config('fieldmaps.user_id', '52000000-0000-4000-8000-000000000001', true);
SELECT (fieldmaps_private.create_organization('Function org', 'function-org', 'First project', 'first-project', 'UTC')).id AS org_id \gset
SELECT id AS project_id FROM fieldmaps.projects WHERE organization_id = :'org_id' \gset
SELECT pg_temp.assert_true((SELECT count(*) = 1 FROM fieldmaps.organization_members WHERE organization_id = :'org_id' AND role = 'owner'), 'organization creator is owner');
SELECT fieldmaps_private.create_invitation(:'org_id', NULL, 'admin', NULL, 1, interval '1 day', repeat('a',64), NULL) AS invitation_id \gset
SELECT set_config('fieldmaps.user_id', '52000000-0000-4000-8000-000000000002', true);
SELECT pg_temp.assert_true((fieldmaps_private.preview_invitation(repeat('a',64),NULL)->>'role') = 'admin', 'preview returns live invite role');
SELECT pg_temp.assert_true(NOT (fieldmaps_private.preview_invitation(repeat('a',64),NULL) ? 'email'), 'preview reveals no bound email');
SELECT fieldmaps_private.redeem_invitation(repeat('a',64),NULL);
SELECT pg_temp.assert_true((SELECT count(*) = 1 FROM fieldmaps.profiles WHERE user_id = fieldmaps.request_user_id()), 'redeem creates missing profile');
SELECT pg_temp.assert_rejected($q$SELECT fieldmaps_private.redeem_invitation(repeat('a',64),NULL)$q$, 'FM003', 'single use invite rejects replay');
SELECT pg_temp.assert_rejected(format('SELECT fieldmaps_private.set_org_role(%L,%L,%L)', :'org_id', '52000000-0000-4000-8000-000000000002', 'owner'), 'FM006', 'admin cannot promote self');
SELECT pg_temp.assert_rejected(format('SELECT fieldmaps_private.set_org_role(%L,%L,%L)', :'org_id', '52000000-0000-4000-8000-000000000001', 'member'), 'FM006', 'admin cannot demote owner');
SELECT pg_temp.assert_rejected(format('SELECT fieldmaps_private.create_invitation(%L,NULL,%L,NULL,1,interval ''1 day'',repeat(''b'',64),NULL)', :'org_id', 'admin'), 'FM006', 'admin cannot invite admin');
SELECT pg_temp.assert_rejected(format('SELECT fieldmaps_private.create_invitation(%L,NULL,%L,NULL,1,interval ''1 day'',repeat(''b'',64),NULL)', :'org_id', 'owner'), 'FM006', 'owner role is not invitable');
SELECT set_config('fieldmaps.user_id', '52000000-0000-4000-8000-000000000001', true);
SELECT pg_temp.assert_rejected(format('SELECT fieldmaps_private.remove_org_member(%L,%L)', :'org_id', '52000000-0000-4000-8000-000000000001'), 'FM002', 'last owner cannot be removed');
SELECT pg_temp.assert_rejected(format('SELECT fieldmaps_private.remove_project_member(%L,%L)', :'project_id', '52000000-0000-4000-8000-000000000001'), 'FM002', 'last manager cannot be removed');
SELECT fieldmaps_private.create_invitation(:'org_id', :'project_id', 'viewer', NULL, 3, interval '1 day', repeat('6',64), NULL) AS existing_project_invite \gset
SELECT pg_temp.assert_rejected($q$SELECT fieldmaps_private.redeem_invitation(repeat('6',64),NULL)$q$, 'FM003', 'existing project member cannot consume invitation');
SELECT pg_temp.assert_true((SELECT use_count = 0 FROM fieldmaps.invitations WHERE id = :'existing_project_invite'), 'existing project member preserves invitation uses');
SELECT pg_temp.assert_true((SELECT role = 'manager' FROM fieldmaps.project_memberships WHERE project_id = :'project_id' AND user_id = fieldmaps.request_user_id()), 'existing project role is preserved');
SELECT fieldmaps_private.create_invitation(:'org_id', NULL, 'member', NULL, 3, interval '1 day', repeat('7',64), NULL) AS existing_org_invite \gset
SELECT pg_temp.assert_rejected($q$SELECT fieldmaps_private.redeem_invitation(repeat('7',64),NULL)$q$, 'FM003', 'existing organization member cannot consume invitation');
SELECT pg_temp.assert_true((SELECT use_count = 0 FROM fieldmaps.invitations WHERE id = :'existing_org_invite'), 'existing organization member preserves invitation uses');
SELECT set_config('fieldmaps.user_id', '52000000-0000-4000-8000-000000000002', true);
SELECT fieldmaps_private.redeem_invitation(repeat('6',64),NULL);
SELECT pg_temp.assert_rejected($q$SELECT fieldmaps_private.redeem_invitation(repeat('6',64),NULL)$q$, 'FM003', 'successful multi-use redemption cannot be repeated');
SELECT pg_temp.assert_true((SELECT use_count = 1 FROM fieldmaps.invitations WHERE id = :'existing_project_invite'), 'new project member consumes exactly one use');
SELECT pg_temp.assert_true((SELECT role = 'admin' FROM fieldmaps.organization_members WHERE organization_id = :'org_id' AND user_id = fieldmaps.request_user_id()), 'joining a project preserves existing organization role');
SELECT set_config('fieldmaps.user_id', '52000000-0000-4000-8000-000000000001', true);
SELECT pg_temp.assert_rejected($q$SELECT fieldmaps_private.forget_user()$q$, 'FM002', 'sole owner with teammates cannot delete account');
SELECT fieldmaps_private.create_invitation(:'org_id', :'project_id', 'observer', 'MixedCase+3@Test.Invalid', 1, interval '1 day', repeat('c',64), NULL);
SELECT fieldmaps_private.create_invitation(:'org_id', :'project_id', 'observer', 'mixedcase+4@test.invalid', 1, interval '1 day', repeat('d',64), NULL);
SELECT pg_temp.assert_rejected(format('SELECT fieldmaps_private.revoke_invitation(%L,%L,%L)', :'org_id', :'project_id', :'invitation_id'), 'FM007', 'revoke checks URL scope');
SELECT set_config('fieldmaps.user_id', '52000000-0000-4000-8000-000000000004', true);
SELECT pg_temp.assert_rejected($q$SELECT fieldmaps_private.redeem_invitation(repeat('d',64),NULL)$q$, 'FM003', 'unconfirmed bound email is rejected');
SELECT set_config('fieldmaps.user_id', '52000000-0000-4000-8000-000000000003', true);
SELECT fieldmaps_private.redeem_invitation(repeat('c',64),NULL);
SELECT pg_temp.assert_true((SELECT count(*) = 1 FROM fieldmaps.organization_members WHERE organization_id = :'org_id'), 'project invite also joins organization');
SELECT fieldmaps_private.forget_user();
SELECT fieldmaps_private.forget_user();
SELECT pg_temp.assert_rejected($q$SELECT fieldmaps_private.ensure_profile(NULL)$q$, 'FM005', 'forgotten account cannot recreate profile');
SELECT pg_temp.assert_rejected($q$SELECT fieldmaps_private.create_organization('No','no-org','No','no-project','UTC')$q$, 'FM005', 'forgotten account cannot create org');
SELECT pg_temp.assert_rejected($q$SELECT fieldmaps_private.redeem_invitation(repeat('d',64),NULL)$q$, 'FM005', 'forgotten account cannot redeem');
SELECT set_config('fieldmaps.user_id', '52000000-0000-4000-8000-000000000005', true);
SELECT fieldmaps_private.forget_user();
SELECT pg_temp.assert_rejected($q$SELECT fieldmaps_private.ensure_profile(NULL)$q$, 'FM005', 'forget without profile cannot revive account');
SELECT pg_temp.assert_rejected($q$SELECT fieldmaps_private.preview_invitation(repeat('f',64),NULL)$q$, 'FM003', 'unknown invite rejected');
RESET ROLE;
SELECT set_config('fieldmaps.user_id', '', true);
SET LOCAL ROLE fieldmaps_api;
SELECT set_config('fieldmaps.user_id', '52000000-0000-4000-8000-000000000002', true);
SELECT (fieldmaps_private.create_project(:'org_id', 'Second project', 'second-project', 'UTC')).id AS second_project \gset
SELECT pg_temp.assert_true(fieldmaps_private.has_project_role(:'second_project', ARRAY['manager']), 'admin creates project as manager');
SELECT fieldmaps_private.create_invitation(:'org_id', :'project_id', 'viewer', NULL, 1, interval '1 day', NULL, repeat('e',64)) AS code_invitation \gset
SELECT set_config('fieldmaps.user_id', '52000000-0000-4000-8000-000000000004', true);
SELECT fieldmaps_private.redeem_invitation(NULL,repeat('e',64));
SELECT pg_temp.assert_rejected(format('SELECT fieldmaps_private.create_project(%L,%L,%L,%L)', :'org_id', 'No', 'no-project', 'UTC'), 'FM006', 'member cannot create project');
SELECT pg_temp.assert_true((SELECT count(*) = 0 FROM fieldmaps.invitations), 'ordinary member cannot list invitations');
SELECT set_config('fieldmaps.user_id', '52000000-0000-4000-8000-000000000001', true);
SELECT fieldmaps_private.set_project_role(:'project_id', '52000000-0000-4000-8000-000000000004', 'manager');
SELECT fieldmaps_private.remove_project_member(:'project_id', '52000000-0000-4000-8000-000000000004');
SELECT pg_temp.assert_true(NOT EXISTS (SELECT FROM fieldmaps.project_memberships WHERE project_id = :'project_id' AND user_id = '52000000-0000-4000-8000-000000000004'), 'manager can remove another member');
SELECT fieldmaps_private.set_org_role(:'org_id', '52000000-0000-4000-8000-000000000004', 'admin');
SELECT fieldmaps_private.set_org_role(:'org_id', '52000000-0000-4000-8000-000000000004', 'member');
SELECT fieldmaps_private.remove_org_member(:'org_id', '52000000-0000-4000-8000-000000000004');
SELECT fieldmaps_private.transfer_ownership(:'org_id', '52000000-0000-4000-8000-000000000002');
SELECT pg_temp.assert_true((SELECT role = 'owner' FROM fieldmaps.organization_members WHERE organization_id = :'org_id' AND user_id = '52000000-0000-4000-8000-000000000002'), 'ownership transfer promotes recipient');
SELECT pg_temp.assert_true((SELECT role = 'admin' FROM fieldmaps.organization_members WHERE organization_id = :'org_id' AND user_id = fieldmaps.request_user_id()), 'ownership transfer demotes former owner');
SELECT fieldmaps_private.create_invitation(:'org_id', :'project_id', 'viewer', NULL, 1, interval '1 day', repeat('1',64), NULL) AS revoked_invitation \gset
SELECT fieldmaps_private.revoke_invitation(:'org_id', :'project_id', :'revoked_invitation');
SELECT pg_temp.assert_rejected($q$SELECT fieldmaps_private.preview_invitation(repeat('1',64),NULL)$q$, 'FM003', 'revoked invitation cannot be previewed');
SELECT fieldmaps_private.create_invitation(:'org_id', :'project_id', 'viewer', NULL, 1, interval '1 day', repeat('2',64), NULL) AS expired_invitation \gset
RESET ROLE;
UPDATE fieldmaps.invitations SET expires_at = now()-interval '1 second' WHERE id = :'expired_invitation';
SET LOCAL ROLE fieldmaps_api;
SELECT pg_temp.assert_rejected($q$SELECT fieldmaps_private.preview_invitation(repeat('2',64),NULL)$q$, 'FM004', 'expired invitation has distinct error');
SELECT pg_temp.assert_rejected($q$SELECT fieldmaps_private.redeem_invitation(repeat('2',64),NULL)$q$, 'FM004', 'expired invitation cannot be redeemed');
SELECT fieldmaps_private.create_organization('Limit one', 'limit-one', 'One', 'one-project', 'UTC');
SELECT fieldmaps_private.create_organization('Limit two', 'limit-two', 'Two', 'two-project', 'UTC');
SELECT fieldmaps_private.create_organization('Limit three', 'limit-three', 'Three', 'three-project', 'UTC');
SELECT pg_temp.assert_rejected($q$SELECT fieldmaps_private.create_organization('Limit four','limit-four','Four','four-project','UTC')$q$, 'FM001', 'organization ownership limit enforced');
SELECT pg_temp.assert_rejected($q$SELECT fieldmaps_private.ensure_profile_row()$q$, '42501', 'internal profile helper is not an API entry point');
SELECT set_config('fieldmaps.user_id', '59999999-0000-4000-8000-000000000099', true);
SELECT fieldmaps_private.forget_user();
RESET ROLE;
SELECT set_config('fieldmaps.user_id', '', true);
