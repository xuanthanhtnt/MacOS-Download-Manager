const api = globalThis.chrome ?? globalThis.browser;

function send(message) {
  return new Promise((resolve) => {
    try {
      api.runtime.sendMessage(message, (response) => {
        void api.runtime.lastError;
        resolve(response || {});
      });
    } catch (e) {
      resolve({});
    }
  });
}

function formatSize(bytes) {
  if (!bytes) return "";
  const units = ["B", "KB", "MB", "GB"];
  let i = 0;
  let v = bytes;
  while (v >= 1000 && i < units.length - 1) { v /= 1000; i++; }
  return `${v.toFixed(v < 10 && i > 0 ? 1 : 0)} ${units[i]}`;
}

function nameOf(url) {
  try {
    const u = new URL(url);
    return decodeURIComponent(u.pathname.split("/").pop() || u.hostname);
  } catch (e) {
    return url;
  }
}

async function init() {
  const status = document.getElementById("status");
  const ping = await send({ type: "ping" });
  if (ping.ok) {
    status.textContent = "Connected to MacOS Download Manager";
    status.className = "status ok";
  } else {
    status.textContent = "MacOS Download Manager is not running";
    status.className = "status bad";
  }

  const { lastEvent } = await send({ type: "lastEvent" });
  if (lastEvent && lastEvent.text) {
    document.getElementById("last").hidden = false;
    const time = new Date(lastEvent.time).toLocaleTimeString();
    document.getElementById("lastText").textContent = `${time} – ${lastEvent.text}`;
  }

  const enabled = document.getElementById("enabled");
  const stored = await api.storage.local.get({ enabled: true });
  enabled.checked = stored.enabled;
  enabled.addEventListener("change", () => api.storage.local.set({ enabled: enabled.checked }));

  document.getElementById("options").addEventListener("click", () => api.runtime.openOptionsPage());

  const [tab] = await api.tabs.query({ active: true, currentWindow: true });
  if (!tab) return;

  const videoButton = document.getElementById("video");
  if (!/^https?:/i.test(tab.url || "")) {
    videoButton.disabled = true;
  }
  videoButton.addEventListener("click", async () => {
    videoButton.disabled = true;
    const res = await send({ type: "mediaPage", url: tab.url, title: tab.title });
    videoButton.textContent = res.ok ? "Sent ✓ – choose the quality in the app" : "MacOS Download Manager is not running";
  });
  const { media = [] } = await send({ type: "media", tabId: tab.id });
  const list = document.getElementById("media");
  document.getElementById("empty").style.display = media.length ? "none" : "block";
  for (const item of media) {
    const li = document.createElement("li");
    const info = document.createElement("div");
    info.className = "name";
    const title = document.createElement("div");
    title.textContent = nameOf(item.url);
    title.title = item.url;
    const meta = document.createElement("small");
    const kind = /mpegurl|\.m3u8/i.test(item.type + item.url) ? "HLS stream" : (item.type || "media");
    meta.textContent = [kind, formatSize(item.size)].filter(Boolean).join(" · ");
    info.append(title, meta);
    const button = document.createElement("button");
    button.textContent = "Download";
    button.addEventListener("click", async () => {
      button.disabled = true;
      const res = await send({ type: "download", url: item.url, referrer: tab.url });
      button.textContent = res.ok ? "Sent ✓" : "Failed";
    });
    li.append(info, button);
    list.append(li);
  }
}

init();
