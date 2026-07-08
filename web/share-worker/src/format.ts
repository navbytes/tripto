import type { ItemCategory, PublicTripItem } from "./types";

/**
 * HTML-escape a value for safe interpolation into markup. Every piece of
 * payload text (trip title, item titles, location names, etc.) is user
 * input and MUST go through this before landing in the response -- a trip
 * titled `<script>...` must render as inert text, never execute.
 */
export function esc(input: unknown): string {
  const s = input === null || input === undefined ? "" : String(input);
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

// ── Design tokens (docs/BUILD_PLAN.md §6.1, design/tokens.json) ───────────

export const COLORS = {
  ink: "#1A1B2E",
  indigo: "#2D2F52",
  slate: "#6B6E8F",
  mist: "#EEEDF4",
  paper: "#FBFAF7",
  amber: "#E8955A",
  amberSoft: "#FBEADB",
} as const;

const CATEGORY_COLORS: Record<ItemCategory, { fg: string; soft: string }> = {
  flight: { fg: "#5B7DB1", soft: "#E3EAF3" },
  hotel: { fg: "#E8955A", soft: "#FBEADB" },
  activity: { fg: "#6E9E7E", soft: "#E3EEE6" },
  food: { fg: "#8B6B9E", soft: "#EDE5F1" },
  transport: { fg: "#4F8A87", soft: "#E0EBEA" },
};

const NEUTRAL_CATEGORY_COLOR = { fg: COLORS.slate, soft: COLORS.mist };

export function categoryColors(category: string): { fg: string; soft: string } {
  return (CATEGORY_COLORS as Record<string, { fg: string; soft: string }>)[category] ?? NEUTRAL_CATEGORY_COLOR;
}

const GRADIENTS = {
  dusk: "linear-gradient(135deg, #E8955A 0%, #C96B5B 55%, #2D2F52 100%)",
  plum: "linear-gradient(135deg, #8B6B9E 0%, #5B7DB1 55%, #1A1B2E 100%)",
  moss: "linear-gradient(135deg, #6E9E7E 0%, #5B7DB1 55%, #2D2F52 100%)",
} as const;

export function gradientFor(key: string): string {
  return (GRADIENTS as Record<string, string>)[key] ?? GRADIENTS.dusk;
}

// ── Time zone / date formatting ────────────────────────────────────────────

/**
 * The IANA tz's city, grandma-readable: last path segment, underscores to
 * spaces ("America/New_York" -> "New York", "Europe/Lisbon" -> "Lisbon").
 * Rendered with CSS text-transform:uppercase, matching the mockup's
 * "NEW YORK" / "LISBON" zone labels.
 */
export function zoneWord(tz: string): string {
  const last = tz.split("/").pop() ?? tz;
  return last.replace(/_/g, " ");
}

/**
 * Grandparent-friendly 12-hour time in the given IANA tz, e.g. "8:15 PM".
 * The share page's audience is non-technical family (BUILD_PLAN §5.2); 24-hour
 * "20:15" reads as a puzzle to many of them (persona dry-run).
 */
export function formatTime(isoInstant: string, tz: string): string {
  return new Intl.DateTimeFormat("en-US", {
    timeZone: tz,
    hour: "numeric",
    minute: "2-digit",
    hour12: true,
  }).format(new Date(isoInstant));
}

/**
 * The calendar date (YYYY-MM-DD) of an instant AS OBSERVED in the given IANA
 * tz -- never UTC. This is the day-grouping key: BUILD_PLAN.md §7.4 requires
 * each item to be read in its own location's local time, and grouping must
 * follow that same local date, not the UTC date the instant happens to fall
 * on.
 */
export function localDateKey(isoInstant: string, tz: string): string {
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone: tz,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).formatToParts(new Date(isoInstant));
  const y = parts.find((p) => p.type === "year")!.value;
  const m = parts.find((p) => p.type === "month")!.value;
  const d = parts.find((p) => p.type === "day")!.value;
  return `${y}-${m}-${d}`;
}

/** Whole-day difference between two YYYY-MM-DD date-only strings (UTC-anchored, no tz ambiguity since neither string carries a time-of-day). */
function daysBetween(aDateOnly: string, bDateOnly: string): number {
  const a = Date.parse(`${aDateOnly}T00:00:00Z`);
  const b = Date.parse(`${bDateOnly}T00:00:00Z`);
  return Math.round((b - a) / 86_400_000);
}

/** "Day N", where N=1 on the trip's start_date. */
export function dayNumberFor(localDate: string, tripStartDate: string): number {
  return daysBetween(tripStartDate, localDate) + 1;
}

/** "Wednesday, May 14" for a YYYY-MM-DD date-only string. */
export function formatDayHeading(localDate: string): string {
  const d = new Date(`${localDate}T00:00:00Z`);
  const weekday = new Intl.DateTimeFormat("en-US", { weekday: "long", timeZone: "UTC" }).format(d);
  const month = new Intl.DateTimeFormat("en-US", { month: "long", timeZone: "UTC" }).format(d);
  return `${weekday}, ${month} ${d.getUTCDate()}`;
}

/** "May 14 – 20 · 6 days" (or "May 14 – Jun 2 · ...", or cross-year) for the trip's date-only start/end. */
export function formatTripDateRange(startDate: string, endDate: string): string {
  const start = new Date(`${startDate}T00:00:00Z`);
  const end = new Date(`${endDate}T00:00:00Z`);
  const days = Math.max(0, daysBetween(startDate, endDate));
  const dayLabel = `${days} day${days === 1 ? "" : "s"}`;

  const fmtMonth = new Intl.DateTimeFormat("en-US", { month: "short", timeZone: "UTC" });
  const startMonth = fmtMonth.format(start);
  const endMonth = fmtMonth.format(end);
  const startYear = start.getUTCFullYear();
  const endYear = end.getUTCFullYear();

  let range: string;
  if (startYear !== endYear) {
    range = `${startMonth} ${start.getUTCDate()}, ${startYear} – ${endMonth} ${end.getUTCDate()}, ${endYear}`;
  } else if (startMonth !== endMonth) {
    range = `${startMonth} ${start.getUTCDate()} – ${endMonth} ${end.getUTCDate()}`;
  } else {
    range = `${startMonth} ${start.getUTCDate()} – ${end.getUTCDate()}`;
  }
  return `${range} · ${dayLabel}`;
}

export interface DayGroup {
  localDate: string;
  dayNumber: number;
  items: PublicTripItem[];
}

/**
 * Groups items by their own local calendar date (per-item tz). Items arrive
 * already ordered by starts_at (get_public_trip's own ORDER BY); grouping
 * preserves that order, so day groups come out chronological too.
 */
export function groupByLocalDay(items: PublicTripItem[], tripStartDate: string): DayGroup[] {
  const order: string[] = [];
  const byDate = new Map<string, PublicTripItem[]>();

  for (const item of items) {
    const key = localDateKey(item.starts_at, item.tz);
    if (!byDate.has(key)) {
      byDate.set(key, []);
      order.push(key);
    }
    byDate.get(key)!.push(item);
  }

  return order.map((localDate) => ({
    localDate,
    dayNumber: dayNumberFor(localDate, tripStartDate),
    items: byDate.get(localDate)!,
  }));
}

/** Token shape for /t/:token -- matches share_links.token (pgcrypto gen_random_bytes(16) as hex = 32 lowercase hex chars), with slack either side. */
export const SHARE_TOKEN_PATTERN = /^[a-f0-9]{16,64}$/;

/** Token shape for /join/:token, per spec: plain alphanumeric, case-insensitive. */
export const INVITE_TOKEN_PATTERN = /^[A-Za-z0-9]{1,128}$/;
