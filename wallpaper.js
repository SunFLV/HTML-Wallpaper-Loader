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

  // Tells the injected file bridge (presets/filebridge.js) that this document is the
  // host shell, not user content: it must not scan itself for file inputs.
  window.__htmlbgWallpaperHost = true;
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
    // 透明背景模式：宿主把壁纸窗口按纯黑抠像（LWA_COLORKEY），所以这里必须画
    // 成 #000000，这些像素才会露出 Windows 系统壁纸；其余模式用用户选的背景色。
    stage.style.background = d.transparent ? "#000000" : (d.background || "#0a0a12");
  }

  function applyConfig(cfg) {
    if (!cfg) return;
    applySource(cfg.source || {});
    applyDisplay(cfg.display || {});
    document.body.setAttribute("data-theme", resolveTheme(cfg.ui && cfg.ui.theme));
    document.documentElement.style.setProperty("--accent", (cfg.ui && cfg.ui.accent) || "#7c5cff");
    frame.style.pointerEvents = cfg.behavior && cfg.behavior.clickThrough ? "none" : "auto";
    document.body.classList.toggle("hide-cursor", !!(cfg.behavior && cfg.behavior.hideCursor));
    pushPresetToIframe(cfg);
  }

  // ---------- 预设页面 <-> 宿主 ----------
  // Preset pages (presets/*.html) live inside the iframe and cannot talk to the
  // Win32 host directly.  Two relays:
  //   iframe -> us -> host : the host only reads document.title, so we re-send the
  //                          iframe's postMessage as a [[htmlbg:kind:payload]] marker
  //   host -> us -> iframe : __htmlbgIframe() posts a message into the iframe
  var WP_BASE_TITLE = document.title;
  var pendingToHost = null;
  var pendingToIframe = [];

  function hostSend(kind, payload) { pendingToHost = { kind: kind, payload: payload || "" }; }

  setInterval(function () {
    try {
      if (pendingToHost) {
        document.title = WP_BASE_TITLE + " [[htmlbg:" + pendingToHost.kind + ":" + encodeURIComponent(pendingToHost.payload) + "]]";
      } else if (document.title !== WP_BASE_TITLE) {
        document.title = WP_BASE_TITLE;
      }
    } catch (e) {}
  }, 350);

  window.__htmlbgAck = function () {
    pendingToHost = null;
    try { document.title = WP_BASE_TITLE; } catch (e) {}
    return "ok";
  };

  // host pushes a message object into the iframe
  window.__htmlbgIframe = function (obj) {
    try {
      if (frame.contentWindow) frame.contentWindow.postMessage({ htmlbg: obj }, "*");
      else pendingToIframe.push(obj);
    } catch (e) {}
    return "ok";
  };

  // Turns { slotKey: "C:\\a\\b.pdf" } into something the bridge can identify.
  // The bytes themselves never travel through here - the bridge asks the host for
  // them afterwards (see filebridge.js), which is the only transport Chromium lets
  // a file:// page use for local files.  "path" is part of the signature so that
  // picking a different file for the same slot always triggers a reload.
  function fileToSlots(files) {
    var map = {};
    Object.keys(files || {}).forEach(function (k) {
      var v = files[k];
      if (v && typeof v === "string") {
        map[k] = { name: String(v).replace(/^.*[\\\/]/, ""), path: v };
      } else if (v) {
        map[k] = v;
      }
    });
    return map;
  }

  function pushPresetToIframe(cfg) {
    var msg = {
      type: "config",
      preset: (cfg && cfg.preset) || null,
      files: fileToSlots(cfg && cfg.files),
      meta: { accent: cfg && cfg.ui && cfg.ui.accent, desktop: true }
    };
    pendingToIframe.push(msg);
    try {
      if (frame.contentWindow) frame.contentWindow.postMessage({ htmlbg: msg }, "*");
    } catch (e) {}
  }

  frame.addEventListener("load", function () {
    var out = pendingToIframe.splice(0);
    out.forEach(function (m) {
      try { frame.contentWindow.postMessage({ htmlbg: m }, "*"); } catch (e) {}
    });
  });

  // iframe -> host relay (preset pages ask for files, report option changes, …)
  window.addEventListener("message", function (e) {
    var d = e.data;
    if (!d || !d.htmlbg || !d.htmlbg.kind) return;
    var m = d.htmlbg;
    if (m.kind === "presetset") {
      // preset options changed inside the page: keep our config in sync locally
      try {
        var p = JSON.parse(m.payload);
        var raw = currentRaw();
        var cfg = raw ? fill(JSON.parse(raw)) : fill(window.WALLPAPER_CONFIG || null);
        cfg.preset = Object.assign({}, cfg.preset || {}, p);
        lastRaw = JSON.stringify(cfg);
        try { localStorage.setItem(STORAGE_KEY, lastRaw); } catch (err) {}
      } catch (err) {}
    }
    hostSend(m.kind, m.payload || "");
  });


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
    display: { scale: 1, opacity: 1, background: "#0a0a12", transparent: false },
    behavior: { reloadMinutes: 0, hideCursor: false, clickThrough: false },
    ui: { theme: "dark", accent: "#7c5cff" },
    preset: {
      id: "", examDate: "2027-06-07", docPath: "", fontSize: 22,
      scrollSpeed: 26, showCountdown: true, countdownOnly: false, panelColor: "",
      label: "距离高考", pos: "right-center", size: "md", paused: false
    },
    files: {}
  };

  function fill(cfg) {
    var out = JSON.parse(JSON.stringify(DEFAULTS));
    if (cfg && typeof cfg === "object") {
      ["source", "display", "behavior", "ui", "preset", "files"].forEach(function (k) {
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
