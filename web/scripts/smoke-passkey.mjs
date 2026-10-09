// Browser test of the passkey-remembered key (not part of `npm test`): serves
// dist/ and a vault (WebDAV-style, minimal PROPFIND) on http://localhost, and
// drives the viewer in Chromium with a CDP virtual authenticator (CTAP2,
// user verification, PRF). Checks: remember after a pasted unlock, only
// ciphertext in IndexedDB, unlock with the passkey after Lock, Forget, and
// that an authenticator without PRF stores nothing.
// Usage: npm run build && node scripts/smoke-passkey.mjs VAULT_DIR KEY_FILE
import { createServer } from "node:http";
import { readFileSync, readdirSync, statSync, existsSync } from "node:fs";
import { join, extname } from "node:path";
// PLAYWRIGHT: path to playwright/index.mjs when it is not installed here.
const { chromium } = await import(process.env.PLAYWRIGHT ?? "playwright");

const [vaultDir, keyFile] = process.argv.slice(2);
const dist = join(import.meta.dirname, "..", "dist");
const types = { ".html": "text/html", ".js": "text/javascript", ".mjs": "text/javascript", ".css": "text/css", ".json": "application/json" };

const server = createServer((req, res) => {
  const path = decodeURIComponent(new URL(req.url, "http://x").pathname);
  const send = (status, body, type = "application/octet-stream") => { res.writeHead(status, { "content-type": type }); res.end(body); };
  if (path.startsWith("/dav/")) {
    const rel = path.slice(5);
    if (rel.includes("..")) return send(400, "");
    const file = join(vaultDir, rel);
    if (req.method === "PROPFIND") {
      if (!existsSync(file) || !statSync(file).isDirectory()) return send(404, "");
      const items = readdirSync(file).map((n) => `<d:response><d:href>/dav/${rel}${encodeURIComponent(n)}${statSync(join(file, n)).isDirectory() ? "/" : ""}</d:href></d:response>`);
      return send(207, `<?xml version="1.0"?><d:multistatus xmlns:d="DAV:"><d:response><d:href>/dav/${rel}</d:href></d:response>${items.join("")}</d:multistatus>`, "application/xml");
    }
    if (rel === "sempere-index.json" || !existsSync(file) || statSync(file).isDirectory()) return send(404, "");
    return send(200, readFileSync(file));
  }
  const f = join(dist, path === "/" ? "index.html" : path);
  if (!existsSync(f)) return send(404, "");
  send(200, readFileSync(f), types[extname(f)] ?? "application/octet-stream");
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
// localhost, not 127.0.0.1: an IP address is not a valid WebAuthn RP ID.
const base = `http://localhost:${server.address().port}`;
const key = readFileSync(keyFile, "utf8");
const secretLine = key.split("\n").find((l) => l.startsWith("AGE-SECRET-KEY-PQ-1"));

const browser = await chromium.launch();
let failures = 0;
const check = (ok, what) => {
  console.log(ok ? "ok  " : "FAIL", what);
  if (!ok) failures++;
};

async function withAuthenticator(options) {
  const context = await browser.newContext();
  const page = await context.newPage();
  const problems = [];
  page.on("console", (m) => { if (m.type() === "error" && !m.text().includes("404")) problems.push(m.text()); });
  page.on("pageerror", (e) => problems.push(String(e)));
  const cdp = await context.newCDPSession(page);
  await cdp.send("WebAuthn.enable");
  const { authenticatorId } = await cdp.send("WebAuthn.addVirtualAuthenticator", {
    options: {
      protocol: "ctap2", ctap2Version: "ctap2_1", transport: "internal", hasResidentKey: true,
      hasUserVerification: true, isUserVerified: true, automaticPresenceSimulation: true, ...options,
    },
  });
  return { context, page, cdp, authenticatorId, problems };
}

async function openVault(page) {
  await page.goto(`${base}/`);
  await page.fill("input[type=url]", `${base}/dav/`);
  await page.selectOption("select", "webdav");
  await page.click("form button[type=submit]");
  await page.waitForSelector("textarea");
}

const unlocked = (page) => page.waitForFunction(() => /\d+ notes?( ·|$)/.test(document.querySelector(".status")?.textContent ?? ""), null, { timeout: 30000 });

const records = (page) => page.evaluate(() => new Promise((resolve, reject) => {
  const r = indexedDB.open("sempere-viewer", 1);
  r.onupgradeneeded = () => r.result.createObjectStore("passkey-keys", { keyPath: "vaultId" });
  r.onerror = () => reject(r.error);
  r.onsuccess = () => {
    const all = r.result.transaction("passkey-keys").objectStore("passkey-keys").getAll();
    all.onsuccess = () => resolve(all.result.map((x) => ({
      keys: Object.keys(x).sort(),
      text: [x.credentialId, x.salt, x.iv, x.ciphertext].map((b) => String.fromCharCode(...new Uint8Array(b instanceof ArrayBuffer ? b : b.buffer))).join("|"),
    })));
    all.onerror = () => reject(all.error);
  };
}));

// 1. With PRF: remember, unlock with the passkey, forget.
{
  const { context, page, cdp, authenticatorId, problems } = await withAuthenticator({ hasPrf: true });
  await openVault(page);
  await page.fill("textarea", key);
  await page.check("form:has(textarea) label.check input");
  await page.click("form:has(textarea) button[type=submit]");
  await page.click("text=Create passkey");
  await unlocked(page);
  check(true, "pasted key unlocked, passkey created");
  const stored = await records(page);
  check(stored.length === 1, `one record stored (${stored.length})`);
  check(JSON.stringify(stored[0]?.keys) === JSON.stringify(["ciphertext", "created", "credentialId", "iv", "location", "salt", "vaultId", "version"]), `record fields ${JSON.stringify(stored[0]?.keys)}`);
  check(!stored[0]?.text.includes(secretLine.slice(0, 24)) && !stored[0]?.text.includes("AGE-SECRET"), "no key text in IndexedDB");
  const { credentials } = await cdp.send("WebAuthn.getCredentials", { authenticatorId });
  check(credentials.length === 1, `one passkey in the authenticator (${credentials.length})`);

  await page.click("text=Lock");
  await openVault(page);
  await page.click("text=Unlock with passkey");
  await unlocked(page);
  check(true, "unlocked with the passkey after Lock");

  await page.click("text=Lock");
  await openVault(page);
  await page.waitForSelector("text=Forget this key");
  await page.click("text=Forget this key");
  await page.waitForSelector("textarea");
  await page.waitForTimeout(300);
  check(await page.locator("text=Unlock with passkey").count() === 0, "forgotten: no passkey button");
  check((await records(page)).length === 0, "forgotten: IndexedDB empty");
  check(problems.length === 0, `no page errors ${JSON.stringify(problems)}`);
  await context.close();
}

// 2. Without PRF: an explanation, nothing stored, the vault still opens.
{
  const { context, page } = await withAuthenticator({ hasPrf: false });
  await openVault(page);
  await page.fill("textarea", key);
  const disabled = await page.isDisabled("form:has(textarea) label.check input");
  if (!disabled) {
    await page.check("form:has(textarea) label.check input");
    await page.click("form:has(textarea) button[type=submit]");
    await page.click("text=Create passkey");
    await page.waitForSelector(".error", { timeout: 30000 });
    const text = await page.textContent(".error");
    check(/PRF/.test(text ?? ""), `explains the missing PRF: ${text}`);
    check((await records(page)).length === 0, "no PRF: nothing stored");
    await page.click("text=Continue without");
    await unlocked(page);
    check(true, "no PRF: vault opens without remembering");
  } else {
    check((await records(page)).length === 0, "no PRF reported up front: option disabled, nothing stored");
  }
  await context.close();
}

await browser.close();
server.close();
process.exit(failures ? 1 : 0);
