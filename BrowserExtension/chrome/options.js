const api = globalThis.chrome ?? globalThis.browser;

const DEFAULT_EXTENSIONS = [
  "zip", "rar", "7z", "gz", "tgz", "bz2", "xz", "tar", "zst",
  "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "epub",
  "mp3", "wav", "flac", "aac", "m4a", "ogg", "opus",
  "dmg", "pkg", "exe", "msi", "apk", "ipa", "deb", "rpm", "iso", "img", "bin", "jar",
  "mp4", "mkv", "avi", "mov", "wmv", "flv", "webm", "m4v", "mpg", "mpeg", "3gp", "ts"
];

async function load() {
  const cfg = await api.storage.local.get({ port: 9614, minSizeKB: 0, extensions: DEFAULT_EXTENSIONS });
  document.getElementById("port").value = cfg.port;
  document.getElementById("minsize").value = cfg.minSizeKB;
  document.getElementById("exts").value = cfg.extensions.join(" ");
}

async function save() {
  const port = parseInt(document.getElementById("port").value, 10) || 9614;
  const minSizeKB = parseInt(document.getElementById("minsize").value, 10) || 0;
  const extensions = document.getElementById("exts").value
    .toLowerCase()
    .split(/[\s,;]+/)
    .map((e) => e.replace(/^\./, ""))
    .filter(Boolean);
  await api.storage.local.set({ port, minSizeKB, extensions });
  document.getElementById("saved").textContent = "Saved ✓";
  setTimeout(() => { document.getElementById("saved").textContent = ""; }, 2000);
}

document.getElementById("save").addEventListener("click", save);
load();
