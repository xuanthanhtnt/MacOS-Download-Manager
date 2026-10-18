// MacOS Download Manager browser integration (Chrome / Edge / Brave / Opera / Vivaldi / Arc / Firefox)
// Captures downloads and media streams and sends them to the MacOS Download Manager app on 127.0.0.1.

// Firefox also provides the `chrome` namespace (callbacks and promises), so prefer it everywhere.
const api = globalThis.chrome ?? globalThis.browser;

const DEFAULTS = {
  enabled: true,
  port: 9614,
  minSizeKB: 0,
  extensions: [
    "zip", "rar", "7z", "gz", "tgz", "bz2", "xz", "tar", "zst",
    "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "epub",
    "mp3", "wav", "flac", "aac", "m4a", "ogg", "opus",
    "dmg", "pkg", "exe", "msi", "apk", "ipa", "deb", "rpm", "iso", "img", "bin", "jar",
    "mp4", "mkv", "avi", "mov", "wmv", "flv", "webm", "m4v", "mpg", "mpeg", "3gp", "ts"
  ]
};

const sessionStore = api.storage.session ?? api.storage.local;

const MEDIA_TYPES = /^(video\/|audio\/)|mpegurl|dash\+xml/i;
const MEDIA_EXT = /\.(m3u8|mp4|webm|mkv|mov|m4v|flv|mp3|m4a|aac|ts)(\?|#|$)/i;

async function settings() {
  const stored = await api.storage.local.get(DEFAULTS);
  return { ...DEFAULTS, ...stored };
}

const EXTENSION_VERSION = api.runtime.getManifest().version;

/**
 * The app copies its newer extension into the folder the browser loads it from. Unpacked extensions
 * are read from disk, so a newer manifest.json there means an update is waiting: reload to apply it.
 */
async function reloadIfUpdatedOnDisk() {
  try {
    const res = await fetch(api.runtime.getURL("manifest.json"), { cache: "no-store" });
    const onDisk = (await res.json()).version;
    if (onDisk && onDisk !== EXTENSION_VERSION) {
      console.log(`MacOS Download Manager extension ${EXTENSION_VERSION} → ${onDisk}: reloading`);
      api.runtime.reload();
      return true;
    }
  } catch (e) {
    // Not an unpacked copy, or the file is being replaced right now: try again later.
  }
  return false;
}

function endpoint(port, path) {
  const separator = path.includes("?") ? "&" : "?";
  return `http://127.0.0.1:${port}${path}${separator}ext=${encodeURIComponent(EXTENSION_VERSION)}`;
}

async function cookiesFor(url) {
  try {
    const list = await api.cookies.getAll({ url });
    return list.map((c) => `${c.name}=${c.value}`).join("; ");
  } catch (e) {
    return "";
  }
}

async function fetchWithTimeout(url, options, ms) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), ms);
  try {
    return await fetch(url, { ...options, signal: controller.signal });
  } finally {
    clearTimeout(timer);
  }
}

async function ping() {
  const { port } = await settings();
  try {
    const res = await fetchWithTimeout(endpoint(port, "/ping"), { method: "GET" }, 2000);
    if (res.ok) {
      // The app tells which extension version it ships; a different one means an update is on disk.
      const info = await res.clone().json().catch(() => ({}));
      if (info.extension && info.extension !== EXTENSION_VERSION) setTimeout(reloadIfUpdatedOnDisk, 1000);
    }
    return res.ok;
  } catch (e) {
    return false;
  }
}

/**
 * Sends a request to the app. Returns true when the app accepted it.
 * If the answer is lost (network error, timeout) but the app is running, the request reached it:
 * the app ignores repeats of the same link, so the browser's copy can safely be stopped.
 */
async function post(path, payload) {
  const { port } = await settings();
  try {
    const res = await fetchWithTimeout(endpoint(port, path), {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload)
    }, 5000);
    return res.ok;
  } catch (e) {
    return await ping();
  }
}

/** Sends a web page that contains a video (YouTube, …) to the app's video downloader. */
async function sendMediaPage(url, title) {
  if (!/^https?:/i.test(url || "")) return false;
  return post("/media", { url, title: title || "" });
}

async function sendDownload({ url, referrer, fileName, fileSize, mime }) {
  const cookies = await cookiesFor(url);
  return post("/download", {
    url,
    referrer: referrer || "",
    cookies,
    userAgent: navigator.userAgent,
    fileName: fileName || "",
    fileSize: fileSize || 0,
    mime: mime || ""
  });
}

function extensionOf(url, filename) {
  const source = filename || url || "";
  const clean = source.split(/[?#]/)[0];
  const name = clean.split(/[\\/]/).pop() || "";
  const dot = name.lastIndexOf(".");
  return dot >= 0 ? name.slice(dot + 1).toLowerCase() : "";
}

function baseName(path) {
  return (path || "").split(/[\\/]/).pop() || "";
}

// MIME types that are always real file downloads (links such as go.microsoft.com/fwlink/?LinkId=…
// have no file extension in the address, so the type or the final file name decides).
const BINARY_MIME = /^(application\/(octet-stream|x-iso9660-image|x-cd-image|zip|x-zip|x-zip-compressed|x-rar|x-rar-compressed|vnd\.rar|x-7z-compressed|gzip|x-gzip|x-tar|x-bzip2|x-xz|zstd|x-apple-diskimage|x-msdownload|x-msi|x-ms-installer|x-msdos-program|vnd\.android\.package-archive|x-debian-package|x-redhat-package-manager|java-archive|epub\+zip|pdf)|video\/|audio\/)/i;

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function logEvent(text) {
  try { await sessionStore.set({ lastEvent: { text, time: Date.now() } }); } catch (e) {}
}

/** Waits briefly for the browser to determine the real file name (from Content-Disposition or redirects). */
async function resolvedFileName(item) {
  let name = baseName(item.filename);
  for (let i = 0; i < 12 && !name; i++) {
    await sleep(150);
    try {
      const [current] = await api.downloads.search({ id: item.id });
      name = baseName(current && current.filename);
    } catch (e) {
      break;
    }
  }
  return name;
}

// ---------------------------------------------------------------------------
// 1. Take over browser downloads
// ---------------------------------------------------------------------------

const handled = new Set();

/** Cancels the browser's own copy of a download and keeps trying until the browser has stopped it. */
async function cancelInBrowser(id) {
  for (let attempt = 0; attempt < 8; attempt++) {
    try { await api.downloads.cancel(id); } catch (e) {}
    let state = null;
    try {
      const [current] = await api.downloads.search({ id });
      state = current ? current.state : null;
    } catch (e) {}
    if (state !== "in_progress") break;
    await sleep(250);
  }
  try { await api.downloads.erase({ id }); } catch (e) {}
}

/**
 * Decides whether a browser download is taken over. Returns true when MacOS Download Manager accepted it
 * (the caller must then cancel the browser's copy).
 */
async function takeOver(item, waitForName) {
  const cfg = await settings();
  if (!cfg.enabled) return false;
  const url = item.finalUrl || item.url;
  if (!/^https?:|^ftp:/i.test(url)) return false; // blob:, data:, file: stay in the browser
  if (handled.has(item.id)) return false;
  handled.add(item.id);

  // Decide from the address, the file name and the MIME type.
  let name = baseName(item.filename);
  let ext = extensionOf(url, name) || extensionOf(item.url, "");
  let take = cfg.extensions.includes(ext) || BINARY_MIME.test(item.mime || "");
  if (!take && !name && waitForName) {
    name = await resolvedFileName(item);
    ext = extensionOf("", name);
    take = cfg.extensions.includes(ext);
  }
  if (!take) {
    await logEvent(`Left in the browser: ${name || url} (type “${ext || item.mime || "unknown"}” is not in the list)`);
    return false;
  }
  if (cfg.minSizeKB > 0 && item.fileSize > 0 && item.fileSize < cfg.minSizeKB * 1024) {
    await logEvent(`Left in the browser: ${name || url} (smaller than ${cfg.minSizeKB} KB)`);
    return false;
  }

  const ok = await sendDownload({
    url,
    referrer: item.referrer,
    fileName: name,
    fileSize: item.fileSize > 0 ? item.fileSize : item.totalBytes,
    mime: item.mime
  });
  await logEvent(ok
    ? `Sent to MacOS Download Manager: ${name || url}`
    : `MacOS Download Manager did not answer – the browser kept the download: ${name || url}`);
  return ok;
}

if (api.downloads.onDeterminingFilename) {
  // Chrome, Edge, Brave, Opera…: the browser waits for us before it chooses the file name,
  // shows a "Save as" dialog or writes the file, so the download can be stopped cleanly.
  api.downloads.onDeterminingFilename.addListener((item, suggest) => {
    let answered = false;
    const answer = () => {
      if (answered) return;
      answered = true;
      try { suggest(); } catch (e) {}
    };
    takeOver(item, false)
      .then(async (taken) => {
        if (taken) {
          await cancelInBrowser(item.id);
        }
        answer();
      })
      .catch((e) => {
        console.warn("MacOS Download Manager:", e);
        answer();
      });
    return true; // we call suggest() asynchronously
  });
} else {
  // Firefox: no onDeterminingFilename – take over as soon as the download is created.
  api.downloads.onCreated.addListener((item) => {
    takeOver(item, true)
      .then((taken) => (taken ? cancelInBrowser(item.id) : null))
      .catch((e) => console.warn("MacOS Download Manager:", e));
  });
}

// ---------------------------------------------------------------------------
// 2. Context menu
// ---------------------------------------------------------------------------

function createMenus() {
  const ignore = () => void api.runtime.lastError;
  api.contextMenus.removeAll(() => {
    ignore();
    api.contextMenus.create({
      id: "mdm-link",
      title: "Download with MacOS Download Manager",
      contexts: ["link", "image", "video", "audio"]
    }, ignore);
    api.contextMenus.create({
      id: "mdm-video",
      title: "Download video with MacOS Download Manager",
      contexts: ["page", "link", "video"]
    }, ignore);
    api.contextMenus.create({
      id: "mdm-all",
      title: "Download all links with MacOS Download Manager",
      contexts: ["page", "selection"]
    }, ignore);
  });
}

/** Adds the YouTube "Download video" button to tabs that were already open before install/update. */
async function injectIntoOpenYouTubeTabs() {
  try {
    const tabs = await api.tabs.query({ url: ["*://www.youtube.com/*", "*://m.youtube.com/*", "*://youtube.com/*"] });
    for (const tab of tabs) {
      try {
        await api.scripting.executeScript({ target: { tabId: tab.id }, files: ["youtube.js"] });
      } catch (e) {}
    }
  } catch (e) {}
}

api.runtime.onInstalled.addListener(() => {
  createMenus();
  injectIntoOpenYouTubeTabs();
  ping(); // tells the app which extension version is installed
});
api.runtime.onStartup?.addListener(() => {
  createMenus();
  ping();
});

function collectLinks() {
  const urls = new Set();
  const selection = window.getSelection();
  const root = selection && !selection.isCollapsed ? selection.getRangeAt(0).cloneContents() : document;
  root.querySelectorAll("a[href], img[src], video[src], audio[src], source[src]").forEach((el) => {
    const raw = el.href || el.src;
    if (raw && /^(https?|ftp):/i.test(raw)) urls.add(raw);
  });
  return Array.from(urls);
}

api.contextMenus.onClicked.addListener(async (info, tab) => {
  if (info.menuItemId === "mdm-video") {
    // A link to a video page, or the current page itself.
    const target = info.linkUrl || info.pageUrl || (tab && tab.url);
    await sendMediaPage(target, info.linkUrl ? "" : tab && tab.title);
  } else if (info.menuItemId === "mdm-link") {
    const url = info.linkUrl || info.srcUrl;
    if (url) await sendDownload({ url, referrer: info.pageUrl });
  } else if (info.menuItemId === "mdm-all" && tab?.id !== undefined) {
    try {
      const results = await api.scripting.executeScript({ target: { tabId: tab.id }, func: collectLinks });
      const urls = results?.[0]?.result || [];
      if (urls.length) await post("/links", { urls, referrer: tab.url });
    } catch (e) {
      console.warn("MacOS Download Manager:", e);
    }
  }
});

// ---------------------------------------------------------------------------
// 3. Video grabber: remember media requests seen in each tab
// ---------------------------------------------------------------------------

const mediaKey = (tabId) => `media-${tabId}`;

async function rememberMedia(tabId, entry) {
  const key = mediaKey(tabId);
  const data = await sessionStore.get({ [key]: [] });
  const list = data[key];
  if (list.some((m) => m.url === entry.url)) return;
  list.unshift(entry);
  if (list.length > 40) list.length = 40;
  await sessionStore.set({ [key]: list });
  try {
    await api.action.setBadgeText({ tabId, text: String(list.length) });
    await api.action.setBadgeBackgroundColor({ tabId, color: "#1f6feb" });
  } catch (e) {}
}

api.webRequest.onResponseStarted.addListener(
  (details) => {
    if (details.tabId < 0) return;
    if (!/^https?:/i.test(details.url)) return;
    const header = (details.responseHeaders || []).find((h) => h.name.toLowerCase() === "content-type");
    const type = header ? header.value || "" : "";
    const isMedia = MEDIA_TYPES.test(type) || MEDIA_EXT.test(details.url);
    if (!isMedia) return;
    // Skip tiny HLS/DASH fragments: keep playlists and whole files only.
    if (/\.(ts|m4s)(\?|$)/i.test(details.url) || /video\/mp2t|iso.segment/i.test(type)) return;
    // YouTube & co. stream small pieces of separate video/audio: use "Download video from this page" instead.
    if (/googlevideo\.com|\/videoplayback/i.test(details.url)) return;
    const lengthHeader = (details.responseHeaders || []).find((h) => h.name.toLowerCase() === "content-length");
    const size = lengthHeader ? parseInt(lengthHeader.value, 10) || 0 : 0;
    rememberMedia(details.tabId, { url: details.url, type, size, time: Date.now() });
  },
  { urls: ["<all_urls>"], types: ["media", "xmlhttprequest", "other"] },
  ["responseHeaders"]
);

api.tabs.onRemoved.addListener((tabId) => {
  sessionStore.remove(mediaKey(tabId));
});

api.tabs.onUpdated.addListener((tabId, changeInfo) => {
  if (changeInfo.status === "loading" && changeInfo.url) {
    sessionStore.remove(mediaKey(tabId));
    try { api.action.setBadgeText({ tabId, text: "" }, () => void api.runtime.lastError); } catch (e) {}
  }
});

// ---------------------------------------------------------------------------
// 4. Messages from the popup
// ---------------------------------------------------------------------------

api.runtime.onMessage.addListener((message, sender, sendResponse) => {
  (async () => {
    if (message.type === "ping") {
      sendResponse({ ok: await ping() });
    } else if (message.type === "media") {
      const key = mediaKey(message.tabId);
      const data = await sessionStore.get({ [key]: [] });
      sendResponse({ media: data[key] });
    } else if (message.type === "lastEvent") {
      const data = await sessionStore.get({ lastEvent: null });
      sendResponse({ lastEvent: data.lastEvent });
    } else if (message.type === "mediaPage") {
      sendResponse({ ok: await sendMediaPage(message.url, message.title) });
    } else if (message.type === "download") {
      sendResponse({ ok: await sendDownload({ url: message.url, referrer: message.referrer }) });
    } else {
      sendResponse({});
    }
  })();
  return true;
});

// Every time the service worker starts (browser start, downloads, clicks…), apply a waiting update.
reloadIfUpdatedOnDisk();
