# Ignyte 1-2-1

Private 1-2-1 lesson booking, coach notes and skill progress for cheer & dance clubs.
Six portals over one login, all free to run: Supabase (free tier), Cloudflare Workers
(free), GitHub Actions (free). No payment processor — clubs take cash or bank transfer
and tick lessons off as paid.

| Portal | Who | What they can do |
| --- | --- | --- |
| `/hq` | Ignyte owner (platform) | Create clubs, invite club owners, suspend/reactivate, see activity, open any club |
| `/club` | Club owner / admin | Today action list, weekly schedule, add slots for any coach, assign athletes, people (invite by email, roles, athlete records, link athlete logins), money (mark paid), settings (price, lesson length, cancel notice, join code) |
| `/coach` | Coach | Own lessons (wrap up: attended/no-show, worked-on skills, notes, homework), contact & medical for their athletes, availability (add/remove slots), assign an athlete to a slot, athlete progress |
| `/family` | Parent | Book lessons for children (or themselves — "I train too"), cancel, see coach notes/homework/progress, what's owed, edit athlete details |
| `/me` | Athlete with own login | Own lessons, book, set goals, skill journey |
| `/book` | Any family/athlete | Athlete → coach → day → time → booked |

A person can hold several roles in a club (parent + coach + admin…). The header shows a
chip for each portal they have.

## Stack

- Astro 7 static site + Tailwind 4, `supabase-js` from the browser.
- `supabase/schema.sql` is the whole database: tables, RLS, SECURITY DEFINER RPCs, seed.
  Running it wipes `public` and rebuilds it (logins survive). Idempotent.
- `.github/workflows/deploy.yml` builds and deploys to Cloudflare Workers on push.

## Local

```
npm ci
PUBLIC_SUPABASE_URL=… PUBLIC_SUPABASE_ANON_KEY=… npm run dev
```

## Onboarding a club

1. Ignyte HQ → "Bring a club on": name, short id, the owner's email.
2. The owner signs up (or in) with that email and lands in `/club`.
3. They add coaches by email under People, add slots under Schedule, and share the
   club code / sign-up link with families.
4. Families sign up with the code, add their athletes, and book.

Recommended Supabase auth settings for a free setup: turn **Confirm email off**
(Supabase's built-in mailer is rate-limited on the free tier) and set the Site URL to
the deployed host.
