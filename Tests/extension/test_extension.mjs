// End-to-end test of the browser extension in a real Chromium (Chrome for Testing):
//  - when the app does not answer, the browser downloads the file itself
//  - when the app accepts the link, the browser must NOT download it (no double download)
//  - links without a file name that redirect to the file (like go.microsoft.com/fwlink) are captured
//
// Needs scripts/test_server.py running (MDM_TEST_SERVER). A fake "app" listens on 127.0.0.1:9614.
import http from "node:http";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const puppeteer = (await import(process.env.MDM_PUPPETEER || "puppeteer")).default;
const here = path.dirname(fileURLToPath(import.meta.url));
const SOURCE_EXT = process.env.MDM_EXT || path.resolve(here, "../../BrowserExtension/chrome");
// Test copy of the extension whose YouTube script also runs on the local test server's /watch page.
const EXT = fs.mkdtempSync(path.join(os.tmpdir(), "mdm-ext-"));
fs.cpSync(SOURCE_EXT, EXT, { recursive: true });
{
  const manifestPath = path.join(EXT, "manifest.json");
  const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
  for (const script of manifest.content_scripts || []) script.matches.push("http://127.0.0.1/*");
  fs.writeFileSync(manifestPath, JSON.stringify(manifest, null, 2));
}
const SERVER = process.env.MDM_TEST_SERVER || "http://127.0.0.1:8765";
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

let failures = 0;
function check(condition, message) {
  if (condition) {
    console.log(`✔ ${message}`);
  } else {
    failures++;
    console.log(`✘ ${message}`);
    console.log(`::error::Extension test: ${message}`);
  }
}

// Fake MacOS Download Manager bridge
let appRunning = false;
let dropAnswers = false; // simulate an answer that never reaches the browser
let shippedExtension = null; // extension version the fake app says it ships (in /ping answers)
const received = [];
const mediaReceived = [];
const requestPaths = [];
const bridge = http.createServer((req, res) => {
  requestPaths.push(req.url);
  let body = "";
  req.on("data", (c) => (body += c));
  req.on("end", () => {
    if (!appRunning) {
      res.writeHead(503);
      return res.end();
    }
    res.setHeader("Content-Type", "application/json");
    if (req.url.startsWith("/ping")) {
      return res.end(JSON.stringify({ ok: true, app: "MacOS Download Manager", ...(shippedExtension ? { extension: shippedExtension } : {}) }));
    }
    if (req.url.startsWith("/media")) {
      try { mediaReceived.push(JSON.parse(body)); } catch (e) { mediaReceived.push({ invalid: body }); }
      return res.end('{"ok":true}');
    }
    if (req.url.startsWith("/download")) {
      try { received.push(JSON.parse(body)); } catch (e) { received.push({ invalid: body }); }
      if (dropAnswers) return req.socket.destroy();
      return res.end('{"ok":true}');
    }
    res.writeHead(404);
    res.end("{}");
  });
});
await new Promise((r) => bridge.listen(9614, "127.0.0.1", r));

// Browser profile: download into a temp folder without asking
const profile = fs.mkdtempSync(path.join(os.tmpdir(), "mdm-profile-"));
const downloads = fs.mkdtempSync(path.join(os.tmpdir(), "mdm-downloads-"));
fs.mkdirSync(path.join(profile, "Default"), { recursive: true });
fs.writeFileSync(path.join(profile, "Default", "Preferences"), JSON.stringify({
  download: { default_directory: downloads, prompt_for_download: process.env.MDM_PROMPT === "1", directory_upgrade: true },
  profile: { default_content_setting_values: { automatic_downloads: 1 } },
  // Like the user's browser: "Load unpacked" needs Developer mode, and Chrome reloads unpacked extensions only with it.
  extensions: { ui: { developer_mode: true } }
}));

const browser = await puppeteer.launch({
  headless: process.env.MDM_HEADLESS === "1",
  userDataDir: profile,
  executablePath: process.env.MDM_CHROME || undefined,
  ignoreDefaultArgs: ["--disable-extensions"],
  args: [
    `--load-extension=${EXT}`,
    "--no-first-run",
    "--no-default-browser-check",
    "--no-proxy-server",
    ...(process.env.MDM_NO_SANDBOX === "1" ? ["--no-sandbox"] : [])
  ]
});

const files = () => fs.readdirSync(downloads).filter((f) => !f.startsWith("."));
const clear = () => { for (const f of fs.readdirSync(downloads)) fs.rmSync(path.join(downloads, f), { force: true }); };

async function clickDownload(href) {
  const page = await browser.newPage();
  await page.goto(`${SERVER}/page?href=${encodeURIComponent(href)}`);
  await page.click("#dl");
  return page;
}

try {
  const worker = await browser.waitForTarget(
    (t) => t.type() === "service_worker" && t.url().startsWith("chrome-extension://"),
    { timeout: 30000 }
  );
  check(!!worker, "extension service worker started");

  // 1. Control: the app does not answer → the browser downloads the file normally.
  appRunning = false;
  clear();
  await clickDownload("/files/big.bin");
  let done = false;
  for (let i = 0; i < 60 && !done; i++) {
    await sleep(500);
    done = files().includes("big.bin");
  }
  check(done, "without the app the browser downloads the file itself");

  // 2. The app accepts the link → only the app downloads it.
  appRunning = true;
  clear();
  received.length = 0;
  await clickDownload("/files/big.bin");
  await sleep(6000);
  check(received.length === 1 && String(received[0].url).endsWith("/files/big.bin"),
        `link sent to the app (received: ${JSON.stringify(received.map((r) => r.url))})`);
  check(files().length === 0, `browser did not download it too (files: ${JSON.stringify(files())})`);

  // 3. Address without a file name that redirects to the file (like go.microsoft.com/fwlink).
  clear();
  received.length = 0;
  await clickDownload("/redirect/big.iso");
  await sleep(6000);
  check(received.length === 1 && String(received[0].url).endsWith("/files/big.iso"),
        `redirected link sent to the app (received: ${JSON.stringify(received.map((r) => r.url))})`);
  check(files().length === 0, `browser did not download the redirected file too (files: ${JSON.stringify(files())})`);

  // 5. "Download video from this page" sends the page to the app's video downloader.
  if (process.env.MDM_SKIP_SW_EVAL !== "1") {
    const timeout = (ms) => new Promise((_, reject) => setTimeout(() => reject(new Error("timeout")), ms));
    const sent = await Promise.race([
      (async () => (await worker.worker()).evaluate(() => sendMediaPage("https://www.youtube.com/watch?v=BaW_jenozKc", "Test video")))(),
      timeout(15000)
    ]).catch((e) => `error: ${e.message}`);
    check(sent === true && mediaReceived.length === 1 && mediaReceived[0].url.includes("BaW_jenozKc"),
          `video page sent to the app (sent: ${sent}, received: ${JSON.stringify(mediaReceived)})`);
  }

  // 6. The "Download video" button appears on a YouTube-like page (with Trusted Types) and sends the page.
  mediaReceived.length = 0;
  const watch = await browser.newPage();
  await watch.goto(`${SERVER}/watch?v=test123&list=RDtest&t=61s`);
  const button = await watch.waitForSelector("#mdm-download-video", { timeout: 8000 }).catch(() => null);
  check(!!button, "Download video button shown on the video page");
  if (button) {
    await button.click();
    await sleep(2500);
  }
  check(mediaReceived.length === 1 && String(mediaReceived[0].url).includes("/watch?v=test123"),
        `button sent the video page to the app (received: ${JSON.stringify(mediaReceived.map((m) => m.url))})`);
  const manifestVersion = JSON.parse(fs.readFileSync(path.join(EXT, "manifest.json"), "utf8")).version;
  check(requestPaths.some((p) => p.includes(`ext=${manifestVersion}`)),
        `requests report the extension version ${manifestVersion} (e.g. ${requestPaths[requestPaths.length - 1]})`);

  // 4. The app got the link but its answer was lost: the browser must still stop its own copy.
  clear();
  received.length = 0;
  dropAnswers = true;
  await clickDownload("/files/big.bin");
  await sleep(7000);
  dropAnswers = false;
  // The browser may resend a request whose connection broke; the app ignores repeats of the same link.
  check(received.length >= 1, `link sent to the app although the answer was lost (received: ${received.length})`);
  check(files().length === 0, `browser stopped its copy when the answer was lost (files: ${JSON.stringify(files())})`);

  // 7. The app refreshed the extension folder with a newer version: the extension reloads itself.
  const extId = new URL(worker.url()).host;
  const extensionState = async () => {
    const p = await browser.newPage();
    try {
      await p.goto(`chrome-extension://${extId}/popup.html`, { timeout: 5000 });
      return await p.evaluate(async () => {
        const disk = await fetch(chrome.runtime.getURL("manifest.json"), { cache: "no-store" })
          .then((r) => r.json()).then((j) => j.version, (e) => "fetch failed: " + e);
        return `loaded=${chrome.runtime.getManifest().version} disk=${disk}`;
      });
    } catch (e) {
      return "page: " + String(e.message || e).slice(0, 60);
    } finally {
      await p.close().catch(() => {});
    }
  };
  const internals = async () => {
    const q = await browser.newPage();
    try {
      await q.goto("chrome://extensions-internals", { timeout: 5000 });
      const text = await q.evaluate(() => document.body.innerText);
      const at = text.indexOf(extId);
      if (at < 0) return "id not listed";
      const part = text.slice(at, at + 4000);
      const pick = (k) => (part.match(new RegExp(`"${k}":\\s*("[^"]*"|\\[[^\\]]*\\]|\\w+)`)) || [])[1];
      return ["state", "disable_reasons", "version", "location", "blocklist_state"].map((k) => `${k}=${pick(k)}`).join(" ");
    } catch (e) {
      return "internals: " + e.message;
    } finally {
      await q.close().catch(() => {});
    }
  };
  const before = await extensionState();
  const manifestFile = path.join(EXT, "manifest.json");
  const updated = JSON.parse(fs.readFileSync(manifestFile, "utf8"));
  const newVersion = "99.0.0";
  updated.version = newVersion;
  fs.writeFileSync(manifestFile, JSON.stringify(updated, null, 2));
  shippedExtension = newVersion;
  appRunning = true;
  const afterWrite = await extensionState();
  try {
    const w = await worker.worker();
    await Promise.race([w.evaluate(() => ping()), sleep(5000)]);
  } catch (e) { /* the worker may already be reloading */ }
  let seen = "";
  let reloaded = false;
  for (let i = 0; i < 12 && !reloaded; i++) {
    await sleep(1500);
    seen = await extensionState();
    reloaded = seen.startsWith(`loaded=${newVersion}`);
  }
  const chromeView = reloaded ? "" : await internals();
  check(reloaded, `extension reloaded itself after an update on disk (before: ${before}; after write: ${afterWrite}; end: ${seen}; chrome: ${chromeView}; last request: ${requestPaths[requestPaths.length - 1]})`);
} catch (e) {
  failures++;
  console.log(`::error::Extension test crashed: ${e && e.stack ? e.stack.split("\n").slice(0, 3).join(" | ") : e}`);
} finally {
  await browser.close().catch(() => {});
  bridge.close();
}

console.log(failures ? `${failures} check(s) failed` : "all extension checks passed");
process.exit(failures ? 1 : 0);
