(function () {
  "use strict";

  var builtinHtml = [
    "<!doctype html><html><head><meta charset='utf-8'><style>",
    "html,body{margin:0;height:100%;overflow:hidden;background:#0a0a12;}",
    ".bg{position:fixed;inset:0;background:",
    "radial-gradient(1200px 800px at 20% 20%,rgba(124,92,255,.45),transparent 60%),",
    "radial-gradient(1000px 700px at 80% 30%,rgba(255,110,196,.40),transparent 60%),",
    "radial-gradient(900px 900px at 50% 90%,rgba(43,217,200,.40),transparent 60%),#0a0a12;}",
    ".orb{position:fixed;border-radius:50%;filter:blur(46px);opacity:.55;mix-blend-mode:screen;animation:float 20s ease-in-out infinite;}",
    ".o1{width:440px;height:440px;background:#7c5cff;top:8%;left:10%;}",
    ".o2{width:380px;height:380px;background:#ff6ec4;top:44%;left:58%;animation-delay:-7s;}",
    ".o3{width:320px;height:320px;background:#2bd9c8;top:60%;left:18%;animation-delay:-13s;}",
    "@keyframes float{0%,100%{transform:translate(0,0) scale(1);}33%{transform:translate(70px,-50px) scale(1.12);}66%{transform:translate(-46px,36px) scale(.94);}}",
    ".grid{position:fixed;inset:0;background-image:linear-gradient(rgba(255,255,255,.045) 1px,transparent 1px),linear-gradient(90deg,rgba(255,255,255,.045) 1px,transparent 1px);background-size:50px 50px;-webkit-mask:radial-gradient(circle at 50% 50%,#000,transparent 78%);mask:radial-gradient(circle at 50% 50%,#000,transparent 78%);}",
    ".title{position:fixed;left:50%;top:50%;transform:translate(-50%,-50%);color:#fff;font-family:system-ui,sans-serif;font-weight:700;font-size:clamp(30px,6vw,76px);letter-spacing:.04em;text-shadow:0 6px 36px rgba(0,0,0,.45);opacity:.92;}",
    "</style></head><body>",
    "<div class='bg'></div><div class='orb o1'></div><div class='orb o2'></div><div class='orb o3'></div><div class='grid'></div>",
    "<div class='title'>HTML 壁纸</div></body></html>"
  ].join("");

  function resolveTheme(t) {
    if (t === "system") return window.matchMedia("(prefers-color-scheme: light)").matches ? "light" : "dark";
    return t || "dark";
  }

  var $ = function (id) { return document.getElementById(id); };
  var frame = $("frame");
  var frameWrap = $("frameWrap");
  var stage = $("stage");
  var currentBlob = null;

  function makeBlob(html) {
    return URL.createObjectURL(new Blob([html], { type: "text/html" }));
  }

  function applySource(s) {
    var src = null;
    if (s.type === "url" && s.url) src = s.url;
    else if (s.type === "file" && s._blobUrl) src = s._blobUrl;
    else if (s.type === "file" && s.file) src = s.file;
    else if ((s.type === "code" || s.type === "builtin") && s.html) src = makeBlob(s.html);
    else src = makeBlob(builtinHtml);

    if (currentBlob && currentBlob !== src) URL.revokeObjectURL(currentBlob);
    currentBlob = src && src.indexOf("blob:") === 0 ? src : null;
    frame.src = src;
  }

  function applyDisplay(d) {
    frameWrap.style.transform = "scale(" + (d.scale || 1) + ")";
    frameWrap.style.opacity = String(d.opacity != null ? d.opacity : 1);
    stage.style.background = d.background || "#0a0a12";
  }

  function applyConfig(cfg) {
    if (!cfg) return;
    applySource(cfg.source || {});
    applyDisplay(cfg.display || {});
    document.body.setAttribute("data-theme", resolveTheme(cfg.ui && cfg.ui.theme));
    document.documentElement.style.setProperty("--accent", (cfg.ui && cfg.ui.accent) || "#7c5cff");
    frame.style.pointerEvents = cfg.behavior && cfg.behavior.clickThrough ? "none" : "auto";
    document.body.classList.toggle("hide-cursor", !!(cfg.behavior && cfg.behavior.hideCursor));
  }

  // 桌面版：设置窗口通过宿主（wallpaper.ps1）推送配置。
  // WebView2 的两个窗口即使共用同一个用户数据目录，file:// 下的 localStorage 也
  // 不互通（实测 B 读不到 A 写入的值），所以不能靠轮询共享存储；改由宿主转发。
  window.__htmlbgApplyCfg = function (json) {
    try {
      var cfg = fill(JSON.parse(json));
      try { localStorage.setItem(STORAGE_KEY, json); lastRaw = json; } catch (e) {}
      applyConfig(cfg);
    } catch (e) {}
  };

  var STORAGE_KEY = "html-wallpaper-config-v1";
  var DEFAULTS = {
    source: { type: "builtin", url: "", file: "", html: "" },
    display: { scale: 1, opacity: 1, background: "#0a0a12" },
    behavior: { reloadMinutes: 0, hideCursor: false, clickThrough: false },
    ui: { theme: "dark", accent: "#7c5cff" }
  };

  function fill(cfg) {
    var out = JSON.parse(JSON.stringify(DEFAULTS));
    if (cfg && typeof cfg === "object") {
      ["source", "display", "behavior", "ui"].forEach(function (k) {
        if (cfg[k] && typeof cfg[k] === "object") {
          Object.keys(cfg[k]).forEach(function (kk) { out[k][kk] = cfg[k][kk]; });
        }
      });
    }
    return out;
  }

  var lastRaw = "";

  function currentRaw() {
    try { return localStorage.getItem(STORAGE_KEY) || ""; } catch (e) { return ""; }
  }

  // 轮询设置窗口的改动（storage 事件在 file:// 下不可靠，轮询更稳）
  function tick() {
    var raw = currentRaw();
    if (raw && raw !== lastRaw) {
      lastRaw = raw;
      try { applyConfig(fill(JSON.parse(raw))); } catch (e) {}
    }
    setTimeout(tick, 800);
  }

  (function init() {
    var raw = currentRaw();
    if (!raw && window.WALLPAPER_CONFIG) {
      // 首次启动：采用 config.json 注入的配置
      var c = fill(window.WALLPAPER_CONFIG);
      try { localStorage.setItem(STORAGE_KEY, JSON.stringify(c)); } catch (e) {}
      lastRaw = JSON.stringify(c);
      applyConfig(c);
    } else if (raw) {
      lastRaw = raw;
      try { applyConfig(fill(JSON.parse(raw))); } catch (e) {}
    } else {
      applyConfig(fill(window.WALLPAPER_CONFIG || null));
    }
    tick();
  })();
})();
