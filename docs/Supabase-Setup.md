# Supabase development connection

Project: **Field Maps GIS**, `lezmqhuucfwqknspgcdy`, in AWS `us-east-1` (session pooler `aws-0-us-east-1.pooler.supabase.com:5432`). It replaced the earlier development project on September 22, 2026.

**Status, September 22, 2026.** The new project is provisioned and every tracked configuration points at it: `backend/config.hosted.json`, `backend/config.local.json`, `mobile/connection.config.json`, and `qgis/pg_service.conf`.

- **Done and verified on the new project:** the three migrations applied in one transaction and recorded in `supabase_migrations.schema_migrations`; PostGIS 3.3.7 in `extensions`; the seven rollback-only assertions in `database/hosted/verify.sql` passed. New generated passwords for `fieldmaps_api` and `fieldmaps_qgis_training` were set as SCRAM verifiers, so no plain-text password reached the server, and both logins connect through the pooler with verified TLS. The QGIS login is read-only and is refused the private `fieldmaps` and `auth` schemas. `anon` and `authenticated` cannot use any FieldMaps schema, and every table has row-level security. The confirmed account `test-user@example.org` has observer access to the practice project.
- **Docker:** the API password is in the new volume `fieldmaps_hosted_api_secrets` and the QGIS password in `fieldmaps_qgis_secrets`. The rebuilt `fieldmaps-hosted-api-1` answers `/health`, rejects requests without a token, and its own connection code logs in to the new database. The earlier `fieldops-hosted-api-1` container is stopped, and the `fieldops_*` volumes still hold the earlier project's credentials.
- **Publishable key:** set in `mobile/connection.config.json`; the project's Auth settings endpoint accepts it, and the project signs tokens with an ES256 key that the API container fetched from its JWKS URL.
- **Auth hardening:** public sign-up is off (Auth settings report `disable_signup: true`), so only administrators create accounts. The administrator password and secret key were rotated after setup; the API and QGIS logins use their own passwords and kept working.
- **Still to do:** turn on leaked-password protection if the plan includes it, then sign in on the simulator and upload one practice record.

Everything under "Verified and pending" was verified against the earlier project and has not been repeated on this one.

The iOS simulator uses `http://127.0.0.1:8000`. That API now connects to **hosted Supabase PostgreSQL 17.6 / PostGIS 3.3.7**, through the IPv4 session pooler on port 5432. Supabase supplies both Auth and the observation database. The API process still runs on this computer; it has not been deployed publicly.

## Start or stop the connected API

From the repository root, with Docker Desktop running:

```sh
docker compose --env-file /dev/null -f database/compose.hosted.yaml up -d --build
curl http://127.0.0.1:8000/health
```

Stop it with:

```sh
docker compose --env-file /dev/null -f database/compose.hosted.yaml stop
```

The local database and test databases remain available. To switch back, stop the hosted API before starting the local API with uvicorn; both configurations bind localhost port 8000. They use separate observation stores. Switching servers does not transfer their data or reset mobile upload receipts.

For Metro, use `pnpm start:simulator` in `mobile/`; its IPv4 setting matches the simulator bundle URL. The development app already includes SecureStore and NetInfo. Physical devices need a reachable HTTPS API.

## Account access for the first mobile upload

On the earlier project, the supplied test account was confirmed and had observer access to the practice project. The running API's restricted database connection returned that project for the account and no projects for an unrelated identity on the same connection pool. The user completed native sign-in and reported an uploaded observation; the API returned HTTP 200 and hosted readback confirmed the record. The following provisioning steps are for additional test accounts.

1. In [Supabase Authentication → Users](https://supabase.com/dashboard/project/lezmqhuucfwqknspgcdy/auth/users), create an email/password test user with Auto Confirm enabled.
2. Give the project administrator its User UID. Keep its password private and enter it only in the mobile Account screen.
3. The administrator assigns that existing user to the practice project with this SQL, replacing `AUTH_USER_UUID`:

```sql
INSERT INTO fieldmaps.project_memberships (user_id, organization_id, project_id, role)
SELECT u.id, p.organization_id, p.id, 'observer'
FROM auth.users u CROSS JOIN fieldmaps.projects p
WHERE u.id = 'AUTH_USER_UUID'::uuid
  AND u.email_confirmed_at IS NOT NULL
  AND p.id = '10000000-0000-4000-8000-000000000002'
ON CONFLICT (user_id, project_id) DO NOTHING;
```

Signing in alone grants no project access. Existing standalone practice observations remain practice records. Create a new observation after signing in and receiving project access; disconnect, save, then reconnect with the app open to check automatic upload.

## Provision a new project

Run these once per Supabase project, from the repository root. Keep every password out of tracked files; the only places they belong are the Docker volumes below and your own password manager.

1. **Schema.** Apply the three files in `supabase/migrations/` in filename order, as the project owner, and record them in `supabase_migrations.schema_migrations` if you do not use the CLI: paste each into the dashboard SQL editor, or run `supabase link --project-ref lezmqhuucfwqknspgcdy` and then `supabase db push`. They create the private schemas, PostGIS in `extensions`, the practice project, and the `fieldmaps_api` and `fieldmaps_qgis_training` logins.
2. **Login passwords.** Generate two passwords, for example with `openssl rand -base64 32`, and set them as the project owner:

   ```sql
   ALTER ROLE fieldmaps_api PASSWORD 'API_PASSWORD';
   ALTER ROLE fieldmaps_qgis_training PASSWORD 'QGIS_PASSWORD';
   ```

3. **API secret volume.** Replace the API password without it touching the shell history or a file in the repository:

   ```sh
   docker compose --env-file /dev/null -f database/compose.hosted.yaml down
   docker volume rm fieldmaps_hosted_api_secrets
   docker volume create fieldmaps_hosted_api_secrets
   read -rs FIELDMAPS_API_PASSWORD
   printf '%s' "$FIELDMAPS_API_PASSWORD" | docker run --rm -i -v fieldmaps_hosted_api_secrets:/s alpine sh -c 'umask 077; cat > /s/database-password'
   unset FIELDMAPS_API_PASSWORD
   ```

   Store the QGIS password the same way in `fieldmaps_qgis_secrets`, file `training-password`, so the administrator can hand it out. To read it back: `docker run --rm -v fieldmaps_qgis_secrets:/s:ro fieldmaps-hosted-api cat /s/training-password`.
4. **Auth settings** in the dashboard: turn off **Allow new users to sign up**, since accounts are created by administrators, and turn on leaked-password protection.
5. **Publishable key.** Copy the `sb_publishable_…` key from **Project Settings → API Keys** into `publishableKey` in `mobile/connection.config.json`, replacing the placeholder. It is public by design; never put a secret or service-role key there.
6. **Test account.** Create a user and grant project access as described in [Account access](#account-access-for-the-first-mobile-upload).
7. **Check.** `pnpm api:hosted:up`, then `curl http://127.0.0.1:8000/health`, sign in on the simulator, and upload one practice record.

## Database and credential setup

On the earlier project, the applied migrations in `supabase/migrations/` matched hosted migration history. The initial migration installs PostGIS in `extensions`, creates private `fieldmaps`, `fieldmaps_meta`, and `gis` schemas, and seeds only the fictional practice project/site/form. The second migration removes browser API execution grants from the dashboard's RLS event-trigger function. The third adds the scoped QGIS training login. No app user or membership is seeded.

`backend/config.hosted.json` contains public connection settings. The restricted `fieldmaps_api` login has no ownership or RLS bypass; it can insert observations and read rows permitted by the verified account's project memberships. The API uses a generated password stored only in the external Docker volume `fieldmaps_hosted_api_secrets`, at `/run/fieldmaps-secrets/database-password`, mode 0600, mounted read-only. The supplied administrator password was used transiently for provisioning and is not the API credential.

This volume is local secret storage for development, not a production secret manager. A new computer needs a separately provisioned API credential and volume. Do not delete the volume as a troubleshooting step; replacing it requires coordinated password rotation and an API restart. Production deployment must inject a runtime secret through its hosting platform.

TLS verifies the Supabase CA chain and pooler hostname. See [certificate provenance and compatibility](../backend/certs/README.md). This client configuration does not change the project's server-wide SSL enforcement setting.

The CLI configuration in `supabase/config.toml` defines the canonical local development and test stack. Use `pnpm db:start`; do not push this local configuration to overwrite hosted Auth settings. The migrations were applied through the authenticated Supabase connector; no local CLI login/link is required to run the API.

## Verified and pending

- **Passed:** 24 backend tests against real local PostGIS, 19 database assertions, Ruff and BasedPyright.
- **Passed on Supabase:** seven rollback-only assertions for membership isolation, restricted writes, spatial readback, and the project-scoped GIS view. Test rows and temporary role grants were removed by rollback.
- **Passed in the running hosted configuration:** restricted pooler login, database query through SQLAlchemy, no projects for an unassigned identity, public Auth signing-key retrieval, HTTP health and rejection of missing/invalid tokens. The first real mobile upload, labeled "First sync test", received HTTP 200 on September 18, 2026 at 19:20:08 UTC. The stored record has revision 1 and appears in `gis.sample_observations` with matching coordinates, count, and notes; the user reported UPLOADED in the app.
- **Advisor results:** the latest check flags [disabled leaked-password protection](https://supabase.com/docs/guides/auth/password-security#password-strength-and-leaked-password-protection); address this Auth setting during deployment hardening. Two [RLS-without-policy notices](https://supabase.com/docs/guides/database/database-linter?lint=0008_rls_enabled_no_policy) are intentional: organizations and migration metadata are administrator-only. [Unused-index notices](https://supabase.com/docs/guides/database/database-linter?lint=0005_unused_index) are expected before traffic; retain the spatial and foreign-key indexes.
- **Offline acceptance:** the user followed the disconnect/save/reconnect test and reported automatic upload. Hosted readback confirmed "Offline sync test", captured September 18, 2026 at 19:24:03.807 UTC and received at 19:24:10.399461 UTC, with revision 1 and matching coordinates, count, and notes in `gis.sample_observations`. Offline interaction was user-tested; database persistence and GIS-view readback were independently verified.

**QGIS connection:** a separate `fieldmaps_qgis_training` login now inherits the scoped reader role. Its actual pooler login returns the two uploaded points with verified TLS; permission checks deny access to private application/Auth tables and observation edits. QGIS Desktop 4.2.2 is now installed: its native PostgreSQL layer returned both records, its attribute table displayed their answers, and its exported map canvas rendered both labeled points. The reusable project is `qgis/fieldmaps-training.qgs`; see [connection and reopening instructions](../qgis/README.md). No password is embedded in its layer sources. A fresh QGIS session may prompt for the scoped GIS credential.

The mobile queue currently uploads new points while the app is active. General form publishing, attachments, edit/delete synchronization, server-to-device downloads, and closed-app background synchronization remain outside this slice. The development mobile-to-database-to-QGIS path is verified for the two test observations; a production rollout and physical-device field trial remain unverified.

References: [Supabase connection methods](https://supabase.com/docs/guides/database/connecting-to-postgres), [PostGIS extension placement](https://supabase.com/docs/guides/database/extensions/postgis), [TLS verification](https://supabase.com/docs/guides/platform/ssl-enforcement).

## Local foundation verification (2026-09-26)

DB-02/04/05/06 now run against local Supabase using the canonical migrations. The local advisor reports one performance warning for the deliberately separate `self_memberships` and `manager_memberships` SELECT policies required by DB-05. Both policies are covered by isolation tests; neither grants another user's role. No new local security warning was reported. This does not verify or change hosted Auth settings.

The new schema/function migrations have been rebuilt and tested locally. The user reported applying the PR #9 package migration; hosted DB-04/05/06 application is not claimed here. The updated verification script must run only after those migrations exist.
