# FieldMaps web

Next.js App Router management application for FieldMaps. Parent `AGENTS.md` contains product routing and operating rules; this folder's `README.md` describes the sections and the design rules.

- Run app commands from `web/`, or use the product-root `pnpm web:*` aliases.
- Dependencies and lockfile belong to this folder; do not hoist or merge with Expo dependencies.
- Source aliases map `@/*` to `web/src/*`. Checks: `pnpm check`, `pnpm build`. `pnpm format` applies only to this app.
- Deploy this folder as the web project root. Do not deploy or change hosted settings without authorization.

## Design

- This application and the collector share one design system, Nocturne. The tokens in `src/app/globals.css` are the values `mobile/src/theme.ts` uses. Change them together, and add a primitive to `src/components/nocturne/chrome.tsx` and `mobile/src/components/chrome.tsx` together.
- Take every colour, size, spacing and radius from the tokens. Do not hard-code a hex, a font name or a pixel value the tokens already carry.
- One theme, no theme switcher. State is a glyph plus a word plus a colour. The accent is a line, never a flood. Charts use the accent ramp alone.

## Honesty

- This application is not connected to the API. Everything it shows comes from fixtures in `src/data/`, and the screens say so — in the top bar, the status footer, and a note in each section that could be read as live state.
- Do not remove or soften those notices for a section that is still reading fixtures, and do not add a control that does not do what its label says. If a feature is not built, the screen states what is missing and why rather than pretending.
- Fixtures mirror `supabase/migrations/`. Do not introduce a domain concept the schema does not have.
- The observation fixtures preview the workspace _after_ `janet-test-v1` is published; the database itself holds two `shell-v1` records. Keep the two numbers distinguishable wherever both appear, and never let a fixture assert a state the real system could not be in without saying it is a preview.
