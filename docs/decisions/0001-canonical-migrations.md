# Canonical migrations and local Supabase

Accepted: 2026-09-26 (DB-02, decision D7).

`supabase/migrations/` is the schema source for hosted services and local tests. Local development uses Supabase CLI 2.118.0, PostgreSQL 17, Auth, Storage and Mailpit. No simulated Auth schema or second migration implementation is used.

Run `pnpm db:start`, then `pnpm test` from the product root. The API integration tests use the restricted `fieldmaps_api` role over localhost port 54322. Administrative fixture operations and GIS role tests use `docker exec` on the fixed local container; they cannot select a hosted database.

The starter creates a random API-role password in ignored `database/.local/fieldmaps-api-password`, mode 0600. It does not print the password or Supabase startup credentials. Backend commands run from `backend/`, where `config.local.json` points to that file.

`pnpm db:stop` preserves local volumes. `pnpm db:reset` explicitly deletes local database contents, reapplies migrations and seeds fictional identities. Routine test commands do not reset a database. API tests use generated observation/package UUIDs; SQL fixtures roll back.

The initial, already-applied migration contains the practice site, form and GIS view. `supabase/seed.sql` adds local-only fictional Auth accounts and memberships. Applied migrations remain unchanged; corrections use new files.

DB-03 retired the historical migration track after the local suite and OPS-06 CI passed. Hosted migration application is a separate operation.

## Tenancy function contracts

`create_organization` returns the organization row; `create_project` returns the project row; `ensure_profile` returns the profile row. Invitation creation returns its UUID. Preview returns organization/project names, role and expiry without email or hashes. Redemption returns organization/project IDs and the granted invitation role. Existing members of the invitation's target receive `FM003 invitation_invalid`; the transaction rolls back the use-count increment and preserves their role. Existing organization membership still permits joining a new project. Role changes use the authorized role functions.

Ownership transfer promotes an existing member and changes the transferring owner to admin in the same transaction. It enforces the recipient's three-organization ownership limit under account locks acquired in UUID order. Forgetting a sole owner with teammates or the last manager of a project in an active organization is refused. A sole-owned organization without other members is marked deleted when its owner is forgotten, preserving research records while hiding the abandoned organization. User locks serialize account deletion, organization creation and ownership transfer; organization locks serialize role changes and invitation redemption.

## CI verification

The workflow covers web checks/build, mobile checks/tests, backend checks/tests, SQL assertions and plan validation. Local Node 24 verification passes the full workspace checks, web build and all tests. The pre-existing mobile formatting failures are fixed, and Biome excludes the git-ignored credentials directory. [All five GitHub Actions jobs passed](https://github.com/Audit-Tools-DECA-Lab-Cornell/Field-Maps/actions/runs/36273492260) on commit `f9f162a` before DB-03 removed the historical files.
