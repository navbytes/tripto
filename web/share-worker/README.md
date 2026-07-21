# tripto-share

The no-app, read-only web view for Tripto share links (BUILD_PLAN.md §5.2 /
§7.5) **plus the public marketing site**: a Cloudflare Worker, no framework,
hand-rolled HTML strings only. Lets anyone with a link see an itinerary in a
browser with no account and no app — `tripto.navbytes.io/t/<token>` — and
gives the product a loud, gradient-heavy landing page at the root.

## What it serves

Public, indexable pages (the App Store Marketing / Support / Privacy URLs):

- `GET /` — the landing page: "unicorn mode" brand (night-violet hero,
  pink→purple→cyan gradients, sticker pills, a pure-CSS phone mockup),
  feature grid, how-it-works, FAQ. Carries the SEO surface: canonical,
  Open Graph/Twitter cards, and a JSON-LD `@graph` (Organization, WebSite,
  WebPage, MobileApplication, FAQPage — the FAQ markup mirrors the visible
  FAQ content, per Google's guidelines). Zero JavaScript; the JSON-LD
  `<script type="application/ld+json">` block is an inert data block, so the
  strict CSP stays.
- `GET /privacy` — the privacy policy, same brand hero.
- SEO/brand infrastructure: `/robots.txt` (allows `/`, disallows `/t/` +
  `/join/`), `/sitemap.xml`, `/llms.txt` (AI-crawler courtesy summary),
  `/favicon.svg` (+ `/favicon.ico` fallback), `/og.jpg` (1200×630 social
  card), `/apple-touch-icon.png`. The two raster images are bundled as
  wrangler `Data` modules from `src/assets/`; regenerate them with
  `scripts/generate-assets.mjs` (needs `playwright-core` + a Chromium).

Private, tokened pages (unchanged product surfaces — calm dusk palette,
tuned for a non-technical audience):

- `GET /t/:token` — calls the `get_public_trip` RPC (SECURITY DEFINER,
  defined in `~/repos/backend/projects/tripto`) and renders the sanitized,
  day-grouped itinerary: hero with the trip's cover gradient, times shown in
  each item's own IANA tz with the zone spelled as a city word ("New York",
  "Lisbon"), category icon tiles, a privacy line, and a footer. Invalid or
  revoked tokens render a branded "link is no longer available" page (404).
- `GET /join/:token` — a static interstitial ("You're invited to a trip on
  Tripto") linking `tripto://join/<token>`. No RPC call; invite tokens are
  only validated in-app.
- `GET /.well-known/apple-app-site-association` — served only once
  `APPLE_TEAM_ID` is configured (see below); 404 until then.
- Anything else — a 404 page in the same visual style.

Every tokened page: `Cache-Control: no-store`, `X-Robots-Tag: noindex,
nofollow`, `Referrer-Policy: no-referrer`, a strict CSP (`default-src
'none'; style-src 'unsafe-inline'; img-src 'self'`), zero JavaScript. All
payload strings are HTML-escaped (`src/format.ts` → `esc()`) — a trip titled
with `<script>` in it renders as inert text. Public pages get the same CSP
with normal caching (`public, max-age=3600`) and no `noindex`.

## Deploy

```sh
cd web/share-worker
npm install
npm run typecheck   # tsc --noEmit
npm run deploy      # wrangler deploy
```

`npm run dev` runs it locally with `wrangler dev` (proxies the same live
Supabase project — there's no local backend to run against).

Config lives in `wrangler.jsonc`: the `SUPABASE_URL` and
`SUPABASE_PUBLISHABLE_KEY` vars are the public values from the root
`CLAUDE.md` — **only the publishable key belongs here or anywhere in this
repo.** The service-role key must never be added to this Worker (or
anywhere in the tripto repo) — it isn't needed; `get_public_trip` is exposed
to `anon` precisely so this Worker never needs elevated credentials.

## Universal links: adding your Apple Team ID

The AASA route reads `APPLE_TEAM_ID` from the Worker's environment and
**404s until it's set** — this repo intentionally does not invent one. Once
you have your Apple Developer Team ID:

1. Add it to `wrangler.jsonc`'s `vars` block:
   ```jsonc
   "vars": {
     "SUPABASE_URL": "...",
     "SUPABASE_PUBLISHABLE_KEY": "...",
     "APPLE_TEAM_ID": "ABCDE12345"
   }
   ```
2. `npm run deploy` again.
3. Confirm: `curl https://tripto.navbytes.io/.well-known/apple-app-site-association`
   should return `{"applinks":{"apps":[],"details":[{"appID":"ABCDE12345.io.navbytes.tripto","paths":["/t/*","/join/*"]}]}}`.
4. Add the matching Associated Domains entitlement
   (`applinks:tripto.navbytes.io`) to the iOS app target.

## Notes for whoever touches this next

- Tokens are never logged (no `console.log` of URLs/tokens anywhere in
  `src/`) — `share_links.token` and `invites.token` are secrets in transit
  even though this Worker only ever receives them, never mints or stores
  them.
- `/t/:token` pattern-checks `[a-f0-9]{16,64}` and `/join/:token` checks
  `[A-Za-z0-9]{1,128}` *before* using the token for anything, per the spec
  this Worker was built against — malformed input never reaches the RPC
  call or gets reflected unescaped.
- The exact URL format the SwiftUI app should embed when generating a share
  link: `https://tripto.navbytes.io/t/<token>`.
