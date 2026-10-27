(function () {
  "use strict";

  var STORAGE_KEY = "html-wallpaper-config-v1";

  // 内置动画背景（默认壁纸）
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

  function defaultConfig() {
    return {
      version: 1,
      source: { type: "builtin", url: "", file: "", html: "" },
      display: { scale: 1, opacity: 1, background: "#0a0a12" },
      behavior: { reloadMinutes: 0, hideCursor: false, clickThrough: false },
      ui: { theme: "dark", accent: "#7c5cff" },
      widget: { showClock: true },
      preset: {
        id: "",
        examDate: "2027-06-07",
        docPath: "",
        fontSize: 22,
        scrollSpeed: 26,
        showCountdown: true,
        label: "距离高考",
        pos: "right-center",
        size: "md",
        paused: false
      },
      files: {}
    };
  }

  // 合并，保证字段完整
  function merge(base, over) {
    if (!over || typeof over !== "object") return base;
    var out = Array.isArray(base) ? base.slice() : Object.assign({}, base);
    Object.keys(over).forEach(function (k) {
      if (base && typeof base[k] === "object" && !Array.isArray(base[k]) && base[k] !== null) {
        out[k] = merge(base[k], over[k]);
      } else {
        out[k] = over[k];
      }
    });
    return out;
  }

  function loadConfig() {
    try {
      var raw = localStorage.getItem(STORAGE_KEY);
      if (raw) return merge(defaultConfig(), JSON.parse(raw));
    } catch (e) {}
    return defaultConfig();
  }

  function serialize(state) {
    var c = JSON.parse(JSON.stringify(state));
    if (c.source) delete c.source._blobUrl;
    return c;
  }

  function save() {
    try { localStorage.setItem(STORAGE_KEY, JSON.stringify(serialize(state))); } catch (e) {}
  }

  var state = loadConfig();
  var currentBlob = null;
  var reloadTimer = null;

  var $ = function (id) { return document.getElementById(id); };
  var frame = $("frame");
  var frameWrap = $("frameWrap");
  var stage = $("stage");
  var panel = $("panel");
  var scrim = $("scrim");

  function makeBlob(html) {
    return URL.createObjectURL(new Blob([html], { type: "text/html" }));
  }

  function applyWallpaper() {
    var s = state.source;
    var src = null;
    if (s.type === "url" && s.url) {
      src = s.url;
    } else if (s.type === "file" && s._blobUrl) {
      src = s._blobUrl;
    } else if (s.type === "file" && s.file) {
      src = s.file;
    } else if ((s.type === "code" || s.type === "builtin") && s.html) {
      src = makeBlob(s.html);
    } else {
      src = makeBlob(builtinHtml);
    }
    if (currentBlob && currentBlob !== src) URL.revokeObjectURL(currentBlob);
    currentBlob = src && src.indexOf("blob:") === 0 ? src : null;
    frame.src = src;
  }

  function applyDisplay() {
    frameWrap.style.transform = "scale(" + state.display.scale + ")";
    frameWrap.style.opacity = String(state.display.opacity);
    stage.style.background = state.display.background;
  }

  function applyBehavior() {
    frame.style.pointerEvents = state.behavior.clickThrough ? "none" : "auto";
    document.body.classList.toggle("hide-cursor", !!state.behavior.hideCursor);
    if (reloadTimer) { clearInterval(reloadTimer); reloadTimer = null; }
    if (state.behavior.reloadMinutes > 0) {
      reloadTimer = setInterval(applyWallpaper, state.behavior.reloadMinutes * 60000);
    }
  }

  function applyUI() {
    var theme = state.ui.theme;
    if (theme === "system") {
      theme = window.matchMedia("(prefers-color-scheme: light)").matches ? "light" : "dark";
    }
    document.body.setAttribute("data-theme", theme);
    document.documentElement.style.setProperty("--accent", state.ui.accent);
    $("clock").style.display = state.widget.showClock ? "block" : "none";
  }

  function applyAll() {
    applyWallpaper();
    applyDisplay();
    applyBehavior();
    applyUI();
    pushPresetToIframe();
  }

  // ---------- 预设页面（iframe 里的 presets/*.html） ----------
  // 桌面版由 PowerShell 宿主读文件；预览版在浏览器里，只能由本页代为选择/解析，
  // 然后按同一套 postMessage 协议回给预设页。
  var pendingToIframe = [];

  function pushPresetToIframe() {
    var msg = {
      type: "config",
      preset: state.preset || null,
      meta: { accent: state.ui.accent }
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

  window.addEventListener("message", function (e) {
    var d = e.data;
    if (!d || !d.htmlbg || !d.htmlbg.kind) return;
    var m = d.htmlbg;

    if (m.kind === "presetset") {
      try {
        var p = JSON.parse(m.payload);
        state.preset = Object.assign({}, state.preset || {}, p);
        syncPreset();
        save();
      } catch (err) {}
      return;
    }
    if (m.kind === "pickfile") {
      // The browser cannot hand out disk paths, so open a real file dialog and pass
      // the File itself into the iframe (File clones across postMessage).
      pendingKey = m.payload || "doc";
      if ($("docPick")) $("docPick").click();
      return;
    }
    if (m.kind === "slots") {
      try {
        var sd = JSON.parse(m.payload || "{}");
        detectedSlots = sd.slots || [];
        renderFileSlots();
      } catch (err) {}
      return;
    }
    if (m.kind === "filestatus") {
      try {
        var st = JSON.parse(m.payload || "{}");
        if (st.key) setSlotStatus(st.key, st.ok ? "已载入" : (st.error || "失败"), st.ok ? "ok" : "bad");
      } catch (err) {}
      return;
    }
  });

  // ---------- 文件导入槽（浏览器版：由 <input type=file> 直接给文件） ----------
  var detectedSlots = [];
  var pendingKey = "doc";

  function setSlotStatus(key, text, cls) {
    var el = document.querySelector('#fileSlots [data-key="' + String(key).replace(/"/g, '\\"') + '"] .slot-state');
    if (el) { el.textContent = text; el.className = "slot-state " + (cls || ""); }
  }

  function renderFileSlots() {
    var box = $("fileSlots");
    if (!box) return;
    box.innerHTML = "";
    if (!detectedSlots.length) {
      var none = document.createElement("p");
      none.className = "hint";
      none.textContent = "当前页面没有检测到文件导入点。";
      box.appendChild(none);
      return;
    }
    detectedSlots.forEach(function (s) {
      var row = document.createElement("div");
      row.className = "slot-item";
      row.setAttribute("data-key", s.key);

      var info = document.createElement("div");
      info.className = "slot-info";
      var nm = document.createElement("div");
      nm.className = "slot-name";
      nm.textContent = s.label || s.key;
      var path = document.createElement("div");
      path.className = "slot-path";
      path.textContent = (state.files && state.files[s.key]) || "未选择文件";
      info.appendChild(nm);
      info.appendChild(path);

      var stEl = document.createElement("div");
      stEl.className = "slot-state";

      var acts = document.createElement("div");
      acts.className = "slot-actions";
      var pick = document.createElement("button");
      pick.className = "btn tiny";
      pick.textContent = "选择文件";
      pick.addEventListener("click", function () { pendingKey = s.key; $("docPick").click(); });
      acts.appendChild(pick);

      row.appendChild(info);
      row.appendChild(stEl);
      row.appendChild(acts);
      box.appendChild(row);
    });
  }

  function onDocPicked(e) {
    var f = e.target.files && e.target.files[0];
    e.target.value = "";
    if (!f) return;
    var key = pendingKey || "doc";
    state.files = state.files || {};
    state.files[key] = f.name;
    save();
    try { frame.contentWindow.postMessage({ htmlbg: { type: "file", key: key, file: f } }, "*"); } catch (err) {}
    renderFileSlots();
    setSlotStatus(key, "已选择", "ok");
  }

  var PRESETS = window.HTMLBG_PRESETS || [];

  function presetPageUrl(page) {
    try { return new URL(page, location.href).href; } catch (e) { return page; }
  }

  function applyPreset(id) {
    var p = null;
    for (var i = 0; i < PRESETS.length; i++) { if (PRESETS[i].id === id) p = PRESETS[i]; }
    if (!p) return;
    var cfg = JSON.parse(JSON.stringify(p.config));
    var keep = Object.assign({}, defaultConfig().preset, state.preset || {});
    state.source = cfg.source;
    if (cfg.source.type === "file") state.source.file = presetPageUrl(cfg.source.file);
    state.source._blobUrl = null;
    state.display = merge(state.display, cfg.display || {});
    if (cfg.ui) state.ui = merge(state.ui, cfg.ui);
    state.preset = Object.assign({}, cfg.preset || {}, keep);
    state.preset.id = p.id;
    syncControls();
    applyAll();
    save();
  }

  function buildPresetList() {
    var box = $("presetList");
    if (!box || !PRESETS.length) return;
    box.innerHTML = "";
    PRESETS.forEach(function (p) {
      var b = document.createElement("button");
      b.className = "preset-item";
      b.setAttribute("data-id", p.id);
      var n = document.createElement("span"); n.className = "name"; n.textContent = p.name;
      var d = document.createElement("span"); d.className = "desc"; d.textContent = p.desc;
      b.appendChild(n); b.appendChild(d);
      b.addEventListener("click", function () { applyPreset(p.id); });
      box.appendChild(b);
    });
  }

  function syncPreset() {
    var p = state.preset || defaultConfig().preset;
    document.querySelectorAll("#presetList .preset-item").forEach(function (el) {
      el.classList.toggle("active", el.getAttribute("data-id") === p.id);
    });
    var opts = $("presetOpts");
    if (opts) opts.classList.toggle("off", !p.id || p.id === "builtin");
    $("examDate").value = /^\d{4}-\d{2}-\d{2}$/.test(p.examDate) ? p.examDate : "2027-06-07";
    $("docFs").value = p.fontSize; $("docFsVal").textContent = p.fontSize + "px";
    $("docSp").value = p.scrollSpeed; $("docSpVal").textContent = p.scrollSpeed + "px/s";
    $("cdShow").checked = !!p.showCountdown;
    $("cdLabel").value = p.label || "距离高考";
    if ($("docPause")) $("docPause").checked = !!p.paused;
    document.querySelectorAll("#posGrid .magnet").forEach(function (b) {
      b.classList.toggle("active", b.getAttribute("data-pos") === (p.pos || "right-center"));
    });
    document.querySelectorAll("#sizeRow .chip").forEach(function (b) {
      b.classList.toggle("active", b.getAttribute("data-size") === (p.size || "md"));
    });
    renderFileSlots();
  }

  function bindPreset() {
    $("examDate").addEventListener("change", function () {
      var v = this.value;
      if (/^\d{4}-\d{2}-\d{2}$/.test(v)) { state.preset.examDate = v; applyPresetOptions(); save(); }
    });
    $("docFs").addEventListener("input", function () {
      state.preset.fontSize = parseInt(this.value, 10) || 22;
      $("docFsVal").textContent = state.preset.fontSize + "px"; applyPresetOptions(); save();
    });
    $("docSp").addEventListener("input", function () {
      state.preset.scrollSpeed = parseInt(this.value, 10) || 0;
      $("docSpVal").textContent = state.preset.scrollSpeed + "px/s"; applyPresetOptions(); save();
    });
    $("cdShow").addEventListener("change", function () {
      state.preset.showCountdown = this.checked; applyPresetOptions(); save();
    });
    $("cdLabel").addEventListener("change", function () {
      state.preset.label = this.value.trim() || "距离高考"; applyPresetOptions(); save();
    });
    if ($("docPause")) $("docPause").addEventListener("change", function () {
      state.preset.paused = this.checked; applyPresetOptions(); save();
    });
    document.querySelectorAll("#posGrid .magnet").forEach(function (b) {
      b.addEventListener("click", function () {
        state.preset.pos = b.getAttribute("data-pos");
        syncPreset(); applyPresetOptions(); save();
      });
    });
    document.querySelectorAll("#sizeRow .chip").forEach(function (b) {
      b.addEventListener("click", function () {
        state.preset.size = b.getAttribute("data-size");
        syncPreset(); applyPresetOptions(); save();
      });
    });
    if ($("docPick")) $("docPick").addEventListener("change", onDocPicked);
  }

  // 只把选项推给 iframe，不重新加载页面
  function applyPresetOptions() {
    pushPresetToIframe();
  }

  // ---------- 面板与 Tabs ----------
  function setTab(name) {
    var tabs = document.querySelectorAll("#sourceTabs .tab");
    var panes = document.querySelectorAll(".panes .pane");
    tabs.forEach(function (t) { t.classList.toggle("active", t.getAttribute("data-tab") === name); });
    panes.forEach(function (p) { p.classList.toggle("active", p.getAttribute("data-pane") === name); });
  }

  function openPanel() {
    // 回填当前来源到输入框
    $("urlInput").value = state.source.url || "";
    $("codeInput").value = state.source.html || "";
    $("filePath").value = state.source.file || "";
    var t = state.source.type;
    if (t !== "url" && t !== "file" && t !== "code") t = "builtin";
    setTab(t);
    panel.classList.add("open");
    scrim.classList.add("show");
    panel.setAttribute("aria-hidden", "false");
  }

  function closePanel() {
    panel.classList.remove("open");
    scrim.classList.remove("show");
    panel.setAttribute("aria-hidden", "true");
  }

  // ---------- 来源加载 ----------
  function loadUrl() {
    var v = $("urlInput").value.trim();
    if (!v) return;
    if (!/^https?:\/\//i.test(v)) v = "https://" + v;
    state.source.type = "url";
    state.source.url = v;
    state.source.html = "";
    state.source.file = "";
    applyWallpaper();
    save();
  }

  function onFilePicked(e) {
    var f = e.target.files && e.target.files[0];
    if (!f) return;
    var reader = new FileReader();
    reader.onload = function () {
      state.source.type = "file";
      state.source._blobUrl = makeBlob(reader.result);
      state.source.file = f.name;
      state.source.html = "";
      state.source.url = "";
      applyWallpaper();
      save();
    };
    reader.readAsText(f);
  }

  function loadFilePath() {
    var v = $("filePath").value.trim();
    if (!v) return;
    state.source.type = "file";
    state.source.file = v;
    state.source._blobUrl = null;
    state.source.html = "";
    state.source.url = "";
    applyWallpaper();
    save();
  }

  function applyCode() {
    var v = $("codeInput").value;
    state.source.type = "code";
    state.source.html = v;
    state.source.url = "";
    state.source.file = "";
    state.source._blobUrl = null;
    applyWallpaper();
    save();
  }

  function useBuiltin() {
    state.source.type = "builtin";
    state.source.html = "";
    state.source.url = "";
    state.source.file = "";
    state.source._blobUrl = null;
    applyWallpaper();
    save();
  }

  // ---------- 显示/行为/界面 实时绑定 ----------
  function bindLive() {
    $("scale").addEventListener("input", function () {
      state.display.scale = parseFloat(this.value);
      $("scaleVal").textContent = Math.round(state.display.scale * 100) + "%";
      applyDisplay(); save();
    });
    $("opacity").addEventListener("input", function () {
      state.display.opacity = parseFloat(this.value);
      $("opacityVal").textContent = Math.round(state.display.opacity * 100) + "%";
      applyDisplay(); save();
    });
    $("bg").addEventListener("input", function () {
      state.display.background = this.value; applyDisplay(); save();
    });
    $("reload").addEventListener("input", function () {
      state.behavior.reloadMinutes = Math.max(0, parseInt(this.value, 10) || 0);
      applyBehavior(); save();
    });
    $("hideCursor").addEventListener("change", function () {
      state.behavior.hideCursor = this.checked; applyBehavior(); save();
    });
    $("clickThrough").addEventListener("change", function () {
      state.behavior.clickThrough = this.checked; applyBehavior(); save();
    });
    $("theme").addEventListener("change", function () {
      state.ui.theme = this.value; applyUI(); save();
    });
    $("accent").addEventListener("input", function () {
      state.ui.accent = this.value; applyUI(); save();
    });
    $("showClock").addEventListener("change", function () {
      state.widget.showClock = this.checked; applyUI(); save();
    });
  }

  function syncControls() {
    $("scale").value = state.display.scale;
    $("scaleVal").textContent = Math.round(state.display.scale * 100) + "%";
    $("opacity").value = state.display.opacity;
    $("opacityVal").textContent = Math.round(state.display.opacity * 100) + "%";
    $("bg").value = state.display.background;
    $("reload").value = state.behavior.reloadMinutes;
    $("hideCursor").checked = state.behavior.hideCursor;
    $("clickThrough").checked = state.behavior.clickThrough;
    $("theme").value = state.ui.theme;
    $("accent").value = state.ui.accent;
    $("showClock").checked = state.widget.showClock;
    syncPreset();
  }

  // ---------- 配置导入/导出 ----------
  function exportConfig() {
    var blob = new Blob([JSON.stringify(serialize(state), null, 2)], { type: "application/json" });
    var a = document.createElement("a");
    a.href = URL.createObjectURL(blob);
    a.download = "wallpaper-config.json";
    a.click();
    setTimeout(function () { URL.revokeObjectURL(a.href); }, 1000);
  }

  function importConfig(file) {
    var reader = new FileReader();
    reader.onload = function () {
      try {
        var data = JSON.parse(reader.result);
        state = merge(defaultConfig(), data);
        syncControls();
        applyAll();
        save();
      } catch (e) {
        alert("配置文件解析失败：请确保是有效的 JSON 文件。");
      }
    };
    reader.readAsText(file);
  }

  function resetConfig() {
    if (!confirm("确定恢复默认设置？当前配置将被覆盖。")) return;
    state = defaultConfig();
    syncControls();
    applyAll();
    save();
  }

  // ---------- 时钟 ----------
  var weekdays = ["星期日", "星期一", "星期二", "星期三", "星期四", "星期五", "星期六"];
  function updateClock() {
    var d = new Date();
    var hh = String(d.getHours()).padStart(2, "0");
    var mm = String(d.getMinutes()).padStart(2, "0");
    var ss = String(d.getSeconds()).padStart(2, "0");
    $("clockTime").textContent = hh + ":" + mm + ":" + ss;
    $("clockDate").textContent =
      d.getFullYear() + "年" + (d.getMonth() + 1) + "月" + d.getDate() + "日 " + weekdays[d.getDay()];
  }

  // ---------- 全屏 ----------
  function toggleFullscreen() {
    if (!document.fullscreenElement) {
      (document.documentElement.requestFullscreen || function () {}).call(document.documentElement);
    } else if (document.exitFullscreen) {
      document.exitFullscreen();
    }
  }

  // ---------- 事件绑定 ----------
  function bindEvents() {
    $("openSettings").addEventListener("click", openPanel);
    $("closePanel").addEventListener("click", closePanel);
    scrim.addEventListener("click", closePanel);
    $("applyBtn").addEventListener("click", function () { save(); closePanel(); });
    $("fullscreenBtn").addEventListener("click", toggleFullscreen);

    document.querySelectorAll("#sourceTabs .tab").forEach(function (t) {
      t.addEventListener("click", function () { setTab(t.getAttribute("data-tab")); });
    });
    $("loadUrl").addEventListener("click", loadUrl);
    $("urlInput").addEventListener("keydown", function (e) { if (e.key === "Enter") loadUrl(); });
    $("fileInput").addEventListener("change", onFilePicked);
    $("loadFile").addEventListener("click", loadFilePath);
    $("applyCode").addEventListener("click", applyCode);
    $("useBuiltin").addEventListener("click", useBuiltin);

    $("exportBtn").addEventListener("click", exportConfig);
    $("importBtn").addEventListener("click", function () { $("importInput").click(); });
    $("importInput").addEventListener("change", function (e) {
      if (e.target.files && e.target.files[0]) importConfig(e.target.files[0]);
      e.target.value = "";
    });
    $("resetBtn").addEventListener("click", resetConfig);

    document.addEventListener("keydown", function (e) {
      var tag = (e.target.tagName || "").toLowerCase();
      var typing = tag === "input" || tag === "textarea" || tag === "select";
      if (e.key === "Escape") closePanel();
      else if ((e.key === "s" || e.key === "S") && !typing) { e.preventDefault(); panel.classList.contains("open") ? closePanel() : openPanel(); }
      else if ((e.key === "f" || e.key === "F") && !typing && e.altKey) toggleFullscreen();
    });

    var mq = window.matchMedia("(prefers-color-scheme: light)");
    if (mq.addEventListener) mq.addEventListener("change", function () { if (state.ui.theme === "system") applyUI(); });
  }

  // ---------- 启动 ----------
  syncControls();
  bindLive();
  bindEvents();
  applyAll();
  updateClock();
  setInterval(updateClock, 1000);
})();
