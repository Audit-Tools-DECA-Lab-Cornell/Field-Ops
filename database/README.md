# FieldMaps database tests

`supabase/migrations/` is the canonical PostgreSQL 17/PostGIS schema. Local development and integration tests run the actual Supabase stack, including Auth, Storage and Mailpit. The schema and task specifications are in [supabase/PLAN.md](../supabase/PLAN.md).

## Run locally

From the product root, with Docker Desktop, Node 24, pnpm 10.17.1 and uv installed:

```sh
pnpm db:start
pnpm test
pnpm db:stop
```

The starter runs pinned Supabase CLI 2.118.0 and generates an ignored API password at `database/.local/fieldmaps-api-password` with mode 0600. It does not display credentials. The API connects as restricted `fieldmaps_api` on localhost port 54322. Studio is on port 54323 and Mailpit on 54324.

`pnpm db:reset` explicitly replaces the local database with the canonical migrations and `supabase/seed.sql`. Start and test commands never reset a database. Stop preserves local volumes. None of these commands targets hosted services.

`pnpm db:test` runs the SQL suite and `hosted/verify.sql` on the local database. Fixtures and temporary role grants roll back. API tests use generated UUIDs and the restricted runtime login; their committed observations/packages remain until an explicit local reset. No integration test silently skips when the stack is unavailable.

## Schema and access

The schema now includes profiles linked to Auth users, organizations, organization members, projects, project memberships, invitations, sites, immutable form versions, observations, immutable site packages and package checks. Composite foreign keys enforce project/organization boundaries.

Organization owners/admins act as managers on their organization's projects. Project managers can read their collaborators' profiles and memberships, except Training memberships. Browser roles and `service_role` cannot access application tables or execute application functions. `fieldmaps_api` cannot bypass RLS or directly grant membership. Column-limited grants allow only the documented profile, organization and project edits.

Tenancy writes go through `fieldmaps_private` functions with a fixed empty search path, current-user authorization and organization locks. Invitation redemption checks the current Auth email, confirmation and use limit. Account forgetting removes memberships and leaves a durable anonymized profile marker until Auth deletion. Training membership insertion becomes active when DB-07 adds the Training project.

`gis.sample_observations` remains a fixed practice-project view, read-only to `fieldmaps_sample_reader`. Its readback tests exercise PostgreSQL, not QGIS Desktop.

## Verification

Verified locally on 2026-09-26: a fresh migration reset, 94 mobile tests, 63 API tests, 88 SQL assertions and 18 hosted-script assertions on the local database. Python lint and type checks pass.

The SQL tests cover geometry, immutable forms, replay ledger, restricted GIS reads, private default privileges, tenancy RLS, ownership limits, invitations and account forgetting. API tests cover upload/package regressions, organization-admin access without project membership, simultaneous invitation redemption and simultaneous last-manager demotion.

DB-03 retired the historical Docker migration track after [all five CI jobs passed](https://github.com/Audit-Tools-DECA-Lab-Cornell/Field-Maps/actions/runs/36273492260). See [the canonical-migrations decision](../docs/decisions/0001-canonical-migrations.md).

Hosted migration application remains a separate operation. `hosted/verify.sql` now requires the DB-04/05/06 migrations and checks their security boundary; applying files locally does not deploy them.
