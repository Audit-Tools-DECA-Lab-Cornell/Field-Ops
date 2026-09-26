CREATE OR REPLACE FUNCTION fieldmaps_private.transfer_ownership(p_org_id uuid, p_user_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE account_id uuid;
BEGIN
  IF fieldmaps.request_user_id() IS NULL THEN
    RAISE EXCEPTION 'role_required' USING ERRCODE = 'FM006';
  END IF;
  FOR account_id IN SELECT DISTINCT id FROM unnest(ARRAY[fieldmaps.request_user_id(), p_user_id]) AS users(id)
    WHERE id IS NOT NULL ORDER BY id LOOP
    PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('account:' || account_id::text, 0));
  END LOOP;
  PERFORM fieldmaps_private.ensure_profile_row();
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_org_id::text, 0));
  IF NOT fieldmaps_private.has_org_role(p_org_id, ARRAY['owner']) THEN
    RAISE EXCEPTION 'role_required' USING ERRCODE = 'FM006';
  END IF;
  IF NOT EXISTS (SELECT FROM fieldmaps.organization_members m JOIN fieldmaps.profiles u ON u.user_id = m.user_id
    WHERE m.organization_id = p_org_id AND m.user_id = p_user_id AND u.deleted_at IS NULL) THEN
    RAISE EXCEPTION 'not_found' USING ERRCODE = 'FM007';
  END IF;
  IF NOT EXISTS (SELECT FROM fieldmaps.organization_members
      WHERE organization_id = p_org_id AND user_id = p_user_id AND role = 'owner')
    AND (SELECT count(*) FROM fieldmaps.organization_members WHERE user_id = p_user_id AND role = 'owner') >= 3 THEN
    RAISE EXCEPTION 'limit_reached' USING ERRCODE = 'FM001';
  END IF;
  UPDATE fieldmaps.organization_members SET role = 'owner', granted_by = fieldmaps.request_user_id(), granted_at = now()
  WHERE organization_id = p_org_id AND user_id = p_user_id;
  UPDATE fieldmaps.organization_members SET role = 'admin', granted_by = fieldmaps.request_user_id(), granted_at = now()
  WHERE organization_id = p_org_id AND user_id = fieldmaps.request_user_id() AND user_id <> p_user_id;
END;
$$;
CREATE OR REPLACE FUNCTION fieldmaps_private.forget_user() RETURNS void
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
  IF EXISTS (SELECT FROM fieldmaps.project_memberships m
    JOIN fieldmaps.projects p ON p.id = m.project_id
    JOIN fieldmaps.organizations o ON o.id = m.organization_id
    WHERE m.user_id = caller AND m.role = 'manager' AND NOT p.is_training AND o.deleted_at IS NULL
      AND NOT EXISTS (SELECT FROM fieldmaps.project_memberships other
        WHERE other.project_id = m.project_id AND other.user_id <> caller AND other.role = 'manager')) THEN
    RAISE EXCEPTION 'sole_owner' USING ERRCODE = 'FM002';
  END IF;
  DELETE FROM fieldmaps.project_memberships WHERE user_id = caller;
  DELETE FROM fieldmaps.organization_members WHERE user_id = caller;
  INSERT INTO fieldmaps.profiles(user_id, deleted_at) VALUES (caller, now())
  ON CONFLICT (user_id) DO UPDATE SET display_name = NULL, observer_initials = NULL, locale = NULL,
    deleted_at = coalesce(fieldmaps.profiles.deleted_at, now());
END;
$$;
REVOKE ALL ON FUNCTION fieldmaps_private.transfer_ownership(uuid, uuid), fieldmaps_private.forget_user()
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION fieldmaps_private.transfer_ownership(uuid, uuid), fieldmaps_private.forget_user()
  TO fieldmaps_api;
INSERT INTO fieldmaps_meta.schema_migrations(version) VALUES ('0010_tenancy_role_guards');
