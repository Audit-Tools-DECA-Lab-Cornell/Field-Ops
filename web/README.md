# FieldMaps web

The management side of FieldMaps: projects, places, instruments, base map packages, the QGIS connection, and the observations the [native collector](../mobile/README.md) writes into the shared spatial database.

This application and the collector are one product, so they carry one design system — **Nocturne**, in the `nocturne` folder under [`designs/_ds`](../designs). Its values live in [`src/app/globals.css`](src/app/globals.css) and are the values [`mobile/src/theme.ts`](../mobile/src/theme.ts) already uses: the same ground, the same accent, the same type scale to the half pixel, the same 0.70× density scale. Change them together or the two applications drift.

## What is real

The collector's uploads are real: it signs in natively, saves offline, uploads on reconnect, and two test observations have been confirmed in hosted PostGIS and opened in QGIS Desktop. **Only one screen is connected to the API.** Base map upload posts a real package to `POST /v1/projects/{project}/packages` and renders the checks the server returns. Every other record, count, chart and connection value comes from fixtures under [`src/data/`](src/data), generated in the browser from a fixed seed.

That is stated on the screens themselves — in the top bar, along the status footer, and in a note on each section that could otherwise be mistaken for live state. Keep it that way. When a section is wired to the API, the note comes off that section and not before.

The fixture observations are a **preview**, and the distinction is load-bearing. The database today holds two `shell-v1` records: the three-field practice form, enough to prove the upload path and nothing else. A management console over two rows demonstrates nothing about managing a study, so the fixtures preview how this workspace will read once `janet-test-v1` is published and a few days of collection have landed. `janet-test-v1` is still a draft, its record count in the database is still zero, and the instrument screen shows both numbers side by side rather than letting one of them pass for the other.

The fixtures mirror the real schema rather than a convenient one: `supabase/migrations/` is the authority for what an organization, project, site, form version and observation are, and [`src/types/domain.ts`](src/types/domain.ts) does not invent a concept the schema does not have. The site geometry is the training site the collector already carries, copied coordinate for coordinate from `mobile/src/maps/sample-site.ts`, so a zone on this map is the polygon the observer tapped inside.

## Sections

| Route           | What it is                                                                                      |
| --------------- | ----------------------------------------------------------------------------------------------- |
| `/`             | The landing page — what the product is, and what is built, open and not built yet               |
| `/overview`     | Overview — what the field returned, coverage against the protocol target, and what is blocking  |
| `/observations` | Data review — one filter set, a coordinated map and table over it, and the record itself        |
| `/places`       | Sites and the zones inside them                                                                 |
| `/instrument`   | Variable library, display logic and form versions                                               |
| `/basemaps`     | Turning a QGIS project into a package: uploading layers, and the checks the server runs on them |
| `/qgis`         | The connection that reads the same database                                                     |

Filters and the selected record live in the URL, so a filtered view can be sent to a colleague, opened in a second tab, and undone with the back button.

## Design rules this application keeps

- **One theme.** The collector has one; a manager reading a field record should see the colours the observer saw.
- **State is a glyph plus a word plus a colour**, in that order, so the colour is never load-bearing. The vocabulary is in [`src/lib/states.ts`](src/lib/states.ts) and nothing invents a state beside it.
- **The accent is a line and a glow, never a flood.** Primary actions are an accent outline. Selection is a two-pixel accent bar plus a tint.
- **Rules fade to transparent at their ends** — the `.rule` class. Box outlines and in-control separators stay solid.
- **Charts use the accent ramp alone.** Nine play types are not nine hues: identity comes from the row label, magnitude from the bar. Sequential magnitude is one hue, dim to bright, and the number is always written in the cell as well.
- **Hierarchy is size and space.** Nothing is bolder than weight 500.
- **Nothing tappable goes below 44 px**, focus is the 2 px accent `:focus-visible` ring, and motion stops under `prefers-reduced-motion`.

The shared chrome is [`src/components/nocturne/chrome.tsx`](src/components/nocturne/chrome.tsx), deliberately parallel to `mobile/src/components/chrome.tsx`. When one side gains a primitive, give the other the same one.

## Public policy pages

`/privacy` and `/privacy/delete-data` are the privacy policy and data deletion pages for the native collector, for its Google Play listing. They live in `src/app/(legal)/`, carry their own stylesheet because they follow the visitor's light or dark system setting, and are prerendered as static pages. Every statement was checked against the mobile, backend and database code; update the pages before the app collects anything new.

Facts only the operator can supply live in `src/app/(legal)/policy.ts`: the operator (DECA Lab at Cornell University, led by Professor Janet Loebach), the privacy contact, and the developer. The server host, retention periods and deletion time are marked "Assumed" there and need confirming with the lab. Any field set back to `null` brings back a visible draft notice and an inline "to be confirmed" marker.

## Run locally

```bash
pnpm install
pnpm dev
```

Open [http://localhost:3000](http://localhost:3000). No API key, account or network is needed: the default map base is bundled vector geometry, and the street tile base is the only thing on any screen that fetches.

## Connect it to the API

One screen talks to the API: base map upload. It reads a single public variable.

```bash
cp .env.example .env.local   # then edit if your API is not on 127.0.0.1:8000
```

| Variable | Value |
| --- | --- |
| `NEXT_PUBLIC_FIELDMAPS_API_URL` | The API's origin, no trailing slash — `http://127.0.0.1:8000` locally, `https://api.example.org` deployed |

`NEXT_PUBLIC_` variables are compiled into the browser bundle, so this one is public by construction. Never put a token or key beside it. Next.js reads `.env.local` at build time, so restart `pnpm dev` after changing it; on Vercel, set it in **Project → Settings → Environment Variables** and redeploy, since a running deployment will not pick it up.

Leave it unset and the screen says so: it assembles the package and downloads the submission rather than pretending to upload it.

The API must also name this origin. Browsers preflight a cross-origin request that carries an `Authorization` header, and the API allows no origin by default, so add the web origin to `browser_origins` in `backend/config.local.json` — see [the API README](../backend/README.md). Miss that step and the upload fails in the browser's network layer before the API is reached. Vercel preview deployments get a new hostname per branch, so those are covered by `browser_origin_pattern` rather than listed.

Two things this cannot fix on its own. A page served over HTTPS may not call an API on `http://127.0.0.1`, so the deployed site needs a deployed API over HTTPS — pointing it at a laptop will not work. And uploading still needs a manager's token, below.

Uploading needs an access token for an account with the **manager** role on the project. There is no web sign-in yet, so the screen has a field to paste one; that is a stopgap and is marked as one.

Quality checks:

```bash
pnpm check   # typecheck and lint
pnpm build
```

## Technical shape

- Next.js 16 App Router, React 19, TypeScript
- Tailwind v4, with the Nocturne tokens registered in `@theme` so the utilities _are_ the design system
- Inter, self-hosted through `next/font`, so chrome never waits on a network
- React Leaflet, rendered browser-side only, over bundled GeoJSON or dark street tiles
- Client-side CSV, GeoJSON and codebook generation
- Progressive Web App manifest and a same-origin offline shell cache

## What this application deliberately does not do

- **Collect observations.** The collector does that, on a device, offline. A browser form beside it would be a second way to enter the same record and a second thing to keep in step.
- **Draw zones or create sites.** Zones come from the QGIS project a base map package is prepared from; the upload screen carries the exported `zones` layer to the server, which derives the boxes. A second authority beside QGIS would drift from it.
- **Edit or publish the instrument.** The API now accepts any seeded form version and validates answers against its stored definition, and `form_versions` rows are already immutable, so what publishing still needs is an editor here and a typed GIS view over the answers. Until those exist, this reads the instrument and shows what is blocking its first version.
- **Deliver a package to a device.** A prepared package is stored, versioned and downloadable from the API, but the collector still reads its bundled geometry. The hosted package provider on the device, with the download and cellular policy that belong to it, is the next piece.
- **Claim a sync path of its own.** QGIS reads the live database; exports are for analysis, backup and interoperability, and say so.
