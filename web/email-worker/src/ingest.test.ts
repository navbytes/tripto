import { test, type TestContext } from "node:test";
import assert from "node:assert/strict";
import PostalMime from "postal-mime";
import { buildIngestPayload, formatFrom, postIngest } from "./ingest.ts";
import type { Env } from "./types.ts";

// A realistic forwarded booking confirmation: multipart/alternative with a
// display-name From, matching what postal-mime + this Worker will actually
// see off Cloudflare Email Routing's `message.raw` stream.
const RAW_BOOKING_EMAIL = [
  'From: "Delta Air Lines" <noreply@delta.com>',
  "To: t-0123456789abcdef0123456789abcdef@plans.tripto.navbytes.io",
  "Subject: Your booking confirmation DL123",
  "MIME-Version: 1.0",
  'Content-Type: multipart/alternative; boundary="BOUNDARY"',
  "",
  "--BOUNDARY",
  'Content-Type: text/plain; charset="utf-8"',
  "",
  "Your flight DL123 departs JFK at 10:00 AM on July 20.",
  "",
  "--BOUNDARY",
  'Content-Type: text/html; charset="utf-8"',
  "",
  "<html><body><p>Your flight DL123 departs JFK at 10:00 AM on July 20.</p></body></html>",
  "",
  "--BOUNDARY--",
  "",
].join("\r\n");

test("buildIngestPayload extracts from/subject/text/html from a parsed MIME message", async () => {
  const parsed = await PostalMime.parse(RAW_BOOKING_EMAIL);
  const payload = buildIngestPayload("0123456789abcdef0123456789abcdef", parsed, null);

  assert.equal(payload.token, "0123456789abcdef0123456789abcdef");
  assert.equal(payload.from, "Delta Air Lines <noreply@delta.com>");
  assert.equal(payload.subject, "Your booking confirmation DL123");
  assert.match(payload.text ?? "", /DL123 departs JFK/);
  assert.match(payload.html ?? "", /<p>Your flight DL123/);
});

test("formatFrom falls back to the raw header when postal-mime found no address", () => {
  const result = formatFrom({ from: undefined }, "Weird Sender <weird@example.com>");
  assert.equal(result, "Weird Sender <weird@example.com>");
});

test("formatFrom omits the angle brackets when there is no display name", () => {
  const result = formatFrom({ from: { name: "", address: "plain@example.com" } }, null);
  assert.equal(result, "plain@example.com");
});

test("postIngest posts the payload with the shared-secret header and returns ok on 2xx", async (t: TestContext) => {
  const calls: { url: string; init?: RequestInit }[] = [];
  const originalFetch = globalThis.fetch;
  t.after(() => {
    globalThis.fetch = originalFetch;
  });
  globalThis.fetch = (async (url: string, init?: RequestInit) => {
    calls.push({ url: String(url), init });
    return new Response(JSON.stringify({ ok: true }), { status: 200 });
  }) as typeof fetch;

  const env: Env = {
    INGEST_EMAIL_URL: "https://example.test/functions/v1/ingest-email",
    EMAIL_INGEST_SHARED_SECRET: "shh",
  };
  const result = await postIngest(env, { token: "abc", from: "a@b.com", subject: "s", text: "t", html: null });

  assert.deepEqual(result, { ok: true });
  assert.equal(calls.length, 1);
  assert.equal(calls[0]?.url, env.INGEST_EMAIL_URL);
  const headers = calls[0]?.init?.headers as Record<string, string>;
  assert.equal(headers["X-Ingest-Secret"], "shh");
  assert.equal(JSON.parse(String(calls[0]?.init?.body)).token, "abc");
});

test("postIngest reports http_error on a non-2xx response", async (t: TestContext) => {
  const originalFetch = globalThis.fetch;
  t.after(() => {
    globalThis.fetch = originalFetch;
  });
  globalThis.fetch = (async () => new Response("nope", { status: 401 })) as typeof fetch;

  const env: Env = { INGEST_EMAIL_URL: "https://example.test", EMAIL_INGEST_SHARED_SECRET: "shh" };
  const result = await postIngest(env, { token: "abc", from: "a@b.com", subject: "s", text: "t", html: null });

  assert.deepEqual(result, { ok: false, reason: "http_error", status: 401 });
});

test("postIngest reports network_error when fetch throws", async (t: TestContext) => {
  const originalFetch = globalThis.fetch;
  t.after(() => {
    globalThis.fetch = originalFetch;
  });
  globalThis.fetch = (async () => {
    throw new Error("boom");
  }) as typeof fetch;

  const env: Env = { INGEST_EMAIL_URL: "https://example.test", EMAIL_INGEST_SHARED_SECRET: "shh" };
  const result = await postIngest(env, { token: "abc", from: "a@b.com", subject: "s", text: "t", html: null });

  assert.deepEqual(result, { ok: false, reason: "network_error" });
});
