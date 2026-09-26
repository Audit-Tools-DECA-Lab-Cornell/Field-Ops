# FieldMaps observation API

FastAPI, SQLAlchemy, and PostgreSQL/PostGIS implement the first authenticated, append-only upload slice. The mobile app saves to SQLite first; its foreground queue uploads when connected. QGIS can consume the same committed database records through a scoped GIS view. QGIS itself is not the synchronization server.

## Run locally

Start Docker Desktop, then run from the product root:

```sh
pnpm db:start
pnpm backend:test
```

From `backend/`, start the API with `uv run --frozen uvicorn fieldmaps_api.main:create_app_from_config --factory --app-dir src --port 8000`. Stop any existing API on that port first. `config.local.json` points to local Supabase port 54322 and its generated ignored password file. `pnpm db:stop` preserves local database volumes; `pnpm db:reset` explicitly recreates the local schema and fictional fixtures.

Tests use ephemeral signing keys and fictional accounts on local Supabase, with real RLS through `fieldmaps_api`. The public identity-provider configuration for the running development API is still the configured hosted Auth provider; local Auth onboarding is handled by the later identity tasks. There is no test-user bypass in the running API. `/health` is liveness, not readiness.

For the separate API connected to hosted PostGIS, use [Supabase setup](../docs/Supabase-Setup.md).

## Configure a development identity provider

Create/select a Supabase development project, use its asymmetric JWT signing key (ES256 or RS256), and create a test email/password account through its Auth dashboard. Configure the project's public values in `backend/config.local.json`:

```json
{
	"database_url": "postgresql+asyncpg://fieldmaps_api@127.0.0.1:54322/postgres",
	"database_password_file": "../database/.local/fieldmaps-api-password",
	"issuer": "https://YOUR_PROJECT.supabase.co/auth/v1",
	"jwks_url": "https://YOUR_PROJECT.supabase.co/auth/v1/.well-known/jwks.json",
	"audience": "authenticated",
	"browser_origins": ["http://localhost:3000", "https://field-maps.vercel.app"],
	"browser_origin_pattern": "https://field-maps-[a-z0-9-]+-audit-tools-web-apps-deca-lab-at-cornell\\.vercel\\.app"
}
```

`browser_origins` names the origins the management application is served from. Both configurations list localhost as well as the deployed site, because `pnpm api:hosted:up` runs this API on the development machine against the hosted database — a browser on `localhost:3000` is a normal caller of either one. `localhost` and `127.0.0.1` are different origins to a browser, so both are listed. A browser
preflights any cross-origin call carrying an `Authorization` header, and the default is an empty
list — no origin allowed — so base map upload from the web application fails until its origin is
named here. It is an allowlist by design: a wildcard would let any page a signed-in manager has
open spend their token.

`browser_origin_pattern` covers the origins that cannot be listed one by one — Vercel names a
preview deployment `<project>-git-<branch>-<team>.vercel.app`, a new host per branch. The pattern
must match the whole origin (Starlette applies `fullmatch`), and the team slug is what makes it
safe: a host ending in someone else's team, or in a suffix like `.vercel.app.evil.invalid`, does
not match. Escape the dots. A pattern the regex engine cannot compile is refused at startup, not
per request.

These issuer/JWKS values are public. No Supabase service-role key is needed by this API. It validates the JWT signature, expiry, audience, and issuer and derives the user UUID from the signed subject. Legacy HS256 projects must switch to a supported asymmetric signing key before using this verifier. See [Supabase JWT documentation](https://supabase.com/docs/guides/auth/jwts).

Tenancy functions now create organizations, projects and memberships; the HTTP identity/tenancy endpoints are still BE-06/07. For manual local provisioning, create the matching Auth and profile rows before inserting a membership. Signing in alone grants no project access. From an authorized local administrator SQL session, replace `AUTH_USER_UUID` in this statement:

```sql
INSERT INTO fieldmaps.project_memberships (user_id, organization_id, project_id, role)
SELECT 'AUTH_USER_UUID'::uuid, organization_id, id, 'observer'
FROM fieldmaps.projects
WHERE id = '10000000-0000-4000-8000-000000000002'
ON CONFLICT (user_id, project_id) DO NOTHING;
```

Rebuild/restart the API after public config changes. Configure the same provider and project in [mobile connection settings](../mobile/README.md#enable-the-connected-development-slice), then rebuild the native development client for SecureStore and NetInfo. The Supabase account's database is not used by this local slice: Supabase supplies identity; observations remain in local PostGIS.

## Deploy it

The image carries every configuration it might run under and picks one at startup from the
`FIELDMAPS_CONFIG` environment variable. Unset, it reads `config.local.json`, which is the local
development file and names localhost Supabase — so a deployed container that does not set this
variable answers `/health` and fails every request that touches the database.

On [Render](https://render.com/docs/docker), deploying `backend/Dockerfile`:

| What | Where | Value |
| ---- | ----- | ----- |
| Environment variable | `FIELDMAPS_CONFIG` | `config.render.json` |
| Secret File | `database-password` | the `fieldmaps_api` role's password, nothing else in the file |

That is the whole list. Everything else — the pooler URL, the TLS settings, the CA path, the
identity provider, the browser origins — is public and lives in `config.render.json`, which
differs from `config.hosted.json` only in where the password is read from: Render mounts Secret
Files at `/etc/secrets/<name>`, and `make api-hosted-up` mounts a volume at
`/run/fieldmaps-secrets`.

`PORT` is set by the host and the container honours it, falling back to 8000. Choose a region
close to the database; this configuration points at `aws-0-us-east-1`.

Two things a deployment still needs that are not in this repository: the web application's
origin must appear in `browser_origins` before a browser there can call the API, and
`NEXT_PUBLIC_FIELDMAPS_API_URL` in the web deployment must name the API. Missing either one and
base map upload fails in the browser rather than at the API.

## Contract and guarantees

| Endpoint                                         | Behavior                                                          |
| ------------------------------------------------ | ----------------------------------------------------------------- |
| `GET /v1/projects`                               | Projects visible to the verified account                          |
| `PUT /v1/projects/{project}/observations/{uuid}` | Validate and commit a new point or acknowledge an identical retry |
| `GET /v1/projects/{project}/observations/{uuid}` | Read a permitted observation                                      |
| `POST /v1/projects/{project}/packages`            | Check a base map submission and store a prepared package version  |
| `GET /v1/projects/{project}/packages`             | List prepared package versions and their state                    |
| `GET /v1/projects/{project}/packages/{package}`   | Read one package's manifest and every check it ran                |
| `GET /v1/projects/{project}/packages/{package}/archive` | Download the zip; the ETag is its `sha256`                  |

The PUT body contains `site_id`, `form_version`, `[longitude, latitude]` coordinates, `observer`, timezone-aware `observed_at`, and the answers as further top-level keys. The site and form version are resolved against the project's own rows rather than two string literals, and each answer is validated against that form version's stored definition, so a new instrument is a seeded form version and not a code change. Unknown sites and forms are still rejected, and an answer that fails its field's type or bounds returns 422.

A package submission carries the site and form version, the GeoJSON layers (`ground` and `zones` required, `paths` and `trees` optional) and optionally the `.qgz`/`.qgs` project file, base64 encoded so no multipart dependency is needed. Preparation runs five checks — layers present, layer sources, coordinate reference, imagery licence, derived geometry — and stores the result either way: a blocked package keeps its reasons but does not download. Network tile sources block unless their host is allow-listed, because imagery permission is granted rather than assumed. The archive carries no clock, so its `sha256` is a content identity: the same submission prepared again next month is byte-identical, and the ETag is stable. When it was prepared lives on the row and in the API response, not inside the zip. Rows are immutable and preparing one needs the manager role.

A 200 receipt includes observation/project/user UUIDs, original `received_at`, and `accepted_revision: 1`. A receipt is returned only after commit. Identical retries return the original receipt; conflicting content returns 409 and preserves the original. The authenticated user and normalized payload fingerprint are immutable. A lost response can therefore be retried without duplicate records.

Project membership is enforced in both the API lookup and database row policies. The API uses a restricted non-owner role with transaction-local identity, preventing pooled connections from retaining another account's context. It can select permitted rows and insert observations; it cannot edit/delete observations or grant membership. The SQLite queue keeps records until matching receipt verification and never uploads unassigned practice records.

## Verification and limits

`pnpm backend:test` exercises real local Supabase, including token rejection, membership checks, connection-pool isolation, conflicting/concurrent retries, input boundaries, and restricted GIS readback. Python Ruff and BasedPyright also pass. The local SQL suite passes 78 assertions, followed by 18 assertions from the hosted verification script run locally. Native sign-in, mobile-to-running-API reconnect, and QGIS Desktop refresh still need a configured account/device acceptance run.

This is a local development service. Local Supabase is development infrastructure and must not be deployed as a production database. The hosted development database now has adapted migrations, restricted runtime credentials, and verified TLS. Production rollout still needs approved region/retention choices, a public HTTPS API deployment, managed secret injection, network restrictions, backups, monitoring, and API resource limits. The API has no attachments, update/delete synchronization, download cursor, or closed-app mobile background synchronization yet. Package archives live in a `bytea` column capped at 16 MB, which keeps them transactional with their manifest and checks and under the same row policies; moving to object storage later means replacing one column. The device cannot fetch a package yet.

Use QGIS read-only access for this slice; arbitrary GIS edits do not yet synchronize back to devices. The local database listens on port 54322; a QGIS Desktop login is not provisioned by these commands. The GIS test validates the database view, not the desktop application's behavior.

References: [FastAPI typed responses](https://fastapi.tiangolo.com/tutorial/response-model/), [Supabase mobile auth](https://supabase.com/docs/guides/auth/quickstarts/react-native), [PostGIS](https://postgis.net/).
