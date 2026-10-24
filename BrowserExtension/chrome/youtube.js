// Adds a "Download video" button on YouTube watch/shorts pages (like IDM's download panel).
// The page address is sent to MacOS Download Manager, where the quality is chosen.
(() => {
  // The script can be injected twice (manifest + after an extension update): run once per page.
  if (window.__mdmYouTubeButton) return;
  window.__mdmYouTubeButton = true;
  const api = globalThis.chrome ?? globalThis.browser;
  const BUTTON_ID = "mdm-download-video";

  function isVideoPage() {
    const path = location.pathname;
    return path.startsWith("/watch") || path.startsWith("/shorts/") || path.startsWith("/live/");
  }

  function setLabel(button, text) {
    button.querySelector("span").textContent = text;
  }

  function createButton() {
    const button = document.createElement("button");
    button.id = BUTTON_ID;
    button.type = "button";
    button.title = "Download this video with MacOS Download Manager";
    // Built with DOM calls: YouTube enforces Trusted Types, which blocks innerHTML.
    const icon = document.createElement("b");
    icon.setAttribute("aria-hidden", "true");
    icon.textContent = "⬇";
    const label = document.createElement("span");
    label.textContent = "Download video";
    button.append(icon, label);
    Object.assign(button.style, {
      position: "fixed",
      top: "68px",
      right: "24px",
      zIndex: "2147483647",
      display: "flex",
      alignItems: "center",
      gap: "6px",
      padding: "8px 14px",
      border: "0",
      borderRadius: "18px",
      background: "linear-gradient(135deg, #2060ff, #10c4bc)",
      color: "#fff",
      font: "600 13px/1 -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif",
      boxShadow: "0 4px 14px rgba(0,0,0,.28)",
      cursor: "pointer",
      opacity: "0.92"
    });
    button.addEventListener("mouseenter", () => { button.style.opacity = "1"; });
    button.addEventListener("mouseleave", () => { button.style.opacity = "0.92"; });
    button.addEventListener("click", () => {
      const title = document.title.replace(/\s*-\s*YouTube\s*$/, "");
      setLabel(button, "Sending…");
      try {
        api.runtime.sendMessage({ type: "mediaPage", url: location.href, title }, (response) => {
          void api.runtime.lastError;
          const ok = response && response.ok;
          setLabel(button, ok ? "Sent ✓ – choose the quality" : "Open MacOS Download Manager first");
          setTimeout(() => setLabel(button, "Download video"), 3500);
        });
      } catch (e) {
        setLabel(button, "Reload the page");
      }
    });
    return button;
  }

  // Ask the app to read this video's qualities in the background (the list then appears at once).
  let prefetched = "";
  let prefetchTimer = null;
  function prefetch(delay) {
    clearTimeout(prefetchTimer);
    prefetchTimer = setTimeout(() => {
      const url = location.href;
      if (!isVideoPage() || url === prefetched) return;
      prefetched = url;
      try {
        api.runtime.sendMessage({ type: "mediaPrefetch", url }, () => void api.runtime.lastError);
      } catch (e) { /* extension reloaded */ }
    }, delay);
  }

  function update() {
    let button = document.getElementById(BUTTON_ID);
    const fullscreen = !!document.fullscreenElement;
    if (isVideoPage() && !fullscreen) {
      if (!button && document.body) {
        button = createButton();
        button.addEventListener("mouseenter", () => prefetch(0));
        document.body.appendChild(button);
      }
      prefetch(1500);
    } else if (button) {
      button.remove();
    }
  }

  // YouTube is a single-page app: follow its navigation events and URL changes.
  document.addEventListener("yt-navigate-finish", update);
  document.addEventListener("fullscreenchange", update);
  window.addEventListener("popstate", update);
  let lastURL = location.href;
  setInterval(() => {
    if (location.href !== lastURL) {
      lastURL = location.href;
      update();
    }
  }, 1000);
  update();
})();
