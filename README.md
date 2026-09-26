# FieldMaps

Custom offline field collection for research teams: a native collector, a web management application, an authenticated API, and a shared spatial database readable in QGIS.

This is one Git repository with independently managed components. The root owns product documentation and development commands; each application owns its dependencies, lockfile, and runtime. FieldMaps remains independent of Playspace, COPA, and YEE.

## Product layout

```text
field-maps/
├── web/          Next.js management application, source, public assets, and build config
├── mobile/       Expo / React Native collector with SQLite and MapLibre
├── backend/      FastAPI authentication and observation API
├── database/     Local Supabase tooling, SQL tests and hosted verification
├── supabase/     Canonical schema migrations, local Supabase configuration and seeds
├── qgis/         Read-only live project, connection settings, and launcher
├── docs/         Requirements, architecture, research, and implementation scope
├── designs/      Design references
├── package.json  Product command aliases; no application dependencies
└── Makefile      Python, Docker, and database orchestration
```

## Start working

Use Node 24 (`nvm use`), pnpm 10.17.1, and Docker Desktop for API/database work. Python development uses uv and Python 3.13 or newer.

```sh
pnpm setup:apps
pnpm backend:setup
pnpm dev
```

`pnpm dev` opens the web development server at http://localhost:3000. Root `pnpm install` only installs the dependency-free command package; use `pnpm setup:apps` to install web and mobile dependencies.

| Root command                                  | What it does                                                        |
| --------------------------------------------- | ------------------------------------------------------------------- |
| `pnpm dev` / `pnpm build` / `pnpm start`      | Web development / production build / production server              |
| `pnpm mobile:simulator`                       | Metro for the existing iOS simulator development build              |
| `pnpm mobile:ios` / `pnpm mobile:android`     | Build and run the native development app                            |
| `pnpm api:hosted:up` / `pnpm api:hosted:stop` | Start/stop the local API connected to hosted Supabase               |
| `pnpm check`                                  | Web and mobile type/lint checks, then Python Ruff/BasedPyright      |
| `pnpm test`                                   | Mobile tests, local API integration tests, and local SQL assertions |

Run `pnpm run help` for the command overview. Integration tests need the local databases started with `pnpm db:start`; they do not run against Supabase. The hosted API needs the already provisioned local credential volume. See [workspace operations](docs/Workspace.md) for prerequisites, individual checks, and deployment instructions.

## Current functionality

The mobile collector saves georeferenced observations to SQLite and automatically uploads while the app is active. Native sign-in and two real test uploads have been exercised; the user tested offline save/reconnect, and both records were independently verified in hosted PostGIS and QGIS Desktop. The API still runs on the development computer. This is not a production deployment.

The collector has been rebuilt to the [Riverside Collector design](designs/Riverside%20Collector%20v2.dc.html): an armed place-a-point map mode, one question per screen against a reusable versioned form engine, drafts that survive a force quit, and the Nocturne dark interface. The practice `shell-v1` form and its records are unchanged and still upload. The new `janet-test-v1` instrument subset renders and saves offline but is held on the device, because the API accepts only `shell-v1` today. This redesign is verified by types, tests and bundling only; it has not yet run on a device. See the [mobile collector](mobile/README.md) for what is deliberately left open.

The web application has been rebuilt as the management side of the same product, on the collector's Nocturne design system and the real database vocabulary: an overview of what the field returned, data review over a coordinated map and table, places, the instrument and its variable library, base map package preparation, and the QGIS connection, behind a public landing page. Base map upload is connected to the API: the browser posts a QGIS export to the new package endpoints, which check it, derive zones and an extent, and store an immutable versioned archive. Every other record, count and connection value on its screens comes from local fixtures, and each screen says so. Package download onto a device, attachments, bidirectional edits, and closed-app background synchronization remain future work; the API now resolves a site and form version from the database and validates answers against the form's definition, so a second instrument is a seeded form version rather than a code change. A typed GIS view over its answers is still owed.

Next implementation scope: publishing [Janet's versioned test form](docs/Janet-Test-Form-Scope.md) — dual acceptance in the API, an immutable server form version, and a typed GIS view — once its open protocol decisions are settled. The first test form excludes all 16 hidden spreadsheet rows, as confirmed by the user.

## Component documentation

- [Web management application](web/README.md) and [mobile collector](mobile/README.md)
- [Backend API](backend/README.md), [local spatial database](database/README.md), and [hosted Supabase setup](docs/Supabase-Setup.md)
- [QGIS project and connection](qgis/README.md) and [testing on a real QGIS base map](docs/QGIS-Base-Map-Testing.md)
- [Production architecture](docs/Production-Architecture-Recommendation.md) and [QGIS feasibility research](docs/QGIS-Field-Collection-Feasibility.md)
- [Design brief](docs/Claude-Design-Brief.md) and [workspace management](docs/Workspace.md)
