# JAM Spirit Sites (jamspiritsites.com) — Teardown

Researched 2026-08-03. **Access caveat:** jamspiritsites.com, all `*.style.jamspiritsites.com`
demo sites, hosted client sites, and third-party pages (BBB, Birdeye, SaaSHub, archive.org)
all returned 403 to every fetch attempt from this environment; even example.com 403'd, so
direct page reads were impossible. Everything below comes from search-engine snippets and
indexed third-party profiles. Items marked **unverified** could not be confirmed first-hand.

## Company

- Trading names: **JAM Web Designs, Inc.** (parent), JAMSpiritSites.com, OnlineProcessingServices.com,
  and gymnastics brand ChalkJock.com (now folded into JAMSpiritSites) ([chalkjock.com](https://chalkjock.com/)).
- Tagline: "The Original Cheerleading Website Designers and Class Management Experts."
- Founded **1999**, based Oklahoma City (3700 N Classen Blvd #215); unfunded/bootstrapped;
  described as a "small development team of three" ([Tracxn](https://tracxn.com/d/companies/jamspiritsites.com/__mo3NEPo4yJvs_DKNMX4W2ffRQ3ERDij0t3ByiHh7MsQ),
  [BBB profile](https://www.bbb.org/us/ok/oklahoma-city/profile/website-maintenance/jam-web-designs-incjam-spirit-sites-0995-90089793),
  [Yellow Pages](https://www.yellowpages.com/oklahoma-city-ok/jam-web-designs-inc)).
- Not BBB accredited; BBB has "insufficient information to issue a rating."
- Note: unrelated to "The JAM Brands" (event producer acquired by Varsity Spirit) despite the
  similar name ([FierceBoard](https://fierceboard.com/threads/the-jam-brands-announces-merger-with-varsity-spirit.43476/)).
- Datanyze lists "$10M revenue, New York, NY" — almost certainly auto-generated junk data;
  treat as false ([Datanyze](https://www.datanyze.com/companies/jamspiritsites/42503394)).

## 1. Pricing — largely UNOBTAINABLE

- A pricing page exists ([jamspiritsites.com/pricing](https://jamspiritsites.com/pricing)) and a
  sign-up page titled "together" ([jamspiritsites.com/sign-up](https://jamspiritsites.com/sign-up)),
  but both 403 to fetches and Google indexes no snippet text from either. **No dollar amounts,
  setup fees, tier names, or contract terms could be verified from any source.**
- The only pricing-structure fact found: Snap is sold as **"a single monthly fee"** covering
  "class management, website, domain name, email, and other services in one interface"
  (search snippet of [jamspiritsites.com/class-management](https://jamspiritsites.com/class-management)).
  So the model is bundled SaaS subscription, not one-off web design.
- Sales channel is quote/contact-led: 1-877-239-9308 / sales@jamwd.com; orders run through their own
  checkout ([onlineprocessingservices.com](https://onlineprocessingservices.com/ops_index.php?componentName=OrderProcess&cookiedestroyed=1&scid=17711)).
- Not listed on Capterra/G2, so no third-party pricing data exists either.
- Dollar figures that surface in search ($75/month etc.) are **client gyms' class fees**, not JAM's.

## 2. Product

Two intertwined offerings on one platform ("Snap Cloud"):

**Websites ("SpiritSites")**
- Numbered pre-built **style templates** (demo sites at `NNN.style.jamspiritsites.com`, seen 224–475),
  customizable hero sections (own colors, photo, or YouTube video backgrounds); marketed as
  custom-designed "to capture what your gym represents" ([e.g. 464.style demo](http://464.style.jamspiritsites.com/), [471.style](http://471.style.jamspiritsites.com/)).
- Page types observed on demos/client sites: Home, General/Gym Info, Classes, Teams (incl.
  per-program pages like tumbling levels), Forms (downloadable, email/fax back), Calendar/News
  sections, Contact, Member Login, social links ([461.style General Info](http://461.style.jamspiritsites.com/index.php?componentName=Section&scid=89943),
  [462.style Forms](http://462.style.jamspiritsites.com/index.php?componentName=Forms&scid=90481)).
- Legacy PHP CMS (`index.php?componentName=...` URLs) with a drag-and-drop "Snap Cloud" editor,
  email + domain management tools ([search snippet](https://jamspiritsites.com/)).
- **Custom domains confirmed** — client sites run on their own domains (see Market below).

**Snap class management** (snap.jamwd.com, per-club subpaths)
- Online class registration/enrollment, waitlists, automated recurring billing, payment portal,
  makeup-class self-scheduling, attendance, legal/waiver requirement tracking
  ([docs.jamwd.com](http://docs.jamwd.com/knowledgebase/attendance/), [Facebook](https://www.facebook.com/GymManagement/)).
- Card processing via **First Data / Payeezy** merchant account (club applies for its own
  merchant account) ([docs: Connecting To First Data](http://docs.jamwd.com/knowledgebase/connecting-to-first-data/)).
- Help resources at [help.jamwd.com](https://help.jamwd.com/) and [docs.jamwd.com](http://docs.jamwd.com/contact/).

## 3. Market

- Verticals: cheerleading (core), gymnastics, dance, tumbling, parkour gyms.
- Tech-tracker estimate: **~150 sites** use the platform ([ContactOut](https://contactout.com/top-companies-using-jamspiritsites) — low-confidence
  scraped data; its "top companies" list is visibly polluted, so treat the count as rough).
- Identified clients (all North America, overwhelmingly US): Spirit Xtreme (TX)
  ([spirit-xtreme.com](https://www.spirit-xtreme.com/index.php?componentName=textBody&scid=55866)),
  Long Island Cheer (NY), Cheer St. Louis (MO), Jersey Pride Cheer (NJ), Team Illinois Cheer,
  Off Main Cheer & Tumbling, RSD Gym Dance & Cheer, Elite All-Stars of Maine, Texas Lonestar
  Cheer Co, Futures Gymnastics (Canada). **No UK clients found.**
- Praise (from their own marketing/testimonials, so biased): one gym reported summer enrollment
  +75% after launch with "97% of new clients" citing the site; "first class" service, personable.
- Complaints: thin public record. One Yellow Pages review of JAM Web Designs cites "major lack of
  communication on the owner's part... a lot of misinformation. Waited forever" — may relate to
  their general design work, not the gym product. No Reddit/FierceBoard user discussion of the
  product was findable. Facebook page is small (~794 likes) ([Facebook](https://www.facebook.com/JAMSpiritSites/)).

## 4. UK comparables

No direct UK equivalent (cheer/dance-specific hosted club websites) was found. Nearest options:

- **Pitchero** — UK hosted club-website + membership + payments platform (team-sport oriented, not
  cheer-specific). Free for 1-team clubs; paid from ~£30/mo (Standard £38/mo, Ultimate £80/mo,
  Pro £99/mo); Stripe fees from 1.84% + 17p; 30-day trial ([pitchero.com/pricing](https://www.pitchero.com/pricing)).
- **ClassForKids** — UK bookings/payments/comms for kids' classes incl. a cheerleading vertical;
  single all-in monthly licence, but booking pages rather than full club websites
  ([classforkids.com](https://www.classforkids.com/industries/cheerleading-management-software/)).
- **Coacha** — UK cheerleading/gymnastics club management (free Lite tier + paid), safeguarding/GDPR
  focus; management not websites ([coacha.co.uk](https://www.coacha.co.uk/Cheerleading-Management-Software)).
- **LoveAdmin** — UK membership/payments admin, tiered pricing, no member caps ([loveadmin.com](https://loveadmin.com/)).
- US-only but closest product analogue: **97 Display** — websites + marketing specifically for cheer
  gyms ([97display.com/cheer](https://97display.com/cheer/)).
- Takeaway: UK cheer clubs today stitch together a generic website (Wix/Squarespace or a local
  agency) plus a management tool above — the JAM-style "website + registration + billing in one
  cheer-branded bundle" gap appears open in the UK.

## Not verified / open questions

- All pricing specifics (fees, tiers, setup, contract length) — page is unindexed and unreachable.
- Whether "150 sites" is accurate; real client count could differ substantially.
- Whether design work is truly custom per client or template-pick-plus-tweaks.
- Current state of the product (site titles/UX suggest a dated PHP stack; no press or funding news).
