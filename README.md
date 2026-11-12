# CoachMohsen

CoachMohsen: the padel coaching app for **Padel Pro**, self-hosted on Supabase + Cloudflare Pages
at https://coachmohsen.net (the Cloudflare address coachmohsen.pages.dev forwards there). It started as a copy of Padel 360 (November 2026) and is now
developed on its own; Padel 360 is not affected by changes here.

## How it is organised

**Club → Venue → Court.** There is one club, *Padel Pro*, with one venue, *Padel Pro - Andalus*, and
four courts (Court 1 to Court 4). Venues and their courts are edited in the **Venues** tab.

- Every session is booked on a court and needs a start time.
- A court holds one session at a time. The database enforces this for all coaches together,
  even though coaches cannot see each other's sessions. The booking form marks courts that are
  already taken at the chosen time (it shows the time only, not who booked).
- Fixed weekly slots also carry a court. When generating sessions, a slot whose court is taken is skipped.

Roles: **Sys admin** (users, theme, everything), **Club admin** (team, players, coach assignment, all
sessions except private remarks), **Coach** (own players and sessions), **Player** (one page with all
their sessions). Everyone can edit their own account (photo, names, phone, email).

## Layout

```
public/                  the website Cloudflare Pages serves (no build step)
  index.html             the app
  config.js              Supabase URL + publishable key (public by design)
  vendor/                supabase-js browser build
.github/workflows/       deploy.yml
supabase/migrations/     database changes, applied in order by the deploy workflow
supabase/seed/           demo accounts (run by the workflow when DEMO_PASSWORD is set)
tests/                   smoke test (in-memory backend) and database tests (tests/db/run.sh)
```

## Deploying (automatic)

Every push to `main` runs `.github/workflows/deploy.yml`, which:

1. applies any new file in `supabase/migrations/` to the database and sets the sys admin email,
2. publishes `public/` to Cloudflare Pages (project `coachmohsen`, created on the first run),
3. points Supabase sign-in links at the site address,
4. creates the demo accounts (`sysadmin|clubadmin|coach|player@coachmohsen.dev`) when `DEMO_PASSWORD` is set,
5. writes a short result to the `ci-status` branch (`STATUS.md`).

It needs these repository secrets (Settings → Secrets and variables → Actions):

| Secret | Where to get it |
| --- | --- |
| `SUPABASE_DB_URL` | Supabase → **Connect** → *Session pooler* string, with the database password filled in |
| `SUPABASE_ACCESS_TOKEN` | Supabase → account menu → **Access Tokens** → Generate |
| `SYSADMIN_EMAIL` | your own sign-in email; that account becomes **Sys admin** |
| `CLOUDFLARE_API_TOKEN` | Cloudflare → My Profile → **API Tokens** → Create Custom Token: *Account · Cloudflare Pages · Edit* |
| `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET` | optional · Google Cloud → OAuth client (Web application) → turns on *Continue with Google* |
| `APPLE_SERVICES_ID`, `APPLE_SECRET` | optional · Apple Developer → Services ID + generated secret (renew every 6 months) → turns on *Continue with Apple* |
| `CLOUDFLARE_ACCOUNT_ID` | Cloudflare → Workers & Pages overview, right-hand panel |

`public/config.js` holds the Supabase Project URL and anon key (public by design).

## Tests

`npm i -g playwright && node tests/smoke.js` — serves `public/` with an in-memory backend
and checks sign-in, coach calendar, trainee page, coach log, player view and Player ID.
