import type { Env } from "./types";
import { SHARE_TOKEN_PATTERN, INVITE_TOKEN_PATTERN } from "./format";
import {
  renderItineraryPage,
  renderMessagePage,
  renderPrivacyPage,
  renderLandingPage,
  SITE_ORIGIN,
  FAVICON_SVG,
  APP_STORE_URL,
} from "./templates";
import { fetchPublicTrip } from "./supabase";
// Binary brand assets (wrangler "Data" rules in wrangler.jsonc). Regenerate
// with web/share-worker/scripts/generate-assets.mjs.
import OG_IMAGE from "./assets/og.jpg";
import TOUCH_ICON from "./assets/apple-touch-icon.png";

// Token URLs must never be edge/browser cached, indexed, or leaked via
// referrer -- every page this worker serves carries these. (Zero-JS pages,
// so a tight CSP costs nothing; img-src 'self' only allows the favicon.)
const SECURITY_HEADERS: Record<string, string> = {
  "Cache-Control": "no-store",
  "X-Robots-Tag": "noindex, nofollow",
  "Referrer-Policy": "no-referrer",
  "X-Content-Type-Options": "nosniff",
  "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; img-src 'self'",
};

// Public, indexable, cacheable pages (root landing + privacy) — they are the
// App Store Marketing / Support / Privacy URLs, so they must resolve and get
// their own headers, not SECURITY_HEADERS' no-store/noindex. The JSON-LD
// <script type="application/ld+json"> blocks are data (never executed), so
// they don't need a script-src carve-out.
const PUBLIC_HTML_HEADERS: Record<string, string> = {
  "Content-Type": "text/html; charset=utf-8",
  "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; img-src 'self'",
  "Cache-Control": "public, max-age=3600",
  "X-Content-Type-Options": "nosniff",
  "Referrer-Policy": "strict-origin-when-cross-origin",
};

function html(body: string, status = 200): Response {
  return new Response(body, {
    status,
    headers: {
      "Content-Type": "text/html; charset=utf-8",
      ...SECURITY_HEADERS,
    },
  });
}

/** Static public asset (favicon, og image, robots, sitemap…): long-ish cache, nosniff. */
function asset(body: BodyInit, contentType: string, maxAge = 86400): Response {
  return new Response(body, {
    status: 200,
    headers: {
      "Content-Type": contentType,
      "Cache-Control": `public, max-age=${maxAge}`,
      "X-Content-Type-Options": "nosniff",
    },
  });
}

// ── SEO infrastructure ─────────────────────────────────────────────────────
// Only the landing page and /privacy are meant to be crawled; token pages
// (/t/, /join/) are unlisted and additionally carry X-Robots-Tag: noindex.

const ROBOTS_TXT = `User-agent: *
Allow: /
Disallow: /t/
Disallow: /join/

Sitemap: ${SITE_ORIGIN}/sitemap.xml
`;

// lastmod dates: bump the "/" entry when the landing page changes materially,
// and "/privacy" when the policy's "Last updated" date changes.
const SITEMAP_XML = `<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
  <url>
    <loc>${SITE_ORIGIN}/</loc>
    <lastmod>2026-07-22</lastmod>
    <changefreq>monthly</changefreq>
    <priority>1.0</priority>
  </url>
  <url>
    <loc>${SITE_ORIGIN}/privacy</loc>
    <lastmod>2026-07-11</lastmod>
    <changefreq>yearly</changefreq>
    <priority>0.5</priority>
  </url>
</urlset>
`;

// Optional AI-crawler courtesy file (llmstxt.org convention): a compact,
// factual summary so LLM agents cite real facts instead of guessing.
const LLMS_TXT = `# Tripto

> Tripto is a group trip planner for iPhone, built for families and friend
> groups: everyone's flights, stays and plans on one shared day-by-day
> itinerary, each shown in its own local time zone. It works offline, has
> shared per-person packing lists, and can share a read-only web itinerary
> link that needs no app and no account. No ads, no tracking, no data
> selling. Status: released — "Tripto — Trip Organizer" is on the App Store
> for iPhone (${APP_STORE_URL}). Contact: tripto@navbytes.io.

## Pages

- [Home](${SITE_ORIGIN}/): what Tripto does, features, FAQ
- [Privacy policy](${SITE_ORIGIN}/privacy): full privacy policy

Note: URLs under /t/ and /join/ are private share/invite links — do not
crawl, index, or cite them.
`;

function notFoundPage(): Response {
  return html(
    renderMessagePage({
      pageTitle: "Not found — Tripto",
      heading: "Page not found",
      message: "There's nothing at this address.",
    }),
    404,
  );
}

function invalidLinkPage(): Response {
  return html(
    renderMessagePage({
      pageTitle: "Link unavailable — Tripto",
      heading: "This link is no longer available",
      message:
        "It may have been revoked, or the address might be mistyped. Ask whoever shared it for a fresh link.",
    }),
    404,
  );
}

function badJoinTokenPage(): Response {
  return html(
    renderMessagePage({
      pageTitle: "Invalid invite — Tripto",
      heading: "That invite link doesn't look right",
      message: "Double-check the address, or ask whoever invited you to send it again.",
    }),
    400,
  );
}

function joinInterstitialPage(token: string): Response {
  return html(
    renderMessagePage({
      pageTitle: "You're invited — Tripto",
      heading: "You're invited to a trip on Tripto",
      message: "Tap below to open the invite in the app.",
      actionHref: `tripto://join/${token}`,
      actionLabel: "Open in Tripto",
      mutedLine: "Have the app? The button opens your invite right inside it.",
      subActionHref: APP_STORE_URL,
      subActionLabel: "New here? Get Tripto on the App Store",
    }),
  );
}

function serverErrorPage(): Response {
  return html(
    renderMessagePage({
      pageTitle: "Something went wrong — Tripto",
      heading: "Something went wrong",
      message: "Give it another try in a moment.",
    }),
    500,
  );
}

async function handleShareLink(rawToken: string, env: Env): Promise<Response> {
  if (!SHARE_TOKEN_PATTERN.test(rawToken)) {
    return invalidLinkPage();
  }

  const result = await fetchPublicTrip(env, rawToken);
  if (!result.ok) {
    return invalidLinkPage();
  }

  return html(renderItineraryPage(result.data, rawToken));
}

function handleJoin(rawToken: string): Response {
  if (!INVITE_TOKEN_PATTERN.test(rawToken)) {
    return badJoinTokenPage();
  }
  return joinInterstitialPage(rawToken);
}

function handleAasa(env: Env): Response {
  if (!env.APPLE_TEAM_ID) {
    return notFoundPage();
  }

  const body = JSON.stringify({
    applinks: {
      apps: [],
      details: [
        {
          appID: `${env.APPLE_TEAM_ID}.io.navbytes.tripto`,
          // ONLY /join/* — invite links open the app to claim. /t/* share
          // links are deliberately excluded so they always render the sanitized
          // web view (the no-app audience the share link exists for); the app
          // has no handler for a share token, so claiming /t/* would open it to
          // a dead end.
          paths: ["/join/*"],
        },
      ],
    },
  });

  return new Response(body, {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    try {
      if (request.method !== "GET" && request.method !== "HEAD") {
        return notFoundPage();
      }

      const url = new URL(request.url);
      const path = url.pathname;

      if (path === "/.well-known/apple-app-site-association") {
        return handleAasa(env);
      }

      if (path === "/" || path === "") {
        return new Response(renderLandingPage(), { status: 200, headers: PUBLIC_HTML_HEADERS });
      }
      if (path === "/privacy" || path === "/privacy/") {
        return new Response(renderPrivacyPage(), { status: 200, headers: PUBLIC_HTML_HEADERS });
      }

      // Crawler + brand asset routes (all public, all static).
      switch (path) {
        case "/robots.txt":
          return asset(ROBOTS_TXT, "text/plain; charset=utf-8");
        case "/sitemap.xml":
          return asset(SITEMAP_XML, "application/xml; charset=utf-8");
        case "/llms.txt":
          return asset(LLMS_TXT, "text/plain; charset=utf-8");
        case "/favicon.svg":
          return asset(FAVICON_SVG, "image/svg+xml", 604800);
        case "/favicon.ico": // legacy UA fallback — serve the SVG, browsers sniff-tolerate it via type header
          return asset(FAVICON_SVG, "image/svg+xml", 604800);
        case "/og.jpg":
          return asset(OG_IMAGE, "image/jpeg", 604800);
        case "/apple-touch-icon.png":
          return asset(TOUCH_ICON, "image/png", 604800);
      }

      const shareMatch = path.match(/^\/t\/([^/]+)\/?$/);
      const shareToken = shareMatch?.[1];
      if (shareToken) {
        return await handleShareLink(shareToken, env);
      }

      const joinMatch = path.match(/^\/join\/([^/]+)\/?$/);
      const joinToken = joinMatch?.[1];
      if (joinToken) {
        return handleJoin(joinToken);
      }

      return notFoundPage();
    } catch {
      // Defensive catch-all: never leak a stack trace or an unstyled
      // platform error page for a public-facing surface. Deliberately no
      // console.log here either -- request URLs can carry tokens.
      return serverErrorPage();
    }
  },

  // Cron keep-alive (see wrangler.jsonc "triggers"). A free-tier Supabase
  // project pauses after ~7 idle days, which would silently break share links
  // and the app's sync during a lull between trips. A daily lightweight read
  // keeps the database marked active — RLS returns [], all we need is for
  // Postgres to be touched. Best-effort: a transient failure is harmless.
  async scheduled(_controller: ScheduledController, env: Env): Promise<void> {
    try {
      await fetch(`${env.SUPABASE_URL}/rest/v1/trips?select=id&limit=1`, {
        headers: { apikey: env.SUPABASE_PUBLISHABLE_KEY },
      });
    } catch {
      // Ignore — the next daily tick retries.
    }
  },
} satisfies ExportedHandler<Env>;
