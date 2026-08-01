# Competitor Teardown — Ignyte Club Manager

**Date:** 1 August 2026. **Scope:** UK-relevant club/class management platforms for cheer, dance and kids' activity clubs, compared against Ignyte Club Manager (free tier + £29/mo Club tier; 1-2-1 privates with recurring weekly series, group classes, memberships, invoicing where the club keeps 100% of payments, skill progression journeys, waiting lists with auto-offers, registers, Excel coach-pay exports, installable PWA).

> **Method note:** Product screenshots could not be captured from this environment (outbound browsing is blocked by network policy, and vendor sites returned 403 to direct fetches). UI and flow descriptions below are sourced from vendor documentation/help centres, review sites (Trustpilot, Capterra, GetApp, Software Advice), app-store listings and independent blog write-ups, all cited inline. Facts that could not be verified are flagged as such. Prices were checked July–August 2026 and may drift; several vendors deliberately hide final transaction fees behind sales calls.

---

## Executive summary

| Product | UK focus | Monthly price | Transaction fees | Standout feature | Biggest complaint |
|---|---|---|---|---|---|
| **ClassForKids** (Class4Kids) | Native UK (Glasgow), 4,500+ clubs | From ~£35/mo licence ([Capterra UK](https://www.capterra.co.uk/software/141287/class4kids)) | ~3.1% incl. Stripe + 0.5% extra on subscriptions; "final fees confirmed by your Account Manager" ([help centre](https://help.classforkids.io/en/articles/12753012-setting-up-and-managing-subscriptions-new-version), [pricing](https://classforkids.io/clubs/pricing)) | Trials pipeline + waiting-list invites built for kids' clubs | Parents can't cancel subscriptions themselves — must beg the club; billing continues after "cancelling" ([Trustpilot](https://www.trustpilot.com/review/class4kids.co.uk)) |
| **LoveAdmin** | Native UK | £16–£28/mo + £195–£295 setup fee ([loveadmin.com/pricing](https://loveadmin.com/pricing/), [ClubPilot roundup](https://clubpilot.co.uk/best-club-management-software-uk)) | ~3% on payments processed; can be passed to parents | Waiting-list automation (siblings-first rules, auto-invoice on accept) | "The most clunky and time consuming payment portal I've experienced" ([Trustpilot via search](https://uk.trustpilot.com/review/loveadmin.com)) |
| **Class Manager** | UK company, cheer-specific marketing | £0 subscription ("free forever") | UK 2.7% + 20p service charge per online payment ([classmanager.com/prices](https://classmanager.com/prices)); help docs also describe a 1% incl-VAT CM fee per Stripe/GoCardless txn ([help](https://intercom.help/classmanager/en/articles/3590947-online-payment-fees-explained)) | Free-until-you-take-payments model + built-in shop | Double-charged parents; "completely misled during the sales process" ([Capterra](https://www.capterra.com/p/183418/Class-Manager/reviews/)) |
| **Gymcatch** | UK-founded, fitness-leaning | £12.75+VAT base, bolt-ons to £30.75+VAT max ([gymcatch.com/business/pricing](https://gymcatch.com/business/pricing/)) | None from Gymcatch — only Stripe/GoCardless/GymcatchPay processor fees ([knowledge base](https://support.gymcatch.com/en/articles/4760927-does-gymcatch-charge-for-payments)) | Cancellation → automatic credit-back without admin touch | Not kids/family-centric; some businesses found "customers were relieved when they switched away" ([Capterra](https://www.capterra.com/p/189291/Gymcatch/reviews/)) |
| **Spond / Spond Club** | Norwegian, huge UK grassroots use (1.5M UK monthly users) | Free (Club Website add-on £19+VAT/mo) ([spond.com](https://www.spond.com/news-and-blog/free-app-for-sports-club-payments/), [help](https://help.spond.com/club/en/articles/58192-what-is-the-transaction-fee-in-spond-club)) | 2.5% + 20p on payments collected | Free team comms/availability app parents already know | Notification overload — "will drive you insane" with multiple kids ([justuseapp/App Store reviews](https://justuseapp.com/en/app/755596884/spond/reviews)); email addresses visible to 200+ group members ([Lewes Lenny](https://leweslenny.substack.com/p/to-spond-or-not-to-spond)) |
| **Jackrabbit Class** | US giant; partial UK payments support | From $49/mo, tiered by student count; Plus (branded app) from $93/mo + $169 setup ([jackrabbitclass.com/pricing](https://www.jackrabbitclass.com/pricing/)) | Gateway fees via partners (Adyen-based Jackrabbit Pay; UK availability provider-dependent) ([ePayments](https://www.jackrabbitclass.com/features/billing-payment-processing/epayments/)) | Depth: skills, makeups, staff time clock → payroll export | "Extremely outdated user interface… way too many buttons" ([Capterra](https://www.capterra.com/p/93349/Jackrabbit-Dance/reviews/?page=8)) |
| **iClassPro** | US; UK freephone support exists | From $129/mo per location; online booking gated to higher plans (+~$70/mo); branded app $499 + $150/mo ([iClassPro pricing](https://www.iclasspro.com/iclasspro-pricing), [MarketBox](https://www.gomarketbox.com/blog/iclasspro-pricing-and-reviews), [iclassp.ro/branded-app](https://www.iclassp.ro/branded-app)) | Pushes own card processing; users call it "overpriced" ([Capterra](https://www.capterra.com/p/127097/iClassPro/reviews/?page=2)) | Best-in-class skill tracking (whole class evaluated on one screen, auto certificates) | Forced/expensive payment processing, price increases, slower support ([Capterra](https://www.capterra.com/p/127097/iClassPro/reviews/?page=10)) |
| **Uplifter** | Canadian; minimal UK presence | Lite free → Bronze $29 → Silver $149; Gold $29 + 1% of transactions ([G2 pricing](https://www.g2.com/products/uplifter/pricing)) | 1% platform cut on Gold; processor fees on top (UK specifics unverified) | SkillPass skill tracking with parent-visible progress | Not established in UK; UK fee structure unverifiable ([Waresport roundup](https://www.waresport.com/blog/best-gymnastics-club-management-software-2026)) |
| **DanceBiz** (ThinkSmart) | AU company, active UK dance market | From £29/mo UK (US from $24.95), priced per paying *customer* count ([SoftwareAdvice UK](https://www.softwareadvice.co.uk/software/262517/dancebiz), [ThinkSmart pricing](https://www.thinksmartsoftware.com/dancebiz/pricing)) | Processor fees (Stripe/IntegraPay); no platform % found | Deep dance-school billing incl. Xero/QuickBooks, SMS | "Price is not competitive" as customer count grows ([SoftwareAdvice reviews](https://www.softwareadvice.co.uk/reviews/262517/dancebiz)) |
| **Membermeister** | Native UK, dance-school niche | Bronze £29 (≤50 students) / Silver £39 (≤150) / Gold £49 (≤300) ([SoftwareAdvice UK](https://www.softwareadvice.co.uk/software/336841/membermeister)) | Processor fees only (GoCardless/Stripe) | Radical simplicity — "anyone can use this system straight away" | Per-student price tiers; no message templates; invoices land in spam ([Capterra](https://www.capterra.com/p/140240/membermeister/reviews/)) |

Also on the radar (not torn down in full): **Bookiphy** markets directly at UK cheer classes ([bookiphy.com](https://bookiphy.com/industries/cheerleading-classes)); **Coacha** (£21.29/mo flat, has a 1-2-1 module — from our earlier internal research in `docs/multi-club-spec.md`, not re-verified this pass); **Pembee** appears frequently in UK gymnastics roundups ([Pembee blog](https://www.pembee.app/blog/the-best-gymnastics-management-software-for-2026)); **Spark Membership**, **Amilia**, **PlayPass**, **TeamLinkt** court cheer in North America ([Activity Messenger comparison](https://activitymessenger.com/blog/cheerleading-software/)).

---

## 1. ClassForKids (formerly Class4Kids) — the primary UK competitor

**Who:** Glasgow-based, building for UK kids' clubs since 2013; claims 4,500+ clubs and 1M parents ([classforkids.com via GetApp](https://www.getapp.com/customer-management-software/a/classforkids/)).

### 1.1 Pricing & fees
- One monthly licence fee, "all core features… no additional charges for adding extra venues, coaches or children" ([classforkids.com/pricing](https://www.classforkids.com/pricing/)). Capterra UK lists it "from £35/month" ([Capterra UK](https://www.capterra.co.uk/software/141287/class4kids)); ITQlick estimates $49.99–$69.99/mo ([ITQlick](https://www.itqlick.com/class4kids/pricing)). The exact ladder is not published — the pricing page says displayed transaction fees "are estimates only… confirmed by your Account Manager" based on your revenue and volume ([classforkids.io/clubs/pricing](https://classforkids.io/clubs/pricing)). That opacity is itself a sales lever for Ignyte.
- Online payments carry a processing fee of **3.1% (including Stripe's fee)**, and subscription (recurring) payments add **another 0.5%** for Stripe Billing (smart retries, payment notifications) ([help centre — subscriptions](https://help.classforkids.io/en/articles/12753012-setting-up-and-managing-subscriptions-new-version)).
- Clubs may absorb the fee or pass it to parents at checkout ([classforkids.io payments feature](https://classforkids.io/clubs/features/payments)).
- Capterra UK lists a free version/trial flag ([Capterra UK](https://www.capterra.co.uk/software/141287/class4kids)) — in practice this appears to be a demo/trial; could not verify a genuine free tier.

### 1.2 Feature set
Bookings for term/block classes; **paid or free trials** configurable "in seconds", with a pipeline that tracks whether each trialist is "ready to join a class, needs a reminder, or isn't interested" ([features](https://classforkids.io/clubs/features), [bookings](https://classforkids.io/clubs/features/bookings)). **Waiting lists** capture overflow and let the club "invite them to book in seconds" when a space opens ([features](https://classforkids.io/clubs/features)). **Registers** with per-coach permission levels (from attendance-only up to full emergency contacts), printable/exportable for coaches not on the system, and offline marking that syncs later ([register management](https://classforkids.io/clubs/features/register-management), [classforkids.com registers](https://www.classforkids.com/features/register-management/)). **Subscriptions** auto-bill via Stripe Billing with failed-payment smart retries ([help](https://help.classforkids.io/en/articles/12753012-setting-up-and-managing-subscriptions-new-version)). **Comms:** automated booking confirmations, bulk/individual messaging, trial follow-ups, waiting-list invites ([parent communication](https://classforkids.io/clubs/features/parent-communication)). **Parent app** on iOS/Android for viewing/managing bookings, check-ins, cancelled-class notices ([help — download the app](https://help.classforkids.io/en/articles/7021972-for-parents-and-carers-download-the-classforkids-app), [App Store](https://apps.apple.com/gb/app/classforkids/id1643933405)). Franchise tooling for multi-site brands ([franchise](https://www.classforkids.com/franchise/)).

### 1.3 End-user experience
- **Parent:** finds the club's branded booking page via the club's website/socials/link ("mobile-friendly… find classes, book, and pay in seconds") ([bookings](https://classforkids.io/clubs/features/bookings)). Card details saved at first booking; subscription confirmed by adding a payment method ([help — how parents book subscription classes](https://help.classforkids.io/en/articles/6745016-how-parents-and-carers-book-into-subscription-classes)). **Cancelling is the sore point: "Only the club will be able to cancel your subscription"** — the parent must find the club's contact details and ask ([help — manage your subscription](https://help.classforkids.io/en/articles/8518869-for-parents-and-carers-how-to-manage-your-subscription)).
- **Coach:** opens their register (web or app) with whatever detail level the admin granted; can download/print; offline register marking syncs when back online ([register management](https://classforkids.io/clubs/features/register-management)).
- **Admin:** sets up term/block/subscription classes, trials and waiting lists; payment chasing is largely delegated to Stripe Billing retries for subscriptions; bulk messaging for the rest ([features](https://classforkids.io/clubs/features)).

### 1.4 Integrations
Stripe only for payments (fee bundled into C4K's 3.1%). No GoCardless/direct debit, no Xero/QuickBooks, no SMS found in any documentation — comms are email/in-platform. (Stated as absence of evidence, not verified absence.)

### 1.5 Complaints & praise
- Trustpilot (≈4★): parents report being **charged after cancelling** — "kept trying to charge their account even after they cancelled with the class provider"; one was **charged monthly for 7 months after cancelling**, with "no response to emails and text messages" and "no way for them to remove card details or access customer support" ([Trustpilot](https://www.trustpilot.com/review/class4kids.co.uk), [page 2](https://www.trustpilot.com/review/class4kids.co.uk?page=2)). A club-side reviewer said it "went downhill… no customer support" ([Trustpilot](https://www.trustpilot.com/review/class4kids.co.uk)).
- Capterra (4.8★, ~99 reviews): "easy to use, looks great to customers, and has cut down admin time massively"; "the best investment" for dance school admin. Cons: "some very simple features take a very long time to implement" and "no option for half term and full term booking — it's only one or the other" ([Capterra reviews](https://www.capterra.com/p/141287/Class4Kids/reviews/)).

### 1.6 What it visibly does NOT do
No 1-2-1 private-lesson engine (class/term bookings only); no skill progression/badges anywhere in its feature pages ([features](https://www.classforkids.com/features/)); no parent self-serve subscription cancellation; no direct debit; no accounting export; no coach-pay/payroll export; pricing withheld until a sales call.

---

## 2. LoveAdmin

**Who:** UK membership-management platform spanning sports clubs, class providers, Scouts, membership orgs ([loveadmin.com](https://loveadmin.com/)).

### 2.1 Pricing & fees
- Published plans: **Sports Clubs £16/mo + £195 setup; Activity Providers £28/mo + £295 setup; Membership Organisations £16/mo + £195 setup**; Enterprise custom ([loveadmin.com/pricing](https://loveadmin.com/pricing/) as summarised by [ClubPilot](https://clubpilot.co.uk/best-club-management-software-uk)).
- Standard plans carry **~3% transaction fee** on payments processed through the platform, with the option to pass it to members "just like a booking fee" ([ClubPilot](https://clubpilot.co.uk/best-club-management-software-uk), [Capterra UK](https://www.capterra.co.uk/software/182986/loveadmin)). Note: a search summary claimed a 2026 rebrand to "Thrive4" — **this could not be verified** and is omitted from conclusions.

### 2.2 Feature set
Branded, filterable public timetables (by location, coach, age) with photos/videos ([calendar feature](https://loveadmin.com/software/features/calendar/)); booking & registration ([booking feature](https://loveadmin.com/software/features/booking-registration/)); one-touch **attendance registers** with statuses attended/absent/ill/injured and configurable columns (consents, guardian details) ([how to record attendance](https://help.loveadmin.com/how-to-record-attendance)); **waiting lists with automated invite rules — first-in-first-out, siblings-first ("related parties"), or first-come — raising an invoice automatically on acceptance** ([5 automated workflows](https://loveadmin.com/management/5-admin-workflows-that-can-be-fully-automated-today/)); memberships paid annually, rolling, or by instalment; trial follow-up emails; the **JoinIn app** for parents (bookings, payments, real-time updates, personal info management) ([JoinIn](https://loveadmin.com/software/features/joinin-online-app/)).

### 2.3 End-user experience
- **Parent:** uses JoinIn (web/app) with one-time login; books sessions, pays fees, joins waiting lists, gets real-time alerts ([JoinIn](https://loveadmin.com/software/features/joinin-online-app/)). Bank statements show "LoveAdmin / Pay Here Ltd", which confuses some parents ([Zendesk](https://loveadmin.zendesk.com/hc/en-us/articles/360019238457-What-is-the-LoveAdmin-Pay-Here-Ltd-reference-on-your-bank-statement)). Reviewers say some customers "find it difficult to sign up for sessions, particularly when needing to add other family members" ([Capterra](https://www.capterra.com/p/182986/LoveAdmin/reviews/)).
- **Coach:** tap-to-mark registers on mobile work well, but "doing anything more advanced is a bit clunky" on a phone ([Capterra](https://www.capterra.com/p/182986/LoveAdmin/reviews/)).
- **Admin:** builds timetables, sets waiting-list automation, edits sessions and notifies attendees with credit/refund options; payment chasing is automated via GoCardless collection and invoice-on-acceptance flows ([5 automated workflows](https://loveadmin.com/management/5-admin-workflows-that-can-be-fully-automated-today/), [GoCardless partner page](https://gocardless.com/partners/love-admin)).

### 2.4 Integrations
**GoCardless** direct debit is deeply integrated ("set up customers to pay by GoCardless and manage payments all from within LoveAdmin") ([GoCardless partner page](https://gocardless.com/partners/love-admin)); PayPal historically supported ([Zendesk](https://loveadmin.zendesk.com/hc/en-us/articles/360017847532-PayPal-and-GoCardless-Help)). **No direct Xero integration found** — reconciliation happens via GoCardless↔Xero, not LoveAdmin itself (unverified beyond that).

### 2.5 Complaints & praise
- Trustpilot ≈4★ from ~162 reviews ([Trustpilot](https://uk.trustpilot.com/review/loveadmin.com)). Praise: "everything in our Club runs smoothly… The Love Admin team can't do enough for you! Customer service at its finest"; a drama school "found LoveAdmin fantastic" from enquiry through setup.
- Complaints: "the most clunky and time consuming payment portal" a reviewer had experienced; "Awful experience… wished they'd checked Trustpilot before signing up… charged monthly fees even though they hadn't used the system yet"; the V1→V2 migration "had its challenges and still has"; support felt "robotic" to some ([Trustpilot](https://uk.trustpilot.com/review/loveadmin.com), [Capterra](https://www.capterra.com/p/182986/LoveAdmin/reviews/)).

### 2.6 What it visibly does NOT do
No 1-2-1 privates engine; no skill progression/badges; setup fees (£195–£295) sting small clubs; ~3% platform fee on top of monthly cost; heavyweight onboarding for a 60-athlete cheer club.

---

## 3. Class Manager (classmanager.com)

**Who:** UK company selling to dance schools and explicitly to cheer ("Cheer Dance Management Software" landing page: [classmanager.com/cheer-class-management-software](https://classmanager.com/cheer-class-management-software)).

### 3.1 Pricing & fees
- Current model: **no monthly subscription at all** — "FREE class management software, no monthly subscription" ([classmanager.com/prices](https://classmanager.com/prices), [UK page](https://classmanager.com/gb)). Revenue comes from a **service charge on online payments: UK 2.7% + 20p** (US 3.1% + 30¢) ([classmanager.com/prices](https://classmanager.com/prices)). "You pay nothing on the months you don't take payments" — explicitly marketed for summer/Christmas breaks.
- Their help centre separately documents a **1% (incl. VAT) Class Manager fee per Stripe transaction and per GoCardless transaction** on top of processor fees ([Online Payment Fees Explained](https://intercom.help/classmanager/en/articles/3590947-online-payment-fees-explained), [help.classmanager.com/en/stripe](https://help.classmanager.com/en/stripe)). The two pages likely reflect old vs new pricing; **which applies to a given club could not be verified** — worth a mystery-shop.

### 3.2 Feature set
Classes and scheduling, registers/attendance, recurring billing and invoicing, discounts, parent portal, communications, built-in **shop** for uniforms/merch ([shop feature](https://classmanager.com/features/shop)), **Xero invoice sync** (manual "sync" button; drafts excluded; no auto-update after export) ([Xero integration help](https://help.classmanager.com/en/getting-started-with-xero-integration-class-manager-help-center)), payment methods incl. Stripe card and GoCardless direct debit ([available payment methods](https://help.classmanager.com/en/available-payment-methods-in-class-manager)).

### 3.3 End-user experience
- **Parent:** registers via the club's portal, gets invoices, pays online by card/DD; "ease for parents to sign up and make payments" is echoed in reviews, but so are double-charges (below).
- **Coach:** mobile registers/attendance (documented in billing/class help articles; thin public detail on a dedicated coach app).
- **Admin:** sets up classes and billing runs; invoice-first workflow (raise, send, auto-collect); Xero export for the accountant; "for as little as £25 per day" of management time saved is their marketing claim ([classmanager.com blog](https://classmanager.com/blog/save-time-money-and-stress-with-dance-studio-management-software)).

### 3.4 Integrations
Stripe, GoCardless, Xero (one-way manual sync). No SMS found; no Zoom/calendar sync found.

### 3.5 Complaints & praise
- Capterra 4.8★ from ~175 reviews ([Capterra](https://www.capterra.com/p/183418/Class-Manager/reviews)). Praise: "dependable, adaptable, with great customer service"; "very well priced compared to other software"; team "open to feedback and regularly add new features".
- Complaints: "Payments are routinely mishandled — on multiple occasions, customers have been charged twice, leading to complaints and frustration from parents… refund requests"; "completely misled during the sales process, with features that were promised either not existing or being so poorly implemented that they are unusable"; wants for "deeper reporting, easier navigation" ([Capterra reviews](https://www.capterra.com/p/183418/Class-Manager/reviews/)).

### 3.6 What it visibly does NOT do
No skill progression tracking found; no real 1-2-1 privates engine; no native parent app in stores (web portal); the "free" model means **every pound a club collects online is taxed at 2.7%+20p** — a busy club pays far more than a £29 flat fee; and months with payments are never free.

---

## 4. Gymcatch

**Who:** UK-founded booking platform for fitness instructors, boutique studios and gyms; used by some class businesses ([gymcatch.com](https://gymcatch.com/business/gymsandstudios/)).

### 4.1 Pricing & fees
- **£12.75+VAT/mo** base after one free month; optional bolt-ons (each ~£4/$4) up to a hard ceiling of **£30.75+VAT/mo with everything on**; add/remove bolt-ons anytime; cancel anytime ([pricing](https://gymcatch.com/business/pricing/), [knowledge base](https://support.gymcatch.com/en/articles/4760996-how-much-does-gymcatch-cost-is-pricing-fixed-can-i-cancel-at-any-time)). Cost does not scale with team members, customers or bookings ([Capterra](https://www.capterra.com/p/189291/Gymcatch/)).
- **"Gymcatch doesn't take any booking or commission fee"** — the only per-transaction cost is the processor's (Stripe, GoCardless, or GymcatchPay/Unipaas) ([does Gymcatch charge for payments?](https://support.gymcatch.com/en/articles/4760927-does-gymcatch-charge-for-payments), [other fees](https://support.gymcatch.com/en/articles/4760928-do-you-charge-any-other-fees)). This is the closest fee philosophy to Ignyte's "keep 100%".

### 4.2 Feature set
Classes, courses, **1-2-1 appointments** (advertise availability or schedule team members; repeats schedulable up to a year ahead) ([appointments how-to](https://support.gymcatch.com/en/articles/5089339-how-do-i-create-appointments-on-gymcatch)); memberships, bundles/passes; **wait lists**; booking open/close windows, cancellation policies with **auto-credit-backs**; waivers/PAR-Q capture; customer iOS/Android app + website embed; Zoom integration; calendar sync ([features](https://gymcatch.com/business/features/), [Capterra](https://www.capterra.com/p/189291/Gymcatch/)).

### 4.3 End-user experience
- **Customer (adult-centric):** downloads the Gymcatch app or uses the web embed, finds the business, books and pays; can self-cancel inside policy and is **auto-refunded/credited "without intervention"** — a reviewer highlight ([Capterra reviews](https://www.capterra.com/p/189291/Gymcatch/reviews/)).
- **Instructor/coach:** manages schedule and attendance from the app; one reviewer wished they could "manually delete bookings from their phone rather than having to use a laptop" ([Capterra](https://www.capterra.com/p/189291/Gymcatch/reviews/)).
- **Admin:** 8-step self-serve setup ([getting started](https://support.gymcatch.com/en/articles/5432692-8-steps-to-getting-started-on-gymcatch)); no account manager required.

### 4.4 Integrations
Stripe, GoCardless, GymcatchPay (Unipaas), Zoom, website embeds, calendars ([taking payments](https://gymcatch.com/business/taking-payments/)).

### 4.5 Complaints & praise
Capterra 4.9★ from ~222 reviews: "Amazing Booking system… very easy to use"; "visual, bright, modern and professional"; prompt support. Negatives: "did not suit their business and customers were relieved when they switched"; one had "weekly complaints about Gymcatch" even though setup was confirmed correct ([Capterra reviews](https://www.capterra.com/p/189291/Gymcatch/reviews/)).

### 4.6 What it visibly does NOT do
Built for adult fitness consumers: **no child/family athlete model, no safeguarding fields, no trials pipeline, no term invoicing, no skill tracking, no coach-pay reporting**; documentation shows no dependant-booking flow (absence of evidence — could not verify any family feature).

---

## 5. Spond & Spond Club

**Who:** Norwegian free team-management app; "more than 1.5 million people across the UK use Spond every month — from grassroots sports clubs to community dance troupes" ([spond.com](https://www.spond.com/news-and-blog/free-app-for-sports-club-payments/)). Many UK cheer squads run comms on it.

### 5.1 Pricing & fees
- Core app and Spond Club admin portal: **free, no ads** ([spond.com](https://www.spond.com/news-and-blog/free-app-for-sports-club-payments/)). Payments collected through Spond incur **2.5% + 20p** (Stripe processing) ([help — transaction fee](https://help.spond.com/club/en/articles/58192-what-is-the-transaction-fee-in-spond-club), [VAT and fees](https://help.spond.com/club/en/articles/600536-vat-and-fees-what-clubs-need-to-know)); clubs choose whether to bake the fee into the price or line-item it per member. Club Website add-on **£19+VAT/mo** ([help](https://help.spond.com/club/en/articles/600536-vat-and-fees-what-clubs-need-to-know)).

### 5.2 Feature set
Groups/subgroups, events with availability (accept/decline), attendance, group + private messaging, polls, guardian accounts acting for children, payment requests, **subscription payments** for recurring subs tied to group/member type ([help — subscriptions](https://help.spond.com/club/en/articles/316473-how-to-set-up-subscription-payments-for-annual-fees-and-other-items-excluding-nif-in-spond-club)), manual invoice generation for offline payers ([help — invoices](https://help.spond.com/club/en/articles/25809-generate-invoice-and-manual-payment-registration-in-spond-club)), **xlsx payment exports emailed per club account** ([help — exports](https://help.spond.com/club/en/articles/197545-managing-club-accounts-and-payment-exports-in-spond-club)), bespoke payment reports (requests, settlements, outstanding) ([help — payments](https://help.spond.com/club/en/articles/177554-payments-in-spond-club)), fundraising tools, volunteer sign-ups.

### 5.3 End-user experience
- **Parent:** joins by invite link/code (there is **no public discovery/booking marketplace** — you must already be in the club); responds to events for their child, chats, and pays requests in-app with guardian controls and instalment options ([spond.com payments](https://www.spond.com/payments/)).
- **Coach:** creates events for the squad, sees who's coming, marks attendance, messages parents — all free on their phone.
- **Admin:** Spond Club web portal holds the member registry; sets up payment requests/subscriptions; downloads xlsx exports and payment reports; invoices for the few who can't pay online ([help — Spond Club](https://help.spond.com/club/en/collections/607446-club)).

### 5.4 Integrations
Stripe under the hood; no Xero/accounting, no GoCardless, no SMS (push/email built in). Payment data leaves via xlsx export.

### 5.5 Complaints & praise
- Praise: free, "fantastic feedback from parents about its ease of use" ([instapv review](https://instapv.co.uk/spond-app/)); polls and availability loved by volunteer-run clubs.
- Complaints: **notification overload** — "when you have multiple kids or multiple teams per kid, the non-stop notifications with no context about where the messages are coming from will drive you insane" ([justuseapp](https://justuseapp.com/en/app/755596884/spond/reviews)); duplicate notifications 5–30 minutes after reading ([justuseapp](https://justuseapp.com/en/app/755596884/spond/reviews)); privacy alarm at "200+ people have access to your email address" in big groups, including junior clubs ([To Spond or Not to Spond — Lewes Lenny](https://leweslenny.substack.com/p/to-spond-or-not-to-spond)).

### 5.6 What it visibly does NOT do
No public class booking/trials for prospective members; no term/class registers with notes; no skill tracking; no memberships-with-benefits model; no coach-pay; no accounting integration. It is a comms+collections layer, not a club back office — which is exactly why clubs pair it with (or should replace it with) something like Ignyte.

---

## 6. Jackrabbit Class (US giant)

**Who:** US cloud suite for gymnastics/dance/swim/cheer, 7,000+ programs worldwide ([jackrabbitclass.com](https://www.jackrabbitclass.com/)).

### 6.1 Pricing & fees
- **Tiered by total student count, from $49/mo**; **Jackrabbit Plus** (adds custom-branded parent app) from **$93/mo** + one-time **$169 setup + app-store fees**; standard plan has no contracts or setup fees; **PayPath** option: $0 subscription, replaced by a "technology fee" passed to parents ([jackrabbitclass.com/pricing](https://www.jackrabbitclass.com/pricing/), [Nerdisa summary](https://nerdisa.com/jackrabbitclass/)).
- Payments via partner gateways; **Jackrabbit Pay** (Adyen) covers US/CA/AU/NZ cards — **UK ePayments depend on which legacy provider you choose**; 3DS2 support is UK-specific ([ePayments](https://www.jackrabbitclass.com/features/billing-payment-processing/epayments/), [payment partner help](https://help.jackrabbitclass.com/help/contact-a-payment-partner)). Practical upshot: usable in the UK but clearly US-first, priced in USD.

### 6.2 Feature set
Online registration, enrolment, tuition billing/autopay, parent portal + branded app (Plus), waitlists, makeup classes, skills/levels tracking, deep reporting, **staff portal with time clock: staff hours by department export to Express Payroll, QuickBooks Desktop (IIF) or Excel/CSV** ([time clock](https://www.jackrabbitclass.com/features/time-clock/), [export help](https://help.jackrabbitclass.com/help/manage-time-clock-overview)) — the only competitor here with a genuine coach-pay export story.

### 6.3 End-user experience
- **Parent:** portal/app shows schedules, balances, posted charges; enrols per-child per-class — reviewers say "parents having to enroll in things individually, the app being slow… lots of complaints from parents about it" ([Capterra — Jackrabbit Dance reviews](https://www.capterra.com/p/93349/Jackrabbit-Dance/reviews/?page=5)).
- **Coach:** staff portal for schedules, attendance, skills marking, clock-in/out.
- **Admin:** immensely capable but "hampered by an extremely outdated user interface that makes training very difficult… way too many buttons" ([Capterra](https://www.capterra.com/p/93349/Jackrabbit-Dance/reviews/?page=8)); parent-portal messages arrive by email rather than a unified inbox ([Capterra](https://www.capterra.com/p/172591/Jackrabbit-Gymnastics/reviews/?page=4)).

### 6.4 Integrations
Partner payment gateways/Adyen, QuickBooks Desktop payroll export, Express Payroll, email automation. No Xero, no GoCardless.

### 6.5 Complaints & praise
Praise: parent/staff portals "save front desk staff time"; billing power. Complaints: dated UI, steep learning curve, slow/clunky parent app, per-student pricing creep as you grow ([Capterra review pages](https://www.capterra.com/p/93349/Jackrabbit-Dance/reviews/?page=8), [Jackrabbit Gymnastics reviews](https://www.capterra.ae/reviews/172591/jackrabbit-gymnastics)).

### 6.6 What it visibly does NOT do (for a small UK club)
GBP-native pricing and UK direct debit; simple 1-hour self-serve setup; a price a 60-athlete club can justify (student-count tiers punish growth); modern UI.

---

## 7. iClassPro (US giant)

**Who:** US suite for gymnastics, cheer, swim, dance ([iclasspro.com](https://www.iclasspro.com/)).

### 7.1 Pricing & fees
- From **$129/mo per location** (Capterra lists $139 start), no long-term commitment ([iClassPro pricing](https://www.iclasspro.com/iclasspro-pricing), [Capterra pricing](https://www.capterra.com/p/127097/iClassPro/pricing/)). In 2024 online booking was pulled out of the base "signature" plan into higher tiers, effectively **+~$70/mo per location** for the feature small clubs need most ([MarketBox](https://www.gomarketbox.com/blog/iclasspro-pricing-and-reviews)).
- Branded app: reported **$499 setup + $150/mo** (another source: $999 + $99/mo; both third-party — treat the exact figure as unverified) ([iclassp.ro/branded-app](https://www.iclassp.ro/branded-app), [MarketBox](https://www.gomarketbox.com/blog/iclasspro-pricing-and-reviews)).
- Reviewers "complained about being forced into using iClassPro's credit card processing, which they find overpriced… and mention price increases" ([Capterra](https://www.capterra.com/p/127097/iClassPro/reviews/?page=2)). UK freephone support line exists (+44 800 058 4011) ([SoftwareWorld](https://www.softwareworld.co/software/iclasspro-reviews/)), but the product is USD-priced and US-processing-centric.

### 7.2 Feature set
Classes, camps, parties, POS, appointments, business intelligence, automations; **skill tracking is the crown jewel: evaluate an entire class on one screen, generate completion certificates, email custom progress reports to parents** ([gymnastics features](https://www.iclasspro.com/gymnastics-software-features)); parent self-service portal + branded app for schedules, attendance, payments ([class management](https://www.iclasspro.com/class-management)).

### 7.3 End-user experience
- **Parent:** portal/app to enrol, pay before due dates, track attendance and skill progress; push notifications.
- **Coach:** tablet-friendly class evaluation screens; certificates auto-generated.
- **Admin:** rich but heavyweight; setup challenges and "rigid" first-line support reported ([Capterra](https://www.capterra.ae/reviews/127097/iclasspro)).

### 7.4 Integrations
Own payments stack (compulsory per reviewers), email; no Xero/GoCardless.

### 7.5 Complaints & praise
92% positive sentiment across ~477 reviews; "no other class management system offers as many features while keeping prices so reasonable" (long-term fans) vs a 10-year customer reporting "customer service has declined, with delayed responses over a week", plus "more constant problems with the program being down" ([Capterra reviews](https://www.capterra.com/p/127097/iClassPro/reviews/?page=10)).

### 7.6 What it visibly does NOT do (for a small UK club)
£/GBP pricing, direct debit, affordable entry (booking gated to ~$199/mo tiers), lightweight setup. Skill tracking depth is the thing to study, not the packaging.

---

## 8. Uplifter

**Who:** Canadian membership/skill-development platform (skating, gymnastics origins) ([uplifterinc.com](https://www.uplifterinc.com/top-sports/gymnastics)).

- **Pricing:** Lite free plan; Bronze **$29/mo**; Silver **$149/mo**; Gold **$29/mo + 1% of transactions**; no setup or cancellation fees ([G2 pricing](https://www.g2.com/products/uplifter/pricing), [Capterra](https://www.capterra.com/p/151182/Uplifter/)). Currency/UK availability of these plans **unverified** — marketing and roundups position it for North American clubs ([Waresport](https://www.waresport.com/blog/best-gymnastics-club-management-software-2026)); UK gymnastics roundups recommend Pembee/LoveAdmin instead ([Pembee](https://www.pembee.app/blog/the-best-gymnastics-management-software-for-2026)).
- **Features:** class/camp registration, scheduling, payments, attendance, **built-in skill tracking with real-time progress and personalised instructor feedback** ([uplifterinc.com](https://www.uplifterinc.com/top-sports/gymnastics)).
- **Verdict for UK:** low direct threat today; relevant only as proof that "skill tracking + registration" is a winning combo in club sports. Include in watchlist, not battlecards.

---

## 9. DanceBiz (ThinkSmart Software)

**Who:** ThinkSmart's dance-school product (siblings: MusicBiz, ClassBiz); Australian company with UK sales presence ([thinksmartsoftware.com](https://www.thinksmartsoftware.com/dancebiz/home)).

### 9.1 Pricing & fees
From **£29/mo UK** ([SoftwareAdvice UK](https://www.softwareadvice.co.uk/software/262517/dancebiz)) / **$24.95 US start** ([Capterra](https://www.capterra.com/p/131208/DanceBiz/)); **charged by the number of *customers* (paying families) on the account, not students**; monthly rolling or cheaper annual plan; free trial without card; unlimited staff logins ([ThinkSmart pricing](https://www.thinksmartsoftware.com/dancebiz/pricing)).

### 9.2 Feature set & flows
Class management, enrolment, attendance tracking, billing/invoicing including class-count "tracking packages" that invoice per attendance, text-message (SMS) and email comms, online customer portal, apps; time-tracking and analytics ([ThinkSmart features](https://www.thinksmartsoftware.com/dancebiz/features), [GetApp UK](https://www.getapp.co.uk/software/2048370/dancebiz-1)). Admin experience per a UK school: "admin hours massively reduced… fees are issued promptly and enrolment changes are picked up right away" ([SoftwareAdvice UK reviews](https://www.softwareadvice.co.uk/reviews/262517/dancebiz)).

### 9.3 Integrations
QuickBooks, **Xero**, Stripe, Zoom, IntegraPay "and more" ([GetApp UK](https://www.getapp.co.uk/software/2048370/dancebiz-1)).

### 9.4 Complaints & praise
Praise: support "fast, friendly and accurate… they really listen to their customers"; "excellent value for money". Complaint: "price is not competitive" for some (customer-count pricing grows with the club) ([SoftwareAdvice UK](https://www.softwareadvice.co.uk/reviews/262517/dancebiz)).

### 9.5 What it visibly does NOT do
No cheer-specific skill journeys/badging found; dated web-first UX (no strong native-app story found); per-customer pricing penalises growth; no free tier.

---

## 10. Membermeister

**Who:** UK software built for dance schools ([membermeister.com/dance](https://www.membermeister.com/dance)).

### 10.1 Pricing & fees
**Bronze £29/mo (≤50 students), Silver £39 (≤150), Gold £49 (≤300)**; free trial, no free tier ([SoftwareAdvice UK](https://www.softwareadvice.co.uk/software/336841/membermeister), [GetApp UK](https://www.getapp.co.uk/software/115343/membermeister)). No platform transaction fee found — payments go through the club's own **GoCardless** (DD, auto-reconciling invoices) or **Stripe** (card/Apple Pay/Google Pay) ([features](https://membermeister.com/features)).

### 10.2 Feature set & flows
Customisable online registration form that writes straight into the database; **enrol a new student to a class or waiting list "with one click"**; class registers printed or marked on mobile; invoicing with automatic reconciliation; email comms; SMS messaging listed among features ([features](https://membermeister.com/features), [GetApp UK](https://www.getapp.co.uk/software/115343/membermeister)). Web app only (runs as desktop web app; no store-listed parent app found — flagged as absence of evidence) ([WebCatalog listing](https://webcatalog.io/en/apps/membermeister)).

### 10.3 Complaints & praise
- Praise: "You still cannot beat the simplicity of the system and anyone can use this system straight away"; "very quick to get back to you… the other very well known systems I have used alongside Membermeister have not been so quick" ([SoftwareAdvice UK](https://www.softwareadvice.co.uk/software/336841/membermeister)).
- Complaints (all [Capterra reviews](https://www.capterra.com/p/140240/membermeister/reviews/)): wished it would "record credits for cancelled lessons and auto deduct from next invoice run"; "no templates for messages"; "system can be slightly slow when loading student details"; "emails and invoices landed in spam/junk mail folders"; navigation resets ("would be good to have Next buttons for students and classes").

### 10.4 What it visibly does NOT do
No parent self-booking of individual sessions (admin-led enrolment); no trials pipeline; no skill tracking; no parent app; per-student tiering means a growing club pays more for the same features.

---

## Where Ignyte wins / where we're behind

Ordered by what a small UK cheer/dance club owner cares about most (money, time, parent goodwill, growth — in that order).

### Where Ignyte wins

1. **The club keeps 100% of every payment.** Every UK rival taxes revenue: ClassForKids ~3.1% (+0.5% on subscriptions), LoveAdmin ~3%, Class Manager 2.7%+20p, Spond 2.5%+20p. A club turning over £3,000/mo hands £75–£100/mo to its software before the licence — more than Ignyte's entire £29 Club tier. Gymcatch is the only rival with the same philosophy, and it can't model children.
2. **A real 1-2-1 privates engine.** Parent-bookable 30-min privates, N simultaneous spaces per slot, coach-joined bookability, weekly recurrence until cancelled, late-cancel windows. Nothing in the UK price band does this: ClassForKids has no privates engine, Class Manager and Membermeister are class/enrolment-led, LoveAdmin is sessions/memberships, Spond is invite-only comms. Only iClassPro ($129–199+/mo) and Jackrabbit ($49+/mo, USD, dated UI) get close.
3. **Skill progression journeys visible to parents.** In the UK set: ClassForKids none, Class Manager none found, LoveAdmin none, Membermeister none, DanceBiz none found. Parents only get this from US suites (iClassPro certificates, Jackrabbit skills, Uplifter SkillPass). For cheer (tumbling skill ladders) this is emotionally sticky and a genuine differentiator at £29.
4. **Parents can cancel by themselves.** ClassForKids' own help centre says "Only the club will be able to cancel your subscription", and its Trustpilot 1-star reviews are dominated by parents charged for months after cancelling, unable to remove card details. Ignyte's "anyone can cancel any time (late-cancel still payable)" plus self-serve card management directly weaponises the competitor's worst press.
5. **Waiting lists that work themselves.** Freed spaces auto-offered oldest-first with coach preference, 24 h expiry, roll to next family. ClassForKids requires the admin to notice and invite; LoveAdmin has strong invite rules but behind a £28/mo + £295 setup + 3% wall.
6. **Excel coach-pay export.** Only Jackrabbit (US, QuickBooks Desktop/Express Payroll) has payroll exports. No UK rival helps a club owner pay self-employed coaches — a monthly ritual every cheer club does in a spreadsheet today.
7. **Genuinely free tier + flat £29.** Rivals' entry points: ClassForKids ~£35 + fees, Membermeister £29 capped at 50 students, DanceBiz £29 scaling with customers, LoveAdmin £16–£28 + setup + 3%. Ignyte's flat price with no per-student maths is the simplest offer in the market; Class Manager's "free" is really a 2.7%+20p revenue tax.
8. **Safeguarding-first data model.** Under-18s never get logins; single child record with medical/consent data owned by the parent. Spond's model (child data spread across big groups, emails visible to 200+ members) is a documented parental worry.
9. **Installable, offline-capable PWA with no app-store tax.** Jackrabbit charges $169 + store fees, iClassPro ~$499 + $150/mo for branded apps. (Caveat: ClassForKids ships free store apps with offline registers — see behind-list item 6.)

### Where we're behind

1. **Automated payment collection.** Ignyte invoices, but rivals *collect*: ClassForKids auto-bills subscriptions via Stripe Billing with smart retries; Class Manager, LoveAdmin and Membermeister run GoCardless direct debit with auto-reconciliation. Until Ignyte offers "connect your own Stripe/GoCardless and auto-collect" (still keeping 100% minus processor fees), admins are chasing bank transfers by hand — the #1 admin pain in every review corpus.
2. **Trials pipeline.** ClassForKids lets clubs sell free/paid trials and tracks each trialist (ready to join / needs reminder / not interested); LoveAdmin sends automated post-trial follow-ups. Trials are the growth engine of every cheer club; Ignyte has no trial concept yet.
3. **Broadcast comms (email templates + SMS).** DanceBiz and Membermeister list SMS; ClassForKids does bulk messaging; Membermeister reviewers even complain about missing message *templates* — table stakes. Ignyte currently has transactional notifications only.
4. **Accounting handoff.** Class Manager syncs invoices to Xero; DanceBiz integrates Xero and QuickBooks. Ignyte's invoicing has no Xero export.
5. **Public timetable/booking page polish.** LoveAdmin's filterable branded timetables (photos, video, filter by coach/age/location) and ClassForKids' "book in seconds" pages are the shop window. Ignyte's public club portal needs to sell classes as well as manage them.
6. **App-store presence.** ClassForKids, Gymcatch, Spond and Jackrabbit Plus all have store apps; parents in Facebook groups equate "has an app" with "is legit". The PWA mitigates cost but not discoverability.
7. **Waivers/consent form builder.** Gymcatch (waivers/PAR-Q) and LoveAdmin (consents on registers) capture custom forms at signup; cheer clubs need photo consent + medical waivers on file.
8. **Reporting/BI depth.** Jackrabbit and iClassPro ship dashboards (enrolment trends, revenue per programme). Ignyte's reporting is thin beyond registers and coach-pay.
9. **Merch/shop.** Class Manager has a built-in shop — uniforms, bows and competition fees are real cheer revenue Ignyte doesn't touch.
10. **Multi-location/franchise tooling.** ClassForKids has a franchise product; iClassPro prices per location. Not urgent for the target segment, already on the multi-club roadmap.

---

## Steal these ideas

1. **Trial status pipeline** (ClassForKids): every trialist carries a state — booked → attended → "ready to join" / "send reminder" / "not interested" — with conversion stats per class. Add to Ignyte's waiting-list/enquiry flow.
2. **Waiting-list invite rules incl. siblings-first, with auto-invoice on acceptance** (LoveAdmin): our auto-offer engine already exists; add a "related parties first" toggle and raise the invoice the moment a family accepts.
3. **"Absorb or pass on the processing fee" toggle at checkout** (ClassForKids, LoveAdmin): when Ignyte adds card collection via the club's own Stripe, let the club choose who pays Stripe's ~1.5% + 20p — and advertise "0% platform fee" beside it.
4. **Register statuses beyond present/absent — ill/injured with notes** (LoveAdmin): cheap to add to our registers and valuable for cheer safeguarding/return-to-training.
5. **Auto-credit on in-policy cancellation, zero admin touch** (Gymcatch): reviewers single out "clients cancel and are auto-refunded without intervention". Map to Ignyte as automatic makeup-credit issuance when a cancellation beats the notice window.
6. **Whole-class skill evaluation on one screen + auto certificates emailed to parents** (iClassPro): our skill journeys have the data; a coach-side "mark the whole squad" grid and a PDF certificate on level-up would match a $129/mo feature at £29.
7. **Time-clock/department-style coach-pay breakdown** (Jackrabbit): extend the Excel coach-pay export with per-class-type "departments" (privates vs squad sessions) and an accountant-ready CSV shape.
8. **xlsx payment export emailed per account + guardian instalments** (Spond): low-effort parity for treasurer-friendly exports; instalment plans for competition fees are a cheer-specific win.
9. **Smart retries + parent payment-failure notifications** (ClassForKids via Stripe Billing): when autopay lands, use Stripe Billing's retry machinery rather than reinventing dunning.
10. **"Pay nothing in months you take nothing" marketing** (Class Manager): Ignyte's free tier + flat £29 can be framed the same way for seasonal clubs — "summer break costs you £0".
11. **One-click enrol from enquiry form** (Membermeister): public enquiry/registration form that lands in a queue where admin enrols or waitlists in one click.
12. **Anti-Spond notification design** (lesson from Spond's reviews): per-club labels on every notification, digest batching, and per-child muting — make "we won't spam you like Spond" a feature.
13. **Filterable public timetable with media** (LoveAdmin): photos/video on the class cards, filter by coach/age/day, on our public `/c/{slug}` portal.

---

*Compiled 2026-08-01 from vendor sites, help centres and review platforms as linked above. All quotes are as rendered by the cited source pages at retrieval time; review-site content changes frequently.*
