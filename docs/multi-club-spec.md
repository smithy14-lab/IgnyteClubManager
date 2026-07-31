# Ignyte Club Manager — Multi-Club Release
## Research & specification, for your review

**Status: DRAFT for review — nothing in this document is built yet.** Read it with a pen. Every section ends in checklists you can tick or strike through; Section E.4 has the five decisions only you can make. When you've marked it up, we'll agree the changes and cut the next release plan from it.

**How this was produced:** seven analysis agents inventoried every page, table and database function in the current app and wrote per-area specifications; two research agents studied ~16 competing platforms and mined real user reviews and forums; an adversarial critic then hunted the specs for contradictions and security holes. This document is the merged result.

---

## 1. Executive summary

- **The market gap is real and it's yours.** Nothing under ~£35/month combines parent self-booking of privates + recurring weekly series + makeup credits + family/safeguarding data + skill progression. The vertical suites that have those features (iClassPro, Jackrabbit) start at $129–199/month and gate private-lesson booking behind their top tiers; the cheap generic schedulers (Calendly, Acuity, Square) have no family accounts, no makeups, no progression. Privates are an afterthought everywhere — coaches still run them by text and envelope cash.
- **What wins hearts:** automation of drudgery (autopay, self-serve makeups, reminders), fast human support, and 1-hour setup. **What earns 1-star fury:** trapped money (can't cancel recurring payments), login friction, buried availability, per-student pricing games. The multi-club design below is shaped around both lists.
- **The conversion is one shared platform, many walled clubs.** Every club-owned row gets stamped with its club; a membership table records "parent at Club A, coach at Club B" on one login; the database itself (not just the app) enforces that no club can ever see another's data. Your existing club migrates first, behind a rehearsed, reversible plan.
- **The critic found three critical issues to resolve before building** — how a child attending two clubs is modelled (a safeguarding question), the missing "pending approval" join state, and how your owner access is audited. They're in Section E with recommendations.

---

## 2. Market research — the landscape

*(Full product-by-product table in the appendix of the research; highlights below.)*

| Product | Privates booking | Skill tracking | Makeups | Family accounts | Typical cost |
|---|---|---|---|---|---|
| iClassPro | Yes — but Elite tier only | Deepest (Skill Bank) | Class makeups | Yes | $129–299/mo |
| Jackrabbit Class | Yes (Appointments) | Yes | Portal makeups | Yes | $49–245/mo |
| TeamUp | Yes (availability) | No | No | Weak | ~$99+/mo |
| ClassForKids | No real privates engine | No | No | Yes | £34.99+/mo + txn fee |
| Coacha | Yes (1-2-1 module) | No | No | Yes | £21.29/mo flat |
| Bookwhen | Slot-based | No | No | Ticket types | Free–£50/mo |
| TutorBird | Yes (availability) | Notes only | **Best-in-class credits** | Yes | ~$15/mo |
| Acuity / Calendly / Square | Availability engines | No | No | **No** | $0–61/mo |

**What's table stakes in 2026:** online self-booking, reminders, card payments, cancellation windows, class waitlists, credit packs.
**What's rare (your differentiators):** parent-bookable recurring series; skill progression *visible to parents* (only the $129+/mo suites have it, and reviewers ask for more depth); a real makeup-credit engine; semi-private support; appointment waitlists.
**How coaches run privates without software:** paper slips to the front desk, cash in envelopes, Venmo/text the coach, waiting lists "in the coach's head", invoices made in Word and chased on WhatsApp. Upfront payment reportedly cuts no-shows by up to 80% — money chasing is the #1 manual pain.
**Pricing sensitivity:** solo coach ceiling ≈ £15–25/mo; small club ≈ £20–50/mo flat with unlimited students strongly preferred. Per-student pricing is a documented churn driver ("owners delete students to keep the price down" — Jackrabbit reviews). Seasonal clubs hate paying through dead months.

## 3. Market research — what users love & hate

**Parents' top complaints (from reviews):** time-wasting booking mazes (TeamUp: "massively time-wasting and excruciating"); *trapped money* — can't cancel recurring payments or remove a card without begging the club (ClassForKids' single biggest Trustpilot grievance, including a parent triple-charged £40 in a month); login friction so bad people delete the app (iClassPro's password field bugs); 6am-refresh culture because availability and waitlists are invisible; painful multi-child enrolment.

**Coaches' top complaints:** "I just want to see my schedule for the day" (verbatim, iClassPro staff app); apps that open on the wrong screen; binary skill tracking with no gradients; private-lesson scheduling dumped on their personal phones.

**Owners' top complaints:** buggy regressions, useless reports, emails that need HTML skills, support that decays after the first year, per-student pricing games, painful setup, expensive exits.

**What earns raves:** "Things that used to take hours — chasing payments, managing class lists, updating parents — are now largely automated" (ClassForKids 5-star); "Automatic invoicing and AUTO PAY!!! THE BIGGEST TIME SAVER!" (My Music Staff); self-serve makeups called "a game changer" (iClassPro swim school); support that answers within the hour (Bookwhen); "learned the basics in about 1 hour... wish I'd set it up sooner."

**The ten must-not-get-wrong items** (each traced to 1-star evidence): few-tap booking with no dead ends · parent self-serve cancel/pause of payments · billing correctness with instant failure alerts · one family account for all siblings · logins that just work · live availability + fair waitlists · coach app opens on "my day" · self-serve reversible makeups · stable releases · honest flat pricing with easy exit.

**The ten delight opportunities:** kill the private-lesson text tango (already your core!) · autopay that chases slow payers · sub-hour human support · measurable admin-time payback · 1-hour setup to first booking · cross-program makeup tokens · gradient skill tracking with parent-visible milestones (already yours) · mail-merge comms without HTML · coach pay transparency (already yours) · calendar sync + a genuinely good mobile app (already yours).

---

*Sections A–E below are the engineering specification, written in plain English where possible. A = how the data is walled per club; B = every way someone enters the system; C = every page, one by one; D = your Owner HQ; E = the disagreements, gaps and the five decisions for you.*

---
## A. Architecture in plain English

A few terms used throughout: a **tenant** is one club's private slice of the shared system. **RLS (Row-Level Security)** is the database's built-in bouncer — rules attached to each table that decide, per row, who may see or change it, enforced even if the app code has a bug. An **RPC** is a named database function the app calls to do one job (e.g. "book this slot") with its permission checks inside. A **slug** is the short web-address name for a club (e.g. `/c/leeds-tumble`).

### A.1 The chosen tenant model

All specs agree on the same core model — there is no disagreement here:

- **One shared database, one shared app** for all clubs (not a separate copy per club). Every club-owned row is stamped with a `club_id` pointing at the existing `clubs` table, which becomes the **tenant root**: it gains a unique `slug` (portal link), a unique `join_code` (poster/verbal code), `created_at`, and later branding and billing columns. Clubs are **never hard-deleted** — `status='churned'` archives them, and every `club_id` link is set to "restrict delete" so a mistaken deletion cannot cascade a club's data away.
- **One login per human, membership per club** — a new `club_members` join table `(club_id, profile_id, role, status, joined_at)` records "this person is a *parent* at Club A and a *coach* at Club B." This is the model the market research found in every modern competitor (TeamUp, ClassForKids, Sawyer, Coacha) and the thing users complain about missing in the legacy silo products (iClassPro, Jackrabbit).
- The old global `profiles.role` column is **demoted**: its only remaining meaningful value is `'owner'` (you, the platform operator). Crucially, the per-club role list (`parent`, `athlete`, `coach`, `admin`) **does not contain `owner`**, so no club admin can ever mint an owner through any membership screen — a structural safety guarantee, not just a UI one.
- Role changes on `profiles` require `is_owner()` full stop (`guard_role_change` trigger tightened); club admins change membership roles only.

### A.2 How security scoping works

Every rule that decides "can this person see this row" now asks two questions instead of one: *is this row in a club you belong to?* and *what is your role in that club?* A single audited helper function, `my_club_ids()`, returns the caller's club list and is used in every policy as `club_id in (select my_club_ids())`; two companions, `is_admin_of(club)` and `is_coach_of(club)`, replace the old global `is_admin()`/`is_coach()`. The platform-owner bypass lives **only inside those three helpers** (they return "yes" for the owner), never sprinkled through individual policies, so there is exactly one place to audit or later gate it. This design also fixes today's confirmed cross-club leaks: the slot board, coach rates, locations, settings and skills tables are currently readable platform-wide (`using(true)` policies), and `get_slot_board` returns every slot and every coach's rates to anyone.

| Table | Scoping method |
|---|---|
| `clubs` | Tenant root (owner-managed; members may read name/branding) |
| `club_members` | Direct `club_id` (part of the primary key) |
| `profiles` | No `club_id` — one login spans clubs; scope lives in `club_members` |
| `athletes` | Direct `club_id`, required (a child at two clubs = two rows — **contested, see E.1**) |
| `club_settings` | Direct `club_id`, becomes the primary key (the `id=1` singleton is abolished) |
| `locations` | Direct `club_id`, required (currently ownerless) |
| `coach_profiles` | Direct `club_id`; key becomes (club, coach) — a coach at two clubs has two rate/bio rows |
| `slots` | Direct `club_id`, required (root of the booking chain); composite FK stops a slot pointing at another club's location |
| `slot_coaches` | Inherits via `slots` |
| `booking_series` | Direct `club_id`, required (its series id has no parent table to inherit from) |
| `bookings` | Direct `club_id`, auto-stamped from the slot by a trigger (hottest table — flat indexed check beats per-row joins) |
| `waitlist` | Direct `club_id`, auto-stamped from the slot (same reasoning) |
| `notifications` | Direct `club_id`, optional (per-person already; club id enables branded emails; null = platform notice) |
| `skills` | Direct `club_id`, optional (null = platform template library) |
| `athlete_skills` | Inherits via `athletes`; write RPC asserts skill's club = athlete's club |
| `progress_notes` | Inherits via `athletes` |
| `credit_ledger` | Direct `club_id`, required — credits are club currency; one login, two clubs = two balances |
| `broadcasts` | Direct `club_id`, required — "everyone" must mean the club, not the platform |
| `skill_media` | Inherits via `athletes`; the storage file path gains a club prefix |
| `club_leads` | Platform-level, no `club_id`; **RLS fixed from `is_admin()` to `is_owner()`** (today every club admin can read your sales leads) |

Supporting details: every `club_id` column referenced by RLS gets an index (slots, bookings, waitlist, athletes, credit ledger, locations, series, broadcasts, skills); bookings/waitlist get a `stamp_club_from_slot` trigger; the hardcoded `tumble/dance` discipline list becomes a per-club configurable list validated at booking time. Roughly 30 database functions change: every admin/coach gate becomes club-scoped, `get_slot_board` gains a **mandatory club argument** (closing the biggest single leak), booking/cancel/waitlist functions assert athlete + slot + coach + credits all share one club, broadcasts and credit adjustments only touch the admin's own club's members, and `slot_starts_at` reads the slot's club's timezone instead of "the" timezone. Any new function must be added to the schema's explicit execute-grant list (the codebase locks function execution down by default).

### A.3 Skill library: per-club copies

**Decision: per-club copies cloned from a platform template.** Skills rows with `club_id = null` are your owner-editable seed library; provisioning a club copies them into that club's own rows. Rejected alternative: a shared library with per-club overrides — it needs a resolution layer inside every read path and doubles the RLS complexity. This also fixes today's bug where the admin skills tab edits the global library for everyone. Accepted cost: improvements to your template don't auto-flow to existing clubs (an owner "re-sync" tool can come later). A template skill can never be attached to an athlete.

### A.4 Storage, cron jobs, notifications

- **Storage (`skill-media` bucket):** today any logged-in user can fetch any child's video platform-wide. New file path: `{club_id}/{athlete_id}/{uuid}-{filename}`; new policies read the club prefix — parents see their own children's media, coaches/admins only their club's; upload requires being a coach of that club; the `add_skill_media` RPC double-checks the path's club matches the athlete's club (defence in depth).
- **Cron (scheduled jobs):** keep the two existing hourly/daily jobs (register reminders, rebook nudges) but make the **functions loop over clubs internally**, each iteration using that club's timezone, skipping suspended/churned clubs, and wrapped so one club's failure never starves the rest. Rejected: one cron job per club (drifts out of sync with the clubs table).
- **Notifications & email:** the in-app bell stays per-person (already safe), but every producer must only target same-club people, and rows carry `club_id` so the email edge function can send "{Club name} via Ignyte" with the club's logo/colour and correct deep link — replacing today's hardcoded "Ignyte Club Manager" branding, single from-address and single app URL. The Resend free tier (100 emails/day) will not survive multi-club (see E.2).

### A.5 Migration plan for the existing live club (ordered)

Rehearse on a database branch first; steps 1–3 are additive and safe under live traffic; step 4 is the atomic cutover and needs a short maintenance window coordinated with the app deploy (function signatures change).

1. **Backup.** Point-in-time-recovery checkpoint + full dump. Freeze other schema changes.
2. **Additive migration.** Create the `club_role` type, `club_members` table + policies, the new `clubs` columns (slug, join_code, created_at), every `club_id` column as *nullable*, the stamp triggers, the three helper functions + `join_club`, and all indexes. Nothing existing is touched — the live app is unaffected.
3. **Create the tenant row.** Insert/update the clubs row for the existing club: `status='active'`, real slug (e.g. `ignyte`), generated join code.
4. **Backfill (one transaction).** Stamp every existing row in every scoped table with the club's id; copy the club's skills once more with `club_id=null` to become the platform template; create a `club_members` row for every existing user carrying over their current role (the owner gets no membership — owner access is the bypass).
5. **Cutover (one transaction + coordinated deploy).** Make the `club_id` columns required (except notifications/skills), swap primary keys (`club_settings`, `coach_profiles`), drop the discipline check constraints, drop **all** old policies and create the new club-scoped ones (including storage, profiles, and the club_leads owner-only fix), replace every function with its club-aware version, re-run the execute-lockdown grant block, and deploy the frontend build that passes the club id everywhere — in the same window.
6. **Storage migration.** Script copies every media object from `{athlete}/{file}` to `{club}/{athlete}/{file}`, updates the database path, verifies, then deletes the old object; a temporary legacy-path read policy covers the transition.
7. **Cleanup.** Drop the legacy storage policy and dead shims; confirm both cron jobs ran their new bodies.
8. **Gate.** Run the full isolation test suite (18-row attack matrix plus positive assertions — two seeded clubs, cross-club booking/credit/broadcast/storage/role-escalation attacks must all fail; multi-club parent/coach and owner behaviours must all pass; query plans must show the club indexes in use) **green before the first real second club is provisioned**, and re-run it in CI after every future migration.

---

## B. Logins & entry flows

Shared conventions for all flows: app routes stay as-is (`/dashboard`, `/book`, …) — they are not club-prefixed; instead every signed-in page resolves an **active club** (stored choice → server-remembered `profiles.last_club_id` → sole membership → Club Picker screen) and passes it to every query. A public **security invariant**: the portal link and join code can only ever produce `parent`/`athlete` memberships — `coach` and `admin` are granted exclusively via an admin-created invite (`club_invites` table: token id, club, role, optional locked email, 7-day expiry, use limits, revocable) or by you. New RPCs this section introduces (`get_club_public` for anonymous portal reads, `provision_club`, `join_club`, `create_club_invite`/`revoke_club_invite`, `rotate_join_code`, extended `owner_create_account`) must all be added to the function grant list.

### B.1 Club self-serve trial signup wizard

Entry: "Start free trial" on `/` and `/pricing` → `/signup?type=club`. The wizard asks, in order:

| Screen | Collects |
|---|---|
| Your account | Admin full name, email, password, phone (no role, no club yet) |
| Verify email | Interstitial; platform-branded confirmation; wizard resumes on return (state cached locally) |
| Your club | Club name; slug (auto-suggested, live uniqueness check, editable); country/timezone |
| What you teach | Discipline list (seeded with tumble/dance, free-text additions); skill-library choice (copy platform seed / start empty) |
| Locations | 1..n names + addresses ("add later" allowed — a "Main venue" placeholder is created so slot creation never borrows another club's location) |
| Done / share | Portal link `/c/{slug}`, join code, invite-a-coach and invite-parents shortcuts, trial end date |

Nothing is written until the final submit, which calls **one atomic `provision_club` transaction**: clubs row (`status='trial'`, 30-day `trial_ends_at`, generated join code) → per-club settings row → founder's admin membership → locations → optional skills copy → set their default club → convert any matching sales lead → notify you of the new trial. Atomicity matters: a half-provisioned club (clubs row without settings) breaks every timezone/settings read.

Edge cases: slug taken between check and submit → clean error, back to the club screen (the database unique constraint is the authority). Wizard abandoned after email verify → orphan account with zero memberships; next login lands on the Club Picker's empty state which resumes the wizard. An already-logged-in user (e.g. a parent elsewhere) hits the CTA → skips account creation, becomes admin of the new club while keeping their other membership. Email already registered → "log in instead" path continuing into the wizard. Trial expiry writes nothing — `trial_ends_at < now()` is treated exactly like suspension (B.8).

### B.2 Owner-created club

From `/owner`: an "Add club" form with the same fields as the wizard plus initial status and contact fields; calls the `provision_club` variant that (for you) accepts a status and does **not** make you a member — owner access is the platform bypass, never a membership. Then you create the first admin either via the extended `owner_create_account(email, name, phone, password, club_id, role)` — which now also inserts the admin membership, replacing today's unscoped promotion — or (preferred, no password handling by you) via an emailed admin invite the person self-registers through.

Edge cases: the admin's email already has a platform account (she's a parent elsewhere) → the function must detect this and add only the membership, not fail ("existing account linked as admin"). Converting a lead marks it `converted` and links the club. Additional admins later: same mechanism, no limit.

### B.3 Parent joining a club

Three ranked paths (research: the club-distributed link is the dominant industry pattern; no marketplace/search at launch):

| Priority | Path | Mechanism |
|---|---|---|
| Primary | Portal link `/c/{slug}` | Shared on website/WhatsApp/socials; club-branded signup embedded on the portal page |
| Fallback 1 | Join code | 6-character code on generic `/signup` or the logged-in "Join a club" screen; for posters and word of mouth |
| Fallback 2 | Invite email | Admin enters parent emails → tokenized links `/join/{invite_id}`; the path for onboarding an existing member list |

Primary path, new user: branded landing → signup form (name, email, password, phone, "I am a: parent / adult athlete") → signup metadata carries the club slug and role → the account-creation trigger creates the profile, validates the club is live, inserts the parent membership and sets it as their default club. **Soft-fail rule:** a bad slug/code/token or a suspended club never aborts the signup — the account is created without a membership and the person lands on a "Join a club" recovery screen. Email confirmation returns them to a club-branded welcome, then `/athletes` prompts them to add children (athlete records now stamped with the club).

Edge cases: email already registered → log in on the portal instead; **for signed-in users the portal's Join button still requires the code** — "slug identifies, code authorizes," so slugs can't be enumerated to walk into clubs (the critic notes this rule conflicts with the portal page spec — see E.1). Second club → just a second membership row. Duplicate join → idempotent "already a member." Code rotated by the admin → old code dies instantly (UI warns about printed posters). Invite expired/revoked/used-up → friendly expired screen, no writes. A child attending two clubs is two athlete records by design in this spec (contested — E.1).

### B.4 Coach invite

1. Admin → Staff tab → "Invite coach": email (recommended), role locked to `coach` (admin-role invites exist behind an extra confirm). Creates a single-use, 7-day invite.
2. Club-branded invite email with `/join/{invite_id}` link (or copy-link for WhatsApp).
3. Signed-out recipient: branded accept screen → signup → profile + coach membership created. Signed-in: accept → membership added to the existing login.
4. The coach-membership insert auto-creates their per-club `coach_profiles` row (rates/bio), and they land on `/coach` to complete it.

Edge cases: invite sent to someone who's already a **parent at the same club** → one membership row exists, so accepting upgrades parent→coach with an explicit confirm; family features survive because "owns this athlete" checks are role-agnostic — a coach-parent still manages their own kids. Token forwarded to the wrong person → single-use + expiry bounds it; if an email was locked in, accept from any other confirmed email is rejected. Invites at a suspended club → creation fails (write freeze). Coach removed later → membership set to `removed` (soft), and their future slot assignments in that club must be cleaned up (flagged as under-specced — E.2).

### B.5 Adult athlete

Same paths as the parent flow with the athlete role, plus: the signup branch requires a date of birth, and the server keeps its 18+ check — an under-18 claiming "athlete" soft-fails ("ask a parent/guardian to create the account"), never creating a membership. The self-owned athlete record is created **at membership time, not signup time** (because athlete records are per-club), so joining a second club later creates a second record. An adult athlete who later adds children can keep the athlete role and still own child records; the admin can flip their role if they want the parent interface.

### B.6 One person in multiple clubs (switcher + role-per-club)

One login, N memberships, one role per (club, person) pair. On every page load, `requireAuth` loads all memberships in one query and resolves the active club: device-stored choice → server-remembered last club → sole membership → **Club Picker screen** (a card per club with logo, name, your-role badge, plus "Join a club" and "Start a club" actions). The role for the page is the **active membership's role** — a parent-at-A/coach-at-B sees the parent app under A and, after switching, the coach app under B, same session, no re-login. Server-side, every club-scoped function re-derives the role from the membership table against the club being acted on, so a confused client can never act cross-club.

The switcher itself: the drawer header (today hardcoded "Your club") becomes the active club's name + logo; tapping lists memberships with role badges plus "Join a club"; shown only with 2+ memberships. Switching writes the server-remembered default, updates local storage, **purges the service-worker data cache** (a flagged stale-data leak), and reloads to `/dashboard`. Notifications are cross-club by design (one bell) with a club chip per item; tapping one for a non-active club switches first. Deep links from emails carry the club and are honoured if a membership matches.

Edge cases: membership removed while active → falls through to the Picker on next load. Owner with personal memberships behaves like a normal member in the app; the owner console stays club-agnostic. Shared devices: the stored club choice is validated against the signed-in user's memberships, discarding another user's stale value.

### B.7 Password reset & email branding

**Decision: auth-lifecycle emails (confirm signup, password reset) are platform-branded; notification emails are club-branded.** Rationale: the account spans clubs — a club-branded reset email to a two-club user is wrong at best and phishing-shaped at worst; and it's the zero-extra-infrastructure answer. Club context still travels where it helps: confirm emails redirect to a club-branded welcome page; a reset started from a club's portal returns the user to that portal afterwards; notification emails read the notification's club to render "{Club} via Ignyte", logo, colour and correct link, falling back to platform branding for platform notices. Per-club-branded *auth* emails are explicitly a future premium-tier item.

Edge cases: reset for an account with zero memberships works and lands on the Club Picker empty state. Confirm link clicked after its originating invite expired → account confirms fine (the membership was created at signup; expiry only matters pre-signup). Email change → platform-branded confirms to both addresses; memberships follow the profile automatically.

### B.8 Suspended club behaviour

**Decision: suspended = read-only; sessions survive.** Nobody is signed out (they may belong to healthy clubs); enforcement is per-club at the data layer:

| Surface | While suspended |
|---|---|
| Club-scoped reads (bookings, progress, ledger…) | Still allowed — parents keep history, coaches see past registers |
| Every mutating function for that club (book, cancel, register, admin actions, invites, joins) | Raises `club_suspended` via a shared `assert_club_active` check at the top of each function |
| Signup via that club's slug/code/token | Soft-fails membership creation; portal shows "not accepting signups" |
| Cron loops | Skip clubs not in trial/active — no reminders, nudges, or waitlist offers generated |
| Emails | Suppressed upstream (no new notification rows are created for the club) |
| Member UX | Persistent "{Club} is currently unavailable" banner; booking/cancel buttons disabled; club greyed in the switcher; users with other memberships auto-resolve to a healthy club |
| Admin UX | Same read-only view plus a "contact Ignyte to reactivate" notice; admin retains read access for data-export comfort |
| Offline/PWA | Previously cached data remains viewable until next online load (accepted) |

Suspend = one status update + notify that club's admins; reactivate = one status update, all gates clear instantly, nothing to rebuild. Churn (after a grace period) closes read access too, pending a data-retention policy. Trial expiry reuses the exact same gate — no separate enforcement path. Edge cases: an in-flight booking at the suspension instant gets a clean error inside the transaction, no partial writes; pending waitlist offers freeze (can't be accepted) and expire normally on reactivation; a user whose *only* club is suspended still logs in, into the read-only banner state; the owner is never blocked (support/export on the club's behalf). *(Note: whether families may still cancel, and whether staff see data at all, is contested between specs — see E.1.)*

Cross-flow invariants (acceptance checklist): no path from public artifacts to a coach/admin membership; signup never aborts on bad club context; membership rows are only ever created by the four named functions; all new RPCs are in the grant list; club switch and sign-out both purge the data cache; auth emails platform-branded, notification emails club-branded; suspension blocks every mutation with no session revocation; trial expiry reuses the suspension gate.

---

## C. Page-by-page requirements

Conventions applying to every page: the active club `{id, slug, name, logo, accent colour, status}` and the user's role-in-club come from `requireAuth`; every query adds a club filter and every RPC carries the club id (client filters are UX — RLS is the enforcement); the app injects the club's accent colour and logo and uses the club's name wherever "Ignyte" appears in family-visible copy. Three global states every signed-in page can render: **NO_CLUB** (zero memberships → full-page join screen with code input, no nav but sign-out), **CLUB_SUSPENDED** (persistent banner, reads work, all writes disabled, offer to switch if another live membership exists), **STALE_CONTEXT** (stored club no longer valid → silent fallback + one toast).

### C.1 Marketing home `/`

**Changes for multi-club:** repositioned as the SaaS front door: "Start free trial" CTA wired to the club-signup wizard (B.1). Copy shifts from one club's site to the platform's pitch.
**Unchanged:** public, static, no database reads.
**New states:** none.
- [ ] "Start free trial" lands on `/signup?type=club` and completes into a working trial club.
- [ ] No club-specific data or branding renders on the platform home.

### C.2 About `/about`

**Changes for multi-club:** copy rewrite from single-club story to platform story (the existing club's own marketing presence vs the platform's is an open item — E.2).
**Unchanged:** public, static, no database reads.
**New states:** none.
- [ ] Page contains no single-club-only claims presented as the platform.

### C.3 Pricing `/pricing`

**Changes for multi-club:** carries the trial CTA into the wizard; must eventually present the plan ladder (`standard`/`plus`/`comped` exist as fields — prices and page copy are an open gap, E.2). Research recommendation: tier by active-member count with all features included; "your club branding" promise maps to the Branding tab.
**Unchanged:** public, static.
**New states:** none.
- [ ] Trial CTA functions identically to the home-page CTA.
- [ ] Plan names shown match the plan enum used in Owner HQ.

### C.4 Contact `/contact`

**Changes for multi-club:** still writes `club_leads` (your sales pipeline). **Security fix ships with this work:** leads become readable by the owner only — today every club admin on the platform can read them.
**Unchanged:** anonymous insert form, fields.
**New states:** none.
- [ ] A club admin's session gets zero rows from `club_leads`.
- [ ] A submitted lead appears in Owner HQ and can be converted into a provisioned club with the link recorded.

### C.5 Public club portal `/c/{slug}` (new page)

**Changes for multi-club:** entirely new; one dynamic client-rendered route in the static PWA. Data comes only through a new anonymous-callable RPC returning a limited projection — the clubs table itself stays locked. Content for a not-yet-registered parent: club name, logo, accent colour, short blurb, location names/areas (full addresses optional per club), coach roster (name/photo/disciplines/bio — **only opted-in fields, never rates**), primary CTA "Join {club}" feeding the club slug into signup, secondary "Already have an account? Sign in to join," optional "typical schedule" text; no live availability at launch. *(The two specs define different RPC names/projections and disagree on whether a signed-in visitor can join from the slug alone — E.1.)*
**Unchanged:** n/a (new).
**New states:** unknown slug → "Club not found" + platform link; suspended/churned → "{club} isn't taking new members right now" (no roster, no CTA); signed-in member → CTA becomes "Open {club}".
- [ ] Anonymous fetch returns only the whitelisted projection; no rates, emails, settings, or member data reachable via the RPC.
- [ ] Signup via portal link lands the new account as a member of that club with role parent (or athlete 18+), never in an unscoped pool.
- [ ] Existing signed-in user completing "join" gains a second membership and the switcher appears.
- [ ] Churned club slug shows the closed state; direct RPC call returns empty.
- [ ] Page works offline-degraded (shell cached, data fetch fails gracefully) and carries the club's branding, not the platform default.

### C.6 Login `/login`

**Changes for multi-club:** login itself stays platform-branded (the account spans clubs); after login, active-club resolution (B.6) decides where the user lands — including the Club Picker for multi-club users and the join screen for zero-membership users. Password reset started from a club portal returns to that portal afterwards; the reset email is always platform-branded.
**Unchanged:** email+password sign-in, reset-request mechanics.
**New states:** post-login Club Picker; post-login NO_CLUB join screen.
- [ ] Two-club user logging in with no stored choice sees the Club Picker, not an arbitrary club.
- [ ] Zero-membership login lands on the join screen, never an empty dashboard.
- [ ] Reset email is platform-branded regardless of entry point; portal-initiated resets return the user to that portal.

### C.7 Signup `/signup`

**Changes for multi-club:** three modes on one page: (a) club-founder wizard via `?type=club` (B.1); (b) parent/adult-athlete signup arriving from a portal link with the club slug pre-bound; (c) generic signup with a "Have a join code?" field. Metadata now carries join slug/code/token + intended role instead of a global role; the account-creation trigger enforces server-side that public paths can only yield parent/athlete memberships and never aborts signup on bad club context (soft-fail to the join screen).
**Unchanged:** core account fields (name, email, password, phone), 18+ athlete DOB check (server-side).
**New states:** invalid/expired code or suspended club → account created, membership skipped, recovery screen; under-18 athlete claim → guardian-required error.
- [ ] No combination of client-supplied metadata yields a coach/admin/owner membership from public signup.
- [ ] Bad club context never blocks account creation; the user can recover via the join screen.
- [ ] Portal-originated signup carries the club's branding through email confirmation to a club-branded welcome.

### C.8 Dashboard `/dashboard`

**Changes for multi-club:** parent/athlete branch: athletes, bookings, waitlist, skills counts and credit balance all filtered to the active club; the credit card is labelled with the club name; greeting/header shows active club name + logo; the role branch is decided by role-in-active-club (coach-at-A/parent-at-B sees the parent dashboard under B). Admin branch counts (slots/bookings/waitlist/members) become per-club — they currently count the whole platform.
**Unchanged:** page structure, cards, role-branch layout, upcoming-bookings rendering, links to /book, /progress, /athletes.
**New states:** NO_CLUB, CLUB_SUSPENDED (bookings listed read-only, "Book a session" CTA hidden); zero athletes *in this club* but athletes elsewhere → "No athletes at {club} yet" instead of generic first-run copy.
- [ ] User with memberships in Club A and Club B sees only Club A's bookings, waitlist entries, credit balance, and skill counts while Club A is active; switching flips every card with no page redesign.
- [ ] Parent-at-A/coach-at-B user gets the parent dashboard under A and the coach dashboard under B.
- [ ] Zero-membership user hitting /dashboard gets the join screen, never an empty dashboard.
- [ ] Suspended club: dashboard renders history, all booking CTAs disabled, banner visible.
- [ ] No query on this page returns rows from a non-active club (verify with a two-club fixture and network inspection).

### C.9 Book `/book`

**Changes for multi-club:** slot board RPC now requires the club id — only the active club's slots, coaches and rates; athlete selector lists only this club's enrolees; cancellation-policy copy comes from this club's settings (not `id=1`); credit balance shown/spent is this club's ledger and the booking function validates athlete + slot + coach + credit share one club; discipline filter chips come from the club's configured list, not hardcoded tumble/dance; the board-view preference key becomes club-suffixed so preferences don't bleed between clubs.
**Unchanged:** board layout, slot cards, capacity/notice UX, waitlist join flow, credit-spend confirmation flow.
**New states:** no athletes at this club → "Add an athlete at {club} first" → /athletes; suspended → board hidden, banner only.
- [ ] Slot board never contains a slot, coach, or rate from another club (two-club fixture, overlapping dates).
- [ ] Booking with an athlete from Club B while Club A is active is impossible in the UI and rejected by `book_slot` if forced.
- [ ] Credit balance shown equals the active club's ledger sum; booking with credit debits only that club's ledger.
- [ ] Cancellation-policy copy changes when switching clubs with different settings.
- [ ] Discipline chips reflect the active club's discipline list.

### C.10 Bookings `/bookings`

**Changes for multi-club:** bookings, series and waitlist reads scoped to the active club; cancel functions use *this* club's notice hours and refund/makeup rules, refunds land in this club's ledger; waitlist-offer accept validated same-club (including the "any coach" free-coach lookup, which now passes the club id); the calendar (.ics) export's identity and event summaries carry the club, not hardcoded "@ignyte"; offer countdowns render in the club's timezone.
**Unchanged:** tabs/sections (upcoming, series, waitlist), cancel confirmation UX, offer accept/decline interaction, .ics download mechanics.
**New states:** offers pending at a *non-active* club are not listed — a hint chip "1 waitlist offer at {other club}" links to the switcher (the offer itself surfaces via the bell); suspended club: cancel remains allowed (families must be able to exit — contested, E.1), rebook CTAs disabled.
- [ ] Bookings list for Club A contains zero Club B rows in every tab.
- [ ] Late-cancel behavior (notice hours, refund vs makeup token) follows the active club's settings when the two clubs differ.
- [ ] Accepting an offer only succeeds for the club the offer belongs to; cross-club accept attempts fail server-side.
- [ ] .ics file for a Club A booking contains Club A's name and no "Ignyte"-only branding; UIDs remain stable per booking. *(Critic: changing the UID domain for the existing club would duplicate already-imported events — resolve before shipping, E.2.)*
- [ ] Pending offer at the non-active club produces the hint chip and a bell notification, and is absent from the active club's waitlist tab.

### C.11 Athletes `/athletes`

**Changes for multi-club:** creating an athlete stamps enrolment in the active club; the list shows this club's enrolees. If the family has athletes at other clubs, a collapsed "At other clubs" row shows name + club chip only (no medical notes) with an "Enrol at {active club}" action that links the existing record rather than duplicating the child; "delete" on a multi-club athlete un-enrols from the active club, hard-deleting only at the last enrolment; medical notes and media consent stay per-child and travel across clubs (consent copy says so). **This page assumes one shared child record with per-club enrolments — the database spec assumes one record per club. This is the single biggest unresolved decision (E.1/E.5) and must be settled before this page is built.**
**Unchanged:** add/edit form fields, medical-notes UX, media-consent toggle, parent+admin access rule (admin now = admin-of-active-club).
**New states:** NO_CLUB; empty list with athletes elsewhere → the "at other clubs" row.
- [ ] Athlete created under Club A does not appear in Club B's booking selectors, rosters, or admin views.
- [ ] Enrolling an existing athlete at a second club does not create a duplicate row; progress/skills remain per-club.
- [ ] "Delete" on a multi-club athlete un-enrols only; single-club delete removes the record.
- [ ] Club B's admin/coaches cannot read an athlete not enrolled at Club B (RLS test).
- [ ] Media-consent value is honored by both clubs' upload flows.

### C.12 Progress `/progress`

**Changes for multi-club:** skills, skill statuses, notes, media and lesson discipline-focus all scoped to the active club; skills come from the club's own library, so a two-club athlete has two independent progress trees — the page shows only the active club's; media signed URLs use the club-prefixed storage paths and Club A's uploads are invisible under Club B; coach names on notes resolve within the club; discipline labels from the club's set.
**Unchanged:** skill grid/status rendering, notes timeline, media lightbox, athlete-picker interaction (picker now lists active-club enrolees only).
**New states:** club has an empty skill library → "No skills set up yet — ask {club}"; a media fetch denied post-migration → per-item "unavailable" placeholder, not a page error.
- [ ] Two-club athlete: switching clubs swaps the entire skill tree, notes, and media with no overlap.
- [ ] A signed URL created in Club A's context cannot be minted by a Club B family/coach for a Club A object (storage policy test).
- [ ] Progress notes never show a coach from another club.
- [ ] Club A editing its skill library does not alter Club B's or the seed library.

### C.13 Notifications bell + drawer/header (AppLayout)

**Bell — changes:** the bell is **cross-club** (one login, one bell): the dropdown shows notifications from all clubs, each with a club chip from the notification's club id; tapping an item for a non-active club switches context (toast "Switched to {club}") before navigating; **mark-as-read changes from "everything unread" to "the items currently rendered,"** and offer notifications are excluded from bulk mark-read until acted on (today an unopened Club B offer would be silently marked read); the unread badge counts all clubs.
**Bell — unchanged:** placement, top-20 window, item rendering, refresh behaviour.
**Bell — new states:** item from a club the user has left → read-only, no navigation, chip greyed.
- [ ] Club B's waitlist offer is visible in the bell while Club A is active, with club chip.
- [ ] Tapping it lands on Club B's /bookings with Club B branding applied.
- [ ] Opening the bell in Club A does not mark the Club B offer notification read.
- [ ] Badge = total unread across clubs; per-club counts not required.
- [ ] Users never see a notification addressed to another profile (unchanged per-user isolation).

**Drawer/header — changes:** header shows active club logo + name; accent colour applied app-wide; drawer header "Your club" → the actual club name; **club switcher** rendered only with 2+ memberships — clubs listed with logo, name, role chip and unread dot; selecting one stores the choice, re-resolves the role, and reloads the current route (falling back to /dashboard if the new role doesn't permit it); nav items filtered by role-in-active-club; tab title "{Club} · Ignyte"; single-membership users see chrome identical to today, re-branded. *(Staff pages spec a staff-only switcher variant — reconciliation needed, E.1.)*
**Drawer — unchanged:** drawer mechanics, install-prompt UI, sign-out, service-worker registration, nav item set per role.
**Drawer — new states:** NO_CLUB chrome (platform logo, join screen only); suspended club listed with "inactive" tag, still selectable read-only.
- [ ] 1-club user never sees a switcher; 2-club user always does.
- [ ] Switching clubs updates branding, nav (role may change), bell context chips, and active page data without sign-out.
- [ ] Switching from a role that permits the current route to one that doesn't redirects to /dashboard, no error flash.
- [ ] Stored active club survives reload; invalid stored value triggers the STALE_CONTEXT fallback.
- [ ] Accent color and logo never show the previous club after a switch (including cached shell).

### C.14 App shell & offline (PWA)

**Changes for multi-club:** single install, single platform-branded manifest (the manifest is fetched before login and can't be per-club in a static PWA; per-club installed apps are explicitly deferred to a premium tier); club identity is applied in-app immediately after auth resolves, with neutral platform chrome on first paint — never the previous club's branding baked into cached HTML. Service-worker data cache: all club-scoped requests must carry the club in the URL so one club's cached responses can never be replayed for another; the cache is purged on sign-out (fixing the existing cross-*user* leak on shared devices) and version-bumped in this migration. *(Whether the cache must also be purged on club switch is contested — E.1.)* Offline: cached data is per-club by URL; a never-loaded club shows the offline page, never the other club's rows.
**Unchanged:** install prompt, shell caching approach, offline page.
- [ ] One installed PWA serves both clubs; switching requires no reinstall or re-login.
- [ ] Killing and relaunching the app restores the last active club's branding and data.
- [ ] Airplane-mode switch from Club A to never-loaded Club B shows empty/offline state, not Club A data.
- [ ] Sign-out → sign-in as a different user on the same device yields zero cached rows from the previous user.
- [ ] Install-prompt dismissal stays device-level; per-club view preferences are club-suffixed.

### C.15 Cross-page rule: credits & makeup tokens are per-club

Ledger rows carry the club; balances are always computed and displayed **per club** — no aggregate "your credits" number anywhere; every displayed balance is labelled "{n} credits · {club name}"; booking spends only from the slot's club's ledger; cancels refund/grant makeup tokens into the same club per that club's settings; credits are non-transferable between clubs with no UI to move them.
- [ ] User with 3 credits at Club A and 0 at Club B sees 0 on Club B's /book and cannot spend A's credits there (UI + RPC).
- [ ] Late cancel at Club A grants a makeup token usable only on Club A slots.
- [ ] Dashboard/book balance labels always include the club name.
- [ ] Admin credit adjustments can only ever create ledger rows for their own club — the family view never shows a foreign-club adjustment.

### C.16 Cross-page rule: waitlist offers are per-club

Offer promotion reads the **slot's club's** offer-hours and timezone; offer notifications carry the club id and name; a family can hold simultaneous live offers at multiple clubs, each handled independently on that club's /bookings (or via bell deep-link with auto-switch); accept validates offer→slot→club and spends that club's credits; offer-expiry emails use the club's branding.
- [ ] Offer created at Club B while active in Club A: bell notification with chip appears; Club A's waitlist tab does not list it; the hint chip on Club A's /bookings does.
- [ ] Offer expiry honors Club B's offer-hours and timezone even when they differ from Club A's.
- [ ] Accepting the Club B offer books with a Club B-enrolled athlete and Club B credits only.
- [ ] Two live offers at two clubs can both be accepted without interfering.
- [ ] Declining/leaving an offer at one club never touches waitlist state at the other.

### C.17 Coach Hub `/coach`

Staff pages always render in exactly one club's context; context source: `?club=` URL param → stored choice → sole staff membership → picker interstitial. The client's club id is never trusted — every RPC re-derives authorization from the membership table; RLS is the backstop. A suspended/churned active club renders a lock screen instead of the tabs *(contested vs the read-only model — E.1)*.

**Changes for multi-club, by area:**

| Area | Change |
|---|---|
| Lessons (my bookings) | Filtered to the active club's slots where the coach is assigned; athlete joins (incl. medical notes) only through the same-club chain |
| Join slots (board) | Club-scoped board RPC verifying coach membership; rates shown are the coach's **per-club** profile row |
| Join/leave slot | Server derives the club from the slot and verifies active coach membership there — no reliance on client-passed club id |
| Register | Coach-of-booking unchanged; the admin override becomes admin-of-that-slot's-club; register-reminder cron loops clubs in each club's timezone |
| Progress editor | Skills list = the active club's library; all three write RPCs verify the athlete's club matches and the caller is coach/admin **of that club**; explicit same-club check added so a coach who once taught a family at Club A cannot edit that athlete's Club B records |
| Skill media upload | New `{club_id}/{athlete_id}/…` path; storage policies keyed on the club segment; uploads use the active club prefix; mismatched paths rejected |
| My settings | Edits the coach's profile row **for the active club only** ("Your profile at {Club}"); disciplines offered come from the club's configured set |

**Coach at two clubs:** context switcher for all actions **plus one merged read-only "My week" agenda** — a calendar strip aggregating the coach's *assigned* lessons across all their clubs via a new server-side `coach_agenda(from, to)` RPC (never assembled client-side from per-club boards, which would leak other coaches' data); entries badged with each club's name/colour; tapping one switches context and deep-links to that lesson's register. Explicitly **not** merged: the join-slots board, registers, and progress editing (merging mutations multiplies wrong-club mistakes). The agenda also powers a soft client-side clash warning ("You're already teaching at {other club} at this time") — deliberately not a database constraint, so clubs never learn each other's schedules through error messages.
**Unchanged:** tab set, register interaction, progress-editing UX, profile-upsert mechanics.
**New states:** club picker interstitial for multi-club staff with no stored choice; suspended-club lock screen.
- [ ] A coach with one club membership sees no switcher and no behavior change from today, except data is provably scoped (seed a second club; zero rows from it appear anywhere in /coach).
- [ ] A coach with memberships at Club A and Club B sees a switcher; every tab's data changes completely on switch; URL reflects the active club and is shareable to themselves.
- [ ] The slot-board RPC called with a club id the coach doesn't belong to returns an authorization error, not an empty board.
- [ ] Joining a Club B slot while Club A is active still succeeds *iff* the coach belongs to Club B (server derives club from slot), and the UI prevents reaching that state.
- [ ] Register view shows medical notes only for athletes of the active club; a direct REST query for another club's athletes returns zero rows under the coach's JWT.
- [ ] Progress editor skill list matches the active club's library exactly; editing a Club A athlete against a Club B skill id fails server-side.
- [ ] Skill media uploaded from Coach Hub lands under `{club_id}/{athlete_id}/…`; a signed URL for another club's object cannot be created under this coach's JWT.
- [ ] "My settings" saved at Club A leaves the coach's Club B rates/bio/disciplines untouched.
- [ ] Merged "My week" agenda shows entries from both clubs with distinct club badges; it contains only the coach's own assigned lessons, never other coaches' slots.
- [ ] Coach at a suspended club sees the lock screen for that club but can still switch to and fully use their other club.

### C.18 Club Admin `/admin` (all tabs)

**Changes for multi-club, by tab:**

| Tab | Change |
|---|---|
| Slots | Slot creation gated on admin-of-club, stamps the club, default location = first location **of that club** (clear error if none — never borrow another club's); delete/extend-series verify ownership before touching bookings or notifying; board is club-scoped |
| Bookings | All reads club-filtered; manual booking verifies athlete + slot + coach share the club; register and cancel per-club; the manual-booking athlete picker lists only the club's athletes |
| People | Reads the **membership list** joined to profiles, not the global user table; the role dropdown edits the *membership* role — `owner` is never grantable, server-enforced; "Remove" ends the membership (soft), never deletes the profile (the person may belong to other clubs); coach-rate edits target this club's profile row; credit adjustments verify the target is an active member here, stamp the club on the ledger, and show only this club's balances |
| Messages | Broadcast inserts notifications only for this club's active members matching the audience role; broadcast and notification rows carry the club; read counts aggregate this club only; rows carry the club so emails brand correctly |
| Locations | Club-stamped on insert; list/edit filtered |
| Skills | Edits the club's own library, no longer the shared seed; deleting a skill affects only this club's athletes |
| Export | Same UX; the whole query set (bookings, athletes, parents, coach rates) club-filtered end-to-end; filename `{slug}-bookings-{from}-{to}.xlsx`; **the export never contains another club's rows even for people who belong to both clubs** — the person appears, their other-club data does not |
| Settings | Reads/writes the club's own settings row (the `id=1` singleton is gone); fields unchanged (timezone, cancellation notice, waitlist offer hours, makeup tokens) plus the club's discipline set |
| Branding & Joining (NEW) | See below |

Dashboard admin-branch counts are also club-filtered (currently platform-wide). Admin at two clubs: same context switcher; **no merged views** — every tab is single-club; an admin of A who is a *parent* at B never sees B in the staff switcher.

**New Branding & Joining tab** (backed by columns on `clubs`, writable by that club's admins only through a narrow path — admins must never be able to touch status, plan, or billing fields):

| Field | Spec |
|---|---|
| Club display name | Text, 2–50 chars; used in header/title, portal, notification emails ("{Club} via Ignyte") and calendar exports; distinct from the legal/contact name you hold |
| Logo | Upload to a new `club-branding` bucket, path `{club_id}/logo.{ext}`; PNG/SVG/WebP ≤ 512 KB, square recommended, crop preview; public-read acceptable (logos appear on public pages and emails), write restricted to that club's admins *(critic: drop SVG — E.3)* |
| Accent colour | Single hex; validated for contrast against white and near-black text (WCAG AA large-text minimum) with a suggested passing shade on failure; default `#ff6a1a`; applied as a CSS variable and passed to the email webhook |
| Portal slug | Lowercase kebab, 3–30 chars, platform-unique, reserved-word blocklist; **set at provisioning by you; read-only here** (with copy buttons for the links) — slug changes are an Owner HQ action because they break distributed links; old slug redirects to new for 90 days *(mechanism unspecced on static hosting — E.2)* |
| Join mode | `open` (link/code joins immediately) / `approval` (requests queue for admin approval — recommended default) / `invite_only` (link disabled; invites only) *(pending state has no database backing yet — E.1)* |
| Join code | 6-character human-readable code shown beside the link; "Regenerate" invalidates the old code immediately |
| Pending requests | In approval mode: list with approve/decline; approving activates the membership; declining notifies politely |

**Unchanged:** tab structure, slot-creation form, register/cancel interactions, broadcast composer, Excel-export UX, settings fields.
**New states:** picker interstitial; suspended lock screen; no-locations error state on slot creation; pending-requests queue.
- [ ] Every tab's queries return zero rows from a seeded second club under a Club A admin's JWT — verified both through the UI and via direct REST calls (RLS backstop).
- [ ] Slot creation with no locations in the club fails with an actionable error and never selects another club's location; created slots carry the correct club id.
- [ ] Extend-series / delete-slot against another club's series/slot return authorization errors.
- [ ] People-tab role change mutates only the membership row; attempting to set `owner` via crafted request is rejected server-side.
- [ ] Removing a member from Club A leaves their profile, their Club B memberships, and their Club B data fully intact.
- [ ] Credit adjustment targeting a profile with no active membership in the admin's club fails; ledger rows carry the club; the family's Club B balance is unaffected.
- [ ] Broadcast to "all parents" reaches exactly Club A's active parent members; read counts count only those notifications; a two-club regression test proves counts don't bleed.
- [ ] Skills tab edits alter only this club's library; another club's identically named skill is a different row.
- [ ] Excel export from Club A contains no Club B bookings, memberships, or coach rates, including for people who belong to both.
- [ ] Settings save affects only this club's row; cancel-notice hours and waitlist offer-hours read the correct club's values (test with two clubs configured differently).
- [ ] Branding tab: logo upload lands under `{club_id}/`; slug is read-only; a failing accent colour shows the contrast warning; saved branding renders on next load and cannot modify status/plan fields (verified by crafted request).
- [ ] Join settings: regenerating the code kills the old one immediately; approval mode holds new members pending until approved; invite-only disables the public link with a friendly message.

### C.19 Owner HQ `/owner` (summary — full detail in Section D)

**Changes for multi-club:** graduates from "clubs registry + leads list" to the platform console: club health table, per-club drill-in with audited "view as," one-transaction provisioning wizard, suspension lifecycle, plan/billing fields, platform announcements, platform stats. Owner-only throughout; all aggregate reads via owner-only server functions, not client-side query fan-out.
**Unchanged:** owner-only gate; leads pipeline concept (now feeding the provisioning wizard).
**New states:** archive filter for churned clubs; view-as banner mode.
- [ ] All Owner HQ acceptance criteria in Section D pass.

---

## D. Owner HQ platform console

### D.1 Club list with health metrics

A single owner-only RPC returns one row per club:

| Column | Definition |
|---|---|
| club | id, name, slug, status, plan, billing_status |
| active_families | distinct parents (active membership) with ≥1 booking in the last 30 days |
| members | active memberships by role (parents/athletes/coaches/admins) |
| bookings_per_week | trailing 4-week mean of confirmed bookings |
| fill_rate | booked ÷ capacity across the club's slots, last 4 weeks |
| last_activity | most recent of: booking created, register taken, broadcast sent |
| trial_ends_at / next_flag | e.g. "trial ends in 3d", "no activity 14d", "past_due" |

UI: sortable table, status filter chips (lead/trial/active/suspended/churned), row click → drill-in. Warning badges: trial ending ≤ 7 days, zero activity ≥ 14 days, past-due billing.

### D.2 Per-club drill-in and "View as"

Drill-in tabs: Overview (health + bookings-per-week sparkline), Members (read-only), Settings snapshot (settings + branding, read-only), Plan & billing (editable, D.4), Activity (broadcasts, provisioning/suspension events, owner audit entries for this club), Actions (view-as, suspend, edit slug, provision admin).

**"View as club admin" — the impersonation spec.** Explicitly *not* auth impersonation: you never obtain a user's session, no service key reaches the browser, no credentials are touched. Instead the existing owner-passes-everywhere pattern is formalized:

1. "View as admin" → server logs a `view_as_start` audit row → opens `/admin?club={slug}&viewas=1`.
2. A persistent, non-dismissable banner: "Viewing {Club} as Owner — actions are logged," styled distinctly from club branding.
3. **Read-only by default, server-enforced**: mutating controls are disabled in the UI *and* every admin mutation RPC rejects an owner-not-admin caller unless support actions are enabled. *(This conflicts with the database spec's unconditional owner bypass — must be reconciled, E.1.)*
4. "Enable support actions" grants mutation ability for **60 minutes** (expiry stored server-side in an `owner_support_grants` table checked by the mutation RPCs); the grant is logged, and every owner-invoked mutation during the window writes an audit row (action, detail, timestamp).
5. Notifications generated by support actions are attributed to the club (families see normal club-branded messages), but the audit log records the true actor.
6. The audit log is owner-readable in HQ and support actions (not view-as reads) surface in the club's Activity tab; retention ≥ 12 months.
7. View-as never exposes: parent credentials/sessions, other clubs' data through the viewed club's UI, or plan/billing changes from within `/admin` (HQ-only).

### D.3 Club provisioning

One transactional RPC replaces the current account-creation + manual-clubs-row flow. Inputs: club name, slug, timezone, discipline set, plan + trial end, admin name + email, optional source lead. Effects, atomically: clubs row (`status='trial'` unless overridden) → settings row with defaults + timezone → skills library seeded from the platform template → admin auth account created **or existing profile reused** (single-login model) + admin membership → source lead marked converted and linked → club-branded admin welcome/invite queued. The HQ wizard mirrors these inputs in order, pre-filled from the lead when launched off the pipeline. Ships with the `club_leads` owner-only RLS fix.

### D.4 Suspension & lifecycle; plan/billing fields (Stripe deferred)

Status lifecycle: `lead → trial → active → suspended → churned`, with `suspended ↔ active` and `trial → active/churned`; **all transitions owner-only and audited**. Suspension effects (enforced in the database, not just UI): members authenticate but that club's pages lock (families with other clubs unaffected); every mutating function checks the club is trial/active; join links, codes and the public portal go dark; cron skips the club; data fully retained; unsuspend is one click and instant. `churned` = suspended + hidden from the default list (archive filter shows it); no data deletion in this spec (retention/erasure is a flagged compliance gap — E.2).

Billing fields on `clubs`, editable only from HQ:

| Field | Type / values | Notes |
|---|---|---|
| plan | `trial`, `standard`, `plus`, `comped` | `plus` reserved for the future branding upsell; all core features on every plan per the pricing research |
| billing_status | `trialing`, `active`, `past_due`, `canceled`, `comped` | Owner-set manually until Stripe; drives HQ badges only — **no automated enforcement yet** (auto-suspend on past-due is a Stripe-phase decision) |
| trial_ends_at | timestamp | HQ badge + future automated reminders |
| active_family_limit | number, optional | Null = uncapped; counted against the active-families metric; soft limit (HQ warning, no hard block) |
| stripe_customer_id / stripe_subscription_id | text, optional | Empty until integration — Stripe wiring becomes a data backfill, not a migration |
| billing_notes | free text | Agreed price, discounts, invoicing arrangements |

### D.5 Platform announcements & platform stats

**Announcements:** an owner RPC inserts one notification per **active admin membership** across all non-churned clubs, deduplicated per person (an admin of two clubs gets one), typed `platform` (so club broadcast read-counts never count them), platform-branded, delivered via the same email webhook with the platform sender. HQ lists past announcements with read counts. Not sent to parents/coaches — an operator channel only.

**Platform stats (HQ overview):** one RPC: clubs by status; totals across active clubs (active families, bookings this week vs last, register-taken rate); new leads 7/30 days + pipeline by status; notification email volume last 7 days with a warning threshold against the Resend 100/day free tier; newest signups. Stat tiles above the club table; aggregates only — **no per-family personal data on this screen**.

### D.6 Acceptance criteria — Owner HQ

- [ ] Club list shows every club with the D.1 metrics; metrics for a seeded club with known fixture data match hand-computed values.
- [ ] All HQ RPCs reject non-owner callers (tested with an admin JWT) and appear in the function-execution grant list with owner-only checks inside.
- [ ] `club_leads` is readable by owner only; a club admin's JWT gets zero rows.
- [ ] The provisioning wizard creates club + settings + seeded skills + admin membership in one transaction; a mid-flow failure (e.g. duplicate slug) leaves no partial rows.
- [ ] Provisioning with an email that already exists attaches an admin membership to the existing profile instead of erroring or duplicating the account.
- [ ] View-as opens `/admin` with the persistent banner; with support actions off, every mutation RPC invoked as owner-in-view-as fails server-side even via crafted request.
- [ ] Enabling support actions writes an audit row, expires after 60 minutes (a mutation at +61 min fails), and every mutation in the window is logged with action + detail.
- [ ] View-as of Club A cannot read Club B data through any Club A admin surface.
- [ ] Suspending a club: members hit the lock screen, join link/code dead, mutating RPCs rejected, cron skips it, other clubs unaffected; unsuspending restores everything with no data loss.
- [ ] Plan/billing fields are editable only via HQ (a club admin's crafted update is rejected) and render as badges in the club list.
- [ ] A platform announcement reaches exactly the active admins across non-churned clubs, once per person; it never appears in any club's broadcast read counts; read tracking works.
- [ ] Platform stats tiles load from the single stats RPC and contain no per-family personal data.
- [ ] Every owner lifecycle action (provision, suspend, unsuspend, slug change, plan change, view-as, support-action grant) appears in the owner audit log with actor, club, action, timestamp.

---

## E. Gaps, risks & contradictions

### E.1 Contradictions between the specs (each with a recommended resolution)

1. **CRITICAL — Two incompatible child-record designs.** The database and login specs say a child at two clubs = two independent athlete rows; the family-pages spec says one shared record with per-club *enrolments*, un-enrol instead of delete, and medical notes/consent that travel across clubs — which requires an enrolments join table no spec defines. Two independent rows means divergent medical notes and consent flags — a safeguarding hazard, not a nit. **Recommendation:** adopt the family-pages model (one child record + `athlete_enrolments(athlete_id, club_id)` join table; skills/notes/media hang off the enrolment, medical notes/consent off the child), and rewrite the database and login specs to match. This is also founder decision #1 below — get sign-off before building.
2. **CRITICAL — Join-approval mode has no database backing.** The admin spec recommends `approval` as the default join mode with a pending queue; the database and login specs have no `pending` membership status and make joins instantly active, and nobody defines what a pending member can see. **Recommendation:** add `'pending'` to the membership status values, have the join paths honour the club's join mode, define the pending experience (a "waiting for approval" screen; no club data visible), and build the approve/decline queue — then keep `approval` as the default for children's clubs.
3. **CRITICAL — "Read-only view-as" vs the unconditional owner bypass.** The staff spec makes owner view-as read-only by default with a 60-minute audited support-grant window; the database spec makes the owner helpers *unconditionally* return true, with no grant table, no audit table, and no expiry check — every mutation silently passes for the owner, always. Opposite trust models. **Recommendation:** implement the staff spec's model — the owner-bypass helpers (for *mutations*) must consult the support-grants table, and the `owner_support_grants`/`owner_audit_log` tables must be added to the database spec. This is founder decision #5.
4. **HIGH — A fifth, un-audited membership-write path.** The login spec's invariant says only four named functions may create memberships; the database spec's RLS lets admins insert/update membership rows directly — including granting `admin` with no invite, no email match, no confirm — and the owner-provisioning RPC is a sixth path nobody lists. **Recommendation:** remove direct admin insert on `club_members` (admins update role/status only, on existing rows in their club); staff roles are granted only via invites; update the invariant list to include owner provisioning.
5. **HIGH — Suspended-club behaviour disagrees three ways.** Login spec: reads allowed, *all* mutations blocked (including cancel), admins keep read access for export. Family spec: **cancel remains allowed** at a suspended club. Staff spec: staff see a **lock screen with no data**. Plus a real bug all specs share: an expired trial still has `status='trial'`, so the cron skip condition (`status in ('trial','active')`) keeps firing reminders for lapsed trials, and the `assert_club_active` gate everything depends on is never defined in the database spec. **Recommendation:** members read-only *plus* cancel allowed (consumer-rights and reputation), admins read + export, coaches read-only; define `assert_club_active` to check both status *and* `trial_ends_at`, and fix the cron condition to match. This is founder decision #4.
6. **HIGH — Two different public-portal RPCs.** `get_club_public` (name/slug/logo/colour/status only) vs `get_club_portal` (adds blurb, locations, coach roster with photos/bios — but photos and per-coach "publish" opt-in flags exist in no schema), and the database lockdown grants neither to anonymous users. **Recommendation:** one RPC, one name; ship the minimal projection first, add roster fields only once the opt-in flags exist on `coach_profiles`; add the anonymous grant explicitly.
7. **HIGH — "Slug identifies, code authorizes" vs slug-only joins.** The login spec forbids signed-in users joining from the slug alone; the portal-page spec's Join CTA does exactly that — and the invariant is hollow anyway because a fresh signup with slug metadata joins without a code. **Recommendation:** make the rule uniform — with approval mode as the default (E.1.2), slug-initiated *requests* are safe for everyone (the queue is the gate); in open mode, require the code for all joins, signup included.
8. **MEDIUM — Three active-club resolution algorithms, two storage formats.** The three specs disagree on fallback order (picker vs "most recently joined"), whether a `profiles.last_club_id` column exists (the database spec never adds it), and whether local storage holds the club *id* or the *slug* under the same key — a family-page write would break staff-page reads on the same device. **Recommendation:** one shared resolver: URL param → localStorage (store the **id**) → `last_club_id` (add the column) → sole membership → picker; used by every surface.
9. **MEDIUM — Two different switcher UIs.** Family spec: drawer switcher listing *all* memberships; staff spec: header chip listing *staff* memberships only. Both claim the same layout component; nobody says what a parent-at-A/admin-at-B sees where. **Recommendation:** one switcher listing all memberships with role chips; on staff pages, selecting a club where the user is only a parent routes to /dashboard in that club — one component, role-aware destination.
10. **MEDIUM — Cache purge on club switch.** Login spec: switching must purge the service-worker data cache; family spec: entries are club-keyed by URL so purging on sign-out only is enough. **Recommendation:** keep both — club-keyed URLs as the design, purge-on-switch as cheap insurance; verify supabase-js request shapes (POST RPCs are likely never cached; REST GETs are the real vector) during implementation and relax later if proven safe.
11. **MEDIUM — Where do disciplines and timezone live?** `club_settings` (database spec) vs `clubs` (login spec), with the staff spec citing both. **Recommendation:** `club_settings` (all function reads already point there); the login/provisioning specs update their column references.
12. **LOW-MEDIUM — Signature and format drift (each a real integration bug):** slot-board argument order differs between specs; coach-profile key order differs; slug rules differ (3–40 no blocklist in the DB constraint vs 3–30 + two different blocklists — if only the DB constraint ships, `/c/login` is claimable); join-code alphabet differs (the DB check permits ambiguous characters the login spec excludes); `join_club` needs three behaviours (code/token/slug) but the DB defines one; the status enum in the database spec never gains `suspended` though two specs require it; and under the database spec's RLS as written, **admins cannot edit branding or rotate the join code at all** (no write path on `clubs`). **Recommendation:** a one-page API appendix freezing every signature, constraint and enum, signed off before implementation; add the `suspended` status and the narrow admin branding-write RPC to the database spec.

### E.2 Missed cross-cutting concerns (nobody owns these)

1. The suspension gate (`assert_club_active`) has no database spec despite ~20 functions depending on it — as written, suspension ships unenforced.
2. `club_invites` has no DDL, RLS, indexes, or isolation tests — the whole coach/admin invite system rests on a sketch; the attack matrix has zero invite rows (cross-club invite creation, accept races, accept-after-role-change).
3. Most new RPCs are missing from the grant/lockdown story (provisioning, portal reads — which need an *anonymous* grant the lockdown explicitly revokes — invites, code rotation, coach agenda, branding, and all seven owner-console functions).
4. Removed-member cleanup is unspecced: a removed parent's future bookings (cancel? refund? orphan?), a removed coach's assigned lessons and slot assignments, pending waitlist entries, and whether removal notifies the family.
5. Email infrastructure: per-club from-name **sanitization** (a club named "Stripe Support" gets a phishing-shaped sender), per-club deep links, **per-club rate limiting** (one club's 300-parent broadcast exhausts the shared 100/day Resend free tier and silently starves every other club's waitlist-offer emails), retry/dead-letter handling, and marketing-consent capture for rebook nudges (they are marketing under PECR/GDPR; no consent exists).
6. GDPR/data protection: controller/processor split and per-club DPAs (a sales blocker for schools/franchises), per-club data export for offboarding, cross-club right-to-erasure, retention policy (two specs defer to a "data-lifecycle section" that does not exist), and the fact that medical notes are special-category health data whose cross-club visibility the family spec grants casually.
7. Club deletion is declared impossible ("churned archives") — colliding with erasure obligations and commercial reality; no churn-export, purge job, or anonymization.
8. Anti-abuse: nothing rate-limits join-code guessing (scriptable while signed in, and guessable *pre-auth* via repeated signups with code metadata), slug enumeration, invite accepts, or trial-club creation (slug squatting).
9. Old-client breakage at cutover: installed PWAs can run stale JavaScript for days and will hard-fail against the new function signatures; no compatibility shim (e.g. a temporary 2-argument slot-board overload inferring the sole club), forced-update mechanism, or SW version gate. Also the .ics identity change would duplicate every already-imported calendar event for existing families.
10. Adult-athlete signup vs the new required `athletes.club_id`: unless the trigger change ("create the athlete row at membership time") is actually written, 18+ signup hits a not-null violation and aborts the signup — breaking the login spec's own never-abort invariant.
11. Slug-change redirects: "old slug 302s for 90 days" is impossible on static hosting with a client-rendered portal — needs a slug-history table + client-side lookup; no spec.
12. Link previews: the portal page is client-rendered, so WhatsApp — the *primary* distribution channel — shows a generic platform card for every club; needs edge-rendered or prerendered meta tags, plus a robots/sitemap strategy.
13. Marketing/commercial surface: no spec for the pricing page, plan prices, ToS/DPA pages, or converting the current single-club marketing site into a SaaS site; the existing club's own web presence vs the platform's is unresolved.
14. No demo/sample data for fresh trial clubs (empty dashboard + empty board = dead first-run) despite self-serve trials being the growth engine.
15. CSV member import is cited as a justification for invite emails but specced nowhere.
16. Per-tenant restore and admin blast radius: "an admin deleted all our slots" can only be fixed by whole-platform point-in-time recovery; no per-club audit of *admin* actions, no soft-delete, no tenant-scoped restore plan.
17. Multi-club timezone display in the merged coach agenda (clubs may sit in different timezones) and per-club calendar timezone identifiers are unspecced.

### E.3 Security holes found in the proposed designs

1. **The member-read policy on `clubs` leaks the whole row** — including the join code (defeating invite-only/approval modes: any member reads and shares it), billing notes, plan, billing status and Stripe ids — to every parent. Needs a public-safe view or column-level privileges.
2. **Self-serve club creation enables brand-squatting phishing portals** — a stranger registers a real local club's name and logo and collects real parents' children's names, DOBs and medical notes on your domain, under your brand. No verification, similarity review, approval queue, or takedown flow. The critic calls this the single worst hole in the design.
3. **The owner account is unaudited god-mode as the database spec stands** (see E.1.3), with no MFA/step-up requirement, session controls, or second-owner recovery. One phished password = every club's children's data.
4. **A privacy regression in the new profiles policy:** today a coach sees only families they actually teach; the rewrite lets any coach see every parent's email/phone in the club. Undocumented widening — restore the taught-families rule.
5. **SVG logo upload to a public-read bucket** = stored XSS on the storage origin; no content-type validation specced. Restrict to PNG/WebP or sanitize server-side.
6. **Unvalidated branding values flow into CSS and email:** the accent colour reaches anonymous pages and email templates with only a contrast check, and the club display name flows into email from-names with no character restrictions (header-injection/spoofing surface).
7. **Join-code guessing is unthrottled and partially pre-auth** (the signup endpoint doubles as a code oracle via metadata); in open-join mode a guessed code = instant membership = the club's schedule, roster and settings.
8. **Invite mechanics are racy and token-in-URL:** parallel accepts of a single-use invite can both succeed (no locking specced); the invite id doubles as a bearer token pasted into WhatsApp — fine for parents, dangerous for admin invites. Require email binding for admin invites and row-locking on accept.
9. **The isolation test matrix has blind spots exactly where the new surface is:** zero test rows for invites, branding writes (touching status/plan), code rotation cross-club, portal projection leakage, provisioning slug abuse, the coach agenda (must not leak other coaches' or clubs' slots), support-grant expiry, the branding bucket, and suspended-club RPC rejection. The spec's own rule: whatever isn't in the matrix regresses silently.
10. **Notification deep links auto-switch club context** — combined with URL-param honouring, any link can silently flip a staff user's active club before a muscle-memory action; damage is server-bounded, but staff-context switches triggered by links should require an explicit confirm.

### E.4 Five decisions for the founder (plain-English either/or, with recommendations)

1. **One child record or two?** If a child trains at two clubs, is there ONE record (both clubs see the same medical notes and photo consent; an update at one club is instantly visible at the other) — or does EACH club keep its own copy (parents update allergy info twice; the copies can disagree)? This decides who sees a child's medical information — a safeguarding and legal question, not a technical one. **Recommendation: one record with per-club enrolments** — divergent allergy information is the scenario you never want to explain to a parent or a regulator; accept the extra build cost of the enrolments table.
2. **Open door or approval queue?** When a parent finds a club's link or code, do they get in INSTANTLY and immediately see the schedule and coaches — or wait in a queue until the club clicks approve? Instant = less admin work but anyone with the code walks in; approval = safer for children's clubs but every club must manage a queue. **Recommendation: approval by default, per-club switchable to open** — these are children's clubs; build the pending state properly first (it currently has no database backing).
3. **Self-serve signup or hand-provisioned clubs?** Can any stranger create a club in five minutes with any name and logo — or does every new club go through you first? Self-serve scales and is what the growth flow assumes; it also lets someone impersonate a real local club and collect families' data under your brand. **Recommendation: soft launch with owner approval of each trial club (a one-click approve queue in Owner HQ), moving to full self-serve only once a verification/report/takedown process exists.** You are at single-digit club volume — approval costs you minutes and closes the worst hole in the design.
4. **What happens when a club stops paying?** When you suspend a club: can families still see their history and CANCEL bookings, and can the club's admin still export data — or does everything lock? Locking parents out of cancelling their own child's sessions is a reputational and consumer-rights risk that lands on you; open exports weaken your leverage over a non-payer. **Recommendation: families read + cancel; admin read + export; everything else frozen** — your leverage is the frozen operations, not hostage data, and goodwill with parents transfers between clubs.
5. **How much power do YOU have inside clubs — and do they know?** Full silent access to every club's admin screens at all times (logged) — or look-only by default, with edit powers unlocked case-by-case for an hour and every action recorded? And will clubs be told, in the contract and in the product, that you can do this? **Recommendation: the time-boxed, audited model, disclosed in the contract and visible in the product** — plus the obligations that come with it: MFA on the owner account, no shared login, and a documented recovery path. Whichever you choose, your single owner login can reach every child's data on the platform; treat it accordingly.

---

## G. Proposed release plan (once you've marked this up)

1. **Release 0 — decisions & API freeze.** You answer the five E.4 questions; we freeze the one-page API appendix (E.1.12) so every signature/enum matches.
2. **Release 1 — foundations, invisible.** Additive migration (club tables, membership, helpers), backfill of your club, isolation test suite green. App looks unchanged.
3. **Release 2 — the walls go up.** Cutover migration + club-scoped app deploy in one window. Still one club; now provably isolated. Old installed apps handled by a compatibility shim + forced-update gate.
4. **Release 3 — doors open.** Club portal /c/{slug}, join flows (approval queue), invites, branding tab, club switcher, suspended-state handling.
5. **Release 4 — the platform.** Owner HQ console (health metrics, provisioning wizard, view-as with audit, announcements), pricing page, first trial club onboarded by hand.
6. **Release 5 — self-serve** (behind your approval queue): trial wizard, demo data for fresh clubs, email rate-limiting per club, anti-abuse throttles.

## H. Sign-off sheet

| # | Decision | Your call |
|---|---|---|
| 1 | One child record with per-club enrolments (recommended) — or one copy per club? | ☐ |
| 2 | Join approval queue by default (recommended) — or instant open joins? | ☐ |
| 3 | Owner-approved trials at launch (recommended) — or full self-serve from day one? | ☐ |
| 4 | Suspended clubs: families read + cancel, admin read + export (recommended) — or full lock? | ☐ |
| 5 | Your owner powers: time-boxed audited "view as" (recommended) — or always-on full access? | ☐ |
| 6 | Pricing page: confirm tiers/prices (currently placeholder Free trial → £29/mo) | ☐ |
| 7 | Existing club's marketing site vs the platform site — keep both? | ☐ |
| 8 | Mock screens 1–8: approve / change (mark on each) | ☐ |
