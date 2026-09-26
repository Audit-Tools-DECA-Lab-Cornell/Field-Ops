# Operations: hosted settings, CI, deploys, monitoring, releases

This file is part of the [FieldMaps production plan](README.md) and defines the `OPS-*` tasks.

Most tasks here change hosted services, and **every one of those needs the user's explicit authorization**. The steps below say `Needs user:` for those. An agent may prepare files, checklists and scripts, but must not apply dashboard changes, deploy, or buy anything on its own.

Environments are described in [architecture.md](architecture.md#environments). Running costs are in [decisions.md](decisions.md#running-cost).

## Context

- **API.** It runs only on the developer's machine against hosted Supabase (`docs/Supabase-Setup.md:15`). The Render config exists (`backend/config.render.json`) but nothing is deployed.
- **Auth settings.** Public sign-up is ON (the user changed it on 2026-09-22, and `docs/Supabase-Setup.md:10,81` still says otherwise).
  - There is no custom SMTP. The built-in provider sends only to project team members, at most 2 per hour, so confirmation emails will not reach real users.
  - On a new Free project, email templates cannot be edited without custom SMTP. That blocks the `{{ .Token }}` codes.
- **CI and monitoring.** There is no CI, no Sentry, and no backup drill.
- **Mobile builds.** Bundle IDs end in `.dev` (`mobile/app.json:13,20`). EAS Update is installed, but `runtimeVersion` and `updates.url` are not set.

## Tasks

### OPS-01: Staging Auth settings for public sign-up
Status: todo · Phase 0 · Size S · Depends: none · Blocks: OPS-09
Needs user: apply the settings in the Supabase dashboard for project `lezmqhuucfwqknspgcdy`.
Read first: `docs/Supabase-Setup.md`; <https://supabase.com/docs/guides/deployment/going-into-prod>.
Do:
1. Prepare this checklist for the user:
   - "Confirm email" ON;
   - email OTP length 6, expiry 3600 s;
   - minimum password length 8;
   - Site URL is the staging web origin;
   - Redirect URLs: the web origins plus `fieldmaps://auth/callback`;
   - anonymous sign-ins OFF.
2. After the user applies it, update `docs/Supabase-Setup.md`: sign-up is ON, the settings above, and the date.

Done when:
- the doc states the real settings, dated;
- no stale "sign-up is off" remains (`grep -n "sign-up" docs/Supabase-Setup.md`).

Verify: check the dashboard values. A sign-up on staging returns "confirmation required".

### OPS-02: Custom SMTP via Resend
Status: todo · Phase 0 · Size S · Depends: none · Blocks: OPS-03, OPS-09
Needs user: Q6 in [decisions.md](decisions.md#open-questions) (the sending domain).
Needs user: a Resend account, the DNS records for the sending domain, and SMTP settings in Supabase.
Do:
1. Write the setup steps into `docs/Supabase-Setup.md` under "Email delivery":
   - Resend domain verification (SPF, DKIM);
   - Supabase Auth → SMTP (host `smtp.resend.com`, port 465, the user, and an API key entered only in the dashboard);
   - raise the Auth email rate limit to 30 per hour or more.
2. The user applies them.

Done when: a sign-up email reaches an address that is not a team member.

Verify: a test sign-up to a personal inbox receives the email within 1 minute.

### OPS-03: Email templates with 6-digit codes
Status: todo · Phase 0 · Size S · Depends: OPS-02 · Blocks: OPS-09
Needs user: paste the templates into the Supabase dashboard (staging, and later production).
Read first: <https://supabase.com/docs/guides/auth/auth-email-templates>.
Do:
1. Create `supabase/templates/confirm-signup.html`, `recovery.html` and `email-change.html`.
   - Each shows `{{ .Token }}` prominently: "Your FieldMaps code is 123456".
   - They carry **codes only**, with no link (decision D3). A `{{ .TokenHash }}` link would need a confirm route the web does not have, and would put a one-time token in a URL.
   - Use Nocturne-neutral HTML with inline styles and no tracking pixels.
2. Reference them from `supabase/config.toml` (`[auth.email.template.*]`), so the local stack (DB-02) uses the same files.

Done when: local Mailpit and staging both show the 6-digit code.

Verify: `supabase start`; sign up locally; the Mailpit message shows the code.

### OPS-04: Render staging service for the API
Status: todo · Phase 0 · Size M · Depends: BE-01, BE-02 · Blocks: OPS-09, SYNC-01
Needs user: a Render account and service, the Secret File `database-password`, and later `supabase-secret-key` (BE-08).
Read first: `backend/README.md` ("Deploy it"); `backend/config.render.json`; `backend/Dockerfile`.
Do:
1. Add `render.yaml` (a Blueprint) at the repo root:
   - web service built from `backend/Dockerfile`;
   - `FIELDMAPS_CONFIG=config.render.json`;
   - health check path `/ready`;
   - region Virginia (near `aws-0-us-east-1`);
   - plan Starter.
2. Remove the localhost origins from `config.render.json`, and add the staging Vercel origin and preview pattern.
3. Document the URL in `docs/Supabase-Setup.md` and `backend/README.md`, and put it in `mobile/config/staging.json` (MOB-01).

Done when: the staging API answers `/ready` 200 over HTTPS, and rejects a request with no token with 401 and the error envelope.

Verify: `curl -s https://<staging-api>/ready` and `curl -s -o /dev/null -w '%{http_code}' https://<staging-api>/v1/projects` (expect 401).

### OPS-05: Vercel environment for web auth
Status: todo · Phase 1 · Size S · Depends: WEB-03 · Blocks: none
Needs user: the Vercel project settings (Root Directory `web`) and the environment variables.
Do:
1. Document these in `web/README.md`:
   - `NEXT_PUBLIC_SUPABASE_URL`
   - `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY`
   - `FIELDMAPS_API_URL` (server-only; replaces `NEXT_PUBLIC_FIELDMAPS_API_URL` once WEB-05 lands)
   - `SENTRY_DSN` (server) and `NEXT_PUBLIC_SENTRY_DSN` (browser). A DSN is public; the `NEXT_PUBLIC_` one is fixed at build time
2. The user sets them for Preview (staging) and Production.

Done when: a preview deployment can sign in against staging.

Verify: sign in on a preview URL.

### OPS-06: GitHub Actions CI
Status: doing (workflow prepared; local checks pass; awaiting GitHub Actions) · Phase 0 · Size M · Depends: DB-02 · Blocks: DB-03, OPS-09
Read first: the root `package.json` scripts; `Makefile`; `docs/Workspace.md` ("Development and checks").
Do:
1. Create `.github/workflows/ci.yml` with these jobs:
   - `web`: install, check, build;
   - `mobile`: install, typecheck, lint, test;
   - `backend`: uv sync, ruff, basedpyright, then pytest against `supabase start` using the Supabase CLI setup action;
   - `database`: SQL assertions against the same stack;
   - `contracts`: `pnpm contracts:generate`, then `git diff --exit-code`. Add it here if CON-03 is already done; otherwise CON-03 adds it;
   - `plan`: `node docs/plan/check-plan.mjs`.
2. Use Node 24 and pnpm 10.17.1. Cache pnpm and uv.
3. CI never touches hosted services.

Done when: CI is green on a pull request.

Verify: the Actions run on the next pull request.

### OPS-07: Sentry projects
Status: todo · Phase 0 · Size S · Depends: none · Blocks: MOB-20, OPS-09, QA-06, WEB-16
Needs user: a Sentry account and three projects (api, web, mobile). The DSNs are set as runtime environment variables only.
Do:
1. Document the DSN variable names per app.
2. Set the scrubbing rules: no request bodies, no `answers`, no emails in breadcrumbs.

Done when: each app sends a test event (verified later in QA-06).

### OPS-08: PowerSync staging instance
Status: todo · Phase 2 · Size S · Depends: DB-11, OPS-15, SYNC-01 · Blocks: MOB-09, OPS-09, SYNC-02
Needs user: a PowerSync Cloud account, a US-region instance, and the `powersync_role` password.
Read first: [sync-powersync.md](sync-powersync.md#source-database).
Do:
1. Connect the instance to the staging **direct** connection (`db.<ref>.supabase.co:5432`, IPv6), as `powersync_role`.
2. Client Auth: "Use Supabase Auth", with the JWT secret blank.
3. Set `max_slot_wal_keep_size` on staging. Document how to monitor `pg_replication_slots`.
4. Record the instance URL (public) in `mobile/config/staging.json` (MOB-01).

Done when:
- the instance shows "replicating";
- a staging row change reaches the PowerSync diagnostics app;
- SYNC-02 can deploy.

### OPS-09: Production environment
Status: todo · Phase 4 · Size L · Depends: OPS-01, OPS-02, OPS-03, OPS-04, OPS-06, OPS-07, OPS-08, OPS-17, QA-01, QA-02 · Blocks: OPS-10, OPS-11, OPS-12, QA-05
Needs user: Q5, budget approval (week 10).
Needs user: every step. The new Supabase project is on Pro, and PowerSync on Pro.
Do:
1. Write `docs/Production-Runbook.md` covering these, in order:
   - create the project in us-east-1;
   - apply `supabase/migrations` in order;
   - set the role passwords;
   - Auth settings (OPS-01), SMTP (OPS-02), templates (OPS-03), leaked-password protection (OPS-13), the Before-User-Created hook (DB-08);
   - enable pg_cron (DB-07);
   - **Pending account deletions.** `SELECT user_id, deleted_at FROM fieldmaps.profiles WHERE deleted_at IS NOT NULL`. Each row is an account whose Auth deletion must still be finished, with the Admin API or the dashboard (BE-08);
   - **Upload the Training site package** through BE-13, as a temporary Training manager (DB-07 step 6);
   - **Create the pilot project's QGIS reader login** with `grant-gis-reader.sql` (GIS-02);
   - the Render production service;
   - the PowerSync production instance;
   - Vercel production environment variables;
   - EAS `production` config.
2. The user executes it. Record each step as done, with the date.

Done when: the production health checks are green and QA-01/QA-02 pass against production with synthetic accounts, which are then deleted.

### OPS-10: Backups and restore drill
Status: todo · Phase 4 · Size M · Depends: OPS-09 · Blocks: QA-06
Needs user: restore into a scratch project.
Do:
1. Confirm that daily backups are active on Pro.
2. Write `docs/Restore-Runbook.md`.
   - Storage objects are not in database backups. Package archives can be recreated from the manager's QGIS source, so document re-upload as their recovery path until photos exist.
3. Run one restore drill and record the times: target recovery point 24 h (daily backup), target recovery time 4 h.

Done when: the drill is recorded with its measured times.

### OPS-11: Store listings and submission
Status: todo · Phase 4 · Size L · Depends: BE-08, MOB-07, MOB-20, OPS-09, WEB-14 · Blocks: QA-05
Needs user: Q1 (app name and bundle ID).
Needs user: the Apple Developer and Google Play accounts, the listings, and review submission.
Do:
1. Prepare `docs/Store-Submission.md`:
   - Privacy nutrition labels: email, user ID, precise location of observations, user content, all linked to the user.
   - Play Data safety.
   - The account deletion paths: in the app (MOB-07) and the web link `/privacy/delete-data` (WEB-14).
   - The test account for reviewers, including a join code.
   - Screenshots.
2. Submit a TestFlight internal build and a Play internal-testing build.

Done when: both internal tracks install on the pilot devices.

### OPS-12: Monitoring and alerts
Status: todo · Phase 4 · Size S · Depends: OPS-09 · Blocks: QA-06
Do:
1. Render health alerts.
2. An uptime monitor on `/ready`.
3. A weekly Supabase advisors run, with results noted.
4. PowerSync: replication lag and upload errors in its dashboard, and an alert when `pg_replication_slots` retained WAL exceeds 512 MB.
5. Sentry alert rules for new issues.
6. A daily check that alerts when a profile has had `deleted_at` set for more than 24 hours. That is a pending account deletion (BE-08).

Done when: `docs/Production-Runbook.md` lists each alert and who receives it.

### OPS-13: Auth hardening switches
Status: todo · Phase 1 · Size S · Depends: DB-08, OPS-14 · Blocks: none
Needs user: dashboard changes.
Do:
1. Enable the Before User Created hook, pointing at `fieldmaps_auth_hooks.before_user_created` (DB-08). This needs the function on staging (OPS-14). For production, OPS-09 repeats these switches.
2. Enable leaked-password protection on Pro.
3. Record that CAPTCHA is deferred (decision D9), and why.

Done when: `docs/Supabase-Setup.md` states each switch and its date.

### OPS-14: Apply the Phase 0–1 migrations to staging
Status: todo · Phase 1 · Size S · Depends: DB-04, DB-05, DB-06, DB-07, DB-08 · Blocks: OPS-13
Needs user: every step. Staging is the current project, `lezmqhuucfwqknspgcdy`.
Do:
1. `supabase link --project-ref lezmqhuucfwqknspgcdy`, then `supabase migration list`, then `supabase db push`.
   - Apply migrations in order through the CLI. Never paste single files into the SQL editor: a later file can reference objects an earlier one creates, and the editor records no CLI history.
   - `db push` applies **every** pending file. The list must show exactly the files this task names; if a later phase's file is present, stop and push from a checkout without it.
   - Enable pg_cron in the dashboard first (DB-07).
2. Run `database/hosted/verify.sql` with stop-on-error.
3. Record the applied versions (`TABLE fieldmaps_meta.schema_migrations`) and the verify output, with the date, in `docs/Supabase-Setup.md`.

Done when: staging's ledger lists every migration from DB-04 to DB-08, and `verify.sql` passes there.

### OPS-15: Apply the Phase 2 migrations to staging
Status: todo · Phase 2 · Size S · Depends: BE-13, DB-09, DB-10, DB-11, DB-12, DB-14 · Blocks: OPS-08
Needs user: every step, including Q7: DB-14 discards the pre-Storage test archives.
Do:
The order is expand, deploy, contract. Each step must finish before the next.
1. **Expand.** Push DB-09, DB-10 and DB-12, using the OPS-14 procedure.
   - `db push` applies every pending file, so push from a checkout whose newest migration is DB-12's (for example a `git worktree` at that commit).
   - The running API keeps working: DB-12 only adds columns and makes `archive` nullable.
2. **Deploy.** Deploy BE-13's API code to Render staging. It needs DB-12's `storage_path` and `archive_bytes`, which now exist.
3. **Contract.** From the current checkout, confirm DB-14's list of pre-Storage test packages, then push DB-14 and DB-11 (in file order).
   - `supabase migration list` must show only these two as pending.
   - DB-14 drops `archive`, which only the old API code wrote.
4. Set the `powersync_role` password out-of-band.
5. Check `SELECT tablename FROM pg_publication_tables WHERE pubname = 'powersync'` against DB-11.

Done when:
- staging's ledger lists these migrations;
- `verify.sql` passes;
- the publication matches DB-11;
- a package prepared on staging after this has a `storage_path`.

### OPS-16: Apply the Phase 3 migrations to staging
Status: todo · Phase 3 · Size S · Depends: GIS-01 · Blocks: GIS-02
Needs user: every step.
Do: the same procedure as OPS-14, for GIS-01.

Done when: staging's ledger lists GIS-01's migration, and `verify.sql` passes, including the GIS reader assertions.

### OPS-17: Apply the Phase 3–4 migrations to staging
Status: todo · Phase 4 · Size S · Depends: DB-13, GIS-03 · Blocks: OPS-09
Needs user: every step.
Do: the same procedure as OPS-14, for GIS-03 and DB-13.
- Before GIS-03, confirm that nothing still reads the sample view.

Done when: staging's ledger lists every migration in `supabase/migrations/`, and `verify.sql` passes. Production (OPS-09) is created only from a migration set proven here.
