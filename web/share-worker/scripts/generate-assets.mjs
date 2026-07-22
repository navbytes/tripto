#!/usr/bin/env node
// Regenerates the bundled brand/SEO images:
//   src/assets/og.jpg              1200×630 social share card (og:image)
//   src/assets/apple-touch-icon.png 180×180 home-screen icon
//
// Usage:  npm i --no-save playwright-core && node scripts/generate-assets.mjs
// Set CHROMIUM_PATH if your Chromium lives somewhere unusual.
//
// Deliberately shape/typography-only (no emoji): render hosts often lack
// color-emoji fonts, and tofu boxes in a social card are not the vibe.

import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { mkdirSync, existsSync } from "node:fs";

const here = dirname(fileURLToPath(import.meta.url));
const outDir = join(here, "..", "src", "assets");
mkdirSync(outDir, { recursive: true });

const chromiumPath =
  process.env.CHROMIUM_PATH ??
  ["/opt/pw-browsers/chromium", "/usr/bin/chromium", "/usr/bin/chromium-browser"].find(existsSync);

const INK = "#221533";
const DARK = "#1B1030";
const GRAD = "linear-gradient(115deg,#FF3E9E 0%,#B44CF0 45%,#8B5CF6 62%,#2DD9C8 100%)";
const GRAD_LIGHT = "linear-gradient(100deg,#FF9AD3 0%,#C4A8FF 55%,#6FE8DA 100%)";

const sparkle = (size, color, opacity = 1) =>
  `<svg width="${size}" height="${size}" viewBox="0 0 24 24" style="opacity:${opacity}"><path d="M12 0l2.6 9.4L24 12l-9.4 2.6L12 24l-2.6-9.4L0 12l9.4-2.6z" fill="${color}"/></svg>`;

// The Tripto logo mark: paper-plane dart + contrail (traced from the app
// icon). Keep in sync with logoMark() in src/templates.ts.
const dart = (size, color = "#fff", opacity = 1) =>
  `<svg width="${size}" height="${size}" viewBox="0 0 24 24" fill="none" style="opacity:${opacity}"><path d="M21.6 2.4 3.2 9.9l7.3 2.5 2.5 8.2z" fill="${color}"/><path d="M21.6 2.4 10.5 12.4" stroke="${color}" stroke-width="1.1" opacity=".45"/><path d="M9.4 14.3c-2.2 2.7-4.6 4.8-7 6.4" stroke="${color}" stroke-width="1.5" stroke-linecap="round" opacity=".65"/></svg>`;

const OG_HTML = `<!doctype html><html><head><meta charset="utf-8"><style>
*{margin:0;padding:0;box-sizing:border-box}
body{width:1200px;height:630px;background:${GRAD};font-family:"Liberation Sans","DejaVu Sans",sans-serif;overflow:hidden}
.card{position:absolute;inset:16px;background:${DARK};border-radius:34px;overflow:hidden;
  background-image:radial-gradient(560px 380px at 8% -10%,rgba(255,62,158,.4),transparent 60%),
    radial-gradient(520px 400px at 96% 6%,rgba(45,217,200,.3),transparent 60%),
    radial-gradient(720px 500px at 55% 120%,rgba(139,92,246,.45),transparent 62%)}
.inner{position:absolute;inset:0;padding:64px 72px;display:flex;flex-direction:column;justify-content:space-between}
.wordmark{display:flex;align-items:center;gap:20px}
.wordmark .t{font-size:96px;font-weight:bold;letter-spacing:-4px;color:#fff}
.tag{font-size:57px;font-weight:bold;letter-spacing:-1.5px;line-height:1.14;color:#fff;max-width:900px}
.tag .g{background:${GRAD_LIGHT};-webkit-background-clip:text;background-clip:text;color:transparent}
.pills{display:flex;gap:16px;flex-wrap:wrap}
.pill{border:3px solid rgba(255,255,255,.75);color:#fff;border-radius:999px;padding:14px 26px;font-size:25px;font-weight:bold}
.pill.solid{background:#FFC93E;color:${INK};border-color:${INK};transform:rotate(-2deg);box-shadow:5px 5px 0 rgba(0,0,0,.4)}
.spark{position:absolute}
.dartbig{position:absolute;right:36px;bottom:170px;filter:drop-shadow(0 0 46px rgba(139,92,246,.85))}
</style></head><body>
<div class="card">
  <span class="dartbig">${dart(230, "#fff", 0.96)}</span>
  <span class="spark" style="top:78px;right:120px">${sparkle(54, "#FFC93E")}</span>
  <span class="spark" style="top:170px;right:66px">${sparkle(30, "#6FE8DA", 0.9)}</span>
  <span class="spark" style="bottom:200px;left:44px">${sparkle(26, "#FF9AD3", 0.8)}</span>
  <div class="inner">
    <div class="wordmark">
      ${dart(62)}
      <span class="t">tripto</span>
      <span style="flex:1"></span>
      <span class="pill solid">coming soon · App Store</span>
    </div>
    <div class="tag">One shared itinerary.<br><span class="g">Zero group-chat chaos.</span></div>
    <div class="pills">
      <span class="pill">group trip planner</span>
      <span class="pill">every time zone handled</span>
      <span class="pill">works offline</span>
      <span class="pill">grandma-approved</span>
    </div>
  </div>
</div>
</body></html>`;

const ICON_HTML = `<!doctype html><html><head><meta charset="utf-8"><style>
*{margin:0;padding:0}
body{width:180px;height:180px;background:${GRAD};overflow:hidden;position:relative}
.d{position:absolute;inset:0;display:flex;align-items:center;justify-content:center;
  filter:drop-shadow(0 4px 0 rgba(34,21,51,.28))}
</style></head><body>
<div class="d">${dart(122)}</div>
</body></html>`;

const { chromium } = await import("playwright-core");
const browser = await chromium.launch({ executablePath: chromiumPath });

async function shoot(html, { width, height, out, type, quality }) {
  const page = await browser.newPage({ viewport: { width, height } });
  await page.setContent(html, { waitUntil: "networkidle" });
  await page.screenshot({ path: out, type, ...(quality ? { quality } : {}) });
  await page.close();
  console.log("wrote", out);
}

await shoot(OG_HTML, { width: 1200, height: 630, out: join(outDir, "og.jpg"), type: "jpeg", quality: 88 });
await shoot(ICON_HTML, { width: 180, height: 180, out: join(outDir, "apple-touch-icon.png"), type: "png" });

await browser.close();
