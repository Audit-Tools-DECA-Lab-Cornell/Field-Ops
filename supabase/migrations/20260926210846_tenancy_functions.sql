CREATE FUNCTION fieldmaps_private.assert_active_user() RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE caller uuid := fieldmaps.request_user_id();
BEGIN
  IF caller IS NULL THEN RAISE EXCEPTION 'role_required' USING ERRCODE = 'FM006'; END IF;
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('account:' || caller::text, 0));
  IF NOT EXISTS (SELECT FROM auth.users WHERE id = caller)
    OR EXISTS (SELECT FROM fieldmaps.profiles WHERE user_id = caller AND deleted_at IS NOT NULL) THEN
    RAISE EXCEPTION 'account_deleted' USING ERRCODE = 'FM005';
  END IF;
END;
$$;
CREATE FUNCTION fieldmaps_private.ensure_profile_row() RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE training_org uuid;
BEGIN
  PERFORM fieldmaps_private.assert_active_user();
  INSERT INTO fieldmaps.profiles(user_id) VALUES (fieldmaps.request_user_id()) ON CONFLICT DO NOTHING;
  SELECT organization_id INTO training_org FROM fieldmaps.projects
  WHERE id = '10000000-0000-4000-8000-000000000102';
  IF training_org IS NOT NULL THEN
    PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(training_org::text, 0));
    INSERT INTO fieldmaps.project_memberships(user_id, organization_id, project_id, role)
    SELECT fieldmaps.request_user_id(), organization_id, id, 'observer' FROM fieldmaps.projects
    WHERE id = '10000000-0000-4000-8000-000000000102' ON CONFLICT DO NOTHING;
  END IF;
END;
$$;
CREATE FUNCTION fieldmaps_private.ensure_profile(p_display_name text) RETURNS fieldmaps.profiles
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE result fieldmaps.profiles;
BEGIN
  PERFORM fieldmaps_private.ensure_profile_row();
  UPDATE fieldmaps.profiles SET display_name = p_display_name
  WHERE user_id = fieldmaps.request_user_id() AND display_name IS NULL AND p_display_name IS NOT NULL;
  SELECT * INTO result FROM fieldmaps.profiles WHERE user_id = fieldmaps.request_user_id();
  RETURN result;
END;
$$;
CREATE FUNCTION fieldmaps_private.create_organization(
  p_name text, p_slug text, p_project_name text, p_project_code text, p_timezone text
) RETURNS fieldmaps.organizations
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE result fieldmaps.organizations; new_project uuid := gen_random_uuid();
BEGIN
  PERFORM fieldmaps_private.ensure_profile_row();
  IF (SELECT count(*) FROM fieldmaps.organization_members
    WHERE user_id = fieldmaps.request_user_id() AND role = 'owner') >= 3 THEN
    RAISE EXCEPTION 'limit_reached' USING ERRCODE = 'FM001';
  END IF;
  INSERT INTO fieldmaps.organizations(id, name, slug, created_by)
  VALUES (gen_random_uuid(), p_name, p_slug, fieldmaps.request_user_id()) RETURNING * INTO result;
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(result.id::text, 0));
  INSERT INTO fieldmaps.organization_members(organization_id, user_id, role, granted_by)
  VALUES (result.id, fieldmaps.request_user_id(), 'owner', fieldmaps.request_user_id());
  INSERT INTO fieldmaps.projects(id, organization_id, name, code, timezone)
  VALUES (new_project, result.id, p_project_name, p_project_code, p_timezone);
  INSERT INTO fieldmaps.project_memberships(user_id, organization_id, project_id, role, granted_by)
  VALUES (fieldmaps.request_user_id(), result.id, new_project, 'manager', fieldmaps.request_user_id());
  RETURN result;
EXCEPTION WHEN unique_violation THEN RAISE EXCEPTION 'conflict' USING ERRCODE = 'FM008';
END;
$$;
CREATE FUNCTION fieldmaps_private.create_project(p_org_id uuid, p_name text, p_code text, p_timezone text)
RETURNS fieldmaps.projects LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE result fieldmaps.projects;
BEGIN
  PERFORM fieldmaps_private.ensure_profile_row();
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_org_id::text, 0));
  IF NOT fieldmaps_private.has_org_role(p_org_id, ARRAY['owner','admin']) THEN
    RAISE EXCEPTION 'role_required' USING ERRCODE = 'FM006';
  END IF;
  INSERT INTO fieldmaps.projects(id, organization_id, name, code, timezone)
  VALUES (gen_random_uuid(), p_org_id, p_name, p_code, p_timezone) RETURNING * INTO result;
  INSERT INTO fieldmaps.project_memberships(user_id, organization_id, project_id, role, granted_by)
  VALUES (fieldmaps.request_user_id(), p_org_id, result.id, 'manager', fieldmaps.request_user_id());
  RETURN result;
EXCEPTION WHEN unique_violation THEN RAISE EXCEPTION 'conflict' USING ERRCODE = 'FM008';
END;
$$;
CREATE FUNCTION fieldmaps_private.create_invitation(p_org_id uuid, p_project_id uuid, p_role text,
  p_email text, p_max_uses integer, p_expires_in interval, p_token_hash text, p_join_code_hash text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE result uuid;
BEGIN
  PERFORM fieldmaps_private.assert_active_user();
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_org_id::text, 0));
  IF p_project_id IS NULL THEN
    IF p_role IS NULL OR p_role NOT IN ('member','admin')
      OR NOT fieldmaps_private.has_org_role(p_org_id, ARRAY['owner','admin'])
      OR (p_role = 'admin' AND NOT fieldmaps_private.has_org_role(p_org_id, ARRAY['owner'])) THEN
      RAISE EXCEPTION 'role_required' USING ERRCODE = 'FM006';
    END IF;
  ELSE
    IF NOT EXISTS (SELECT FROM fieldmaps.projects WHERE id = p_project_id AND organization_id = p_org_id) THEN
      RAISE EXCEPTION 'not_found' USING ERRCODE = 'FM007';
    END IF;
    IF p_role IS NULL OR p_role NOT IN ('observer','viewer','manager')
      OR NOT fieldmaps_private.has_project_role(p_project_id, ARRAY['manager']) THEN
      RAISE EXCEPTION 'role_required' USING ERRCODE = 'FM006';
    END IF;
  END IF;
  IF p_expires_in IS NULL OR p_expires_in <= interval '0 seconds' THEN
    RAISE EXCEPTION 'invitation_invalid' USING ERRCODE = 'FM003';
  END IF;
  INSERT INTO fieldmaps.invitations(organization_id, project_id, role, email, max_uses,
    expires_at, token_hash, join_code_hash, created_by)
  VALUES (p_org_id, p_project_id, p_role, lower(p_email), p_max_uses,
    now() + p_expires_in, p_token_hash, p_join_code_hash, fieldmaps.request_user_id()) RETURNING id INTO result;
  RETURN result;
END;
$$;
CREATE FUNCTION fieldmaps_private.revoke_invitation(p_org_id uuid, p_project_id uuid, p_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE invitation fieldmaps.invitations;
BEGIN
  PERFORM fieldmaps_private.assert_active_user();
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_org_id::text, 0));
  SELECT * INTO invitation FROM fieldmaps.invitations WHERE id = p_id;
  IF NOT FOUND OR invitation.organization_id IS DISTINCT FROM p_org_id
    OR invitation.project_id IS DISTINCT FROM p_project_id THEN
    RAISE EXCEPTION 'not_found' USING ERRCODE = 'FM007';
  END IF;
  IF (p_project_id IS NULL AND (NOT fieldmaps_private.has_org_role(p_org_id, ARRAY['owner','admin'])
      OR (invitation.role = 'admin' AND NOT fieldmaps_private.has_org_role(p_org_id, ARRAY['owner']))))
    OR (p_project_id IS NOT NULL AND NOT fieldmaps_private.has_project_role(p_project_id, ARRAY['manager'])) THEN
    RAISE EXCEPTION 'role_required' USING ERRCODE = 'FM006';
  END IF;
  UPDATE fieldmaps.invitations SET revoked_at = coalesce(revoked_at, now()) WHERE id = p_id;
END;
$$;
CREATE FUNCTION fieldmaps_private.preview_invitation(p_token_hash text, p_join_code_hash text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE invitation fieldmaps.invitations;
BEGIN
  IF fieldmaps.request_user_id() IS NULL THEN RAISE EXCEPTION 'role_required' USING ERRCODE = 'FM006'; END IF;
  IF num_nonnulls(p_token_hash, p_join_code_hash) <> 1 THEN
    RAISE EXCEPTION 'invitation_invalid' USING ERRCODE = 'FM003';
  END IF;
  SELECT * INTO invitation FROM fieldmaps.invitations i
  WHERE i.token_hash = p_token_hash OR i.join_code_hash = p_join_code_hash;
  IF NOT FOUND OR invitation.revoked_at IS NOT NULL OR invitation.use_count >= invitation.max_uses
    OR NOT EXISTS (SELECT FROM fieldmaps.organizations WHERE id = invitation.organization_id AND deleted_at IS NULL) THEN
    RAISE EXCEPTION 'invitation_invalid' USING ERRCODE = 'FM003';
  END IF;
  IF invitation.expires_at <= now() THEN RAISE EXCEPTION 'invitation_expired' USING ERRCODE = 'FM004'; END IF;
  RETURN jsonb_build_object('organization_name', (SELECT name FROM fieldmaps.organizations WHERE id = invitation.organization_id),
    'project_name', (SELECT name FROM fieldmaps.projects WHERE id = invitation.project_id),
    'role', invitation.role, 'expires_at', invitation.expires_at);
END;
$$;
CREATE FUNCTION fieldmaps_private.redeem_invitation(p_token_hash text, p_join_code_hash text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE invitation fieldmaps.invitations;
BEGIN
  PERFORM fieldmaps_private.ensure_profile_row();
  IF num_nonnulls(p_token_hash, p_join_code_hash) <> 1 THEN
    RAISE EXCEPTION 'invitation_invalid' USING ERRCODE = 'FM003';
  END IF;
  SELECT * INTO invitation FROM fieldmaps.invitations i
  WHERE i.token_hash = p_token_hash OR i.join_code_hash = p_join_code_hash;
  IF NOT FOUND THEN RAISE EXCEPTION 'invitation_invalid' USING ERRCODE = 'FM003'; END IF;
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(invitation.organization_id::text, 0));
  PERFORM fieldmaps_private.preview_invitation(p_token_hash, p_join_code_hash);
  UPDATE fieldmaps.invitations i SET use_count = i.use_count + 1
  WHERE (i.token_hash = p_token_hash OR i.join_code_hash = p_join_code_hash)
    AND i.revoked_at IS NULL AND i.expires_at > now() AND i.use_count < i.max_uses
  RETURNING * INTO invitation;
  IF NOT FOUND THEN
    PERFORM fieldmaps_private.preview_invitation(p_token_hash, p_join_code_hash);
    RAISE EXCEPTION 'invitation_invalid' USING ERRCODE = 'FM003';
  END IF;
  IF invitation.email IS NOT NULL AND NOT EXISTS (SELECT FROM auth.users u
    WHERE u.id = fieldmaps.request_user_id() AND u.email_confirmed_at IS NOT NULL AND lower(u.email) = invitation.email) THEN
    RAISE EXCEPTION 'invitation_invalid' USING ERRCODE = 'FM003';
  END IF;
  IF invitation.project_id IS NULL THEN
    INSERT INTO fieldmaps.organization_members(organization_id, user_id, role, granted_by)
    VALUES (invitation.organization_id, fieldmaps.request_user_id(), invitation.role, invitation.created_by)
    ON CONFLICT DO NOTHING;
  ELSE
    INSERT INTO fieldmaps.organization_members(organization_id, user_id, role, granted_by)
    VALUES (invitation.organization_id, fieldmaps.request_user_id(), 'member', invitation.created_by)
    ON CONFLICT DO NOTHING;
    INSERT INTO fieldmaps.project_memberships(user_id, organization_id, project_id, role, granted_by)
    VALUES (fieldmaps.request_user_id(), invitation.organization_id, invitation.project_id, invitation.role, invitation.created_by)
    ON CONFLICT DO NOTHING;
  END IF;
  RETURN jsonb_build_object('organization_id', invitation.organization_id, 'project_id', invitation.project_id, 'role', invitation.role);
END;
$$;
CREATE FUNCTION fieldmaps_private.change_org_member(p_org_id uuid, p_user_id uuid, p_role text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE old_role text;
BEGIN
  PERFORM fieldmaps_private.ensure_profile_row();
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_org_id::text, 0));
  SELECT role INTO old_role FROM fieldmaps.organization_members WHERE organization_id = p_org_id AND user_id = p_user_id;
  IF NOT fieldmaps_private.has_org_role(p_org_id, ARRAY['owner','admin'])
    OR p_role = 'owner'
    OR (NOT fieldmaps_private.has_org_role(p_org_id, ARRAY['owner'])
      AND (old_role <> 'member' OR (p_role IS NOT NULL AND p_role <> 'member'))) THEN
    RAISE EXCEPTION 'role_required' USING ERRCODE = 'FM006';
  END IF;
  IF old_role IS NULL THEN RAISE EXCEPTION 'not_found' USING ERRCODE = 'FM007'; END IF;
  IF old_role = 'owner' AND (SELECT count(*) FROM fieldmaps.organization_members
    WHERE organization_id = p_org_id AND role = 'owner') = 1 THEN
    RAISE EXCEPTION 'sole_owner' USING ERRCODE = 'FM002';
  END IF;
  IF p_role IS NULL THEN
    IF EXISTS (SELECT FROM fieldmaps.project_memberships m JOIN fieldmaps.projects p ON p.id = m.project_id
      WHERE m.organization_id = p_org_id AND m.user_id = p_user_id AND m.role = 'manager' AND NOT p.is_training
        AND NOT EXISTS (SELECT FROM fieldmaps.project_memberships other
          WHERE other.project_id = m.project_id AND other.user_id <> p_user_id AND other.role = 'manager')) THEN
      RAISE EXCEPTION 'sole_owner' USING ERRCODE = 'FM002';
    END IF;
    DELETE FROM fieldmaps.project_memberships WHERE organization_id = p_org_id AND user_id = p_user_id;
    DELETE FROM fieldmaps.organization_members WHERE organization_id = p_org_id AND user_id = p_user_id;
  ELSE
    UPDATE fieldmaps.organization_members SET role = p_role, granted_by = fieldmaps.request_user_id(), granted_at = now()
    WHERE organization_id = p_org_id AND user_id = p_user_id;
  END IF;
END;
$$;
CREATE FUNCTION fieldmaps_private.set_org_role(p_org_id uuid, p_user_id uuid, p_role text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM fieldmaps_private.assert_active_user();
  IF p_role IS NULL THEN RAISE EXCEPTION 'role_required' USING ERRCODE = 'FM006'; END IF;
  PERFORM fieldmaps_private.change_org_member(p_org_id, p_user_id, p_role);
END;
$$;
CREATE FUNCTION fieldmaps_private.remove_org_member(p_org_id uuid, p_user_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN PERFORM fieldmaps_private.change_org_member(p_org_id, p_user_id, NULL); END;
$$;
CREATE FUNCTION fieldmaps_private.change_project_member(p_project_id uuid, p_user_id uuid, p_role text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE org_id uuid; old_role text; training boolean;
BEGIN
  PERFORM fieldmaps_private.ensure_profile_row();
  SELECT organization_id, is_training INTO org_id, training FROM fieldmaps.projects WHERE id = p_project_id;
  IF org_id IS NULL THEN RAISE EXCEPTION 'not_found' USING ERRCODE = 'FM007'; END IF;
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(org_id::text, 0));
  IF NOT fieldmaps_private.has_project_role(p_project_id, ARRAY['manager']) THEN
    RAISE EXCEPTION 'role_required' USING ERRCODE = 'FM006';
  END IF;
  SELECT role INTO old_role FROM fieldmaps.project_memberships WHERE project_id = p_project_id AND user_id = p_user_id;
  IF old_role IS NULL THEN RAISE EXCEPTION 'not_found' USING ERRCODE = 'FM007'; END IF;
  IF old_role = 'manager' AND p_role IS DISTINCT FROM 'manager' AND NOT training
    AND NOT EXISTS (SELECT FROM fieldmaps.project_memberships
      WHERE project_id = p_project_id AND user_id <> p_user_id AND role = 'manager') THEN
    RAISE EXCEPTION 'sole_owner' USING ERRCODE = 'FM002';
  END IF;
  IF p_role IS NULL THEN
    DELETE FROM fieldmaps.project_memberships WHERE project_id = p_project_id AND user_id = p_user_id;
  ELSE
    UPDATE fieldmaps.project_memberships SET role = p_role, granted_by = fieldmaps.request_user_id(), granted_at = now()
    WHERE project_id = p_project_id AND user_id = p_user_id;
  END IF;
END;
$$;
CREATE FUNCTION fieldmaps_private.set_project_role(p_project_id uuid, p_user_id uuid, p_role text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM fieldmaps_private.assert_active_user();
  IF p_role IS NULL THEN RAISE EXCEPTION 'role_required' USING ERRCODE = 'FM006'; END IF;
  PERFORM fieldmaps_private.change_project_member(p_project_id, p_user_id, p_role);
END;
$$;
CREATE FUNCTION fieldmaps_private.remove_project_member(p_project_id uuid, p_user_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN PERFORM fieldmaps_private.change_project_member(p_project_id, p_user_id, NULL); END;
$$;
CREATE FUNCTION fieldmaps_private.transfer_ownership(p_org_id uuid, p_user_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM fieldmaps_private.ensure_profile_row();
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_org_id::text, 0));
  IF NOT fieldmaps_private.has_org_role(p_org_id, ARRAY['owner']) THEN
    RAISE EXCEPTION 'role_required' USING ERRCODE = 'FM006';
  END IF;
  IF NOT EXISTS (SELECT FROM fieldmaps.organization_members m JOIN fieldmaps.profiles u ON u.user_id = m.user_id
    WHERE m.organization_id = p_org_id AND m.user_id = p_user_id AND u.deleted_at IS NULL) THEN
    RAISE EXCEPTION 'not_found' USING ERRCODE = 'FM007';
  END IF;
  UPDATE fieldmaps.organization_members SET role = 'owner', granted_by = fieldmaps.request_user_id(), granted_at = now()
  WHERE organization_id = p_org_id AND user_id = p_user_id;
  UPDATE fieldmaps.organization_members SET role = 'admin', granted_by = fieldmaps.request_user_id(), granted_at = now()
  WHERE organization_id = p_org_id AND user_id = fieldmaps.request_user_id() AND user_id <> p_user_id;
END;
$$;
CREATE FUNCTION fieldmaps_private.forget_user() RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE caller uuid := fieldmaps.request_user_id(); org_id uuid; training_org uuid;
BEGIN
  IF caller IS NULL THEN RAISE EXCEPTION 'role_required' USING ERRCODE = 'FM006'; END IF;
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('account:' || caller::text, 0));
  IF NOT EXISTS (SELECT FROM auth.users WHERE id = caller) THEN RETURN; END IF;
  IF EXISTS (SELECT FROM fieldmaps.profiles WHERE user_id = caller AND deleted_at IS NOT NULL) THEN RETURN; END IF;
  SELECT organization_id INTO training_org FROM fieldmaps.projects WHERE id = '10000000-0000-4000-8000-000000000102';
  IF training_org IS NOT NULL THEN
    PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(training_org::text, 0));
  END IF;
  FOR org_id IN SELECT organization_id FROM fieldmaps.organization_members WHERE user_id = caller
    UNION SELECT organization_id FROM fieldmaps.project_memberships WHERE user_id = caller ORDER BY 1 LOOP
    PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(org_id::text, 0));
  END LOOP;
  IF EXISTS (SELECT FROM fieldmaps.organization_members m WHERE m.user_id = caller AND m.role = 'owner'
    AND EXISTS (SELECT FROM fieldmaps.organization_members other WHERE other.organization_id = m.organization_id AND other.user_id <> caller)
    AND NOT EXISTS (SELECT FROM fieldmaps.organization_members other WHERE other.organization_id = m.organization_id AND other.user_id <> caller AND other.role = 'owner')) THEN
    RAISE EXCEPTION 'sole_owner' USING ERRCODE = 'FM002';
  END IF;
  UPDATE fieldmaps.organizations o SET deleted_at = now()
  WHERE EXISTS (SELECT FROM fieldmaps.organization_members m WHERE m.organization_id = o.id AND m.user_id = caller AND m.role = 'owner')
    AND NOT EXISTS (SELECT FROM fieldmaps.organization_members m WHERE m.organization_id = o.id AND m.user_id <> caller);
  DELETE FROM fieldmaps.project_memberships WHERE user_id = caller;
  DELETE FROM fieldmaps.organization_members WHERE user_id = caller;
  INSERT INTO fieldmaps.profiles(user_id, deleted_at) VALUES (caller, now())
  ON CONFLICT (user_id) DO UPDATE SET display_name = NULL, observer_initials = NULL, locale = NULL,
    deleted_at = coalesce(fieldmaps.profiles.deleted_at, now());
END;
$$;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA fieldmaps_private FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA fieldmaps_private TO fieldmaps_api;
REVOKE ALL ON FUNCTION fieldmaps_private.ensure_profile_row(),
  fieldmaps_private.change_org_member(uuid, uuid, text),
  fieldmaps_private.change_project_member(uuid, uuid, text) FROM fieldmaps_api;
INSERT INTO fieldmaps_meta.schema_migrations(version) VALUES ('0008_tenancy_functions');
