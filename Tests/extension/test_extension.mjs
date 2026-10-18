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
const EXT = process.env.MDM_EXT || path.resolve(here, "../../BrowserExtension/chrome");
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
const received = [];
const bridge = http.createServer((req, res) => {
  let body = "";
  req.on("data", (c) => (body += c));
  req.on("end", () => {
    if (!appRunning) {
      res.writeHead(503);
      return res.end();
    }
    res.setHeader("Content-Type", "application/json");
    if (req.url.startsWith("/ping")) return res.end('{"ok":true,"app":"MacOS Download Manager"}');
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
  profile: { default_content_setting_values: { automatic_downloads: 1 } }
}));

const browser = await puppeteer.launch({
  headless: process.env.MDM_HEADLESS === "1",
  userDataDir: profile,
  executablePath: process.env.MDM_CHROME || undefined,
  ignoreDefaultArgs: ["--disable-extensions"],
  args: [
    `--disable-extensions-except=${EXT}`,
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

  // 4. The app got the link but its answer was lost: the browser must still stop its own copy.
  clear();
  received.length = 0;
  dropAnswers = true;
  await clickDownload("/files/big.bin");
  await sleep(7000);
  dropAnswers = false;
  check(received.length === 1, `link sent to the app although the answer was lost (received: ${received.length})`);
  check(files().length === 0, `browser stopped its copy when the answer was lost (files: ${JSON.stringify(files())})`);
} catch (e) {
  failures++;
  console.log(`::error::Extension test crashed: ${e && e.stack ? e.stack.split("\n").slice(0, 3).join(" | ") : e}`);
} finally {
  await browser.close().catch(() => {});
  bridge.close();
}

console.log(failures ? `${failures} check(s) failed` : "all extension checks passed");
process.exit(failures ? 1 : 0);
