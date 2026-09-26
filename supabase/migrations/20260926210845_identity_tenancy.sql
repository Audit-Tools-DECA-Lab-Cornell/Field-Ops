CREATE TABLE fieldmaps.profiles (
  user_id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  display_name text CHECK (length(btrim(display_name)) BETWEEN 1 AND 100),
  observer_initials text CHECK (observer_initials ~ '^[A-Z0-9]{1,10}$'),
  locale text,
  created_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz
);
ALTER TABLE fieldmaps.organizations
  ADD COLUMN slug text,
  ADD COLUMN created_by uuid,
  ADD COLUMN plan text NOT NULL DEFAULT 'pilot',
  ADD COLUMN data_region text NOT NULL DEFAULT 'us-east-1',
  ADD COLUMN is_platform boolean NOT NULL DEFAULT false,
  ADD COLUMN created_at timestamptz NOT NULL DEFAULT now(),
  ADD COLUMN deleted_at timestamptz;
UPDATE fieldmaps.organizations SET slug = CASE
  WHEN id = '10000000-0000-4000-8000-000000000001' THEN 'practice'
  ELSE 'org-' || replace(id::text, '-', '') END;
ALTER TABLE fieldmaps.organizations ALTER COLUMN slug SET NOT NULL,
  ADD UNIQUE (slug), ADD CHECK (slug ~ '^[a-z0-9](?:[a-z0-9-]{1,38}[a-z0-9])$');
CREATE TABLE fieldmaps.organization_members (
  organization_id uuid NOT NULL REFERENCES fieldmaps.organizations(id),
  user_id uuid NOT NULL REFERENCES fieldmaps.profiles(user_id) ON DELETE CASCADE,
  role text NOT NULL CHECK (role IN ('owner', 'admin', 'member')),
  granted_by uuid,
  granted_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (organization_id, user_id)
);
CREATE INDEX organization_members_user_idx ON fieldmaps.organization_members(user_id, organization_id);
ALTER TABLE fieldmaps.projects ADD COLUMN code text, ADD COLUMN description text,
  ADD COLUMN timezone text NOT NULL DEFAULT 'America/New_York',
  ADD COLUMN status text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'archived')),
  ADD COLUMN is_training boolean NOT NULL DEFAULT false,
  ADD COLUMN created_at timestamptz NOT NULL DEFAULT now();
UPDATE fieldmaps.projects SET code = CASE
  WHEN id = '10000000-0000-4000-8000-000000000002' THEN 'practice'
  ELSE 'project-' || replace(id::text, '-', '') END;
ALTER TABLE fieldmaps.projects ALTER COLUMN code SET NOT NULL,
  ADD UNIQUE (organization_id, code), ADD CHECK (code ~ '^[a-z0-9](?:[a-z0-9-]{1,38}[a-z0-9])$');
DO $$
DECLARE orphan_ids text;
BEGIN
  SELECT string_agg(DISTINCT m.user_id::text, ', ') INTO orphan_ids
  FROM fieldmaps.project_memberships m LEFT JOIN auth.users u ON u.id = m.user_id
  WHERE u.id IS NULL;
  IF orphan_ids IS NOT NULL THEN
    RAISE EXCEPTION 'Memberships have no Auth user: %', orphan_ids USING ERRCODE = '23503';
  END IF;
END;
$$;
INSERT INTO fieldmaps.profiles(user_id)
SELECT DISTINCT m.user_id FROM fieldmaps.project_memberships m JOIN auth.users u ON u.id = m.user_id;
ALTER TABLE fieldmaps.project_memberships ADD COLUMN granted_by uuid,
  ADD COLUMN granted_at timestamptz NOT NULL DEFAULT now(),
  ADD FOREIGN KEY (user_id) REFERENCES fieldmaps.profiles(user_id) ON DELETE CASCADE;
CREATE TABLE fieldmaps.invitations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES fieldmaps.organizations(id),
  project_id uuid,
  email text CHECK (email = lower(email)),
  role text NOT NULL,
  token_hash text UNIQUE CHECK (token_hash ~ '^[a-f0-9]{64}$'),
  join_code_hash text UNIQUE CHECK (join_code_hash ~ '^[a-f0-9]{64}$'),
  expires_at timestamptz NOT NULL CHECK (isfinite(expires_at)),
  max_uses integer NOT NULL CHECK (max_uses > 0),
  use_count integer NOT NULL DEFAULT 0 CHECK (use_count >= 0 AND use_count <= max_uses),
  created_by uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  revoked_at timestamptz,
  FOREIGN KEY (organization_id, project_id) REFERENCES fieldmaps.projects(organization_id, id),
  CHECK (token_hash IS NOT NULL OR join_code_hash IS NOT NULL),
  CHECK ((project_id IS NULL AND role IN ('member', 'admin'))
    OR (project_id IS NOT NULL AND role IN ('observer', 'viewer', 'manager')))
);
CREATE INDEX invitations_project_idx ON fieldmaps.invitations(organization_id, project_id);
CREATE SCHEMA fieldmaps_private;
REVOKE ALL ON SCHEMA fieldmaps_private FROM PUBLIC, anon, authenticated, service_role;
GRANT USAGE ON SCHEMA fieldmaps_private TO fieldmaps_api;

CREATE FUNCTION fieldmaps_private.my_org_ids() RETURNS SETOF uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT m.organization_id FROM fieldmaps.organization_members m
  JOIN fieldmaps.profiles u ON u.user_id = m.user_id AND u.deleted_at IS NULL
  JOIN fieldmaps.organizations o ON o.id = m.organization_id AND o.deleted_at IS NULL
  WHERE m.user_id = fieldmaps.request_user_id();
$$;
CREATE FUNCTION fieldmaps_private.has_org_role(p_org_id uuid, p_roles text[]) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT EXISTS (SELECT FROM fieldmaps.organization_members m
    JOIN fieldmaps.profiles u ON u.user_id = m.user_id AND u.deleted_at IS NULL
    JOIN fieldmaps.organizations o ON o.id = m.organization_id AND o.deleted_at IS NULL
    WHERE m.organization_id = p_org_id AND m.user_id = fieldmaps.request_user_id() AND m.role = ANY(p_roles));
$$;
CREATE FUNCTION fieldmaps_private.my_project_ids() RETURNS SETOF uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT p.id FROM fieldmaps.projects p JOIN fieldmaps.project_memberships m ON m.project_id = p.id
    JOIN fieldmaps.profiles u ON u.user_id = m.user_id AND u.deleted_at IS NULL
    JOIN fieldmaps.organizations o ON o.id = p.organization_id AND o.deleted_at IS NULL
    WHERE m.user_id = fieldmaps.request_user_id()
  UNION
  SELECT p.id FROM fieldmaps.projects p
    WHERE fieldmaps_private.has_org_role(p.organization_id, ARRAY['owner','admin']);
$$;
CREATE FUNCTION fieldmaps_private.my_collaborative_project_ids() RETURNS SETOF uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT p.id FROM fieldmaps.projects p
  WHERE NOT p.is_training AND p.id IN (SELECT fieldmaps_private.my_project_ids());
$$;
CREATE FUNCTION fieldmaps_private.has_project_role(p_project_id uuid, p_roles text[]) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT EXISTS (SELECT FROM fieldmaps.projects p
    JOIN fieldmaps.organizations o ON o.id = p.organization_id AND o.deleted_at IS NULL
    WHERE p.id = p_project_id AND (
      ('manager' = ANY(p_roles) AND fieldmaps_private.has_org_role(p.organization_id, ARRAY['owner','admin']))
      OR EXISTS (SELECT FROM fieldmaps.project_memberships m
        JOIN fieldmaps.profiles u ON u.user_id = m.user_id AND u.deleted_at IS NULL
        WHERE m.project_id = p.id AND m.user_id = fieldmaps.request_user_id() AND m.role = ANY(p_roles))));
$$;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA fieldmaps_private FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA fieldmaps_private TO fieldmaps_api;

DROP POLICY assigned_projects ON fieldmaps.projects;
CREATE POLICY assigned_projects ON fieldmaps.projects FOR SELECT TO fieldmaps_api
  USING (id IN (SELECT fieldmaps_private.my_project_ids()));
DROP POLICY assigned_sites ON fieldmaps.sites;
CREATE POLICY assigned_sites ON fieldmaps.sites FOR SELECT TO fieldmaps_api
  USING (project_id IN (SELECT fieldmaps_private.my_project_ids()));
DROP POLICY assigned_forms ON fieldmaps.form_versions;
CREATE POLICY assigned_forms ON fieldmaps.form_versions FOR SELECT TO fieldmaps_api
  USING (project_id IN (SELECT fieldmaps_private.my_project_ids()));
DROP POLICY assigned_observations ON fieldmaps.observations;
CREATE POLICY assigned_observations ON fieldmaps.observations FOR SELECT TO fieldmaps_api
  USING (project_id IN (SELECT fieldmaps_private.my_project_ids()));
DROP POLICY assigned_packages ON fieldmaps.site_packages;
CREATE POLICY assigned_packages ON fieldmaps.site_packages FOR SELECT TO fieldmaps_api
  USING (project_id IN (SELECT fieldmaps_private.my_project_ids()));
DROP POLICY assigned_package_checks ON fieldmaps.package_checks;
CREATE POLICY assigned_package_checks ON fieldmaps.package_checks FOR SELECT TO fieldmaps_api
  USING (EXISTS (SELECT FROM fieldmaps.site_packages p WHERE p.id = package_checks.package_id
    AND p.project_id IN (SELECT fieldmaps_private.my_project_ids())));
DROP POLICY assigned_observation_uploads ON fieldmaps.observations;
CREATE POLICY assigned_observation_uploads ON fieldmaps.observations FOR INSERT TO fieldmaps_api
  WITH CHECK (created_by = fieldmaps.request_user_id() AND upload_hash IS NOT NULL
    AND fieldmaps_private.has_project_role(project_id, ARRAY['observer','manager']));
DROP POLICY manager_prepares_package ON fieldmaps.site_packages;
CREATE POLICY manager_prepares_package ON fieldmaps.site_packages FOR INSERT TO fieldmaps_api
  WITH CHECK (prepared_by = fieldmaps.request_user_id()
    AND fieldmaps_private.has_project_role(project_id, ARRAY['manager']));
DROP POLICY manager_prepares_package_checks ON fieldmaps.package_checks;
CREATE POLICY manager_prepares_package_checks ON fieldmaps.package_checks FOR INSERT TO fieldmaps_api
  WITH CHECK (EXISTS (SELECT FROM fieldmaps.site_packages p WHERE p.id = package_checks.package_id
    AND p.prepared_by = fieldmaps.request_user_id() AND p.prepared_at >= transaction_timestamp()
    AND fieldmaps_private.has_project_role(p.project_id, ARRAY['manager'])));

ALTER TABLE fieldmaps.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE fieldmaps.organization_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE fieldmaps.invitations ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON fieldmaps.profiles, fieldmaps.organization_members, fieldmaps.invitations
  FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON fieldmaps.profiles, fieldmaps.organizations, fieldmaps.organization_members,
  fieldmaps.invitations TO fieldmaps_api;
CREATE POLICY visible_profiles ON fieldmaps.profiles FOR SELECT TO fieldmaps_api
  USING (user_id = fieldmaps.request_user_id() OR EXISTS (
    SELECT FROM fieldmaps.project_memberships m WHERE m.user_id = profiles.user_id
      AND m.project_id IN (SELECT fieldmaps_private.my_collaborative_project_ids())
      AND fieldmaps_private.has_project_role(m.project_id, ARRAY['manager'])));
GRANT UPDATE (display_name, observer_initials, locale) ON fieldmaps.profiles TO fieldmaps_api;
CREATE POLICY own_profile_update ON fieldmaps.profiles FOR UPDATE TO fieldmaps_api
  USING (user_id = fieldmaps.request_user_id() AND deleted_at IS NULL)
  WITH CHECK (user_id = fieldmaps.request_user_id() AND deleted_at IS NULL);
CREATE POLICY assigned_organizations ON fieldmaps.organizations FOR SELECT TO fieldmaps_api
  USING (id IN (SELECT fieldmaps_private.my_org_ids()));
CREATE POLICY visible_org_members ON fieldmaps.organization_members FOR SELECT TO fieldmaps_api
  USING (user_id = fieldmaps.request_user_id()
    OR fieldmaps_private.has_org_role(organization_id, ARRAY['owner','admin']));
CREATE POLICY manager_memberships ON fieldmaps.project_memberships FOR SELECT TO fieldmaps_api
  USING (project_id IN (SELECT fieldmaps_private.my_collaborative_project_ids())
    AND fieldmaps_private.has_project_role(project_id, ARRAY['manager']));
CREATE POLICY manager_invitations ON fieldmaps.invitations FOR SELECT TO fieldmaps_api
  USING (fieldmaps_private.has_org_role(organization_id, ARRAY['owner','admin'])
    OR (project_id IS NOT NULL AND fieldmaps_private.has_project_role(project_id, ARRAY['manager'])));
GRANT UPDATE (name, slug) ON fieldmaps.organizations TO fieldmaps_api;
CREATE POLICY manager_organization_update ON fieldmaps.organizations FOR UPDATE TO fieldmaps_api
  USING (fieldmaps_private.has_org_role(id, ARRAY['owner','admin']))
  WITH CHECK (fieldmaps_private.has_org_role(id, ARRAY['owner','admin']));
GRANT UPDATE (name, description, timezone, status) ON fieldmaps.projects TO fieldmaps_api;
CREATE POLICY manager_project_update ON fieldmaps.projects FOR UPDATE TO fieldmaps_api
  USING (fieldmaps_private.has_project_role(id, ARRAY['manager']))
  WITH CHECK (fieldmaps_private.has_project_role(id, ARRAY['manager']));

CREATE FUNCTION fieldmaps.protect_organization_identity() RETURNS trigger
LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
  IF (NEW.id, NEW.is_platform, NEW.plan, NEW.data_region) IS DISTINCT FROM
     (OLD.id, OLD.is_platform, OLD.plan, OLD.data_region) THEN
    RAISE EXCEPTION 'Organization identity cannot change' USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER protected_organization_identity BEFORE UPDATE ON fieldmaps.organizations
FOR EACH ROW EXECUTE FUNCTION fieldmaps.protect_organization_identity();
CREATE FUNCTION fieldmaps.protect_project_identity() RETURNS trigger
LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
  IF (NEW.id, NEW.organization_id, NEW.code, NEW.is_training) IS DISTINCT FROM
     (OLD.id, OLD.organization_id, OLD.code, OLD.is_training) THEN
    RAISE EXCEPTION 'Project identity cannot change' USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER protected_project_identity BEFORE UPDATE ON fieldmaps.projects
FOR EACH ROW EXECUTE FUNCTION fieldmaps.protect_project_identity();
REVOKE ALL ON FUNCTION fieldmaps.protect_organization_identity(), fieldmaps.protect_project_identity()
FROM PUBLIC, anon, authenticated, service_role;
INSERT INTO fieldmaps_meta.schema_migrations(version) VALUES ('0007_identity_tenancy');
