import type { Env } from "./types";
import { SHARE_TOKEN_PATTERN, INVITE_TOKEN_PATTERN } from "./format";
import { renderItineraryPage, renderMessagePage } from "./templates";
import { fetchPublicTrip } from "./supabase";

// Token URLs must never be edge/browser cached, indexed, or leaked via
// referrer -- every page this worker serves carries these. (Zero-JS pages,
// so a tight CSP costs nothing.)
const SECURITY_HEADERS: Record<string, string> = {
  "Cache-Control": "no-store",
  "X-Robots-Tag": "noindex, nofollow",
  "Referrer-Policy": "no-referrer",
  "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'",
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
      mutedLine: "Have the app? The link opens it. Otherwise ask for a TestFlight invite.",
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
          paths: ["/t/*", "/join/*"],
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
} satisfies ExportedHandler<Env>;
