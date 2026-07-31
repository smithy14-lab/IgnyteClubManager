# Ignyte Club Manager

Private 1-2-1 lesson booking and skill progression for cheerleading tumble and
all-star dance — an installable, offline-capable web app in the Ignyte Cheer &
Dance brand.

**Everything runs on free tiers:** Astro static site (host anywhere free) +
Supabase (database, logins) + optional Resend (email notifications).

## What it does

| Who | What they can do |
| --- | --- |
| **Parents** | Add their athletes (under-18s never get their own login), search slots by coach/date/time, book 30-min 1-2-1s (one-off or weekly until cancelled), cancel, join waiting lists, view progression |
| **Adult athletes (18+)** | Own account; book and manage their own lessons and view their progression |
| **Coaches** | Add themselves to slots, see their lessons, take the register (present/absent), update skill statuses and leave lesson notes |
| **Club admins** | Create slots (e.g. 12:00–12:30 with 4 spaces, repeating weekly), extend/remove them, manage people's roles, set the cancellation policy |

Booking rules baked into the database:

- A slot has N spaces (simultaneous lessons) and only coaches who joined it are bookable — strictly one athlete per coach per slot.
- Weekly bookings repeat every week until cancelled; when an admin extends the series, weekly bookings roll forward automatically.
- Anyone can cancel any time. Inside the club's notice window (default 24 h, changeable in Admin → Settings) it's recorded as a **late cancellation (still payable)**.
- Freed spaces are automatically **offered to the waiting list** (oldest first, coach preferences respected) with an in-app notification + email; offers expire after 24 h and roll to the next family.

## Setup (once, ~15 minutes)

### 1. Supabase (free)

1. Create a project at [supabase.com](https://supabase.com).
2. Open **SQL Editor**, paste the whole of [`supabase/schema.sql`](supabase/schema.sql), and run it.
3. In **Authentication → Providers**, keep Email enabled. (Optionally turn off "Confirm email" while testing.)
4. Copy your **Project URL** and **anon public key** from Project Settings → API.

### 2. Run / build the app

```bash
cp .env.example .env    # paste your Supabase URL + anon key
npm install
npm run dev             # local development
npm run build           # production build to dist/
```

Deploy `dist/` to any free static host (Netlify, Cloudflare Pages, Vercel,
Azure Static Web Apps…). Set the two `PUBLIC_SUPABASE_*` environment variables
in the host's build settings.

### 3. Make yourself admin

Sign up in the app, then run in the Supabase SQL editor:

```sql
update public.profiles set role = 'admin' where email = 'you@example.com';
```

From then on you can promote coaches/admins from **Admin → People** in the app.

### 4. Email notifications (optional, free)

In-app notifications work out of the box. For email too:

1. Create a free [Resend](https://resend.com) account and API key (100 emails/day free).
2. Install the [Supabase CLI](https://supabase.com/docs/guides/cli), then:
   ```bash
   supabase link --project-ref YOUR_PROJECT_REF
   supabase secrets set RESEND_API_KEY=re_xxx APP_URL=https://your-app-url
   supabase functions deploy send-notification-email --no-verify-jwt
   ```
3. In the dashboard: **Database → Webhooks → Create** — table `notifications`,
   event `INSERT`, type *Supabase Edge Function*, function
   `send-notification-email`.

### Install on a phone

Visit the site in a browser: Android/Chrome shows an **Install** prompt; on
iPhone use **Share → Add to Home Screen**. The app then opens full-screen and
previously-viewed pages/data stay readable offline (booking needs a
connection).

## Project layout

```
src/pages/            app pages (all static; auth + data handled in-browser)
src/layouts/          shared shell: header, nav, notifications, install prompt
src/lib/              Supabase client + shared helpers
public/sw.js          service worker (offline caching)
supabase/schema.sql   entire database: tables, security policies, booking logic, skill library
supabase/functions/   email notification edge function
```

The skill library (tumble levels 1–6 and all-star dance) is seeded by the
schema and editable in the `skills` table.
