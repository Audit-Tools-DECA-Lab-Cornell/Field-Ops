# QGIS plan: site packages in, typed layers out (`qgis/`)

This file is part of the [FieldMaps production plan](../docs/plan/README.md) and defines the `GIS-*` tasks. It covers both directions between QGIS and FieldMaps. Several steps change code elsewhere, and those tasks are defined in other files:

| Direction | What | Tasks |
|---|---|---|
| QGIS → FieldMaps | A manager exports site layers from a QGIS project and uploads them as a site package | BE-13 (Storage, zones, current pointer), WEB-08 (upload on the site page), MOB-14 (device download) |
| FieldMaps → QGIS | Analysts read accepted observations as typed layers | **GIS-01 to GIS-04** (here), BE-15, WEB-12 |
| Later | Self-serve access with keys, richer formats, a publishing plugin | GIS-06 to GIS-08 (post-pilot) |

Decision D10 in [decisions.md](../docs/plan/decisions.md) sets the pilot's access model: per-project read-only database logins, with OGC API Features plus keys after the pilot.

## Context (verified 2026-09-22)

**Inbound: QGIS packages today**
- The API accepts GeoJSON layers `ground` and `zones` (required) and `paths` and `trees` (optional), plus an optional `.qgz` or `.qgs`. Five checks run: source project, layer sources, coordinate reference, imagery licence, and archive (`backend/src/fieldmaps_api/packages.py`, `qgis_project.py`).
- Zones are reduced to bounding boxes (`packages.py:469-478`).
- The imagery allow-list is an empty constant (`packages.py:31`).
- There is no GDAL, GeoPackage or raster support.
- The hosted database lacked the package tables until DB-01.

**Outbound: reading observations today**
- `gis.sample_observations` is owner-executed with `security_barrier`. Its WHERE clause hard-codes the org, project and `shell-v1` (`supabase/migrations/20260918185806_fieldops_initial.sql`), so RLS does not apply to it.
- The only reader is the login `fieldmaps_qgis_training`: INHERIT from `fieldmaps_sample_reader`, read-only, with 30 s timeouts.
- `qgis/pg_service.conf` has one service, `fieldmaps_training`. `fieldmaps-training.qgs` is kept outside git, next to its attachments archive.

**Why this is not multi-tenant.** Every new project would need a hand-written view, role and grant, and nothing maps a reader to a project.

## Target (pilot)

```
gis.observations                              generic view, security_invoker, answers as jsonb
gis.p<last 12 hex of project id>_<form>_v<n>  typed view per published form version (registry: fieldmaps.gis_views)
fieldmaps.gis_reader_grants                   role_name → project_id (+ expires_at, revoked_at)
fieldmaps_gis_reader (NOLOGIN)                USAGE on gis + extensions only; column-limited SELECT on base tables;
                                              RLS TO fieldmaps_gis_reader: granted, non-training, non-deleted rows only
per-project login role                        fieldmaps_gis_p<last 12 hex of project id>, INHERIT, member of fieldmaps_gis_reader
qgis/pg_service.conf                          one service per project (public settings only; human-readable names)
```

Names are derived from the project's UUID, not from its code (decision D16):
- codes are unique only within an organization, so two organizations' `survey` projects would collide in the shared `gis` schema and in cluster-wide role names;
- codes may contain hyphens;
- long names are silently truncated at 63 bytes.

Training projects never appear in any `gis` view, and can never receive a reader grant (DB-07).

Tested on Postgres (2026-09-26): a reader with USAGE on `gis` and `extensions` only, column-level SELECT and its own policy
- reads the granted project through a `security_invoker` view (it gets nothing before the grant);
- gets `permission denied for schema fieldmaps` on the raw table.

## Tasks

### GIS-01: Generic and typed GIS views, generated when a form is published
Status: todo · Phase 3 · Size L · Depends: CON-02, DB-09, DB-10 · Blocks: GIS-02, GIS-03, GIS-06, OPS-16, QA-05, WEB-12
Read first:
- `supabase/migrations/20260918185806_fieldops_initial.sql:232-269` (today's sample view and reader)
- `contracts/form-definition.schema.json`
- the migration conventions in [supabase/PLAN.md](../supabase/PLAN.md)

Do: add migration `gis_views`.
1. **Roles and the grants table.**
   - Create the shared base role `fieldmaps_gis_reader` (NOLOGIN).
   - Create the table `fieldmaps.gis_reader_grants`:
     - `role_name text NOT NULL`, `organization_id uuid NOT NULL`, `project_id uuid NOT NULL`
     - `created_at timestamptz NOT NULL DEFAULT now()`, `expires_at timestamptz`, `revoked_at timestamptz`
     - `PRIMARY KEY (role_name, project_id)`
     - `FOREIGN KEY (organization_id, project_id) REFERENCES fieldmaps.projects (organization_id, id)`
   - Add a trigger that refuses a grant for an `is_training` project.
   - Enable RLS, and `REVOKE ALL … FROM PUBLIC, anon, authenticated, service_role`.
2. **Reader access.** `security_invoker` views check base-table privileges and RLS as the querying login, so grant exactly the following to `fieldmaps_gis_reader`, and nothing else:
   - `GRANT USAGE ON SCHEMA gis, extensions`.
     - QGIS calls `geometry_columns`, `postgis_version()` and `ST_AsBinary` by name.
     - Do **not** grant USAGE on `fieldmaps`. Views resolve their tables by OID, so they work without it, and without it the reader cannot query raw tables by name. Both behaviours were verified.
   - Column-level SELECT on only the columns the views reference, including join and filter columns:
     - `observations`: `id, qgis_id, organization_id, project_id, site_id, form_version_id, observer_code, observed_at, received_at, revision, deleted_at, zone_code, round, geom, answers`
     - `sites`: `id, organization_id, project_id, code`
     - `form_versions`: `id, organization_id, project_id, form_id, version`
     - `forms`: `id, organization_id, project_id, code`
     - `projects`: `id, organization_id, code, is_training`

     Never grant `created_by`, `upload_hash`, `device_id` or `app_version`.
   - `GRANT SELECT ON fieldmaps.gis_reader_grants`, with `CREATE POLICY own_grants … FOR SELECT TO fieldmaps_gis_reader USING (role_name = current_user)`.
   - `FOR SELECT TO fieldmaps_gis_reader` policies, none of which queries its own table. A policy on `projects` that joins `projects` recurses infinitely (42P17, verified).
     - `projects`: `USING (NOT is_training AND id IN (<active grants>))`.
     - `observations`, `sites`, `form_versions`, `forms`: `USING (project_id IN (<active grants>))`. On `observations`, also require `deleted_at IS NULL`.
     - Here `<active grants>` is `SELECT g.project_id FROM fieldmaps.gis_reader_grants g WHERE g.role_name = current_user AND g.revoked_at IS NULL AND (g.expires_at IS NULL OR g.expires_at > now())`.
     - Training can never appear. The grant trigger (step 1) refuses Training projects, and `is_training` cannot change (DB-05's protected-column trigger).
     - The exclusions sit **in the policies**, not only in the views, because a reader could otherwise bypass the views.
   - No INSERT, UPDATE or DELETE anywhere.
3. **Manager read path for BE-15.** `GRANT SELECT ON fieldmaps.gis_reader_grants TO fieldmaps_api`, with a policy `fieldmaps_private.has_project_role(project_id, ARRAY['manager'])`.
4. **The generic view.** Create `gis.observations WITH (security_invoker = true)`, and `GRANT SELECT` on it to `fieldmaps_gis_reader`. Its columns:
   - `fid` (`qgis_id`), `observation_id`, `project_code`, `site_code`, `zone_code`, `round`, `form_code`, `form_version`
   - `observer_code`, `observed_at`, `received_at`, `revision`
   - `answers` (jsonb)
   - `geom geometry(Point,4326)`
5. **The typed view per published version.**
   - Create the registry `fieldmaps.gis_views(form_version_id uuid PRIMARY KEY, organization_id uuid NOT NULL, project_id uuid NOT NULL, view_name text UNIQUE NOT NULL)`.
     - RLS on, with defaults revoked.
     - `GRANT SELECT … TO fieldmaps_api`, with a manager policy (`has_project_role(project_id, ARRAY['manager'])`). BE-15 reads view names here.
   - Create `fieldmaps_private.publish_gis_view(form_version_id uuid)`, SECURITY DEFINER with `search_path = ''`.
     - **Revoke EXECUTE from everyone, `fieldmaps_api` included.** It is called only from inside `publish_form_version`, which has already authorized the caller (DB-09).
     - It asserts `state = 'published'`, and skips `is_training` projects.
     - It builds `gis.p<last 12 hex of project_id>_<form code, lowercased, '-' → '_', at most 24 chars>_v<n>`. It raises if `octet_length(name) > 63`.
       - Use the last 12 hex digits, the random node of a v4 UUID. Every fixed and synthetic ID in this repository shares its first 12 (`10000000-0000-…`, `50000000-0000-…`).
     - It uses plain `CREATE VIEW`, never `OR REPLACE`, with `security_invoker = true`. It records the name in the registry and refuses a name owned by another `form_version_id`.
     - Each question with an `exportColumn` becomes a typed column: `one` and `text` become text; `number` becomes numeric; `many` becomes `text[]`.
       - A definition may share an `exportColumn` between questions (`knownExportCollisions`; Janet's loose-parts case, Q4). The second and later questions get the suffix `__<question id>`.
       - An `exportColumn` equal to one of the view's fixed columns (`fid`, `geom`, `round` …) gets the suffix `__answer`.
       - Otherwise `CREATE VIEW` fails with 42701, and the whole publish rolls back.
     - Use `format('%I', …)` for every identifier. Accept an `exportColumn` only if it matches `^[A-Za-z][A-Za-z0-9_]{0,62}$`.
     - It grants SELECT on the new view to `fieldmaps_gis_reader`.
   - Replace `publish_form_version` (DB-09) so it calls this function.
   - Backfill views for versions that are already published, skipping training projects.
6. **Tests**, run as a LOGIN INHERIT role that is a member of `fieldmaps_gis_reader`. Add the access ones to `database/hosted/verify.sql` as well.
   - The member login reads `gis.observations` and a typed view, and gets rows for project A only (a positive read, not just an empty result).
   - `SELECT * FROM fieldmaps.observations` fails with 42501.
   - A deleted observation and a Training observation are invisible even through the raw policy.
   - A revoked or expired grant sees nothing.
   - A grant for a Training project is refused.
   - Two organizations with the same project code and form code get two different view names, including for two synthetic `50000000-…` projects.
   - A definition with a known export-column collision, and one with an `exportColumn` named `round`, both publish.
   - A read through the generic view with all five reader policies in place succeeds (no recursion).
   - An identifier-injection attempt in `exportColumn` is refused, as is a name over 63 bytes.
   - `fieldmaps_api` cannot call `publish_gis_view` directly.
7. **Extend DB-04's coverage test.** `fieldmaps_gis_reader` has no USAGE on `fieldmaps`, and no privilege on `created_by` or `upload_hash`.

Done when:
- the tests pass;
- publishing Janet's form locally creates its typed view;
- `supabase db advisors` adds no new warnings.

### GIS-02: Per-project reader logins (runbook)
Status: todo · Phase 3 · Size M · Depends: GIS-01, OPS-16 · Blocks: BE-15, GIS-03, GIS-04
Needs user: runs the script on staging and production, and sets passwords out-of-band.
Do:
1. Create `database/hosted/grant-gis-reader.sql`, a psql script with the variable `:project_id`. The role name is derived: `fieldmaps_gis_p<last 12 hex of project_id>`. The script:
   - **refuses** a Training project;
   - **refuses** when the role already exists with a grant for a different project, so a login is never shared across tenants;
   - creates the role `LOGIN INHERIT NOSUPERUSER NOBYPASSRLS`, with `default_transaction_read_only = on`, 30 s timeouts, and `search_path = pg_catalog, extensions, gis`;
   - grants `fieldmaps_gis_reader`. Every privilege comes through that role; nothing is granted to the login directly. INHERIT is required, because the policies are `TO fieldmaps_gis_reader`;
   - inserts into `gis_reader_grants`.

   There is **no password in the file**; it is set with `\password` in the same session.
2. Create `database/hosted/revoke-gis-reader.sql`. It sets `revoked_at` and runs `ALTER ROLE … NOLOGIN`.
3. Document both in `qgis/README.md`, including how to hand over a password safely (never in a project file).

Done when: on staging, a reader login for project A opens A's typed layer in QGIS and cannot read B. Record the steps and the screenshot in the task notes.

### GIS-03: Retire the fixed-ID sample view
Status: todo · Phase 3 · Size S · Depends: GIS-01, GIS-02 · Blocks: OPS-17
Read first: `database/hosted/verify.sql` (lines 2 and the sample-view assertion use `fieldmaps_sample_reader` and `gis.sample_observations`); `supabase/migrations/20260919001016_qgis_training_reader.sql`.
Do:
1. Add a migration:

   ```sql
   DROP VIEW gis.sample_observations;
   REVOKE ALL ON SCHEMA gis, extensions FROM fieldmaps_sample_reader;
   REVOKE fieldmaps_sample_reader FROM fieldmaps_qgis_training;
   DROP ROLE fieldmaps_sample_reader;
   ```

   Then drop `fieldmaps_qgis_training`, or `ALTER ROLE … NOLOGIN` if dropping is blocked.
   - Its data, the legacy practice project `…-0002`, is readable in QGIS through a normal GIS-02 grant if anyone still needs it.
   - Training data is never readable in QGIS, by design.
   - A role still holding privileges cannot be dropped (2BP01), which is why the REVOKEs come first.
2. Update `database/hosted/verify.sql`: replace the `fieldmaps_sample_reader` grant and assertion with a member login of `fieldmaps_gis_reader`, holding a grant for a non-training fixture project. Port `database/tests/access.sql`'s "GIS role cannot read raw observation tables" the same way.
3. Update `qgis/README.md`. The SQL files `database/sample-*.sql` are already deleted by DB-03.
4. `fieldmaps-training.qgs` is untracked. Tell the user which layer source to repoint; do not edit files outside the repository.

Done when: no object or doc references `sample_observations` or `fieldmaps_sample_reader` except as history, and `verify.sql` passes.

### GIS-04: QGIS connection templates
Status: todo · Phase 3 · Size S · Depends: GIS-02 · Blocks: WEB-12
Do:
1. Turn `qgis/pg_service.conf` into a documented template.
   - One `[fieldmaps_<org slug>_<project code>]` block per project. It is a local file, so readable names are fine; its `user` is the derived `fieldmaps_gis_p…` role.
   - Public settings only, with a checkout-relative certificate path.
2. Add `qgis/templates/fieldmaps-project.qgs`, a small project with the generic layer through `service=` and no credentials, plus the instructions for adding a typed layer.
3. Update `qgis/README.md` for the new model and the launcher (`open-training.command`).

Done when: following the README on a clean QGIS 4.2 install opens a project's typed layer.

### GIS-05: Retired number
Status: dropped (package pipeline improvements are defined in BE-13 so the API owns them) · Size S · Depends: none · Blocks: none

### GIS-06: OGC API Features endpoint with project keys (post-pilot)
Status: todo · Post-pilot · Size L · Depends: BE-03, GIS-01 · Blocks: none
Do:
1. Serve `/ogc/projects/{p}/collections`, `/collections/{form}/items` (GeoJSON, `bbox`, `datetime`, `limit`, `next` links) and `/conformance` from FastAPI, reading the `gis` views as `fieldmaps_api` under RLS.
2. Authenticate with a revocable, hashed project-scoped key, sent in the `Authorization: ApiKey …` header. QGIS's **"API Header"** authentication method sends it. OAuth2 token refresh in QGIS is unreliable, so do not rely on it.
3. Web: a manager creates and revokes keys on the GIS page.

Done when: QGIS adds an OAPIF layer for a project using a key, and a revoked key fails.

### GIS-07: GeoPackage uploads and offline raster base maps (post-pilot)
Status: todo · Post-pilot · Size L · Depends: BE-13 · Blocks: GIS-08
Do:
1. Add a GDAL worker container, which is the first background job; see [architecture.md](../docs/plan/architecture.md#what-is-deliberately-not-in-the-architecture-yet). It accepts a `.gpkg` directly and reprojects it to EPSG:4326 with pyproj/GDAL.
2. Produce PMTiles raster or vector base maps for a site's extent, with the licence check. The device opens them through MapLibre `pmtiles://file://`.

Done when: a GeoPackage in a local CRS becomes a ready package, and the device shows an imagery base offline.

### GIS-08: "Publish to FieldMaps" QGIS plugin (post-pilot)
Status: todo · Post-pilot · Size L · Depends: GIS-07 · Blocks: none
Do: build a QGIS Python plugin that exports the required layers from the open project and calls the package API with the manager's session (device-code or token paste). It shows the server's checks inside QGIS.

Done when: a manager publishes a package from QGIS without the web upload.
