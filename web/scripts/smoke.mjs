// Browser smoke test (not part of `npm test`): serves dist/ and a vault on one
// origin, at /static/ (sempere-index.json) and /dav/ (minimal PROPFIND), and
// drives the viewer in Chromium with Playwright.
// Usage: node scripts/smoke.mjs VAULT_DIR KEY_FILE [SCREENSHOT_DIR [SEARCH_TERM]]
import { createServer } from "node:http";
import { readFileSync, readdirSync, statSync, existsSync } from "node:fs";
import { join, extname } from "node:path";
// PLAYWRIGHT: path to playwright/index.mjs when it is not installed here.
const { chromium } = await import(process.env.PLAYWRIGHT ?? "playwright");

const [vaultDir, keyFile, shots = ".", term] = process.argv.slice(2);
const dist = join(import.meta.dirname, "..", "dist");
const types = { ".html": "text/html", ".js": "text/javascript", ".css": "text/css", ".json": "application/json" };

const server = createServer((req, res) => {
  const url = new URL(req.url, "http://x");
  const path = decodeURIComponent(url.pathname);
  const send = (status, body, type = "application/octet-stream") => { res.writeHead(status, { "content-type": type }); res.end(body); };
  for (const prefix of ["/static/", "/dav/"]) {
    if (!path.startsWith(prefix)) continue;
    const rel = path.slice(prefix.length);
    if (rel.includes("..")) return send(400, "");
    const file = join(vaultDir, rel);
    if (req.method === "PROPFIND" && prefix === "/dav/") {
      if (!existsSync(file) || !statSync(file).isDirectory()) return send(404, "");
      const items = readdirSync(file).map((n) => `<d:response><d:href>${prefix}${rel}${encodeURIComponent(n)}${statSync(join(file, n)).isDirectory() ? "/" : ""}</d:href></d:response>`);
      return send(207, `<?xml version="1.0"?><d:multistatus xmlns:d="DAV:"><d:response><d:href>${prefix}${rel}</d:href></d:response>${items.join("")}</d:multistatus>`, "application/xml");
    }
    if (prefix === "/dav/" && rel === "sempere-index.json") return send(404, "");
    if (!existsSync(file) || statSync(file).isDirectory()) return send(404, "");
    return send(200, readFileSync(file));
  }
  const f = join(dist, path === "/" ? "index.html" : path);
  if (!existsSync(f)) return send(404, "");
  send(200, readFileSync(f), types[extname(f)] ?? "application/octet-stream");
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const base = `http://127.0.0.1:${server.address().port}`;
const key = readFileSync(keyFile, "utf8");

const browser = await chromium.launch();
let failures = 0;
for (const mount of ["static", "dav"]) {
  const page = await browser.newPage({ viewport: { width: 1400, height: 900 } });
  const problems = [];
  // 404s are expected: rewrap-journal.json, and the index on the WebDAV mount.
  page.on("console", (m) => { if ((m.type() === "error" || m.type() === "warning") && !m.text().includes("404")) problems.push(m.text()); });
  page.on("pageerror", (e) => problems.push(String(e)));
  await page.goto(`${base}/`);
  await page.fill("input[type=url]", `${base}/${mount}/`);
  await page.click("form button[type=submit]");
  await page.fill("textarea", key);
  await page.click("form button[type=submit]");
  await page.waitForFunction(() => /\d+ notes?( ·|$)/.test(document.querySelector(".status")?.textContent ?? ""), null, { timeout: 30000 });
  const status = await page.textContent(".status");
  const titles = await page.$$eval(".note-list .title", (els) => els.map((e) => e.textContent));
  await page.click(".note-list button.note >> nth=0");
  await page.waitForSelector(".page svg", { timeout: 30000 });
  await page.screenshot({ path: join(shots, `smoke-${mount}.png`) });
  await page.click(".note-list button.note >> nth=-1");
  await page.waitForSelector(".page svg", { timeout: 30000 });
  await page.keyboard.press("Escape");
  await page.click(".zoom-bar button >> nth=0");
  await page.click(".zoom-bar button >> nth=0");
  await page.click(".zoom-bar button >> nth=0");
  await page.waitForTimeout(300);
  await page.screenshot({ path: join(shots, `smoke-${mount}-papers.png`) });
  await page.fill("input[type=search]", term ?? "");
  await page.waitForTimeout(400);
  const hits = await page.$$eval(".note-list .title", (els) => els.map((e) => e.textContent));
  console.log(mount, "|", status, "|", JSON.stringify(titles), `| search ${term ?? "(none)"}:`, JSON.stringify(hits), "| problems:", JSON.stringify(problems));
  if (problems.length || titles.length === 0 || (term && hits.length === 0)) failures++;
  await page.close();
}
await browser.close();
server.close();
process.exit(failures ? 1 : 0);
