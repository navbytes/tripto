# Tripto — Build & Handoff Specification

**Prepared for:** the engineer/agent implementing v1
**Prepared by:** design + architecture (prior planning session)
**Status:** ready to build. Two interactive React mockups accompany this document (`TripApp.jsx` = core screens, `TripAppFamily.jsx` = family screens). Open them to see the intended look, motion, and interaction; this document is the source of truth for behavior, data, and scope.

---

## 0. How to read this document

This is a handoff, not a suggestion. Where a decision is made, it is stated as a decision with its rationale so you can override it intelligently if reality demands — not re-litigate it from zero. Sections are ordered so you can build in roughly the order they appear.

- **§1 Product brief** — what we're building and for whom. Read once.
- **§2 Scope & phasing** — what's in v1 vs. deferred. The most important section for planning.
- **§3 Architecture** — stack, data model, API surface, sync model.
- **§4 Screen specs** — screen-by-screen behavior, tied to the mockups.
- **§5 Family/collaboration** — roles, sharing, the no-app link.
- **§6 Design system** — tokens, type, components, so the build matches the mockups.
- **§7 Non-functional** — offline, performance, accessibility, privacy.
- **§8 Milestones** — suggested delivery slices with acceptance criteria.
- **§9 Open questions** — decisions we deferred, flagged for you or the product owner.

---

## 1. Product brief

**One-liner.** A mobile-first trip organizer that turns scattered bookings into one shared, at-a-glance itinerary — built for multi-stop leisure travel and for families/groups, not solo business trips.

**Primary users.**
- **The organizer** — plans the trip, carries the mental load, wants control.
- **Companions** — co-parent/co-traveler; contribute and view, edit their own things.
- **Viewers** — kids and low-tech grandparents; read-only, possibly never install the app.

**The wedge.** Existing tools are weak at *group coordination* and at *dense multi-person itineraries*. That's where we win. Solo-traveler polish is table stakes; family/group experience is the differentiator.

**The moat (sequenced, not day one).** "Forward your confirmation email and we build the itinerary for you." This is what creates retention. It is **not** in v1 — see §2 — because email parsing is a rabbit hole that shouldn't block launch.

---

## 2. Scope & phasing — READ THIS FIRST

The single biggest risk to this project is trying to build the moat (email import, live flight status, booking integrations) before proving people will organize trips here at all. Resist it. Ship the organizer first.

### v1 — "The best manual trip organizer" (build this now)
- Create/edit/delete trips.
- Manual add of itinerary items: flight, stay, activity, food.
- Day-grouped itinerary timeline (the core screen).
- Booking/reservation detail view (boarding-pass style).
- Trip list home (upcoming/past).
- **Collaboration:** invite by email, three roles, shared editing.
- **The no-app view-only web link.** (High leverage, low cost, also a growth loop. Keep it in v1.)
- **Family essentials:** per-person "Just mine" filter, shared assignable packing/to-do list.
- Offline read + optimistic local edits.
- Add-to-calendar + directions handoff (uses OS, cheap).

### v1.5 — "The magic" (fast-follow, after v1 retains)
- Email-forwarding parser for the top ~10–15 airlines/hotel chains (covers the majority of volume; do not attempt the long tail).
- Real-time flight status via **one** aggregator API.
- Suggestions from Companions (propose-without-editing-master).

### v2 — "Depth" (later)
- Broader booking integrations.
- Expense tracking/splitting (see §5.5 — family default is *tracking*, friends default is *split*).
- Document vault (passports, visas, insurance).
- Maps view with routing between stops.
- Discovery/recommendations.

**Explicitly out of scope for now:** in-app booking/payments, chat/messaging (use the platform's; don't rebuild WhatsApp), AI trip generation, social feed.

---

## 3. Architecture

> **Scope & cost posture:** v1 targets the **Apple ecosystem only** (iPhone first; iPad and Mac as low-cost fast-follows from the same codebase), and is tuned to keep **running cost near zero at low usage** with growth proportional to real users. Focusing on one platform removes the cross-client coordination burden entirely, and Apple-native features (Sign in with Apple, MapKit, Wallet, Calendar, Live Activities) let us replace several paid backend services with free OS capabilities. The data model (§3.3) and API contract (§3.4) remain the fixed points; keeping them client-agnostic means an Android or web client can be added later without backend rework, but none is built now.
>
> **A note on where cost actually lives:** running cost is driven by the **backend** (database, auth, realtime, storage) scaling with users and data — *not* by the client platform. So Apple-only is primarily a **build-cost and complexity** win; the **running-cost** win comes from the backend choices in §3.2 and the OS-feature substitutions in §3.5. Both are pursued here.

### 3.1 Client — one native Apple app

A single **SwiftUI** codebase, targeting iPhone as the flagship and sharing across iPad and Mac (via native SwiftUI multiplatform / Catalyst) for the laptop-planning surface at low marginal cost. This gives us the at-a-glance-on-your-phone core *and* a big-screen planning view without building or paying to run a separate web app.

Native Apple is not just a cost decision — it's a UX ceiling: fluid timeline scrolling, platform-true gestures and haptics, **Live Activities** for flight countdowns, **Wallet** passes for boarding info, and native **MapKit** rendering. These are precisely the trip-app touches that feel premium, and here they're free platform features rather than services on the bill.

- **Navigation:** native stack. The app is trip-centric, not section-centric — a trip's sub-views are top tabs *within* the trip; no global tab bar in v1.
- **Server cache + offline store:** native (§7.1) — the on-device SQLite/SwiftData mirror plus the sync layer the backend provides.

**Deferred, not designed out:** Android (Compose) and a full web app. Because the API contract and design tokens are kept client-agnostic (a lightweight discipline even with one client — see §3.6), adding them later is a client-only project that doesn't touch the backend or data model. This is a reach-vs-cost trade made deliberately: Apple-only forgoes the large Android market share in exchange for building and running one surface cheaply while validating demand. State it plainly to stakeholders — it's a reach decision, not a running-cost one.

### 3.2 Backend — one service, tuned for a near-zero cost floor

Exactly **one** backend serves the app. Because you don't yet know whether usage is ten people or ten thousand, the governing principle is: **pay ~nothing at rest, scale only with real use.** No idle servers billed 24/7; no fixed monthly floor you owe before a single user arrives.

**Recommended — Sync-first BaaS on a free/low tier that scales to zero.**
A managed backend giving Postgres + auth + realtime + row-level security out of the box, on a plan whose cost starts at or near zero and rises with actual usage. Beyond cost, this collapses most of §5's collaboration and §7.1's offline/sync work into configuration rather than code — the fastest route to a correct collaborative app, and the cheapest to run early. Model the schema (§3.3) as SQL tables, enforce roles via row-level-security policies, let the client subscribe to trip changes for live multi-user updates. Keep storage lean (don't hoard data) to stay inside low tiers longer.

**Alternative — Custom API**, only if a specific need rules out BaaS. A single small service (language is the backend agent's call; clients see only the HTTP contract) + Postgres + a websocket layer, hosted on a scale-to-zero platform so idle cost stays near nothing. The cost tradeoff: you reimplement the sync/RLS guarantees BaaS gives free, which is more build *and* more to run. Prefer the BaaS unless forced off it.

Either way: **Postgres is the datastore**, the schema and the §3.4 contract are unchanged, and **roles are enforced server-side** — the client's role UI is convenience, never the security boundary.

### 3.5 Apple-native substitutions for paid services (running-cost lever)

Each of these replaces a metered/paid backend line with a free OS capability — the concrete "keep running cost low" tactics:

- **Sign in with Apple** for auth instead of a paid auth tier or SMS-OTP costs.
- **MapKit** for map display and basic geocoding instead of a metered maps/geocoding bill (v1 needs display, not heavy routing).
- **Wallet passes + Calendar + Live Activities** via the OS for boarding info, add-to-calendar, and countdowns — no server work, no service fees.
- **APNs** (Apple Push Notification service) for notifications — free — instead of a paid push provider.
- **iCloud consideration:** for a *single-user* data model, CloudKit could even remove the backend database cost entirely by storing each user's data in their own iCloud. **But** our app is fundamentally *collaborative* (shared trips across people who may not share an iCloud family), which CloudKit sharing handles poorly at this shape — so a shared Postgres backend is the right call. Noting it explicitly so the option is considered and consciously rejected, not overlooked. If a future pivot made trips single-user, CloudKit would be the cheapest possible backend.

### 3.6 Lightweight contract discipline (even with one client)

With a single client the heavy anti-drift machinery is unnecessary, but two light habits keep the future cheap and the build clean:

- **Keep the API contract explicit and versioned** (OpenAPI or equivalent). The Swift client generates its models from it. This is what makes a later Android/web client a client-only task rather than a backend excavation.
- **Design tokens as data.** The §6 palette, type scale, spacing, and gradients live once as a tokens artifact compiling to Swift constants (and later, if needed, Compose/CSS). Even for one app this keeps the §6 system honest and single-sourced.

Everything else is simply the SwiftUI app's own concern — no cross-client acceptance parity, no multi-language coordination. That entire burden disappears with the single-platform scope.

### 3.3 Data model

Core entities and the important fields. Types are indicative.

```
User
  id            uuid pk
  email         text unique
  display_name  text
  avatar_color  text          // seeded from palette; see design tokens
  created_at    timestamptz

Trip
  id            uuid pk
  title         text          // "Lisbon"
  destination   text          // "Lisbon, Portugal"
  country_code  text
  start_date    date
  end_date      date
  cover_gradient text         // token key, not a raw hex; see §6
  trip_type     enum('family','friends','solo')  // sets smart defaults (§5.5)
  created_by    uuid fk->User
  created_at    timestamptz

TripMember                    // join table = the collaboration core
  trip_id       uuid fk->Trip
  user_id       uuid fk->User (nullable for pending email invites)
  invite_email  text          // set when user_id is null (not yet joined)
  role          enum('organizer','companion','viewer')
  status        enum('active','pending')
  pk (trip_id, user_id)  // plus a partial unique on (trip_id, invite_email)

ItineraryItem
  id            uuid pk
  trip_id       uuid fk->Trip
  category      enum('flight','hotel','activity','food')
  title         text
  starts_at     timestamptz   // store UTC; see §7.4 time zones
  ends_at       timestamptz nullable
  tz            text          // IANA tz of the item's location, e.g. "Europe/Lisbon"
  location_name text
  location_lat  numeric nullable
  location_lng  numeric nullable
  confirmation  text nullable // confirmation/booking code
  notes         text nullable
  created_by    uuid fk->User
  // category-specific fields live in a JSONB `details` column:
  details       jsonb
    // flight:   { airline, flight_no, from_iata, to_iata, seat, terminal, gate }
    // hotel:    { address, check_in, check_out, nights, room }
    // activity: { ticket_ref, address }
    // food:     { party_size, address, reservation_name }

ItemAssignee                  // who an item is "for" — powers the "Just mine" filter
  item_id       uuid fk->ItineraryItem
  user_id       uuid fk->TripMember.user_id
  pk (item_id, user_id)
  // NOTE: assignees can include people who don't use the app (e.g. Meera, 7).
  // See §5.3 — model non-app members as "profiles" on the trip, not full Users.

PackingItem
  id            uuid pk
  trip_id       uuid fk->Trip
  label         text
  group         enum('documents','kids','shared','clothing','custom')  // extensible
  assignee_id   uuid nullable // TripMember/profile responsible
  is_done       boolean default false
  created_by    uuid fk->User

ShareLink                     // the no-app view-only path
  id            uuid pk
  trip_id       uuid fk->Trip
  slug          text unique   // "lisbon/a7f3" — unguessable
  scope         enum('view')  // only 'view' in v1
  revoked       boolean default false
  created_at    timestamptz
```

**Key modeling decision — non-app family members.** A 7-year-old and a grandparent-who-views-by-link are trip participants but may never be `User`s. Do **not** force every assignee to be a registered user. Introduce a lightweight `TripProfile` (id, trip_id, display_name, avatar_color, optional linked user_id) and have `ItemAssignee`/`PackingItem.assignee` reference profiles. A `User` who joins gets a profile auto-created and linked. This one decision keeps the family features honest; skipping it will bite you the moment you assign "Meera's car seat" to someone with no account.

### 3.4 API surface (Path B; for Path A these become table/RLS operations)

REST, resource-oriented. All mutating routes check the caller's role on the trip.

```
POST   /trips                         create trip (caller becomes organizer)
GET    /trips                         list caller's trips (upcoming/past derived from dates)
GET    /trips/:id                     trip + members + itinerary (the whole trip payload)
PATCH  /trips/:id                     edit trip meta                  [organizer]
DELETE /trips/:id                                                     [organizer]

POST   /trips/:id/members             invite by email (role in body)  [organizer]
PATCH  /trips/:id/members/:uid        change role                     [organizer]
DELETE /trips/:id/members/:uid        remove member                   [organizer]

POST   /trips/:id/items               add itinerary item              [organizer, companion]
PATCH  /items/:id                     edit item        [organizer; companion if own]
DELETE /items/:id                     delete item      [organizer; companion if own]

POST   /trips/:id/packing             add packing item                [organizer, companion]
PATCH  /packing/:id                   toggle/assign/edit              [organizer, companion]

POST   /trips/:id/share-link          create/rotate view link         [organizer]
DELETE /share-link/:id                revoke                          [organizer]
GET    /public/:slug                  PUBLIC read-only trip payload   [no auth]
```

`GET /public/:slug` returns a **sanitized** payload — itinerary + times + locations, but strip confirmation codes, notes, and member emails unless explicitly marked shareable. The link is for "where do we need to be," not for leaking booking references.

---

## 4. Screen specs

Each screen below maps to the mockups. Behavior stated here wins over the mockup where they differ (the mockup is a happy-path prototype).

### 4.1 Home / trip list  (`TripApp.jsx` → Home; **superseded** — see below)
- **This subsection's original spec (a segmented Upcoming/Past control, one
  card style) shipped in v1 and was replaced in the 1.1 UX-redesign track.**
  Full rationale, mockup notes, and acceptance criteria:
  [docs/UX_REDESIGN_ROADMAP.md](UX_REDESIGN_ROADMAP.md) Phase 5. What's
  actually shipped, kept current here:
- **One list, no tabs.** Two orderings concatenated: everything ending today
  or later ("ahead"), soonest-start first, then everything already ended
  ("been"), most recent first — one comparator, no special-casing; a live
  trip's own start date already sorts it to position 0 for free. "Today"/
  liveness is judged per-trip in *that trip's* own effective time zone
  (`TripDateBucketing.liveTimeZone`, §7.4), not the device's.
- **Three registers**, not one card style:
  - **Next** — the nearest "ahead" trip, when it isn't live: the full
    gradient card (as before) plus a countdown-ring "in N days" pill and a
    "FIRST UP" strip naming the trip's next still-ahead itinerary item
    (icon, title/route, weekday + time).
  - **Now** — the nearest "ahead" trip, when it's live: a "Day N of M" pill
    with a thin day-progress bar, and an inline mini-list of today's first
    two plans plus a "+N more today" count; tapping the card opens the trip
    already scrolled to today (§4.2).
  - **Been** — every past trip: a muted compact row (no gradient cover,
    avatars, or countdown), grouped under sticky year headers below a
    "Been there · N trips" section header; swipe or long-press to copy a
    past trip into a new one (reuses the existing duplicate-trip action).
  - Every other "ahead" trip (i.e. not the nearest one) renders the plain
    gradient card unchanged: cover, city, country · start date · duration,
    a countdown pill, an avatar stack. Whole card/row is the tap target.
- Empty state: not a blank screen — a single "Plan a new trip" invitation with one line on what the app does. (See §6 copy guidance.)
- "Plan a new trip" affordance always present at the list foot.

### 4.2 Trip → Itinerary timeline  (`TripApp.jsx` → Itinerary)
- **This is the core screen. Most polish budget goes here.**
- Hero header with trip gradient, back, share. Sub-tabs within the trip: **Itinerary · Bookings · Map · $ Split** (Map and $ Split are v2 placeholders in v1 — either hide them or show a "coming soon" state; do not ship dead tabs silently).
- Body is a **day-grouped vertical timeline**: sticky day headers ("Day 1 · Wed May 14"), a left time gutter, a vertical rail, and one card per item.
- Item card shows a **category-colored icon** (flight=sky blue, hotel=amber, activity=moss, food=plum), title, subtitle, and a ticket glyph when a confirmation exists. Tap → booking detail.
- Time zones: display each item in **its own location's** local time, with a subtle indicator when the zone changes between consecutive items (e.g., the arrival is in a new tz). Never silently mix zones. See §7.4.
- Empty state (trip created, nothing added): show the day skeleton with an inline "Add your first flight, stay, or plan" prompt and the same auto-import nudge that appears in the add flow (even though import is v1.5 — the entry point can exist and route to a waitlist/manual for now, OR be hidden until v1.5; product owner call, flagged in §9).
- FAB (＋) → add-to-itinerary.

### 4.3 Add to itinerary  (`TripApp.jsx` → AddItem)
- Top: the **auto-import nudge** ("Forward your confirmation to plans@tripto.app"). In v1 this is either hidden or routes to a "we'll email you when this is ready" — do not fake parsing. Decide per §9.
- **Category selector** (Flight / Stay / Activity / Food) drives a **contextual form** — the fields change per category (flight → airline, flight no, from/to, date, time, confirmation; stay → hotel, check-in/out, nights, confirmation; etc.).
- Minimize friction: location fields should autocomplete (Places API) in v1.5+; in v1 plain text is acceptable. Date/time pickers use native controls.
- Primary action label states the outcome: "Add flight to itinerary" (not "Submit"). The toast says "Flight added."

### 4.4 Booking detail  (`TripApp.jsx` → BookingDetail)
- **Boarding-pass metaphor** for flights: origin/destination IATA in display serif, a route line, and a perforated lower section with passenger/seat/confirmation/gate. Hotels use the same card frame with stay fields.
- Confirmation code in monospace, easy to read/copy.
- Action row: **Add to calendar · Get directions · Share with group** — all three hand off to the OS or the group; none require us to build much.
- A trip note block for free text.

### 4.5 — see §5 for the three family screens.

---

## 5. Family & collaboration

### 5.1 Roles (`TripAppFamily.jsx` → Invite)
Three roles, enforced **server-side**:
- **Organizer** — full control, manages people and everything in the trip.
- **Companion** — add/suggest/comment; edit *their own* items; cannot restructure others' plans.
- **Viewer** — read-only. The default for kids and grandparents.

Role UI: a friendly picker with one-line descriptions at invite time and editable later. The mockup's inline role menu is the intended pattern.

### 5.2 The no-app view link (`TripAppFamily.jsx` → Invite, top card)
- One tap generates `tripto.app/<trip>/<slug>` — an unguessable, revocable, **read-only** link that opens the itinerary in a browser with no app and no account.
- This is the single most important family feature and a growth loop (every shared link markets the app). Keep it in **v1**.
- Server: `GET /public/:slug` returns the sanitized payload (§3.4). Build a minimal responsive web view for it — it does not need to be the full app, just a clean read-only itinerary.

### 5.3 Non-app participants
Per §3.3: kids and view-only grandparents are **profiles on the trip**, not necessarily Users. Assignments and "who's this item for" reference profiles. This is what lets "Meera (7)" appear on an item and on a packing task without an account. Do not skip this.

### 5.4 "Just mine" filter (`TripAppFamily.jsx` → JustMine)
- A person filter atop the timeline: **Everyone** + one chip per member/profile. Selecting a person filters the dense shared itinerary to items they're an assignee on.
- Kid-aware item tags: nap window, stroller-friendly, kids' menu — small, high-trust touches that signal the app is built *for* families. Model as optional tags on `ItineraryItem.details`.
- Rationale: a family day is dense; each person needs a "what do *I* need right now" lens over the shared master.

### 5.5 Money (deferred to v2, but decide the default now)
- **Family trips default to expense *tracking*** ("what did this trip cost us"), because families usually have one payer. Even-split "you owe me" is available but not the default.
- **Friends trips default to splitting.** `trip_type` drives which mode is primary. Not built in v1; noted so the data model and UX don't get retrofitted painfully.

### 5.6 Suggest-without-editing (v1.5)
Companions proposing an activity that lands in a "suggestions" tray the organizer accepts/declines, rather than editing the master directly. Deferred, but the `ItineraryItem` model should allow a `status: 'suggested' | 'confirmed'` to make this cheap later. Add the column in v1 even though everything is 'confirmed' for now.

---

## 6. Design system

The mockups are the reference implementation. Match them.

### 6.1 Palette — "dusk departure"
Deliberately **not** corporate travel-blue and **not** the terracotta-on-cream look that reads as generic. Deep indigo night-sky + warm amber boarding-light.

```
ink        #1A1B2E   primary text / near-black indigo
indigo     #2D2F52   card ink, dark surfaces
slate      #6B6E8F   secondary text
mist       #EEEDF4   hairlines, rails, inactive fills
paper      #FBFAF7   app background (warm, not white)
amber      #E8955A   primary accent / CTAs / active states
amberSoft  #FBEADB   amber tint fill
--- category colors (semantic; do not reassign) ---
flight  sky  #5B7DB1 / soft #E3EAF3
hotel   amber #E8955A / soft #FBEADB
activity moss #6E9E7E / soft #E3EEE6
food    plum #8B6B9E / soft #EDE5F1
```

Cover gradients are **tokens**, referenced by key from `Trip.cover_gradient`, not raw hex in the DB. Provide a small set (the mockups use three) plus a default.

### 6.2 Type
- **Display:** Fraunces (serif), weights 500–600, used with restraint for city names and screen titles. This is the personality; don't overuse it.
- **Body/UI:** Sofia Sans, 400–700.
- **Data/confirmation codes:** monospace.
- Sentence case everywhere. Labels state what a control does.

### 6.3 Signature elements (keep these; they carry the brand)
- The **boarding-pass detail card** with perforation notches.
- The **day-grouped timeline** with category-colored rail nodes.
- **Gradient trip covers** with glassy overlay pills.
- **Avatar stacks** for members/assignees.

### 6.4 Components to build
SwiftUI views, driven by the token artifact (§3.6): `SegmentedControl`, `TripCard`, `TimelineItem`, `CategoryIcon`, `RolePill` + `RolePicker`, `AvatarStack`, `PersonFilterBar`, `PackingRow`, `Field` (labeled input), `BoardingPassCard`, `ActionRow`, `EmptyState`, `Fab`, `ShareLinkCard`. Build them as reusable views so iPhone/iPad/Mac size classes share one implementation.

### 6.5 Motion & quality floor
- Micro-interactions only where they serve (tab underline slide, check-off, progress bar fill). Respect reduced-motion.
- Quality floor, unannounced: responsive to small screens, visible keyboard focus, adequate tap targets (44pt), dark-mode-ready tokens.

### 6.6 Copy guidance
- Empty screens are invitations, not mood: "Add your first flight, stay, or plan," not "No items yet."
- Errors explain what happened and how to fix it, in the interface's voice; they don't apologize and aren't vague.
- An action keeps its name through the flow: button "Add flight" → toast "Flight added."

---

## 7. Non-functional requirements

### 7.1 Offline & sync
Travelers are offline at exactly the moment they need the app (planes, foreign SIMs, basements). Non-negotiable:
- **Read** the full trip offline (last synced state).
- **Optimistic edits** offline that reconcile on reconnect.
- Conflict policy for collaborative edits: last-write-wins at the field level is acceptable for v1 given low real-time contention; surface a non-destructive "updated by Priya" indicator. (Path A BaaS with realtime handles much of this; if Path B, budget for it explicitly.)

### 7.2 Performance
- Timeline must stay smooth for a 2-week, many-item trip: virtualize the list, lazy-load images, keep the day headers sticky without jank.
- Trip list and timeline should render from local cache instantly, then reconcile.

### 7.3 Accessibility
WCAG-minded: color is never the only signal (category has icon **and** color), text contrast holds on gradients (overlay scrims), full keyboard/screen-reader labels, 44pt targets, reduced-motion honored.

### 7.4 Time zones (get this right — it's where trip apps fail)
- Store all instants in **UTC**; store the item's **IANA tz** alongside.
- Display each item in **its location's** local time.
- When consecutive items cross zones (a flight landing in a new tz), show the shift explicitly so a 20:15 arrival isn't misread. Never render mixed-zone times without labeling.

### 7.5 Privacy & security
- Roles enforced server-side; the client role UI is convenience only.
- The public share payload is sanitized (no confirmation codes, notes, or emails by default).
- Share slugs are unguessable and revocable.
- Personal/booking data encrypted at rest and in transit. Don't log confirmation codes.

---

## 8. Suggested milestones

Each milestone is shippable/testable. Acceptance criteria are the bar.

**M0 — Contract & foundations (unblocks parallel work).**
✅ OpenAPI contract for §3.4 published and versioned; the data model (§3.3) migrated in Postgres; design tokens (§6) committed as a data artifact compiling to Swift constants; the acceptance-case doc (time zones, roles, bucketing, share sanitization) written. This milestone lets the backend and the SwiftUI client proceed against a fixed contract, and keeps a future Android/web client a client-only task. The client generates its models from the contract; no hand-written shapes.

**M1 — Skeleton + trip CRUD + list/home.**
✅ Create/edit/delete a trip; see it in Upcoming/Past correctly by date; cards match the design tokens. Auth working. Local cache renders instantly.

**M2 — Itinerary timeline + item CRUD + booking detail.**
✅ Add flight/stay/activity/food via contextual forms; items appear day-grouped in correct per-location time; tapping an item opens the boarding-pass/stay detail; add-to-calendar and directions hand off to OS. Time-zone display verified across a zone-crossing flight.

**M3 — Collaboration + roles + the no-app link.**
✅ Invite by email; assign the three roles; server enforces them; non-app profiles can be assigned to items; generate/revoke a view-only link that renders a sanitized itinerary in a browser with no account.

**M4 — Family layer.**
✅ "Just mine" person filter over the timeline (including non-app profiles); shared packing list with per-person assignment and family progress; kid-aware tags render.

**M5 — Offline hardening + a11y + performance pass.**
✅ Full offline read + optimistic edit/reconcile; smooth 2-week trip; contrast/reduced-motion/screen-reader audit passes.

**— ship v1 —**

**M6+ (v1.5):** email-forward parser (top 10–15 providers), one flight-status API, suggest-without-editing tray.

---

## 9. Open questions (decide with product owner)

1. **v1 import entry point:** show the "forward your confirmation" nudge now (routing to a waitlist/manual) as a demand signal, or hide it until v1.5 so we don't promise what we don't do? *Recommendation: show it, route to manual + "we'll notify you," measure taps.*
2. **iPhone-first vs. iPhone+iPad+Mac at launch:** all are one SwiftUI codebase, but each added size class is polish/QA time. *Recommendation: iPhone-first, iPad/Mac as fast-follows from the shared views. (Android/full-web remain deferred per §3.1 — a reach decision to revisit after demand is validated, not a running-cost one.)*
3. **Backend Path A (BaaS, faster) vs. Path B (custom).** *Recommendation: A, unless there's a compliance/infra reason.*
4. **Map & $ Split tabs in the trip view:** hide entirely in v1, or show "coming soon"? *Recommendation: hide until built; no dead tabs.*
5. **Conflict resolution ambition:** is field-level last-write-wins + "edited by X" enough for v1, or do we need presence/merge? *Recommendation: LWW is enough at launch scale.*
6. **`trip_type` at creation:** confirm the three types (family/friends/solo) and their default behaviors (money mode, packing list on/off, link-on-by-default for family).

---

## 10. What ships with this document
- `TripApp.jsx` — interactive mockup: Home, Itinerary timeline, Add item, Booking detail.
- `TripAppFamily.jsx` — interactive mockup: Role-aware invite, "Just mine" filter, Shared packing list.
- Both use the tokens in §6 and are the visual source of truth. This document is the behavioral/architectural source of truth. Where they disagree, this document wins.
