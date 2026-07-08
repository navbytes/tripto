import type { PublicTripItem, ItemCategory, PublicTripPayload } from "./types";
import {
  esc,
  categoryColors,
  gradientFor,
  zoneWord,
  formatTime,
  formatDayHeading,
  formatTripDateRange,
  groupByLocalDay,
  type DayGroup,
} from "./format";

// Inline icon symbols, reused across item rows via <use>. Path data lifted
// from the dusk-departure mockup (docs/*.jsx reference / tripto-mockups-v2
// html) so the glyphs match exactly. "i-pin" is a defensive fallback for a
// category value the DB's check constraint shouldn't ever actually let
// through.
const ICON_DEFS = `<svg width="0" height="0" style="position:absolute" aria-hidden="true">
<defs>
<symbol id="i-plane" viewBox="0 0 24 24"><path d="M17.8 19.2 16 11l3.5-3.5C21 6 21.5 4 21 3c-1-.5-3 0-4.5 1.5L13 8 4.8 6.2c-.5-.1-.9.1-1.1.5l-.3.5c-.2.5-.1 1 .3 1.3L9 12l-2 3H4l-1 1 3 2 2 3 1-1v-3l3-2 3.5 5.3c.3.4.8.5 1.3.3l.5-.2c.4-.3.6-.7.5-1.2z" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></symbol>
<symbol id="i-bed" viewBox="0 0 24 24"><path d="M2 4v16M2 8h18a2 2 0 0 1 2 2v10M2 17h20M6 8v9" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></symbol>
<symbol id="i-cam" viewBox="0 0 24 24"><path d="M14.5 4h-5L7 7H4a2 2 0 0 0-2 2v9a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2V9a2 2 0 0 0-2-2h-3l-2.5-3z" fill="none" stroke="currentColor" stroke-width="2" stroke-linejoin="round"/><circle cx="12" cy="13" r="3" fill="none" stroke="currentColor" stroke-width="2"/></symbol>
<symbol id="i-food" viewBox="0 0 24 24"><path d="M3 2v7c0 1.1.9 2 2 2h4a2 2 0 0 0 2-2V2M7 2v20M21 15V2a5 5 0 0 0-5 5v6c0 1.1.9 2 2 2h3zm0 0v7" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></symbol>
<symbol id="i-pin" viewBox="0 0 24 24"><path d="M20 10c0 6-8 12-8 12S4 16 4 10a8 8 0 1 1 16 0z" fill="none" stroke="currentColor" stroke-width="2"/><circle cx="12" cy="10" r="3" fill="none" stroke="currentColor" stroke-width="2"/></symbol>
<symbol id="i-lock" viewBox="0 0 24 24"><rect x="3" y="11" width="18" height="11" rx="2" fill="none" stroke="currentColor" stroke-width="2"/><path d="M7 11V7a5 5 0 0 1 10 0v4" fill="none" stroke="currentColor" stroke-width="2"/></symbol>
<symbol id="i-car" viewBox="0 0 24 24"><path d="M5 17H3v-5l2-5h14l2 5v5h-2M5 12h14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/><circle cx="7.5" cy="17" r="1.6" fill="none" stroke="currentColor" stroke-width="2"/><circle cx="16.5" cy="17" r="1.6" fill="none" stroke="currentColor" stroke-width="2"/></symbol>
</defs>
</svg>`;

const CATEGORY_ICON: Record<ItemCategory, string> = {
  flight: "i-plane",
  hotel: "i-bed",
  activity: "i-cam",
  food: "i-food",
  transport: "i-car",
};

// Shared across every page this worker renders (itinerary, 404, invalid
// link, join interstitial) so they read as one product. Dusk-departure
// tokens per docs/BUILD_PLAN.md §6.1 / design/tokens.json. No webfonts --
// Georgia stands in for the Fraunces display face, system-ui for body text.
const SHARED_STYLES = `
*{box-sizing:border-box}
/* Comfortable base for the share page's older audience, in rem so the reader's
   browser text-zoom actually enlarges everything (persona dry-run). */
html{font-size:112.5%}
html,body{margin:0;padding:0}
body{
  background:#FBFAF7;
  color:#1A1B2E;
  font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,system-ui,sans-serif;
  -webkit-font-smoothing:antialiased;
  text-rendering:optimizeLegibility;
}
a{color:#E8955A}
.wrap{max-width:640px;margin:0 auto;min-height:100vh;display:flex;flex-direction:column}

.hero{color:#fff;padding:36px 24px 30px}
.hero .trip-title{
  font-family:Georgia,'Times New Roman',serif;
  font-size:clamp(23px,7vw,30px);
  font-weight:600;
  letter-spacing:-.3px;
  line-height:1.15;
  margin:0;
  overflow-wrap:anywhere;
}
.hero .trip-meta{font-size:.9rem;opacity:.95;margin-top:6px}

.content{padding:20px 20px 8px;flex:1}
.day-heading{font-size:.95rem;font-weight:700;color:#1A1B2E;margin:22px 0 10px}
.day-heading:first-child{margin-top:2px}

.item-row{
  display:flex;gap:12px;align-items:center;
  background:#fff;border:1px solid #EEEDF4;border-radius:14px;
  padding:12px 14px;margin-bottom:10px;
}
.item-time{width:66px;flex-shrink:0;font-size:.82rem;font-weight:700;color:#55586F;line-height:1.3}
.item-time .zone{display:block;font-size:.62rem;font-weight:800;letter-spacing:.05em;text-transform:uppercase;opacity:1;margin-top:2px}
.item-icon{width:36px;height:36px;border-radius:10px;flex-shrink:0;display:grid;place-items:center}
.item-body{min-width:0}
.item-title{font-size:1rem;font-weight:600;color:#1A1B2E;overflow-wrap:anywhere}
.item-sub{font-size:.85rem;color:#55586F;margin-top:2px;overflow-wrap:anywhere}

.privacy-row{
  display:flex;align-items:center;gap:8px;
  background:#EEEDF4;border-radius:12px;padding:10px 14px;
  font-size:.8rem;font-weight:600;color:#55586F;
  margin:18px 0 4px;
}
.privacy-row svg{flex-shrink:0;color:#6B6E8F}

.site-footer{
  display:flex;align-items:center;justify-content:space-between;gap:12px;flex-wrap:wrap;
  border-top:1px solid #EEEDF4;padding:16px 20px;font-size:12px;color:#6B6E8F;
}
.site-footer .brand{font-family:Georgia,'Times New Roman',serif;font-weight:600;color:#1A1B2E;font-size:14.5px}
.site-footer a{color:#E8955A;font-weight:700;text-decoration:none}

.message-screen{
  flex:1;display:flex;flex-direction:column;align-items:center;justify-content:center;
  text-align:center;padding:52px 28px;
}
.message-screen .brand{font-family:Georgia,'Times New Roman',serif;font-weight:600;font-size:22px;color:#1A1B2E}
.message-screen h1{font-family:Georgia,'Times New Roman',serif;font-weight:600;font-size:21px;margin:16px 0 0;color:#1A1B2E}
.message-screen p{font-size:14px;color:#6B6E8F;max-width:42ch;margin:10px 0 0;line-height:1.5}
.button-link{
  display:inline-block;margin-top:20px;background:#E8955A;color:#fff;
  font-weight:700;font-size:14.5px;text-decoration:none;
  padding:13px 26px;border-radius:14px;
}
.muted-line{font-size:12px;color:#6B6E8F;margin-top:16px;max-width:38ch;line-height:1.5}

@media (max-width:380px){
  .hero{padding:28px 18px 24px}
  .content{padding:16px 16px 4px}
  .item-row{padding:10px 12px;gap:10px}
  .item-time{width:58px;font-size:.78rem}
  .site-footer{padding:14px 16px}
}
`;

function headTags(pageTitle: string): string {
  return `<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${esc(pageTitle)}</title>
<style>${SHARED_STYLES}</style>`;
}

function renderItemRow(item: PublicTripItem): string {
  const { fg, soft } = categoryColors(item.category);
  const iconId = CATEGORY_ICON[item.category] ?? "i-pin";
  const time = formatTime(item.starts_at, item.tz);
  const zone = zoneWord(item.tz);
  const subtitle = item.location_name
    ? `<div class="item-sub">${esc(item.location_name)}</div>`
    : "";

  return `<div class="item-row">
  <div class="item-time">${esc(time)}<span class="zone">${esc(zone)}</span></div>
  <div class="item-icon" style="background:${soft};color:${fg}"><svg width="16" height="16" viewBox="0 0 24 24"><use href="#${iconId}"/></svg></div>
  <div class="item-body">
    <div class="item-title">${esc(item.title)}</div>
    ${subtitle}
  </div>
</div>`;
}

function renderDayGroup(group: DayGroup): string {
  const heading = `Day ${group.dayNumber} · ${formatDayHeading(group.localDate)}`;
  const rows = group.items.map(renderItemRow).join("\n");
  return `<div class="day-heading">${esc(heading)}</div>
${rows}`;
}

/** GET /t/:token success page: the sanitized, day-grouped itinerary. */
export function renderItineraryPage(payload: PublicTripPayload, token: string): string {
  const trip = payload.trip;
  const items = payload.items ?? [];
  const gradient = gradientFor(trip.cover_gradient);
  const dateRange = formatTripDateRange(trip.start_date, trip.end_date);
  const dayGroups = groupByLocalDay(items, trip.start_date);
  const daysHtml = dayGroups.map(renderDayGroup).join("\n");

  return `<!doctype html>
<html lang="en">
<head>
${headTags(`${trip.title} — Tripto`)}
<meta property="og:type" content="website">
<meta property="og:site_name" content="Tripto">
<meta property="og:title" content="${esc(trip.title)}">
<meta property="og:description" content="${esc(dateRange)} — a shared trip itinerary">
<meta name="twitter:card" content="summary">
</head>
<body>
${ICON_DEFS}
<div class="wrap">
  <div class="hero" style="background:${gradient}">
    <p class="trip-title">${esc(trip.title)}</p>
    <p class="trip-meta">${esc(dateRange)}</p>
  </div>
  <div class="content">
    ${daysHtml}
    <div class="privacy-row">
      <svg width="13" height="13" viewBox="0 0 24 24"><use href="#i-lock"/></svg>
      <span>Booking codes, notes and emails stay in the app — this link shows where to be, and when.</span>
    </div>
  </div>
  <div class="site-footer">
    <span class="brand">Tripto</span>
    <span>Made with Tripto · <a href="tripto://t/${esc(token)}">Open in the app</a></span>
  </div>
</div>
</body>
</html>`;
}

/** GET /privacy — the App Store "Privacy Policy URL". Source of truth is
 * web/share-worker/privacy-policy.md; keep this in sync with it and with
 * docs/RELEASE_READINESS.md §4. Public + indexable (unlike token pages). */
export function renderPrivacyPage(): string {
  const style = `
${SHARED_STYLES}
.article{max-width:680px;margin:0 auto;padding:8px 22px 48px}
.article .eyebrow{font-size:12px;font-weight:800;letter-spacing:.12em;text-transform:uppercase;color:#E8955A}
.article h1{font-family:Georgia,'Times New Roman',serif;font-weight:600;font-size:clamp(26px,7vw,34px);letter-spacing:-.3px;margin:8px 0 4px;color:#1A1B2E}
.article .updated{font-size:13px;color:#6B6E8F;margin:0 0 26px}
.article h2{font-family:Georgia,'Times New Roman',serif;font-weight:600;font-size:19px;margin:28px 0 8px;color:#1A1B2E}
.article p{font-size:15px;line-height:1.62;color:#2D2F52;margin:0 0 12px;overflow-wrap:anywhere}
.article strong{color:#1A1B2E}
.article .lead{font-size:16px;color:#1A1B2E}`;
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Privacy Policy — Tripto</title>
<style>${style}</style>
</head>
<body>
<div class="wrap">
  <div class="hero" style="background:${gradientFor("dusk")}">
    <p class="trip-title">Tripto</p>
    <p class="trip-meta">Privacy Policy</p>
  </div>
  <article class="article">
    <p class="eyebrow">Privacy</p>
    <h1>How Tripto handles your data</h1>
    <p class="updated">Last updated 8 July 2026</p>

    <p class="lead">Tripto helps families and groups turn scattered bookings into
      one shared itinerary. We collect as little as possible, never sell your
      data, and never track you across other apps or websites.</p>

    <h2>Who we are</h2>
    <p>Tripto is a personal-scale app operated by navbytes. You can reach us at
      <a href="mailto:tripto@navbytes.io">tripto@navbytes.io</a>.</p>

    <h2>What we collect and why</h2>
    <p><strong>Your account.</strong> When you sign in with Apple we receive your
      name and an email address (which may be an Apple private-relay address you
      can revoke at any time). We use it only to create your account, identify
      you to people you share trips with, and let invited members recognize you.
      We never send you marketing email.</p>
    <p><strong>Your trip content.</strong> The trips, itinerary items (including
      any locations, confirmation codes, and notes you enter), packing lists, and
      the profiles you add for travel companions — including family members who
      don't use the app. This is stored so your trips sync across your devices and
      to the people you invite, and it is protected by row-level security so only
      trip members can read it.</p>
    <p>We do <strong>not</strong> collect analytics, advertising identifiers, or
      location gathered from your device's sensors. Location text and coordinates
      exist only if you type or pick them for an itinerary item.</p>

    <h2>When trip data is shared</h2>
    <p><strong>With people you invite.</strong> Trip members you add (as
      organizer, companion, or viewer) can see that trip's contents according to
      their role.</p>
    <p><strong>Through a share link you create.</strong> If you generate an
      "anyone-can-view" link, anyone holding that unguessable link can see a
      <strong>sanitized</strong> version of the itinerary — dates, places, and
      times only. Confirmation codes, notes, exact coordinates, and member emails
      are never included on the public link, and you can revoke a link at any
      time, which disables it immediately.</p>
    <p>We never share your data with advertisers or data brokers.</p>

    <h2>Where it's stored</h2>
    <p>Trip data is stored in a Supabase (PostgreSQL) database and transmitted
      over encrypted HTTPS. Your session is kept securely in the iOS Keychain on
      your device, and the app keeps a local copy of your trips so they work
      offline.</p>

    <h2>Deleting your data</h2>
    <p>You can delete your account from <strong>Settings → Delete account</strong>
      in the app. This permanently removes your account and any trips you created,
      along with their itinerary and packing content; trips you were only invited
      to simply lose you as a member. Because we offer Sign in with Apple,
      deleting your account also revokes Tripto's Apple sign-in token. Deletion is
      immediate and cannot be undone.</p>

    <h2>Children</h2>
    <p>Tripto lets you add profiles for children as trip participants, but those
      profiles are created and managed by an adult account holder; children do not
      have their own accounts, and we do not knowingly collect data directly from
      children.</p>

    <h2>Changes</h2>
    <p>If this policy changes materially, we'll update the date above and, where
      appropriate, note it in the app.</p>

    <h2>Contact</h2>
    <p>Questions about your data: <a href="mailto:tripto@navbytes.io">tripto@navbytes.io</a>.</p>
  </article>
  <div class="site-footer">
    <span class="brand">Tripto</span>
    <span>tripto.navbytes.io</span>
  </div>
</div>
</body>
</html>`;
}

/** GET / — the root landing page. Doubles as the App Store Marketing URL and
 * Support URL, so it must resolve (not 404) and carry a contact address.
 * Public + indexable. */
export function renderLandingPage(): string {
  const style = `
${SHARED_STYLES}
.landing{max-width:640px;margin:0 auto;padding:26px 22px 48px}
.landing .lead{font-size:17px;line-height:1.55;color:#1A1B2E;margin:0 0 22px}
.landing h2{font-family:Georgia,'Times New Roman',serif;font-weight:600;font-size:18px;color:#1A1B2E;margin:26px 0 10px}
.feature{display:flex;gap:11px;align-items:flex-start;margin:0 0 12px}
.feature .dot{flex-shrink:0;width:8px;height:8px;border-radius:4px;margin-top:7px;background:#E8955A}
.feature p{margin:0;font-size:14.5px;line-height:1.5;color:#2D2F52}
.feature b{color:#1A1B2E}
.badge{display:inline-block;margin:6px 0 4px;background:#FBEADB;color:#9a5a2a;font-size:12.5px;font-weight:700;border-radius:999px;padding:7px 15px}
.contact{margin-top:26px;font-size:14px;color:#6B6E8F;line-height:1.6}
.contact a{color:#E8955A;font-weight:600;text-decoration:none}`;
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="description" content="Tripto turns everyone's scattered bookings into one shared, at-a-glance itinerary — built for families and groups.">
<meta property="og:type" content="website">
<meta property="og:site_name" content="Tripto">
<meta property="og:title" content="Tripto — one shared itinerary for the whole group">
<meta property="og:description" content="Everyone's scattered bookings, one shared at-a-glance itinerary for families and groups.">
<meta name="twitter:card" content="summary">
<title>Tripto — one shared itinerary for the whole group</title>
<style>${style}</style>
</head>
<body>
<div class="wrap">
  <div class="hero" style="background:${gradientFor("dusk")}">
    <p class="trip-title">Tripto</p>
    <p class="trip-meta">One shared itinerary for the whole group</p>
  </div>
  <div class="landing">
    <p class="lead">Tripto turns everyone's scattered bookings into one shared,
      at-a-glance itinerary — built for families and groups, not just solo
      business trips.</p>

    <h2>What it does</h2>
    <div class="feature"><span class="dot"></span><p>A day-by-day timeline that
      shows each flight, stay, and plan in <b>its own local time</b>, so a
      late-night arrival is never misread.</p></div>
    <div class="feature"><span class="dot"></span><p>Boarding-pass detail cards
      with confirmation codes — one tap to add to Calendar or get directions.</p></div>
    <div class="feature"><span class="dot"></span><p>Invite family with a link:
      companions add plans, viewers just watch, and <b>grandparents open a
      read-only web link with no app and no account</b>.</p></div>
    <div class="feature"><span class="dot"></span><p>A shared packing list you
      can assign to each person, and a "Just mine" filter so everyone sees what
      <b>they</b> need.</p></div>
    <div class="feature"><span class="dot"></span><p>Works offline — read the
      whole trip and make edits on the plane; they sync when you land.</p></div>

    <p class="badge">Coming soon to the App Store</p>

    <p class="contact">Questions or support: <a href="mailto:tripto@navbytes.io">tripto@navbytes.io</a><br>
      <a href="/privacy">Privacy policy</a></p>
  </div>
  <div class="site-footer">
    <span class="brand">Tripto</span>
    <span>No ads · no tracking · shared only with people you invite</span>
  </div>
</div>
</body>
</html>`;
}

export interface MessagePageOptions {
  pageTitle: string;
  heading: string;
  message: string;
  actionHref?: string;
  actionLabel?: string;
  mutedLine?: string;
}

/** Shared shell for every non-itinerary page: 404, invalid/revoked link, bad invite token, join interstitial. */
export function renderMessagePage(opts: MessagePageOptions): string {
  const action = opts.actionHref
    ? `<a class="button-link" href="${esc(opts.actionHref)}">${esc(opts.actionLabel ?? "Open")}</a>`
    : "";
  const muted = opts.mutedLine ? `<p class="muted-line">${esc(opts.mutedLine)}</p>` : "";

  return `<!doctype html>
<html lang="en">
<head>
${headTags(opts.pageTitle)}
</head>
<body>
<div class="wrap">
  <div class="message-screen">
    <span class="brand">Tripto</span>
    <h1>${esc(opts.heading)}</h1>
    <p>${esc(opts.message)}</p>
    ${action}
    ${muted}
  </div>
</div>
</body>
</html>`;
}
