CREATE OR REPLACE FUNCTION fieldmaps_private.redeem_invitation(p_token_hash text, p_join_code_hash text)
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
    IF EXISTS (SELECT FROM fieldmaps.organization_members
      WHERE organization_id = invitation.organization_id AND user_id = fieldmaps.request_user_id()) THEN
      RAISE EXCEPTION 'invitation_invalid' USING ERRCODE = 'FM003';
    END IF;
    INSERT INTO fieldmaps.organization_members(organization_id, user_id, role, granted_by)
    VALUES (invitation.organization_id, fieldmaps.request_user_id(), invitation.role, invitation.created_by);
  ELSE
    IF EXISTS (SELECT FROM fieldmaps.project_memberships
      WHERE project_id = invitation.project_id AND user_id = fieldmaps.request_user_id()) THEN
      RAISE EXCEPTION 'invitation_invalid' USING ERRCODE = 'FM003';
    END IF;
    INSERT INTO fieldmaps.organization_members(organization_id, user_id, role, granted_by)
    VALUES (invitation.organization_id, fieldmaps.request_user_id(), 'member', invitation.created_by)
    ON CONFLICT DO NOTHING;
    INSERT INTO fieldmaps.project_memberships(user_id, organization_id, project_id, role, granted_by)
    VALUES (fieldmaps.request_user_id(), invitation.organization_id, invitation.project_id, invitation.role, invitation.created_by);
  END IF;
  RETURN jsonb_build_object('organization_id', invitation.organization_id, 'project_id', invitation.project_id, 'role', invitation.role);
END;
$$;
REVOKE ALL ON FUNCTION fieldmaps_private.redeem_invitation(text, text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION fieldmaps_private.redeem_invitation(text, text) TO fieldmaps_api;
INSERT INTO fieldmaps_meta.schema_migrations(version) VALUES ('0009_invitation_membership_guard');
