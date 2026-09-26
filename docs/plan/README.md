# FieldMaps production plan (index)

This is the entry point for taking FieldMaps from prototype to Janet's first field pilot. Every other plan file links back here. **Read this file first, then only the files your task names.**

- Plan agreed: 2026-09-22.
- Target: the pilot in week 13 (about 3 months) with one developer.
- Source research: seven codebase surveys and three vendor-documentation surveys run on 2026-09-22. Their findings are folded into the files below and cited as `file:line`.

## The goal in one paragraph

**The manager's side (web).** A manager signs up, creates an organization and a project, and uploads a QGIS site package. They publish Janet's form and invite observers.

**The observer's side (app).** An observer signs up, verifies a 6-digit email code, and joins with an invite code. They download the site, collect offline, and sync through PowerSync.

**The result.** Records appear in the web review, in CSV/GeoJSON exports and in QGIS. No production screen shows fixture data.

## Decisions already made (do not re-open without the user)

| # | Decision | Detail |
|---|---|---|
| D1 | Self-serve organizations | Anyone may sign up; organizations are created **on the web only** |
| D2 | PowerSync for mobile sync | Gated by a 3–4 day spike ([SYNC-01](sync-powersync.md)); fallback is the existing outbox |
| D3 | Email + password, 6-digit email codes | For verification and password reset; no social login in v1 |
| D4 | Server "Training" project | Every new account joins it automatically; bundled practice data is removed |
| D5 | Capacity | 1 developer, 13 weeks to the pilot |
| D6 | Budget | Undecided; costs are listed in [decisions.md](decisions.md#running-cost) for approval |

The full decision log, the running cost and the open questions are in [decisions.md](decisions.md).

## File map

| File | Owns | Task IDs defined there |
|---|---|---|
| [docs/plan/README.md](README.md) | This index, conventions, phase board | none |
| [docs/plan/product.md](product.md) | Stakeholders, roles, user journeys, the definition of "pilot-ready" | none |
| [docs/plan/architecture.md](architecture.md) | Target system, layering, security rules, environments | none |
| [docs/plan/contracts.md](contracts.md) | Shared contracts: form definition, observation envelope, API endpoint catalog, error envelope | `CON-*` |
| [docs/plan/sync-powersync.md](sync-powersync.md) | PowerSync design, the spike, stream definitions | `SYNC-*` |
| [docs/plan/operations.md](operations.md) | Hosted settings, CI, deploys, monitoring, backups, releases | `OPS-*` |
| [docs/plan/verification.md](verification.md) | Cross-cutting test suites and acceptance runs | `QA-*` |
| [docs/plan/decisions.md](decisions.md) | Decision log, open questions, running cost | none |
| [supabase/PLAN.md](../../supabase/PLAN.md) | Data model v2, migrations, RLS, private functions (covers `supabase/` and `database/`) | `DB-*` |
| [backend/PLAN.md](../../backend/PLAN.md) | FastAPI modules, endpoints, hardening | `BE-*` |
| [mobile/PLAN.md](../../mobile/PLAN.md) | Auth, onboarding, PowerSync client, packages, UX, release | `MOB-*` |
| [web/PLAN.md](../../web/PLAN.md) | Web auth, information architecture, wiring every screen to the API | `WEB-*` |
| [qgis/PLAN.md](../../qgis/PLAN.md) | QGIS in both directions: site packages in, typed GIS layers out | `GIS-*` |

## Conventions that keep the files in sync

1. **One task, one home.** Each task is defined once, under a `### <ID> — <title>` heading in the file that owns its prefix. Every other file refers to it by ID only and never copies its steps.
2. **Status lives only in the owning file,** on the task's `Status:` line: `todo`, `doing`, `done`, `blocked (reason)`. The phase board below lists IDs only, so it never goes stale.
3. **IDs are permanent.**
   - Never renumber a task.
   - Retire one by setting `Status: dropped (reason)`.
   - Add a task with the next free number in its file.
4. **Dependencies are written as IDs, on the Status line.**
   - `Depends:` is the source of truth. Only hard prerequisites go there: something the task cannot do without.
   - `Blocks:` is generated from everyone else's `Depends:`. Never edit it by hand. Run `pnpm plan:check --fix` after changing any `Depends:`.
   - Anything that is not a task (a user decision, a question) goes on a `Needs user:` line, not in `Depends:`.
   - If you change an interface another task relies on, update that task's `Read first` or `Done when` line in its own file.
5. **Sizes:**
   - `S` is half a day or less.
   - `M` is 1–2 days.
   - `L` is 3–5 days.
   - Anything larger must be split.
6. **Check the plan after editing it.** Run `node docs/plan/check-plan.mjs`, or `pnpm plan:check` from the root. It fails when any of these is true:
   - an ID is referenced but not defined, or is defined twice or outside its owning file;
   - a task heading is not followed directly by a valid `Status:` line with a phase and `Depends:`;
   - `Depends:` and `Blocks:` disagree (run `--fix`);
   - a task depends on a dropped task, on a task in a later phase, or on itself through a cycle;
   - the phase board below omits a scheduled task, lists it more than once, or lists it under a different phase.
7. **When a task finishes:**
   - set its status to `done`;
   - add one line saying what now works and how it was verified;
   - update the component's README only if the task changed what that README describes. The README owns current facts; the plan owns intentions.

## How to work on a task (for any agent or developer)

1. Read this index and the owning file's **Context** section.
2. Read the task's `Read first` list, and the design section it links to in `architecture.md`, `contracts.md` or `sync-powersync.md`.
3. Check that everything in `Depends:` is `done`. If it is not, stop and pick another task, or ask.
4. Do the steps. Stay inside the task's scope. If you find other work, add a new task with the next free ID instead of expanding this one.
5. Meet every `Done when` item, and run the `Verify` commands.
6. Update the status. Never claim a device, hosted or production verification you did not perform.

## Global rules (from `AGENTS.md`)

- **Secrets.** Never read, print or edit `.env`, `.env.*` or secret files. Credentials never go into tracked files. Publishable keys and URLs may.
- **Git.** No commits, pushes, branches or amends without the user's explicit approval.
- **Hosted changes.** Applying a migration, changing dashboard settings or deploying is a separate, explicitly authorized step. Tasks that need one say `Needs user:`.
- **Fixture honesty (web).** A fixture notice comes off a screen only when that screen reads real data.
- **Design system.** Web and mobile share Nocturne. Change tokens in `web/src/app/globals.css` and `mobile/src/theme.ts` together.
- **Toolchains.** Node 24, pnpm 10.17.1, uv with Python 3.13. Each app owns its own dependencies.

## Phase board

Each phase ends with something working that can be demonstrated. The weeks are targets for one developer.

### Phase 0: Foundations (weeks 1–2)

**Demo:** CI green; staging API on HTTPS; a sign-up email arrives with a code; a package upload works against staging.

- **Data:** DB-01, DB-02, DB-03, DB-04
- **API:** BE-01, BE-02, BE-03, BE-04, BE-05, BE-16 (done)
- **Contracts:** CON-01, CON-02, CON-03
- **Operations:** OPS-01, OPS-02, OPS-03, OPS-04, OPS-06, OPS-07
- **Mobile:** MOB-01
- **Web:** WEB-01, WEB-02

### Phase 1: Identity and tenancy (weeks 2–4)

**Demo:** a new observer signs up on a phone, verifies the code, joins by code and sees the project. A manager does the same on the web and creates an org.

- **Data:** DB-05, DB-06, DB-07, DB-08
- **API:** BE-06, BE-07, BE-08, BE-09
- **Contracts:** CON-04
- **Operations:** OPS-05, OPS-13, OPS-14
- **Mobile:** MOB-02, MOB-03, MOB-04, MOB-05, MOB-06, MOB-07, MOB-08
- **Web:** WEB-03, WEB-04, WEB-05, WEB-06, WEB-07, WEB-14
- **Verification:** QA-01

### Phase 2: PowerSync and real data on mobile (weeks 4–7)

**Demo:** the manager uploads a QGIS package and publishes Janet's form. The observer downloads the site, collects offline and syncs, and the row appears in PostGIS.

- **Sync:** SYNC-01, SYNC-02
  - SYNC-01 gates only the PowerSync-specific work: DB-11, OPS-08, SYNC-02, and MOB-09 onwards.
  - The server work that either sync design needs starts at once: DB-09, DB-10, DB-12, and BE-10 to BE-13.
- **Data:** DB-09, DB-10, DB-11, DB-12, DB-14
- **API:** BE-10, BE-11, BE-12, BE-13
- **Operations:** OPS-08, OPS-15
- **Mobile:** MOB-09, MOB-10, MOB-11, MOB-12, MOB-13, MOB-14, MOB-15
- **Verification:** QA-02, QA-03

### Phase 3: Web on real data, and GIS (weeks 7–10)

**Demo:** every web screen reads the API. CSV/GeoJSON export works, and QGIS opens a typed per-form layer for one project.

- **API:** BE-14, BE-15
- **Web:** WEB-08, WEB-09, WEB-10, WEB-11, WEB-12, WEB-13
- **GIS:** GIS-01, GIS-02, GIS-03, GIS-04
- **Operations:** OPS-16

### Phase 4: Mobile UX and hardening (weeks 9–12)

**Demo:** TestFlight and Play internal builds run against production. The isolation suites pass and a restore drill is done.

- **Mobile:** MOB-16, MOB-17, MOB-18, MOB-19, MOB-20, MOB-21
- **Web:** WEB-15, WEB-16
- **Data:** DB-13
- **Operations:** OPS-09, OPS-10, OPS-11, OPS-12, OPS-17
- **Verification:** QA-04

### Phase 5: Pilot (week 13)

**Demo:** Janet's field session on a real iPad and a real Android tablet, read back in QGIS.

- **Verification:** QA-05, QA-06

### Critical path

Three lanes run in parallel and meet at MOB-10:

```
Identity: DB-04 → DB-05 → DB-06 → BE-06 → BE-07 → MOB-06
Server:   CON-02 → BE-10 → BE-12 ─────────────────────────────┐
Sync:     SYNC-01 → DB-11 → OPS-15 → OPS-08 → SYNC-02 → MOB-09 ┴→ MOB-10 → MOB-11 → QA-03 → QA-05
```

`node docs/plan/check-plan.mjs` proves the Depends graph has no cycle, and that nothing depends on a later phase.

### Cut list if the schedule slips

Cut in this order:
1. WEB-09's publish UI (seed Janet's version with a migration instead).
2. WEB-11 charts (show counts only).
3. GIS-01's typed views (keep the generic view and CSV).
4. MOB-16's tablet side rail (use tabs everywhere).

**Never cut:** MOB-05, MOB-07 (account deletion), MOB-11, QA-01, QA-02, and rejection preservation (BE-12, MOB-10).

**Post-pilot backlog:**
- Already defined as tasks: GIS-06, GIS-07, GIS-08.
- Get an ID only when scheduled: photo attachments, closed-app background upload, a visual form builder, CAPTCHA on mobile, billing and quotas, an "other observers" map layer, MapLibre on the web, multi-region hosting.

## Status (2026-09-26)

- **Works today.**
  - Offline save, upload and the PostGIS/QGIS read path were verified on 2026-09-18 with two practice records.
  - Package preparation in the API is real and tested.
- **BE-16 is `done`.**
  - Every API role check names the caller.
  - The package list no longer returns 503.
  - The SQL suite's stale ledger assertion is fixed.
  - Verified by 19 SQL assertions, 59 API tests, Ruff and BasedPyright.
- **DB-01 is `doing`.**
  - The hosted migration now carries caller-scoped package policies.
  - Its 13 hosted assertions pass on a disposable PostGIS, including a rerun after a real package exists.
  - The user reports applying it to staging; package acceptance was not repeated here.
- **Review of PR 9.** Greptile's six findings and about 45 further defects from a verified review pass are folded into the task texts above (see decisions D13–D17).
- **DB-02, DB-04, DB-05 and DB-06 are complete locally (2026-09-26).** A fresh Supabase reset, 94 mobile tests, 62 API tests and SQL isolation/function suites pass.
- **OPS-06 and DB-03 are complete (2026-09-26).** [All five CI jobs passed](https://github.com/Audit-Tools-DECA-Lab-Cornell/Field-Maps/actions/runs/36273492260), then the unused migration track was retired. Local checks pass, including mobile formatting.
- Remaining task status lives in each owning file.
