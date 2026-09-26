# Data model and migrations plan (`supabase/` and `database/`)

This file is part of the [FieldMaps production plan](../docs/plan/README.md). It defines the `DB-*` tasks, which cover:
- the canonical migrations in `supabase/migrations/`;
- the SQL tests and hosted scripts in `database/`;
- every RLS policy and private function.

Related plan files:
- **Design rules** it follows: [architecture.md](../docs/plan/architecture.md#security-rules).
- **Shapes** it must serve: [contracts.md](../docs/plan/contracts.md).
- **Sync tables** must match [sync-powersync.md](../docs/plan/sync-powersync.md#streams-edition-3).
- **GIS views and reader roles** are planned in [qgis/PLAN.md](../qgis/PLAN.md) (GIS-01 to GIS-03).
- **Applying migrations to staging** is done per phase by OPS-14 to OPS-17 in [operations.md](../docs/plan/operations.md).

## Context

**Schema today** (Postgres 17, PostGIS 3.3 in `extensions` on hosted):
- Tables: `organizations`, `projects`, `sites`, `form_versions` (immutable by trigger), `observations`, `project_memberships` (roles `observer`, `manager`, `viewer`), `site_packages`, `package_checks`.
- The user reports applying `supabase/migrations/20260923120000_site_packages.sql` (DB-01); hosted acceptance was not repeated in this implementation.
- Ledger versions `0001`–`0008` exist locally; the next free number is `0009`.

**Identity.**
- The API sets `fieldmaps.user_id` per transaction, and `fieldmaps.request_user_id()` reads it.
- Every policy targets the restricted role `fieldmaps_api` (NOBYPASSRLS; SELECT, and column-limited INSERT).

**Role checks name the caller (2026-09-26).**
- Every membership test in a policy or API query filters on `m.user_id = fieldmaps.request_user_id()`: the package policies (local `0005`, hosted DB-01 file) and `PROJECTS`, `UPLOAD_TARGET`, `PACKAGE_TARGET` (BE-16).
- The policies from the initial migration still rely on the memberships SELECT policy showing each account only its own rows. They are rewritten in DB-05, **before** anything lets members see other members' rows.
- A widened memberships policy would otherwise turn "a manager exists on this project" into "you are a manager". This was reproduced: a viewer prepared a site package.

**Local foundation now implemented:** profiles linked to Auth, organization memberships, invitations, private tenancy functions, caller-scoped RLS and concurrency tests. Public HTTP identity/tenancy endpoints remain BE-06/07; Training data remains DB-07.

**Canonical migration track (2026-09-26).**
- DB-03 removed the historical `database/migrations/0001-0005` track, its ledger, seeds and Docker bootstrap after CI passed.
- `supabase/migrations/` (hosted: a squashed initial file with seeds, plus small files).
- Decision D7 makes `supabase/migrations/` canonical.

**The GIS view.** `gis.sample_observations` is owner-executed with hard-coded IDs, so its WHERE clause is its only tenant boundary (`supabase/migrations/20260918185806_fieldops_initial.sql`). GIS-01 and GIS-03 replace it.

## Conventions for every migration

- **Creating a file.**
  - Use `supabase migration new <name>`. If the CLI is missing, use a `YYYYMMDDHHMMSS_<name>.sql` name that sorts after the last file.
  - Tasks below name a migration by purpose. Its ledger version is the next free `NNNN_<name>`.
- **Applied files are never edited.** Fix mistakes with a new migration. A file counts as applied once it has run anywhere hosted: DB-01 step 1, or OPS-14 to OPS-17.
- **Ledger row.** End every file with `INSERT INTO fieldmaps_meta.schema_migrations(version) VALUES (…)`, as the existing hosted files do.
- **New tables:**
  - enable RLS;
  - grant `fieldmaps_api` only what it needs, column-limited for INSERT and UPDATE;
  - write policies `TO fieldmaps_api`, unless the task names another role, as GIS-01 does for `fieldmaps_gis_reader`;
  - `REVOKE ALL … FROM PUBLIC, anon, authenticated, service_role`.
- **Columns the API writes.** Adding a column the API writes means extending the column-limited grant in the same migration. DB-10 and DB-12 show the pattern.
- **Every membership test names the caller.**
  - Use `m.user_id = fieldmaps.request_user_id()`, or a DB-05 helper.
  - Never rely on a memberships SELECT policy to hide other members' rows.
- **Functions in `fieldmaps`** are SECURITY INVOKER with `SET search_path = pg_catalog`, or `''` where schema-qualified.
- **SECURITY DEFINER** lives only in `fieldmaps_private`, which DB-05 creates. The exact rules are in [architecture.md rule 5](../docs/plan/architecture.md#security-rules).
- **Function parameters never share a name with a column.** Prefix every parameter: `p_project_id`, `p_roles`, `p_user_id`, `p_token_hash` and so on.
  - In a `LANGUAGE sql` function, a column name takes precedence over a same-named parameter. `m.project_id = project_id` then compares the column with itself and is always true. This was verified: a manager of project B passed `has_project_role(A, …)`.
  - In plpgsql the same clash raises 42702.
- **Auth hooks** live in `fieldmaps_auth_hooks`, not `fieldmaps_private` (DB-08).
- **Recursive RLS.**
  - Policies that need "the projects I belong to" call `fieldmaps_private.my_project_ids()` (DB-05).
  - A policy on a table must never query that same table: that is infinite recursion (42P17, verified for `projects`). This applies to `project_memberships` and also to `projects`.
- **Extensions are created explicitly.** Supabase does not enable them by default. Write `CREATE EXTENSION IF NOT EXISTS <name> WITH SCHEMA extensions` (pg_cron: `WITH SCHEMA pg_catalog`) before first use.
- **Domain errors carry their own SQLSTATE.** The API maps them to the error envelope (BE-02):

  | SQLSTATE | Code |
  |---|---|
  | `FM001` | `limit_reached` |
  | `FM002` | `sole_owner` |
  | `FM003` | `invitation_invalid` |
  | `FM004` | `invitation_expired` |
  | `FM005` | `account_deleted` |
  | `FM006` | `role_required` |
  | `FM007` | `not_found` |
  | `FM008` | `conflict` |

  Raise with `RAISE EXCEPTION USING ERRCODE = 'FM002', MESSAGE = 'sole_owner'`.
  - The HTTP status for each code is in [contracts.md](../docs/plan/contracts.md#error-envelope).
  - A new code is added here and there together.
- **Local tests.** Each migration adds assertions to `database/tests/*.sql`, run on the local stack.
- **Hosted assertions.**
  - A migration that changes an access rule also adds to `database/hosted/verify.sql`.
  - Hosted assertions must pass on a database that already holds real rows. Create every row they insert, including parents with unique or version keys, with synthetic `50000000-…` IDs inside the rolled-back transaction, and filter every positive count to those IDs.
  - Use `has_any_column_privilege` for privilege checks. `has_table_privilege` ignores column-level grants.
- **Hosted application needs the user.** It is never part of a task's automated steps.
  - OPS-14 to OPS-17 apply each phase's migrations to staging, always with `supabase db push`, never file by file and never through the SQL editor. The editor does not record `supabase_migrations.schema_migrations`, so a later push would run the file again.
  - `supabase db push` applies **every** pending file; it cannot stop at a version. Before each push, `supabase migration list` must show only the files that the OPS task names. A file from a later phase's task is held on its branch until then.

## Tasks

### DB-01: Port site packages to the hosted migrations
Status: doing (user reports migration applied; staging package acceptance remains unverified) · Phase 0 · Size S · Depends: none · Blocks: DB-12, SYNC-01, WEB-01
Read first: `supabase/migrations/20260923120000_site_packages.sql`; `database/hosted/verify.sql`. The historical local package migrations were retired by DB-03.
Done so far (2026-09-26):
- **The hosted migration** holds local `0004`'s tables and triggers, and `0005`'s tightened policies:
  - every membership test names the caller;
  - checks can be written only by the preparing manager, still a manager, in the transaction that prepared the package.
  - It also carries revokes from the browser roles and ledger rows `0004` and `0005`.
- **`database/hosted/verify.sql` has 13 assertions.** The package checks are:
  - a manager reads the package it prepared;
  - an observer reads it;
  - an observer cannot prepare one;
  - an unassigned user sees none;
  - the API cannot update packages;
  - the browser roles cannot read packages.

  The package sits on a synthetic site (`50000000-…-0006`, rolled back), so the script reruns cleanly after real packages exist.
- **Verified on real PostGIS**, in a disposable container with the hosted migrations applied in order:
  - `verify.sql` passes, including a rerun after a real version 1 exists on the seeded site;
  - a check inserted in a later transaction is refused;
  - with a deliberately widened memberships policy, a viewer still cannot prepare a package.
  - The local SQL suite (19 assertions) and all 59 API tests pass with `0005`.

Remaining:
1. **Needs user:** apply the migration to staging with `supabase link --project-ref lezmqhuucfwqknspgcdy` then `supabase db push`, as the project owner.
   - Not the SQL editor: it records no CLI migration history, so OPS-14's push would run the file again and fail.
   - If it was already pasted, run `supabase migration repair --status applied 20260923120000` first.
2. **Needs user:** run `database/hosted/verify.sql` on staging with stop-on-error. Expect "Thirteen hosted assertions passed…".
3. Update the dated status of these docs:
   - `docs/Supabase-Setup.md`: four migration files, 13 assertions;
   - `database/README.md`: its hosted section still says seven assertions.

Done when:
- `POST /v1/projects/{p}/packages` against staging returns 201 for a manager (with WEB-01 or curl);
- the docs are updated.

Verify: `curl` with a staging manager token; `verify.sql` output.

### DB-02: Local Supabase stack as the development and test database
Status: done (2026-09-26) · Phase 0 · Size L · Depends: none · Blocks: DB-03, DB-04, MOB-05, MOB-21, OPS-06, SYNC-01, WEB-03, WEB-04, WEB-15
What now works: canonical migrations rebuilt on local Supabase; SQL isolation/function checks, 62 API tests and 94 mobile tests pass. Python lint/types pass. Hosted deployment is not claimed.
Read first:
- `supabase/config.toml`
- `database/Makefile`, `database/local-supabase.sh`, `database/tests/run.sql` (the historical Compose stack was retired by DB-03)
- `backend/tests/conftest.py`, `backend/config.local.json`
- `docs/Workspace.md`

Do:
1. **Use `supabase start` (D7).** It runs the migrations in order, provides the `auth` and `storage` schemas, the Supabase roles and Mailpit, and puts PostGIS in `extensions`.
   - There is no hand-made shim fallback: a shim would lack `service_role`, `supabase_auth_admin`, `storage.buckets` and pg_cron, which the migrations need.
   - If the CLI stack cannot run the tests, set this task to `blocked (reason)` and ask.
   - Record the setup in `docs/decisions/0001-canonical-migrations.md`.
2. Fix `supabase/config.toml`. It references a missing `./seed.sql` today (`config.toml:70`).
   - `major_version = 17`
   - Auth confirmations on
   - OTP length 6, expiry 3600
   - minimum password 8
   - templates from `supabase/templates/`, once OPS-03 adds them (no dependency: the stack runs with the default templates until then)
   - `seed.sql_paths` pointing at a new `supabase/seed.sql`
3. Create `supabase/seed.sql` for **local only**.
   - It holds the fixtures the tests need: the sample site and form, and `auth.users` rows for the test identities in `backend/tests/signing.py`.
   - It never holds a real account or secret.
4. Add `database/local-supabase.sh`:
   - generate a random password for `fieldmaps_api` on the local stack;
   - write it to a git-ignored file;
   - point `backend/config.local.json` at `postgresql+asyncpg://fieldmaps_api@127.0.0.1:54322/postgres`, with `database_password_file` set to that file.
5. Port the backend test harness (`conftest.py`) and `database/tests/run.sql` to the local stack.
   - `run.sql` loads `../sample-project.sql` and `../sample-gis.sql` with `\ir`. Replace those with `supabase/seed.sql`, because DB-03 deletes the files.
   - Its migration-ledger assertion lists the exact versions; keep it in sync.
   - Keep every assertion's meaning. Isolate tests with unique UUIDs, and roll back where they do today.
6. Add the root scripts `pnpm db:start`, `pnpm db:stop` and `pnpm db:reset`, and document them in `docs/Workspace.md`.

Done when:
- a fresh clone plus `pnpm db:start` and `pnpm test` passes all 59+ API tests and 19+ SQL assertions against `supabase/migrations`;
- `database/migrations` is no longer used by any test.

Verify: `pnpm db:reset && pnpm test`.

### DB-03: Retire the second migration track
Status: done (2026-09-26) · Phase 0 · Size S · Depends: DB-02, OPS-06 · Blocks: none
Evidence: [CI passed before retirement](https://github.com/Audit-Tools-DECA-Lab-Cornell/Field-Maps/actions/runs/36273492260). The historical migration track, ledger, duplicate seeds and local Docker bootstrap are removed; canonical migrations, local Supabase tests and hosted operations remain.
Do:
1. Delete these, plus their Makefile, `package.json` and `compose` targets:
   - `database/migrations/`
   - `database/migrate.sql`
   - `database/sample-*.sql`
   - `database/seed-local.sql`

   First check that nothing else references them: `grep -rn "migrate.sql\|sample-gis\|sample-project\|seed-local" .`
2. Keep `database/tests/`, `database/hosted/` and the README. Rewrite `database/README.md` to describe the tests and hosted scripts only, and to point here for schema changes.
3. Update the routing table in the root `AGENTS.md` for `database/` and `supabase/`.

Done when:
- CI is green;
- no document mentions `database/migrations` except as history.

### DB-04: Default-privilege hardening and a coverage test
Status: done (2026-09-26) · Phase 0 · Size S · Depends: DB-02 · Blocks: DB-05, OPS-14, QA-01
What now works: canonical migrations rebuilt on local Supabase; SQL isolation/function checks, 62 API tests and 94 mobile tests pass. Python lint/types pass. Hosted deployment is not claimed.
Read first: <https://www.postgresql.org/docs/17/sql-alterdefaultprivileges.html>. A per-schema `REVOKE` only undoes a per-schema `GRANT`, so `ALTER DEFAULT PRIVILEGES IN SCHEMA … REVOKE` changes nothing here. This was verified: a function created afterwards was still executable by `anon`.
Do:
1. Add a migration: `ALTER DEFAULT PRIVILEGES FOR ROLE postgres REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;`.
   - Use the global form, with no `IN SCHEMA`. It was verified to stop new functions being executable by `anon`.
   - Keep the explicit `REVOKE` on every new function anyway.
   - Correct the comment in `architecture.md` rule 2 if it still says "per-schema".
2. Add `database/tests/rls_coverage.sql`. It fails if any of these is true:
   - any table in `fieldmaps` has `relrowsecurity = false`;
   - `has_any_column_privilege` is true for `anon` or `authenticated` on any table in `fieldmaps`, `fieldmaps_private` or `gis`;
   - any function in `fieldmaps`, `fieldmaps_private`, `fieldmaps_auth_hooks` or `gis` is executable by `PUBLIC`, `anon` or `authenticated` (`has_function_privilege`, or `aclexplode(proacl)`);
   - `fieldmaps_api` is `rolbypassrls` or `rolsuper`.

Done when: the test runs in `pnpm test` and passes.

### DB-05: Identity and tenancy schema, private helpers and caller-scoped policies
Status: done (2026-09-26) · Phase 1 · Size L · Depends: BE-16, DB-04 · Blocks: BE-06, BE-07, DB-06, DB-07, DB-09, DB-10, DB-12, DB-13, OPS-14, QA-01
What now works: canonical migrations rebuilt on local Supabase; SQL isolation/function checks, 62 API tests and 94 mobile tests pass. Python lint/types pass. Hosted deployment is not claimed.
Read first:
- [product.md](../docs/plan/product.md#roles)
- the tenancy rows of the endpoint catalog in [contracts.md](../docs/plan/contracts.md)
- `supabase/migrations/20260918185806_fieldops_initial.sql:155-170` (the policies to rewrite)

Do: add one migration, `identity_tenancy`. The **order inside the file matters**: `CREATE POLICY` resolves function names when it runs, and `LANGUAGE sql` bodies are checked against existing tables. Both were verified on Postgres, so any other order fails.
1. **Tables.**
   - **`profiles`:**
     - `user_id uuid PK REFERENCES auth.users(id) ON DELETE CASCADE`
     - `display_name text` (1–100)
     - `observer_initials text CHECK (~ '^[A-Z0-9]{1,10}$')`
     - `locale text`
     - `created_at`, `deleted_at`
   - **`organizations`:** add
     - `slug text NOT NULL UNIQUE CHECK (~ '^[a-z0-9](?:[a-z0-9-]{1,38}[a-z0-9])$')`. Backfill the existing org `…-0001` explicitly as `practice`, so it cannot collide with DB-07's platform org
     - `created_by uuid`
     - `plan text DEFAULT 'pilot'`
     - `data_region text DEFAULT 'us-east-1'`
     - `is_platform bool NOT NULL DEFAULT false`
     - `created_at`, `deleted_at`
   - **`organization_members`:**
     - `(organization_id, user_id REFERENCES profiles ON DELETE CASCADE, role owner|admin|member, granted_by, granted_at)`
     - primary key `(organization_id, user_id)`
   - **`projects`:** add
     - `code text`, unique per org, pattern `^[a-z0-9](?:[a-z0-9-]{1,38}[a-z0-9])$`, backfilled
     - `description`
     - `timezone text NOT NULL DEFAULT 'America/New_York'`
     - `status active|archived`
     - `is_training bool NOT NULL DEFAULT false`
     - `created_at`
   - **`project_memberships`:** add `granted_by` and `granted_at`, and a foreign key from `user_id` to `profiles` with ON DELETE CASCADE.
     - The hosted database has memberships for the confirmed test account. Backfill a `profiles` row for every existing membership's `user_id` that exists in `auth.users`.
     - Stop and report any `user_id` that does not exist in `auth.users`.
   - **`invitations`:**
     - `id uuid PK`, `organization_id`, `project_id NULL` (NULL means an org-level invite)
     - `email text NULL CHECK (email = lower(email))` for bound invites. Plain lowercase text, not citext: citext's operators are invisible under `search_path = ''` and silently fall back to case-sensitive `text = text` (verified).
     - `role`, with `CHECK ((project_id IS NULL AND role IN ('member','admin')) OR (project_id IS NOT NULL AND role IN ('observer','viewer','manager')))`. `owner` is never invitable.
     - `token_hash text NULL`, `join_code_hash text NULL` (at least one), both sha256 hex
     - `expires_at timestamptz NOT NULL`
     - `max_uses int NOT NULL CHECK (max_uses > 0)`, `use_count int NOT NULL DEFAULT 0`
     - `created_by`, `created_at`, `revoked_at`
2. **Private schema and read helpers**, after the tables and before any policy:
   - `CREATE SCHEMA fieldmaps_private; REVOKE ALL ON SCHEMA fieldmaps_private FROM PUBLIC, anon, authenticated, service_role; GRANT USAGE ON SCHEMA fieldmaps_private TO fieldmaps_api;`
     - Policies reach the helpers without USAGE, but the API's direct calls (DB-06) need it. Both behaviours were verified.
   - Each helper is `LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''`:
     - owned by the migration owner, which also owns the tables, so it reads memberships without RLS;
     - `REVOKE ALL ON FUNCTION … FROM PUBLIC, anon, authenticated, service_role`;
     - `GRANT EXECUTE … TO fieldmaps_api`;
     - never `FORCE ROW LEVEL SECURITY` on the membership tables.
   - The helpers. Their parameters are prefixed, per the conventions.
     - `my_project_ids() RETURNS SETOF uuid`: the caller's project memberships, **union** every project of an org where the caller is `owner` or `admin`. An org admin acts as manager on every project in the org, so they must also be able to read those projects; otherwise even `INSERT … RETURNING` fails.
     - `my_collaborative_project_ids() RETURNS SETOF uuid`: the same, excluding `is_training` projects.
     - `my_org_ids() RETURNS SETOF uuid`
     - `has_project_role(p_project_id uuid, p_roles text[]) RETURNS boolean`: an `owner` or `admin` of the project's org counts as `manager`.
     - `has_org_role(p_org_id uuid, p_roles text[]) RETURNS boolean`
   - Every helper filters on `fieldmaps.request_user_id()`.
     - With no identity it returns no rows or `false`, and never raises.
     - Reason: `database/hosted/verify.sql` queries as `fieldmaps_api` with no user set and expects 0 rows.
   - In policies, call them as `project_id IN (SELECT fieldmaps_private.my_project_ids())`, so they are evaluated once per statement.
3. **Rewrite the existing role checks with the helpers** (`DROP POLICY` + `CREATE POLICY`), in this same migration:
   - `assigned_projects` (on `id`), `assigned_sites`, `assigned_forms`, `assigned_observations`, `assigned_packages`: `project_id IN (SELECT fieldmaps_private.my_project_ids())`.
   - `assigned_package_checks`: `package_checks` has no `project_id`, so use `EXISTS (SELECT FROM fieldmaps.site_packages p WHERE p.id = package_checks.package_id AND p.project_id IN (SELECT fieldmaps_private.my_project_ids()))`.
   - `assigned_observation_uploads`: `created_by = request_user_id() AND upload_hash IS NOT NULL AND fieldmaps_private.has_project_role(project_id, ARRAY['observer','manager'])`.
   - `manager_prepares_package`: `prepared_by = request_user_id() AND fieldmaps_private.has_project_role(project_id, ARRAY['manager'])`.
   - Keep `manager_prepares_package_checks` as DB-01 wrote it, apart from moving its membership test to `has_project_role`.
   - **In the same change, rewrite BE-16's three API queries** (`backend/src/fieldmaps_api/queries.py`) onto the helpers. Today they require a membership row; after this migration an org owner or admin acts as manager without one.
     - `PROJECTS`: `WHERE p.id IN (SELECT fieldmaps_private.my_project_ids())`, with the role taken from the caller's own membership, or `manager` for an org owner/admin without one.
     - `UPLOAD_TARGET`: `has_project_role(p.id, ARRAY['observer','manager'])`.
     - `PACKAGE_TARGET`: `has_project_role(p.id, ARRAY['manager'])`.
     - Add an API test: an org admin with no project membership lists the project and can prepare a package.
4. **Read policies** for the new tables and memberships, all `TO fieldmaps_api`. Least privilege: nothing here exists for "curiosity" reads.
   - `profiles`:
     - read your own row, and profiles of members of projects where you are a manager (`has_project_role(…, ARRAY['manager'])`), excluding Training;
     - update your own row (`display_name`, `observer_initials`, `locale`) while `deleted_at IS NULL`, through a column-limited `GRANT UPDATE`.
   - `organizations`: read orgs you belong to (`id IN (SELECT my_org_ids())`). Today there is no read policy at all.
   - `organization_members`: read your own rows; org `owner`/`admin` read all rows of their org.
   - `project_memberships`: keep `self_memberships`. Add a policy letting managers read the memberships of their non-training projects.
     - Training rows stay visible only to their own user, so trainees cannot enumerate every account on the platform.
   - `invitations`: managers of the target project, or org owners/admins, may SELECT.
5. **Writes happen only through functions (DB-06).**
   - The API role gets **no** INSERT, UPDATE or DELETE on `organization_members`, `project_memberships`, `invitations`, `organizations` or `projects`.
   - Two exceptions, both column-limited and backed by policies:
     - `UPDATE (name, slug)` on `organizations` for org owners/admins;
     - `UPDATE (name, description, timezone, status)` on `projects` for managers.
   - Never grant `is_training`, `is_platform`, `plan`, `data_region`, `organization_id` or `code`.
   - Add a BEFORE UPDATE trigger that raises if any of those columns change.
6. **Fixtures that the new foreign keys break.** Fix them in the same change:
   - `database/hosted/verify.sql`: inside its rolled-back transaction, insert `auth.users` rows (`id`, `instance_id`, `aud`, `role`, `email`) and `fieldmaps.profiles` rows for `50000000-…-0001` and `…-0004` before their memberships.
   - `backend/tests/conftest.py::seed_memberships` and `supabase/seed.sql`: the same for USER, VIEWER and MANAGER.
   - `database/tests/run.sql`: rewrite the positional `INSERT … VALUES` fixtures with explicit column lists that include the new required columns.
7. **Tests** (`database/tests/tenancy.sql`), with two orgs:
   - every read policy;
   - a manager of project B is **not** a manager of project A: `has_project_role` returns false, and a package insert on A fails with 42501;
   - an org admin with no project membership lists and reads that org's projects and sites;
   - "no identity sees no projects" still passes;
   - in a project that has a manager and an observer, a viewer cannot insert an observation and an observer cannot insert a site package;
   - a trainee cannot read another trainee's profile or Training membership row;
   - the protected-column trigger raises.

Done when:
- the migration applies on a fresh local stack (`pnpm db:reset`);
- the new tests, the existing SQL suite, the 59 API tests and a local run of `verify.sql` all pass;
- `supabase db advisors` shows no warnings beyond those documented in `docs/Supabase-Setup.md`.

### DB-06: Tenancy functions
Status: done (2026-09-26) · Phase 1 · Size L · Depends: DB-05 · Blocks: BE-06, BE-07, BE-08, DB-07, DB-08, OPS-14
What now works: canonical migrations rebuilt on local Supabase; SQL isolation/function checks, 62 API tests and 94 mobile tests pass. Python lint/types pass. Hosted deployment is not claimed.
Read first: DB-05; the SQLSTATE table in the conventions above; [architecture.md rule 5](../docs/plan/architecture.md#security-rules).
Do: add migration `tenancy_functions`.
- **Every function** below lives in `fieldmaps_private` and is SECURITY DEFINER, with `SET search_path = ''`, owned by the migration owner, `REVOKE EXECUTE … FROM PUBLIC, anon, authenticated, service_role`, and `GRANT EXECUTE … TO fieldmaps_api`.
- **Two assertions come first**:
  1. raise if `fieldmaps.request_user_id() IS NULL`;
  2. except in `forget_user` and `preview_invitation`, call `assert_active_user()`.
- **Every function that writes a membership** first calls `ensure_profile_row()` (step 2). Memberships reference `profiles`, and a web invitee can redeem before anything has called `GET /v1/me`.
- **Authorization.** Each function authorizes the caller against the rows it touches, not just a non-null identity.
- **Serialization.** Functions that change who holds a role first take `pg_advisory_xact_lock(hashtextextended(<organization_id>::text, 0))`, so the last-owner and last-manager checks cannot race.

The functions:
1. **`assert_active_user()`.**
   - Raises `FM005 account_deleted` when there is no `auth.users` row for the caller.
   - Also raises it when the caller's profile exists with `deleted_at IS NOT NULL`.
   - A missing profile is allowed, because new users have none.
2. **`ensure_profile_row()`** and **`ensure_profile(p_display_name text)`.**
   - `ensure_profile_row()` is internal: its EXECUTE is revoked from everyone, `fieldmaps_api` included, and only the functions here call it.
   - They create the profile if it is missing.
   - They add an `observer` membership in the Training project, `INSERT … SELECT … FROM fieldmaps.projects WHERE id = '10000000-0000-4000-8000-000000000102'`. Until DB-07 creates that project, this inserts nothing, rather than failing its foreign key.
   - `ensure_profile` returns the profile.
   - Because `assert_active_user()` runs first, a forgotten account can never regain a membership.
3. **`create_organization(p_name, p_slug, p_project_name, p_project_code, p_timezone)`.**
   - At most 3 orgs where the caller is owner; otherwise raise `FM001`.
   - Inserts the org, the owner membership, the first project and a manager membership.
4. **`create_project(p_org_id, p_name, p_code, p_timezone)`.** For org owners/admins. It adds the caller as manager.
5. **`create_invitation(p_org_id uuid, p_project_id uuid, p_role text, p_email text, p_max_uses int, p_expires_in interval, p_token_hash text, p_join_code_hash text)`**, returning the invitation id.
   - Project invites need a manager of that project; org invites need an org owner/admin.
   - An `admin` invite needs an owner.
   - At least one hash is non-null, and each matches `^[a-f0-9]{64}$`.
   - Hashes are computed by the API (BE-07) and passed in, and BE-07 converts `expires_in_days` to an interval. This function never sees a plaintext token or code.
6. **`revoke_invitation(p_org_id uuid, p_project_id uuid, p_id uuid)`.**
   - Same authorization as `create_invitation`.
   - Raises `FM007` when the row's org or project differs from the arguments, which come from the URL.
7. **`preview_invitation(p_token_hash text, p_join_code_hash text)`.** Read-only.
   - For a live invitation (unrevoked, unexpired, uses left) it returns the org name, the project name (or NULL for an org invite), the role and `expires_at`.
   - Otherwise it raises `FM003` or `FM004`.
   - It never reveals whether or to what email an invite is bound. It is the only way a non-member can read anything about an invitation.
8. **`redeem_invitation(p_token_hash text, p_join_code_hash text)`.**
   - First do the guarded increment:

     ```sql
     UPDATE fieldmaps.invitations i SET use_count = i.use_count + 1
     WHERE (i.token_hash = p_token_hash OR i.join_code_hash = p_join_code_hash)
       AND i.revoked_at IS NULL AND i.expires_at > now() AND i.use_count < i.max_uses
     RETURNING …
     ```

     The UPDATE's row lock makes two concurrent redemptions of a single-use code safe. If no row comes back, look the invitation up again only to tell `FM003 invitation_invalid` from `FM004 invitation_expired`.
   - For bound invites, require all of the following, reading `auth.users` for the caller (never a JWT claim or `user_metadata`):
     - `email_confirmed_at IS NOT NULL`
     - `lower(u.email) = i.email`
   - Choose the target table from `project_id IS NULL`, never from the role text:
     - an org invite inserts `organization_members`;
     - a project invite inserts `project_memberships`, and also an `organization_members` row with role `member` if the caller has none, so `/o/[org]` routes work for them.
   - Reject an existing member of the target with `FM003`; the exception rolls back the guarded increment. An existing organization member may still join a new project. Invitation redemption never changes an existing role.
9. **Role management.** `set_org_role(p_org_id, p_user_id, p_role)`, `remove_org_member(p_org_id, p_user_id)`, `set_project_role(p_project_id, p_user_id, p_role)`, `remove_project_member(p_project_id, p_user_id)`, `transfer_ownership(p_org_id, p_user_id)`.
   - Admins may change only `member` rows, and never to a role above `member`.
   - Only owners may touch `owner` and `admin` rows, or promote anyone to `admin`.
   - Only `transfer_ownership`, called by an owner, creates an owner.
   - Managers (and org owners/admins) manage project roles.
   - Refuse `FM002 sole_owner` when a change would leave an org with no owner, or a non-training project with no manager.
10. **`forget_user()`.**
   - Refuses `FM002` when the caller is the only owner of an org that has other members.
   - It is idempotent. When an `auth.users` row exists for the caller, it:
     - deletes the caller's memberships;
     - **upserts** the profile: `INSERT INTO fieldmaps.profiles (user_id, deleted_at) VALUES (caller, now()) ON CONFLICT (user_id) DO UPDATE SET display_name = NULL, observer_initials = NULL, locale = NULL, deleted_at = coalesce(profiles.deleted_at, now())`.

     The upsert covers a caller who never had a profile (`DELETE /v1/me` before any `GET /v1/me`). Without it, nothing durable would record the pending deletion, and `ensure_profile` would revive the account.
   - A repeat call changes nothing and returns.
   - The profile row with `deleted_at` set is the durable record of a pending Auth deletion. Deleting the Auth user cascades it away, so `SELECT user_id FROM fieldmaps.profiles WHERE deleted_at IS NOT NULL` lists exactly the deletions left to finish.
   - Observations keep `created_by` and `observer_code` as pseudonymous research labels.
11. **Tests** (`database/tests/tenancy_functions.sql`), covering every negative case:
   - `forget_user` with no prior profile, then `ensure_profile`, raises `FM005`;
   - `redeem_invitation` as a user with no profile yet succeeds, and creates the profile;
   - `preview_invitation` returns names for a live invite, reveals no email, and raises `FM003` or `FM004` otherwise;
   - `revoke_invitation` with an id from another project raises `FM007`;
   - after `forget_user`, the functions `ensure_profile`, `create_organization` and `redeem_invitation` each raise `FM005` and add nothing;
   - a second `forget_user` succeeds and changes nothing;
   - `ensure_profile` for an id with no `auth.users` row raises `FM005`;
   - an admin cannot promote themselves, demote an owner, or create an owner or admin invite;
   - a mixed-case bound invite matches its confirmed owner, and an unconfirmed user is refused;
   - the last owner and last manager cannot be removed;
   - a single-use code redeemed twice (two sessions) yields one membership.

Done when: all function tests pass, and DB-04's coverage test still passes.

### DB-07: Training organization and project
Status: todo · Phase 1 · Size M · Depends: CON-02, DB-05, DB-06 · Blocks: BE-06, DB-09, MOB-06, OPS-14
Read first: decisions D4 and D13 in [decisions.md](../docs/plan/decisions.md); `supabase/migrations/20260918185806_fieldops_initial.sql:212-230` (the seeded practice org and project, which stay as they are).
Do: add migration `training`.
1. **Create a new platform org and project with fixed IDs (D13):**
   - org `10000000-0000-4000-8000-000000000101`, "FieldMaps Training", slug `fieldmaps-training`, `is_platform = true`. DB-05 backfilled the practice org's slug as `practice`, so the two cannot collide;
   - project `10000000-0000-4000-8000-000000000102`, "Training", `code = 'training'`, `is_training = true`;
   - site `…-0103` `training-garden`;
   - form version `…-0104`.

   Do **not** convert the seeded practice project `…-0002`. It holds the two records verified on 2026-09-18, and current development builds upload to it. It stays a normal, non-training project until the pilot (see GIS-03).
2. **Seed the training form version** from `contracts/forms/janet-test-v1.json`, code `training-v1`, inserted under the current model. DB-09 later backfills its `forms` row and lifecycle state.
3. **Change the observation SELECT policy.** In an `is_training` project, only rows with `created_by = request_user_id()` are visible.
4. **Purge old Training records.**
   - `CREATE EXTENSION IF NOT EXISTS pg_cron WITH SCHEMA pg_catalog;`
   - Schedule `fieldmaps_training_purge` idempotently: unschedule it if it exists, then `cron.schedule(…)`. It deletes observations of **project `…-0102` only** (the fixed ID, never the flag) received more than 30 days ago.
   - The window depends on open question Q2.
   - pg_cron must be enabled on staging (OPS-14) and production (OPS-09).
5. **Exclude training projects** from every `gis` view (GIS-01) and from GIS reader grants (GIS-02).
6. **Who manages Training.**
   - Nobody holds a membership in the platform org, and the API cannot create one.
   - To upload the Training site package (BE-13 step 6, and the production runbook in OPS-09), an operator adds their own account as manager of `…-0102` with an SQL `INSERT` as the project owner, uploads, and deletes that row.
   - The runbook records this.

Done when:
- a new user calling `ensure_profile` is an observer in Training;
- a second trainee cannot see the first trainee's rows (SQL test);
- project `…-0002` and its rows are unchanged.

### DB-08: Before-User-Created hook
Status: todo · Phase 1 · Size S · Depends: DB-06 · Blocks: OPS-13, OPS-14
Read first: <https://supabase.com/docs/guides/auth/auth-hooks/before-user-created-hook>; [architecture.md rule 5](../docs/plan/architecture.md#security-rules) (hooks are the invoker exception).
Do: add migration `auth_hooks`.
1. Create schema `fieldmaps_auth_hooks`. Grant `USAGE` only to `supabase_auth_admin`, never `fieldmaps_private`.
2. Create table `fieldmaps_auth_hooks.blocked_email_domains(domain text PK)`, seeded with a maintained list of disposable-email domains.
   - It has RLS, `GRANT SELECT … TO supabase_auth_admin`, and `CREATE POLICY auth_admin_reads … FOR SELECT TO supabase_auth_admin USING (true)`.
   - Without the policy, the invoker hook reads zero rows and every domain passes.
3. Create function `fieldmaps_auth_hooks.before_user_created(event jsonb) RETURNS jsonb`:
   - SECURITY INVOKER, with no `request_user_id()` check (none is set during sign-up);
   - `EXECUTE` only for `supabase_auth_admin`;
   - returns `'{}'::jsonb` on success;
   - returns `{"error":{"http_code":400,"message":"Use a permanent email address."}}` for a blocked domain.
4. Enable it locally in `supabase/config.toml` (`[auth.hook.before_user_created]`).

Done when: a local sign-up with a blocked domain fails with that message, and a normal domain succeeds.

### DB-09: Instrument lifecycle (forms and versions)
Status: todo · Phase 2 · Size M · Depends: CON-02, DB-05, DB-07 · Blocks: BE-11, DB-11, DB-13, GIS-01, MOB-13, OPS-15, SYNC-02
Read first: `supabase/migrations/20260918185806_fieldops_initial.sql:75-83` (the trigger that raises on every UPDATE and DELETE).
Do: add migration `instrument`. The steps are in this order, because the backfill is an UPDATE that the current trigger rejects.
1. `DROP TRIGGER immutable_form_version ON fieldmaps.form_versions;`
2. Create `forms(id, organization_id, project_id, code, name, created_at)`, unique `(organization_id, project_id, code)`. Add these columns to `form_versions`:
   - `form_id uuid`
   - `version int`
   - `state text NOT NULL DEFAULT 'published' CHECK (state IN ('draft','published','retired'))`
   - `schema_version int NOT NULL DEFAULT 1`
   - `published_at`, `published_by`
3. **Backfill every existing row, not just `shell-v1`.**
   - Create one `forms` row per `(organization_id, project_id, regexp_replace(code, '-v[0-9]+$', ''))`.
   - Set `form_id`, and set `version` from the suffix (default 1).
   - Known rows: `shell-v1` becomes `shell`/1; `training-v1` becomes `training`/1; test fixtures such as `other-v1` become `other`/1.
   - Assert `NOT EXISTS (SELECT FROM fieldmaps.form_versions WHERE form_id IS NULL OR version IS NULL)`, then `SET NOT NULL` on both, and `ALTER COLUMN state SET DEFAULT 'draft'`.
4. **Recreate the lifecycle trigger** (`CREATE OR REPLACE FUNCTION fieldmaps.preserve_form_version()`, then `CREATE TRIGGER`):
   - identity columns are always frozen;
   - UPDATE of the definition is allowed only while `OLD.state = 'draft'`;
   - after publishing, the only change allowed is `published → retired`, which may set nothing else;
   - DELETE is allowed only for drafts.
5. **Grants and RLS.**
   - **`forms`**: RLS on. `GRANT SELECT, INSERT (id, organization_id, project_id, code, name) … TO fieldmaps_api`. Members read (`project_id IN (SELECT my_project_ids())`); managers insert (`has_project_role(project_id, ARRAY['manager'])`).
   - **`form_versions`:**
     - `GRANT INSERT (id, organization_id, project_id, form_id, version, code, definition, schema_version, state)` and `UPDATE (definition, schema_version)`.
     - `code` is always `forms.code || '-v' || version`, and `version` is `max + 1` for the form, retried once on 23505.
     - `DROP POLICY assigned_forms`, which let every member read every version, and replace it with: members read `published` and `retired` versions.
     - Managers (`has_project_role`) read, insert and update drafts, `WITH CHECK (state = 'draft')`.
6. **Publishing and retiring.**
   - `fieldmaps_private.publish_form_version(p_project_id uuid, p_form_version_id uuid)`, SECURITY DEFINER:
     1. `SELECT … FOR UPDATE` the row;
     2. raise `FM007` if it is missing or its `project_id` differs from the argument;
     3. raise `FM006` unless `has_project_role(project_id, ARRAY['manager'])`;
     4. raise `FM008` unless `state = 'draft'`;
     5. then set `state`, `published_at` and `published_by`.
   - `fieldmaps_private.retire_form_version(p_project_id, p_form_version_id)` does the same for `published → retired`.
   - GIS-01 later adds the typed-view call inside `publish_form_version`, so publishing already works in Phase 2.
7. **Retired versions stay valid for uploads.** Retiring stops new collection, not uploads of records already collected against that version. BE-12 accepts them, and devices keep syncing retired definitions (sync-powersync.md).
8. **Fixtures.** `database/tests/run.sql`, `backend/tests/conftest.py` and `supabase/seed.sql` insert a `forms` row, plus `form_id`, `version` and `state = 'published'`, for every fixture form version. The new NOT NULL columns and the `draft` default would otherwise break them.
9. **Tests:**
   - edit a draft;
   - freeze on publish;
   - retire;
   - a draft is not visible to observers;
   - a manager of org B cannot publish org A's version;
   - `training-v1` has a `forms` row.

Done when: the lifecycle tests pass, and the existing upload tests still resolve `shell-v1`.

### DB-10: Collection schema for sync
Status: todo · Phase 2 · Size M · Depends: DB-05 · Blocks: BE-12, BE-14, DB-11, GIS-01, OPS-15, SYNC-02
Read first: the observation envelope in [contracts.md](../docs/plan/contracts.md#observation-envelope-sync-upload-and-storage).
Do: add migration `collection`.
1. **Add to `observations`:**
   - `zone_code text NULL`, `package_version int NULL`
   - `round int NULL CHECK (round > 0)`, `context jsonb NULL` (fresh period, inherited-from)
   - `gps_accuracy_m real NULL`
   - `device_id uuid NULL`, `app_version text NULL`

   Extend the column-limited INSERT grant to cover them.
2. **Create `upload_rejections`:**
   - `id uuid PK`, `user_id`, `organization_id NULL`, `project_id NULL`, `observation_id uuid`
   - `operation jsonb`, `code text`, `message text`, `created_at`, `resolved_at NULL`
   - Grants: INSERT and `UPDATE (resolved_at)` for `fieldmaps_api`.
   - RLS:
     - users read their own rows;
     - managers (`has_project_role`) read their project's rows;
     - the API inserts `WITH CHECK (user_id = request_user_id() AND (project_id IS NULL OR project_id IN (SELECT fieldmaps_private.my_project_ids())))`. BE-12 sets `project_id` and `organization_id` to NULL when the caller is not a member of the named project, so nobody can plant rows in another tenant's view;
     - the API sets `resolved_at` on **every** unresolved row for (caller, observation id) when a later upload of that observation is accepted.
   - Add an index on `(user_id, observation_id) WHERE resolved_at IS NULL`.
3. **Create `assignments`** `(id, organization_id, project_id, site_id, user_id, form_version_id, starts_on date, ends_on date, created_by, created_at)`.
   - Column-limited grants.
   - Members read the assignments in their projects; managers insert, update and delete.
4. **Create `devices`** `(id uuid PK, user_id, platform text, app_version text, last_seen_at)`.
   - Users upsert their own rows through column-limited grants.
   - Managers read the devices of their project members.
5. Tests for each policy, run as `fieldmaps_api`.

Done when: the policy tests pass, and the existing `PUT` upload tests still pass.

### DB-11: PowerSync replication role and publication
Status: todo · Phase 2 · Size S · Depends: DB-09, DB-10, DB-12, DB-14, SYNC-01 · Blocks: OPS-08, OPS-15, SYNC-02
Read first: [sync-powersync.md](../docs/plan/sync-powersync.md#source-database).
Do: add migration `powersync`. It is idempotent, because SYNC-01 may have left a spike role or publication behind.
1. `DO $$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'powersync_role') THEN CREATE ROLE powersync_role WITH REPLICATION BYPASSRLS LOGIN; END IF; END $$;`
   - No password goes in the file. It is set out-of-band, as for `fieldmaps_api` (see `docs/Supabase-Setup.md`).
2. `GRANT USAGE ON SCHEMA fieldmaps, extensions TO powersync_role;`, then `GRANT SELECT` (whole tables) on exactly the published tables.
   - Grant **whole-table** SELECT, not column lists: PowerSync's initial and chunked snapshots run `SELECT * FROM <table>`, which fails with 42501 under a column-limited grant.
   - The stream queries' explicit column lists keep server-only columns such as `storage_path` off devices.
3. `DROP PUBLICATION IF EXISTS powersync;`, then `CREATE PUBLICATION powersync FOR TABLE` with this list:
   - `fieldmaps.profiles`, `fieldmaps.project_memberships`, `fieldmaps.organization_members`
   - `fieldmaps.projects`, `fieldmaps.sites`, `fieldmaps.zones`
   - `fieldmaps.form_versions`, `fieldmaps.assignments`, `fieldmaps.site_packages`
   - `fieldmaps.observations`, `fieldmaps.upload_rejections`

   `site_packages` is published only after DB-14 has dropped its `archive` bytea. With the column present, the snapshot's `SELECT *` would read rows of up to 16 MiB, over PowerSync's 15 MB row cap. That is why this task depends on DB-14.
4. **Local stack:** guard the role creation so `supabase start` still works if the local `postgres` role cannot grant REPLICATION. Document which case applies.

Done when, on the local stack:
- the migration applies;
- `SELECT tablename FROM pg_publication_tables WHERE pubname = 'powersync'` lists exactly the tables above;
- `site_packages` has no `archive` column.

Applying it to staging is OPS-15's job, and proving replication (including the initial snapshot of every table) is OPS-08's. A DB task's "done" never requires a staging push, because the push depends on the DB task.

### DB-12: Sites, zones, and packages in Storage
Status: todo · Phase 2 · Size M · Depends: DB-01, DB-05 · Blocks: BE-13, DB-11, OPS-15, SYNC-02
Do: add migration `spatial_storage`.
1. **Add to `sites`:** `boundary geometry(MultiPolygon,4326) NULL`, `timezone text NULL`, `current_package_id uuid NULL`.
   - Add `UNIQUE (organization_id, project_id, site_id, id)` on `site_packages`.
   - Use a composite foreign key, `FOREIGN KEY (organization_id, project_id, id, current_package_id) REFERENCES fieldmaps.site_packages (organization_id, project_id, site_id, id)`, so a site can only point at its own package.
   - The pointer lives on `sites` so that `site_packages` stays immutable.
2. **Create `zones`:**
   - `id uuid PK`, `organization_id`, `project_id`, `site_id`, `package_id`
   - `code text`, `name text`, `geom geometry(MultiPolygon,4326)`
   - unique `(site_id, package_id, code)`
   - RLS: members read; managers insert, through a column-limited grant.
3. **Change `site_packages`:**
   - add `storage_path text NULL` and `archive_bytes bigint NULL`;
   - make `archive` nullable;
   - add `CHECK (archive IS NOT NULL OR storage_path IS NOT NULL)`;
   - extend the INSERT grant with `GRANT INSERT (storage_path, archive_bytes) ON fieldmaps.site_packages TO fieldmaps_api;`.
   - Staging already holds packages prepared for DB-01 and WEB-01 (`archive` set, `storage_path` NULL). They are test data and are not backfilled: the immutability trigger forbids it.
   - DB-14 retires the column before PowerSync publishes the table (DB-11).
4. **Grants and policies on `sites`** (manager-only, `has_project_role`, run as `fieldmaps_api` in the tests):
   - `GRANT INSERT (id, organization_id, project_id, code, name, timezone)`, with a manager INSERT policy;
   - `GRANT UPDATE (boundary, timezone, current_package_id)`, with a manager UPDATE policy whose `WITH CHECK` requires `current_package_id` to be NULL or a `ready` package of the same site.
5. **Create the private bucket:** `INSERT INTO storage.buckets (id, name, public) VALUES ('site-packages', 'site-packages', false) ON CONFLICT (id) DO NOTHING`.
   - Add no `storage.objects` policies for `anon` or `authenticated`. Only the API, with its server credential (BE-13), writes and signs objects.

Done when: the migration applies locally, and these pass as `fieldmaps_api`:
- a manager inserts a package with `storage_path` but no `archive`;
- a manager creates a site and points it at its ready package;
- an observer can do neither.

Note: the `workspace` stream in sync-powersync.md reads the current package from `sites.current_package_id`.

### DB-13: Audit log
Status: todo · Phase 4 · Size M · Depends: DB-05, DB-09 · Blocks: OPS-17
Do:
1. **Create table `audit_events`** `(id bigint identity, at, actor_user_id, organization_id, project_id, action text, entity text, entity_id text, changed text[])`.
   - It is append-only: a trigger blocks UPDATE and DELETE.
   - It records **no personal data**. `changed` lists column names only. There are no before/after values, emails, names, initials or hashes. An append-only log cannot be redacted when an account is deleted (J4, Apple 5.1.1(v)).
2. **Add AFTER triggers** whose function is `fieldmaps_private.audit_row()`.
   - It is SECURITY DEFINER with `search_path = ''`, and EXECUTE is revoked from everyone.
   - It takes the actor from `request_user_id()`.
   - Triggers run as the statement's user (`fieldmaps_api`), which has no INSERT on `audit_events` and must never get one, or it could forge audit rows. This is the sanctioned definer exception in [architecture.md rule 5](../docs/plan/architecture.md#security-rules).
   - Add `fieldmaps_private.audit_export(p_project_id, p_format, p_filters)` for BE-14's exports.

   The triggers go on:
   - `organization_members` and `project_memberships`;
   - `invitations` (create, revoke, redeem);
   - `form_versions` (state change);
   - `site_packages` (insert);
   - `profiles` (forget).
3. **RLS:** org owners/admins read their org's events.

Done when:
- each audited action writes one row, with no personal values (SQL tests);
- a manager's package insert as `fieldmaps_api` still succeeds, and so does `verify.sql`.

### DB-14: Retire the package archive column
Status: todo · Phase 2 · Size S · Depends: BE-13 · Blocks: DB-11, OPS-15
Do: add migration `drop_package_archive`.
1. **Needs user (Q7):** on staging, list `SELECT id, site_id, version FROM fieldmaps.site_packages WHERE storage_path IS NULL`. These are the pre-Storage test packages.
   - Re-prepare any that are still needed through BE-13, which creates the next version. The old rows stay as immutable history without an archive; BE-13 answers 410 (`archive_unavailable`) for them.
   - The user confirms that their archives may be discarded.
   - The staging API must already run BE-13's code (OPS-15 checks this). Older code still writes `archive` and would fail once the column is gone.
2. `ALTER TABLE fieldmaps.site_packages DROP COLUMN archive;`
   - Postgres drops DB-12's `archive IS NOT NULL OR storage_path IS NOT NULL` check with the column.
   - Then `ALTER TABLE fieldmaps.site_packages ADD CONSTRAINT site_packages_storage_path_required CHECK (storage_path IS NOT NULL) NOT VALID;`.
3. In `database/hosted/verify.sql`, make **both** package inserts write `storage_path` and `archive_bytes` instead of `archive`: the manager's insert, and the observer's insert inside `assert_rejected`.

Done when: the migration applies locally, and `verify.sql` passes locally. OPS-15 applies it to staging, together with DB-11.
