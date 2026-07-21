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

/** Canonical origin for every absolute URL this worker emits (canonicals,
 * og:url, JSON-LD @ids, sitemap/robots). One constant so it can never drift
 * between pages. */
export const SITE_ORIGIN = "https://tripto.navbytes.io";

// ── Brand: "unicorn mode" (marketing surfaces only) ────────────────────────
// The landing/privacy pages wear a loud gradient-and-sticker look; the token
// share pages (/t/, /join/) keep the calm in-app dusk palette because they
// are product surfaces tuned for a non-technical, older audience.
const BRAND = {
  ink: "#221533", // deep plum — text & borders
  paper: "#FFF9F4", // warm cream page background
  pink: "#FF3E9E",
  purple: "#8B5CF6",
  cyan: "#2DD9C8",
  sun: "#FFC93E",
  dark: "#1B1030", // hero/footer night-violet
} as const;

/** The signature pink→purple→cyan sweep. */
const UNICORN_GRADIENT = `linear-gradient(115deg, ${BRAND.pink} 0%, #B44CF0 45%, ${BRAND.purple} 62%, ${BRAND.cyan} 100%)`;

/** Same sweep in lighter tints — for gradient-clipped text on dark, where the
 * full-strength colors would fail AA contrast. */
const UNICORN_GRADIENT_LIGHT = "linear-gradient(100deg, #FF9AD3 0%, #C4A8FF 55%, #6FE8DA 100%)";

/** And in deeper tones — for gradient-clipped display text on light
 * backgrounds (every stop ≥3:1 on cream, the AA large-text bar). */
const UNICORN_GRADIENT_DEEP = "linear-gradient(115deg, #E11D8F 0%, #7C3AED 55%, #0D9488 100%)";

// AA-safe accent tones for small text/links on light backgrounds (the raw
// brand pink/purple sit just under 4.5:1 on white).
const PINK_DEEP = "#D6157F";
const PURPLE_DEEP = "#6D28D9";

/** Served at /favicon.svg (and reused as the inline page icon). Emoji glyph
 * renders with the viewer's system emoji font — no webfont, CSP-safe. */
export const FAVICON_SVG = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><defs><linearGradient id="g" x1="0" y1="0" x2="64" y2="64" gradientUnits="userSpaceOnUse"><stop stop-color="#FF3E9E"/><stop offset=".55" stop-color="#8B5CF6"/><stop offset="1" stop-color="#2DD9C8"/></linearGradient></defs><rect width="64" height="64" rx="14" fill="url(#g)"/><text x="32" y="44" font-size="34" text-anchor="middle">🦄</text></svg>`;

/** Shared icon/meta links for public (indexable) pages. */
const PUBLIC_HEAD_ICONS = `<link rel="icon" href="/favicon.svg" type="image/svg+xml">
<link rel="apple-touch-icon" href="/apple-touch-icon.png">`;

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

// Shared across every TOKEN page this worker renders (itinerary, 404, invalid
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
  display:inline-block;margin-top:20px;background:${BRAND.sun};color:${BRAND.ink};
  font-weight:800;font-size:15px;text-decoration:none;
  padding:14px 28px;border-radius:999px;
  border:2px solid ${BRAND.ink};box-shadow:4px 4px 0 ${BRAND.ink};
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
<link rel="icon" href="/favicon.svg" type="image/svg+xml">
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
.article .eyebrow{font-size:12px;font-weight:800;letter-spacing:.12em;text-transform:uppercase;color:${PURPLE_DEEP}}
.article h1{font-weight:800;font-size:clamp(26px,7vw,34px);letter-spacing:-.5px;margin:8px 0 4px;color:${BRAND.ink}}
.article .updated{font-size:13px;color:#6B6E8F;margin:0 0 26px}
.article h2{font-weight:800;font-size:19px;margin:28px 0 8px;color:${BRAND.ink}}
.article p{font-size:15px;line-height:1.62;color:#2D2F52;margin:0 0 12px;overflow-wrap:anywhere}
.article strong{color:${BRAND.ink}}
.article .lead{font-size:16px;color:${BRAND.ink}}
.article a{color:${PINK_DEEP};font-weight:600}
.hero{background:${BRAND.dark};background-image:radial-gradient(420px 260px at 12% -10%,rgba(255,62,158,.35),transparent 60%),radial-gradient(420px 280px at 88% 10%,rgba(45,217,200,.28),transparent 60%),radial-gradient(520px 340px at 55% 120%,rgba(139,92,246,.4),transparent 60%)}
.hero .trip-title{font-family:inherit;font-weight:800}
.hero .pill{display:inline-block;margin-top:10px;background:${BRAND.sun};color:${BRAND.ink};border:2px solid ${BRAND.ink};border-radius:999px;padding:6px 14px;font-size:12.5px;font-weight:800;box-shadow:3px 3px 0 rgba(0,0,0,.35);transform:rotate(-1.5deg)}
.site-footer a{color:${PINK_DEEP}}`;
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Privacy Policy — Tripto</title>
<meta name="description" content="How Tripto handles your data: no ads, no tracking, no selling data — trips are visible only to people you invite, and share links are sanitized.">
<link rel="canonical" href="${SITE_ORIGIN}/privacy">
<meta name="theme-color" content="${BRAND.dark}">
<meta property="og:type" content="website">
<meta property="og:site_name" content="Tripto">
<meta property="og:url" content="${SITE_ORIGIN}/privacy">
<meta property="og:title" content="Privacy Policy — Tripto">
<meta property="og:description" content="No ads, no tracking, no selling data. How Tripto — the group trip planner — handles your trips.">
<meta property="og:image" content="${SITE_ORIGIN}/og.jpg">
<meta name="twitter:card" content="summary_large_image">
${PUBLIC_HEAD_ICONS}
<style>${style}</style>
</head>
<body>
<div class="wrap">
  <div class="hero">
    <p class="trip-title">Tripto 🦄</p>
    <p class="trip-meta">Privacy Policy</p>
    <span class="pill">🔒 no ads · no tracking · fr</span>
  </div>
  <article class="article">
    <p class="eyebrow">Privacy</p>
    <h1>How Tripto handles your data</h1>
    <p class="updated">Last updated 11 July 2026</p>

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

    <h2>Importing bookings: AI processing</h2>
    <p>When you import trip details via paste, Tripto extracts booking
      information (flights, hotel stays, activities, and confirmation codes).
      On iPhones with Apple Intelligence enabled (iOS 26+), you choose where
      processing happens:</p>
    <p><strong>On this iPhone (default):</strong> extraction runs on your device
      using Apple's built-in language model. Pasted text never leaves your
      device and is not sent to any third party.</p>
    <p><strong>Cloud AI (optional on capable devices, automatic on others):</strong>
      if you prefer cloud processing or your device doesn't support on-device
      extraction, your booking text — which may contain confirmation codes,
      personal names, and email addresses — is sent to a <strong>third-party
      large-language-model provider</strong> (currently OpenAI) through
      <strong>Cloudflare's AI Gateway</strong>.</p>
    <p><strong>Both paths:</strong></p>
    <ul style="margin:8px 0 12px;padding-left:20px;color:#2D2F52;font-size:15px;line-height:1.62">
      <li>Happens only when you explicitly choose to import; it is never automatic.</li>
      <li>Requires your consent before the first cloud send via any route.</li>
      <li>Extracts and returns structured booking details only; the raw text is not stored in your Tripto account after extraction.</li>
      <li>Is sent over encrypted HTTPS to Cloudflare and the model provider (cloud path only).</li>
      <li>Does not train the provider's models: the current provider, OpenAI, does not use API data to train or improve its models per its data-usage terms. On-device processing uses Apple's first-party model and is not used for training. Request logging is disabled in the Cloudflare gateway (cloud path only).</li>
    </ul>
    <p>Cloudflare and the model provider are sub-processors of your data for
      the cloud import path only. You are not required to use the import
      feature; you can always enter trips manually.</p>

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
    <span><a href="/">tripto.navbytes.io</a></span>
  </div>
</div>
</body>
</html>`;
}

// ── Landing page ("unicorn mode") ──────────────────────────────────────────

/** FAQ content rendered on the landing page AND mirrored into FAQPage
 * JSON-LD. Google requires the structured data to match visible content, so
 * both come from this single list (emoji stripped for the JSON-LD copy). */
const LANDING_FAQS: ReadonlyArray<{ q: string; aHtml: string; aText: string }> = [
  {
    q: "What is Tripto?",
    aHtml:
      "Tripto is a <b>group trip planner for iPhone</b> that turns everyone's scattered bookings into one shared itinerary. Flights, hotels, activities, food — all on one day-by-day timeline the whole group can see, with shared packing lists and read-only share links for family who don't want another app.",
    aText:
      "Tripto is a group trip planner for iPhone that turns everyone's scattered bookings into one shared itinerary. Flights, hotels, activities, food — all on one day-by-day timeline the whole group can see, with shared packing lists and read-only share links for family who don't want another app.",
  },
  {
    q: "When can I get Tripto?",
    aHtml:
      "Tripto is in TestFlight now and <b>coming soon to the App Store</b>. Want early access, or a ping at launch? Email <a href=\"mailto:tripto@navbytes.io\">tripto@navbytes.io</a> and we've got you. 🫶",
    aText:
      "Tripto is in TestFlight now and coming soon to the App Store. Want early access, or a ping at launch? Email tripto@navbytes.io and we've got you.",
  },
  {
    q: "Do grandparents (or anyone) need the app to see the trip?",
    aHtml:
      "Nope — that's the superpower. Share a <b>read-only link</b> and the itinerary opens in any web browser: no app, no account, no password. They see the dates, places and times; the private stuff stays private.",
    aText:
      "No — that's the superpower. Share a read-only link and the itinerary opens in any web browser: no app, no account, no password. They see the dates, places and times; the private stuff stays private.",
  },
  {
    q: "Does Tripto work offline, like on a plane?",
    aHtml:
      "Yes. The whole trip is <b>readable and editable in airplane mode</b>, and your changes sync the moment you're back online. Offline is not a plot twist.",
    aText:
      "Yes. The whole trip is readable and editable in airplane mode, and your changes sync the moment you're back online.",
  },
  {
    q: "How does Tripto handle time zones?",
    aHtml:
      "Every plan is saved with its own time zone and always shown in <b>the place's local time</b> — so a 9:40 PM landing in Lisbon never reads like an afternoon nap slot. It's the #1 way trip apps betray you, and it's solved.",
    aText:
      "Every plan is saved with its own time zone and always shown in the place's local time — so a 9:40 PM landing in Lisbon never reads like an afternoon nap slot.",
  },
  {
    q: "Is my trip data private?",
    aHtml:
      "Very. <b>No ads, no tracking, no selling data — ever.</b> Trips are visible only to people you invite, and public share links show a sanitized view: never your confirmation codes, notes or emails. Read the full <a href=\"/privacy\">privacy policy</a>.",
    aText:
      "Yes. No ads, no tracking, no selling data — ever. Trips are visible only to people you invite, and public share links show a sanitized view: never your confirmation codes, notes or emails. Full policy at tripto.navbytes.io/privacy.",
  },
];

const LANDING_TITLE = "Tripto — Group Trip Planner · One Shared Itinerary";
const LANDING_DESCRIPTION =
  "Turn your group's scattered bookings into one shared, time-zone-smart itinerary. No ads, no tracking, works offline. Coming soon to iPhone.";

/** Organization + WebSite + WebPage + MobileApplication + FAQPage in one
 * @graph. Kept truthful: no invented ratings, prices, or download links. */
function landingJsonLd(): string {
  const org = {
    "@type": "Organization",
    "@id": `${SITE_ORIGIN}/#organization`,
    name: "navbytes",
    url: `${SITE_ORIGIN}/`,
    email: "tripto@navbytes.io",
    logo: { "@type": "ImageObject", url: `${SITE_ORIGIN}/apple-touch-icon.png` },
  };
  const website = {
    "@type": "WebSite",
    "@id": `${SITE_ORIGIN}/#website`,
    url: `${SITE_ORIGIN}/`,
    name: "Tripto",
    description: LANDING_DESCRIPTION,
    publisher: { "@id": `${SITE_ORIGIN}/#organization` },
    inLanguage: "en",
  };
  const app = {
    "@type": "MobileApplication",
    "@id": `${SITE_ORIGIN}/#app`,
    name: "Tripto",
    operatingSystem: "iOS",
    applicationCategory: "TravelApplication",
    description:
      "Tripto is a group trip planner for families and friends: one shared day-by-day itinerary with per-place local times, boarding-pass detail cards, shared packing lists, offline support, and read-only web share links that need no app or account.",
    url: `${SITE_ORIGIN}/`,
    image: `${SITE_ORIGIN}/og.jpg`,
    author: { "@id": `${SITE_ORIGIN}/#organization` },
  };
  const webpage = {
    "@type": "WebPage",
    "@id": `${SITE_ORIGIN}/#webpage`,
    url: `${SITE_ORIGIN}/`,
    name: LANDING_TITLE,
    description: LANDING_DESCRIPTION,
    isPartOf: { "@id": `${SITE_ORIGIN}/#website` },
    about: { "@id": `${SITE_ORIGIN}/#app` },
    primaryImageOfPage: { "@type": "ImageObject", url: `${SITE_ORIGIN}/og.jpg` },
    inLanguage: "en",
  };
  const faq = {
    "@type": "FAQPage",
    "@id": `${SITE_ORIGIN}/#faq`,
    mainEntity: LANDING_FAQS.map((f) => ({
      "@type": "Question",
      name: f.q,
      acceptedAnswer: { "@type": "Answer", text: f.aText },
    })),
  };
  return JSON.stringify({ "@context": "https://schema.org", "@graph": [org, website, webpage, app, faq] });
}

const LANDING_STYLES = `
*{box-sizing:border-box}
html{font-size:100%;scroll-behavior:smooth}
html,body{margin:0;padding:0}
body{
  background:${BRAND.paper};
  color:${BRAND.ink};
  font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,system-ui,sans-serif;
  -webkit-font-smoothing:antialiased;
  text-rendering:optimizeLegibility;
  line-height:1.5;
  overflow-x:hidden;
}
a{color:${PURPLE_DEEP}}
:focus-visible{outline:3px solid ${BRAND.purple};outline-offset:3px;border-radius:6px}
.skip-link{position:absolute;left:-999px;top:8px;background:${BRAND.sun};color:${BRAND.ink};font-weight:800;padding:10px 16px;border-radius:999px;z-index:99}
.skip-link:focus{left:8px}
.shell{max-width:1120px;margin:0 auto;padding:0 22px}

/* ── header + hero (night violet with neon glows) ── */
.top{
  background:${BRAND.dark};
  background-image:
    radial-gradient(640px 420px at 10% -12%, rgba(255,62,158,.34), transparent 60%),
    radial-gradient(520px 400px at 92% 4%, rgba(45,217,200,.24), transparent 60%),
    radial-gradient(760px 520px at 55% 118%, rgba(139,92,246,.38), transparent 62%);
  color:#EDE6FF;
  position:relative;
}
.nav{display:flex;align-items:center;justify-content:space-between;gap:14px;padding:20px 0 6px}
.wordmark{font-size:24px;font-weight:900;letter-spacing:-.5px;color:#fff;text-decoration:none;display:inline-flex;align-items:center;gap:8px;padding:6px 2px}
.nav-links{display:flex;align-items:center;gap:8px;flex-wrap:wrap}
.nav-links a{color:#EDE6FF;text-decoration:none;font-weight:700;font-size:14.5px;padding:11px 16px;border-radius:999px}
.nav-links a:hover{background:rgba(255,255,255,.1)}
.nav-links a.say-hi{background:${BRAND.sun};color:${BRAND.ink};border:2px solid ${BRAND.ink};box-shadow:3px 3px 0 rgba(0,0,0,.4)}
@media(max-width:620px){.nav-links a.anchor{display:none}}

.hero-grid{display:grid;gap:48px;align-items:center;padding:44px 0 74px}
@media(min-width:940px){.hero-grid{grid-template-columns:1.08fr .92fr;padding:60px 0 92px}}

.sticker{
  display:inline-block;background:${BRAND.sun};color:${BRAND.ink};
  font-size:13.5px;font-weight:800;letter-spacing:.01em;
  border:2px solid ${BRAND.ink};border-radius:999px;padding:9px 16px;
  box-shadow:3px 3px 0 rgba(0,0,0,.4);transform:rotate(-2deg);
}
h1{
  font-size:clamp(38px,7vw,64px);
  font-weight:900;letter-spacing:-.03em;line-height:1.04;
  margin:22px 0 0;color:#fff;
}
h1 .grad{
  background:${UNICORN_GRADIENT_LIGHT};
  -webkit-background-clip:text;background-clip:text;color:transparent;
}
.hero-sub{font-size:clamp(16.5px,2.2vw,19px);line-height:1.6;max-width:56ch;margin:20px 0 0;color:#EDE6FF}
.hero-sub b{color:#fff}
.cta-row{display:flex;gap:14px;flex-wrap:wrap;margin-top:30px;align-items:center}
.btn{
  display:inline-block;text-decoration:none;font-weight:800;font-size:16px;
  padding:16px 26px;border-radius:999px;border:2.5px solid ${BRAND.ink};
}
.btn-hot{background:${BRAND.sun};color:${BRAND.ink};box-shadow:5px 5px 0 rgba(0,0,0,.45)}
.btn-ghost{background:transparent;color:#fff;border-color:rgba(255,255,255,.65);box-shadow:none}
.btn-ghost:hover{border-color:#fff}
.truth-line{margin:22px 0 0;font-size:13.5px;color:#C9BCE8}

/* floating doodads */
.floaty{position:absolute;font-size:30px;opacity:.9;pointer-events:none;user-select:none}
.f1{top:14%;left:3%;--r:-12deg}
.f2{top:8%;right:6%;--r:14deg;font-size:36px}
.f3{bottom:12%;left:6%;--r:8deg;font-size:26px}
@media(max-width:939px){.floaty{display:none}}

/* CSS phone mock */
.phone-wrap{position:relative;display:flex;justify-content:center}
.phone{
  width:min(330px,88vw);background:#fff;border:3px solid ${BRAND.ink};
  border-radius:40px;padding:14px 14px 18px;transform:rotate(3deg);
  box-shadow:12px 12px 0 rgba(0,0,0,.45), 0 0 90px rgba(139,92,246,.5);
  color:${BRAND.ink};
}
.phone .statusbar{display:flex;justify-content:space-between;font-size:11.5px;font-weight:700;color:#8A8AA3;padding:2px 10px 8px}
.phone .mini-hero{background:${UNICORN_GRADIENT};border-radius:22px;color:#fff;padding:16px 16px 14px;border:2px solid ${BRAND.ink}}
.phone .mini-hero .t{font-size:18px;font-weight:900;letter-spacing:-.02em}
.phone .mini-hero .d{font-size:12px;font-weight:700;opacity:.95;margin-top:3px}
.phone .day{font-size:12px;font-weight:900;letter-spacing:.04em;text-transform:uppercase;color:#6B6E8F;margin:14px 4px 8px}
.phone .row{display:flex;gap:10px;align-items:center;border:2px solid ${BRAND.ink};border-radius:16px;padding:10px 12px;margin-bottom:9px;background:#fff;box-shadow:3px 3px 0 rgba(34,21,51,.12)}
.phone .row .emoji{width:38px;height:38px;border-radius:12px;display:grid;place-items:center;font-size:19px;flex-shrink:0;border:2px solid ${BRAND.ink}}
.phone .row .tt{font-size:13.5px;font-weight:800;line-height:1.25}
.phone .row .ts{font-size:11px;font-weight:700;color:#6B6E8F;margin-top:1px}
.phone .pack{display:flex;align-items:center;gap:8px;background:#F3EDFF;border:2px dashed ${BRAND.purple};border-radius:999px;padding:8px 14px;font-size:12px;font-weight:800;color:#4C1D95;margin-top:4px;justify-content:center}
.phone-sticker{
  position:absolute;top:-16px;right:2%;background:${BRAND.pink};color:${BRAND.ink};
  font-size:13px;font-weight:800;border:2px solid ${BRAND.ink};border-radius:999px;
  padding:8px 14px;transform:rotate(6deg);box-shadow:3px 3px 0 rgba(0,0,0,.4);
}

/* ── marquee ── */
.marquee{background:linear-gradient(90deg,${BRAND.sun},${BRAND.pink} 34%,${BRAND.purple} 66%,${BRAND.cyan});border-top:3px solid ${BRAND.ink};border-bottom:3px solid ${BRAND.ink};overflow:hidden;display:flex}
.marquee-track{display:flex;flex-shrink:0;min-width:100%;justify-content:space-around;gap:34px;padding:13px 17px;font-size:15px;font-weight:900;letter-spacing:.06em;text-transform:uppercase;color:${BRAND.ink};white-space:nowrap}

/* ── sections ── */
section{padding:72px 0}
.kicker{display:inline-block;font-size:13px;font-weight:900;letter-spacing:.14em;text-transform:uppercase;color:${PINK_DEEP};background:#FFE9F4;border:2px solid ${BRAND.ink};border-radius:999px;padding:7px 14px;transform:rotate(-1.2deg)}
h2{font-size:clamp(28px,4.6vw,42px);font-weight:900;letter-spacing:-.025em;line-height:1.08;margin:18px 0 12px}
h2 .grad{background:${UNICORN_GRADIENT_DEEP};-webkit-background-clip:text;background-clip:text;color:transparent}
.section-sub{font-size:17px;color:#4A3B63;max-width:60ch;margin:0}

.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(270px,1fr));gap:20px;margin-top:38px}
.card{
  background:#fff;border:2.5px solid ${BRAND.ink};border-radius:22px;
  padding:24px 22px;box-shadow:6px 6px 0 ${BRAND.ink};
}
.card .tile{width:52px;height:52px;border-radius:15px;display:grid;place-items:center;font-size:26px;border:2.5px solid ${BRAND.ink};transform:rotate(-4deg);margin-bottom:16px}
.card h3{font-size:19.5px;font-weight:900;letter-spacing:-.015em;margin:0 0 8px}
.card p{font-size:15px;line-height:1.6;color:#4A3B63;margin:0}
.card p b{color:${BRAND.ink}}

/* how it works */
.steps-band{background:#F3EDFF;border-top:3px solid ${BRAND.ink};border-bottom:3px solid ${BRAND.ink}}
.steps{display:grid;grid-template-columns:repeat(auto-fit,minmax(250px,1fr));gap:22px;margin-top:38px;counter-reset:step}
.step{background:#fff;border:2.5px solid ${BRAND.ink};border-radius:22px;padding:26px 22px;box-shadow:6px 6px 0 ${BRAND.ink};position:relative}
.step .num{
  font-size:52px;font-weight:900;line-height:1;letter-spacing:-.04em;
  background:${UNICORN_GRADIENT_DEEP};-webkit-background-clip:text;background-clip:text;color:transparent;
}
.step h3{font-size:19.5px;font-weight:900;margin:10px 0 8px}
.step p{font-size:15px;line-height:1.6;color:#4A3B63;margin:0}

/* manifesto */
.manifesto{text-align:center;max-width:760px;margin:0 auto}
.manifesto blockquote{
  font-family:Georgia,'Times New Roman',serif;font-style:italic;
  font-size:clamp(22px,3.6vw,32px);line-height:1.35;letter-spacing:-.01em;
  color:${BRAND.ink};margin:0;
}
.manifesto blockquote .hl{background:linear-gradient(transparent 58%, ${BRAND.sun} 58%)}
.manifesto figcaption{margin-top:18px;font-size:14px;font-weight:800;color:${PURPLE_DEEP}}

/* FAQ */
.faq-list{margin-top:34px;display:grid;gap:14px;max-width:820px}
.faq{background:#fff;border:2.5px solid ${BRAND.ink};border-radius:18px;box-shadow:5px 5px 0 ${BRAND.ink}}
.faq summary{
  cursor:pointer;list-style:none;display:flex;justify-content:space-between;align-items:center;gap:16px;
  font-size:16.5px;font-weight:800;padding:18px 20px;border-radius:18px;
}
.faq summary::-webkit-details-marker{display:none}
.faq summary::after{content:"+";font-size:24px;font-weight:900;color:${PINK_DEEP};flex-shrink:0;line-height:1}
.faq[open] summary::after{content:"–";color:${PURPLE_DEEP}}
.faq .a{padding:0 20px 20px;font-size:15px;line-height:1.65;color:#4A3B63}
.faq .a b{color:${BRAND.ink}}

/* final CTA */
.cta-banner{
  background-image:linear-gradient(rgba(27,16,48,.26),rgba(27,16,48,.26)),${UNICORN_GRADIENT};
  border:3px solid ${BRAND.ink};border-radius:28px;
  box-shadow:10px 10px 0 ${BRAND.ink};color:#fff;text-align:center;
  padding:clamp(38px,6vw,64px) 26px;position:relative;overflow:hidden;
}
.cta-banner h2{color:#fff;margin:0 0 10px;text-shadow:0 2px 0 rgba(34,21,51,.25)}
.cta-banner p{font-size:17px;max-width:52ch;margin:0 auto;color:#fff;font-weight:600}
.cta-banner .btn-hot{margin-top:28px}
.cta-banner .store-line{display:block;width:fit-content;margin:22px auto 0;font-size:13.5px;font-weight:800;color:${BRAND.ink};background:${BRAND.sun};border:2px solid ${BRAND.ink};border-radius:999px;padding:9px 16px;transform:rotate(-1.2deg)}

/* footer */
.footer{background:${BRAND.dark};color:#C9BCE8;margin-top:84px;border-top:3px solid ${BRAND.ink}}
.footer-inner{display:flex;justify-content:space-between;gap:26px;flex-wrap:wrap;padding:44px 0 20px}
.footer .fm{font-size:22px;font-weight:900;color:#fff}
.footer .tag{margin:8px 0 0;font-size:14px;max-width:34ch;line-height:1.55}
.footer nav{display:flex;flex-direction:column;gap:4px}
.footer nav a{color:#EDE6FF;text-decoration:none;font-weight:700;font-size:14.5px;padding:8px 0}
.footer nav a:hover{color:${BRAND.cyan}}
.footer .legal{border-top:1px solid rgba(255,255,255,.14);padding:18px 0 26px;font-size:12.5px;display:flex;justify-content:space-between;gap:10px;flex-wrap:wrap}

/* motion: everything opt-in, nothing moves for reduced-motion users */
@media (prefers-reduced-motion: no-preference){
  .marquee-track{animation:marquee 30s linear infinite}
  @keyframes marquee{to{transform:translateX(calc(-100% - 34px))}}
  .floaty{animation:floaty 6s ease-in-out infinite}
  .f2{animation-delay:-2s}.f3{animation-delay:-4s}
  @keyframes floaty{0%,100%{transform:rotate(var(--r,0deg)) translateY(0)}50%{transform:rotate(var(--r,0deg)) translateY(-13px)}}
  .card,.step,.btn{transition:transform .18s ease,box-shadow .18s ease}
  .card:hover,.step:hover{transform:translate(-3px,-3px);box-shadow:9px 9px 0 ${BRAND.ink}}
  .btn-hot:hover{transform:translate(-2px,-2px);box-shadow:7px 7px 0 rgba(0,0,0,.45)}
}
`;

/** GET / — the root landing page. Doubles as the App Store Marketing URL and
 * Support URL, so it must resolve (not 404) and carry a contact address.
 * Public + indexable — this page carries the site's full SEO surface
 * (canonical, OG/Twitter cards, JSON-LD @graph, FAQ content). */
export function renderLandingPage(): string {
  const faqsHtml = LANDING_FAQS.map(
    (f, i) => `<details class="faq"${i === 0 ? " open" : ""}>
      <summary>${esc(f.q)}</summary>
      <p class="a">${f.aHtml}</p>
    </details>`,
  ).join("\n    ");

  const marqueeTrack = `<div class="marquee-track">
      <span>no more 47-message group chats ✦</span>
      <span>every time zone handled ✦</span>
      <span>grandma can see the plan ✦</span>
      <span>works on airplane mode ✦</span>
      <span>packing lists that slap ✦</span>
      <span>zero ads, zero tracking ✦</span>
    </div>`;

  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${LANDING_TITLE}</title>
<meta name="description" content="${LANDING_DESCRIPTION}">
<link rel="canonical" href="${SITE_ORIGIN}/">
<meta name="robots" content="index, follow, max-image-preview:large">
<meta name="theme-color" content="${BRAND.dark}">
<meta name="author" content="navbytes">
<meta property="og:type" content="website">
<meta property="og:site_name" content="Tripto">
<meta property="og:url" content="${SITE_ORIGIN}/">
<meta property="og:title" content="Tripto — one shared itinerary, zero group-chat chaos">
<meta property="og:description" content="${LANDING_DESCRIPTION}">
<meta property="og:image" content="${SITE_ORIGIN}/og.jpg">
<meta property="og:image:width" content="1200">
<meta property="og:image:height" content="630">
<meta property="og:image:alt" content="Tripto — the group trip planner. One shared itinerary for the whole crew.">
<meta property="og:locale" content="en_US">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="Tripto — one shared itinerary, zero group-chat chaos">
<meta name="twitter:description" content="${LANDING_DESCRIPTION}">
<meta name="twitter:image" content="${SITE_ORIGIN}/og.jpg">
${PUBLIC_HEAD_ICONS}
<script type="application/ld+json">${landingJsonLd()}</script>
<style>${LANDING_STYLES}</style>
</head>
<body>
<a class="skip-link" href="#main">Skip to content</a>

<div class="top">
  <header class="shell">
    <nav class="nav" aria-label="Main">
      <a class="wordmark" href="/">Tripto <span aria-hidden="true">🦄</span></a>
      <div class="nav-links">
        <a class="anchor" href="#features">The good stuff</a>
        <a class="anchor" href="#faq">FAQ</a>
        <a href="/privacy">Privacy</a>
        <a class="say-hi" href="mailto:tripto@navbytes.io">Say hi 👋</a>
      </div>
    </nav>
  </header>

  <span class="floaty f1" aria-hidden="true">✨</span>
  <span class="floaty f2" aria-hidden="true">🌈</span>
  <span class="floaty f3" aria-hidden="true">🛼</span>

  <div class="shell hero-grid">
    <div>
      <span class="sticker">✨ the trip app your group chat has been begging for</span>
      <h1>One shared itinerary.<br><span class="grad">Zero group-chat chaos.</span></h1>
      <p class="hero-sub">Tripto is the <b>group trip planner</b> for families &amp; friends —
        every flight, stay and plan on one timeline, each shown in <b>its own local
        time</b>. Works offline, shares to a link grandma can open, and keeps the
        whole squad hyped. 💖</p>
      <div class="cta-row">
        <a class="btn btn-hot" href="mailto:tripto@navbytes.io?subject=Ping%20me%20when%20Tripto%20launches%20%F0%9F%94%94">🔔 Get pinged at launch</a>
        <a class="btn btn-ghost" href="/privacy">Our privacy promise 🔒</a>
      </div>
      <p class="truth-line">🚀 In TestFlight now — App Store launch soon. Trusted by exactly one
        very organized family (so far). 🫡</p>
    </div>

    <div class="phone-wrap">
      <div class="phone" role="img" aria-label="Preview of the Tripto app: a trip called “algarve with the fam”, with a day timeline showing a flight landing in Lisbon at 9:40 AM local time, a castle visit, dinner plans, and a shared packing list that is nearly done.">
        <div class="statusbar" aria-hidden="true"><span>9:41</span><span>🦄⚡🔋</span></div>
        <div class="mini-hero" aria-hidden="true">
          <div class="t">algarve with the fam 🍊</div>
          <div class="d">Aug 12 – 19 · 7 days · 6 legends</div>
        </div>
        <div aria-hidden="true">
          <div class="day">Day 2 · Tue, Aug 13</div>
          <div class="row"><span class="emoji" style="background:#E3F2FF">✈️</span><div><div class="tt">TP 353 — the fam lands!</div><div class="ts">9:40 AM · Lisbon time · gate hugs @ arrivals</div></div></div>
          <div class="row"><span class="emoji" style="background:#FFE9F4">🏰</span><div><div class="tt">Pena Palace w/ everyone</div><div class="ts">1:15 PM · tickets sorted ✔</div></div></div>
          <div class="row"><span class="emoji" style="background:#FFF3D6">🍤</span><div><div class="tt">dinner @ Ramiro 🤤</div><div class="ts">8:00 PM · table for six</div></div></div>
          <div class="pack">🧦 packing list: 12/14 packed — so close</div>
        </div>
      </div>
      <span class="phone-sticker" aria-hidden="true">grandma's watching live 💜</span>
    </div>
  </div>
</div>

<div class="marquee" aria-hidden="true">
  ${marqueeTrack}
  ${marqueeTrack}
</div>

<main id="main">
  <section id="features" class="shell" aria-labelledby="features-h">
    <span class="kicker">the good stuff</span>
    <h2 id="features-h">Why your squad will be <span class="grad">obsessed</span></h2>
    <p class="section-sub">Everything a group trip actually needs — nothing it doesn't. Built for
      families &amp; friend groups, not business travelers with 4 apps and a lanyard.</p>

    <div class="cards">
      <article class="card">
        <span class="tile" style="background:#FFE9F4" aria-hidden="true">🕰️</span>
        <h3>Time zones? Handled.</h3>
        <p>Every flight, stay and plan shows in <b>its own local time</b> — so a 9:40 PM
          landing in Lisbon never reads as afternoon-nap o'clock. Jet lag is confusing
          enough.</p>
      </article>
      <article class="card">
        <span class="tile" style="background:#F3EDFF" aria-hidden="true">🎫</span>
        <h3>Boarding-pass energy</h3>
        <p>Tap any plan for the full detail card — confirmation codes, one-tap
          <b>add to Calendar</b>, one-tap directions. Airport mode: activated.</p>
      </article>
      <article class="card">
        <span class="tile" style="background:#E7FBF4" aria-hidden="true">💌</span>
        <h3>The whole crew's invited</h3>
        <p>One link invites everyone. Organizers plan, companions add, viewers vibe — and
          <b>grandparents open a read-only web page</b>. No app. No account. No stress.</p>
      </article>
      <article class="card">
        <span class="tile" style="background:#FFF3D6" aria-hidden="true">🧦</span>
        <h3>Packing lists that slap</h3>
        <p>One shared list, assignable per person, with a <b>“Just mine”</b> filter.
          Nobody forgets the sunscreen. Or the charger. Again.</p>
      </article>
      <article class="card">
        <span class="tile" style="background:#E3F2FF" aria-hidden="true">✈️</span>
        <h3>Airplane-mode approved</h3>
        <p>Read the whole trip and <b>make edits mid-flight</b> — everything syncs the
          moment you land. Offline is a feature, not a plot twist.</p>
      </article>
      <article class="card">
        <span class="tile" style="background:#FFE9F4" aria-hidden="true">🔐</span>
        <h3>Privacy is the vibe</h3>
        <p><b>No ads. No tracking. No selling data — ever.</b> Share links show where
          &amp; when, never your confirmation codes or notes.</p>
      </article>
    </div>
  </section>

  <section class="steps-band" aria-labelledby="how-h">
    <div class="shell">
      <span class="kicker">zero-effort setup</span>
      <h2 id="how-h">Group-chat chaos → <span class="grad">itinerary</span> in 3 moves</h2>
      <div class="steps">
        <div class="step">
          <div class="num" aria-hidden="true">1</div>
          <h3>Start the trip</h3>
          <p>Name it something iconic (<i>“algarve with the fam 🍊”</i>), set the dates,
            pick a vibe. Ten seconds, tops.</p>
        </div>
        <div class="step">
          <div class="num" aria-hidden="true">2</div>
          <h3>Drop in the plans</h3>
          <p>Flights, stays, dinners, that one museum someone insists on — everything
            lands on one clean, day-by-day shared timeline.</p>
        </div>
        <div class="step">
          <div class="num" aria-hidden="true">3</div>
          <h3>Share the link</h3>
          <p>The squad joins in the app; grandma follows along from her browser.
            Everyone knows where to be. Iconic behavior.</p>
        </div>
      </div>
    </div>
  </section>

  <section class="shell" aria-label="Our vibe">
    <figure class="manifesto">
      <blockquote>“Group trips should feel like the group chat at its best —
        <span class="hl">everybody hyped, nobody lost at baggage claim.</span>” 🫶</blockquote>
      <figcaption>— the Tripto manifesto, probably</figcaption>
    </figure>
  </section>

  <section id="faq" class="shell" aria-labelledby="faq-h">
    <span class="kicker">asking for a friend</span>
    <h2 id="faq-h">FAQ <span class="grad">👀</span></h2>
    ${faqsHtml}
  </section>

  <section class="shell" aria-labelledby="cta-h">
    <div class="cta-banner">
      <h2 id="cta-h">Be the organized friend ✨</h2>
      <p>The one with the plan, the packing list, and the peace of mind.
        Main-character behavior, honestly.</p>
      <a class="btn btn-hot" href="mailto:tripto@navbytes.io?subject=Ping%20me%20when%20Tripto%20launches%20%F0%9F%94%94">🔔 Get pinged at launch</a>
      <p class="store-line">🍎 Coming soon to the App Store</p>
    </div>
  </section>
</main>

<footer class="footer">
  <div class="shell">
    <div class="footer-inner">
      <div>
        <div class="fm">Tripto <span aria-hidden="true">🦄</span></div>
        <p class="tag">One shared itinerary for the whole group — every plan, every
          time zone, everybody on the same page.</p>
      </div>
      <nav aria-label="Footer">
        <a href="/">Home</a>
        <a href="#features">Features</a>
        <a href="#faq">FAQ</a>
        <a href="/privacy">Privacy policy</a>
        <a href="mailto:tripto@navbytes.io">Support — tripto@navbytes.io</a>
      </nav>
    </div>
    <div class="legal">
      <span>© 2026 navbytes · Tripto</span>
      <span>No ads · No tracking · Just vibes &amp; itineraries ✌️</span>
    </div>
  </div>
</footer>
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
