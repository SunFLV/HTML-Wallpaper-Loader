(function () {
  "use strict";

  var STORAGE_KEY = "html-wallpaper-config-v1";

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
        countdownOnly: false,
        // 只渲染面板：壁纸窗口被裁到面板这一块，其余露出系统壁纸（宿主负责改窗口）
        fitPanel: false,
        panelColor: "",
        label: "距离高考",
        pos: "right-center",
        size: "md",
        paused: false
      },
      // slot key -> absolute-ish path; delivered to the page as a real File
      files: {}
    };
  }

  function merge(base, over) {
    if (!over || typeof over !== "object") return base;
    var out = Object.assign({}, base);
    Object.keys(over).forEach(function (k) {
      if (base[k] && typeof base[k] === "object" && !Array.isArray(base[k])) {
        out[k] = merge(base[k], over[k]);
      } else {
        out[k] = over[k];
      }
    });
    return out;
  }

  function serialize(state) {
    var c = JSON.parse(JSON.stringify(state));
    if (c.source) delete c.source._blobUrl;
    return c;
  }

  // 旧配置里「只渲染面板」叫 display.transparent（"透明背景"），现在归到预设项
  // preset.fitPanel（窗口裁到面板那一块）。遇到旧字段就地迁移，免得用户已经勾过的
  // 选项在升级后悄悄失效。
  function normalize(s) {
    if (s && s.display && s.display.transparent) {
      s.preset = s.preset || {};
      if (!s.preset.fitPanel) s.preset.fitPanel = true;
    }
    return s;
  }

  var ipc = null;
  try { ipc = require("electron").ipcRenderer; } catch (e) {}

  var $ = function (id) { return document.getElementById(id); };
  var state;

  function save() {
    if (ipc) ipc.send("save-config", serialize(state));
    else { try { localStorage.setItem(STORAGE_KEY, JSON.stringify(serialize(state))); } catch (e) {} }
    reportToHost();
    try { setFileState(); } catch (e) {}
  }

  // ---------- 与宿主（wallpaper.ps1）通信 ----------
  // WebView2 的每个窗口即使共用同一个用户数据目录，file:// 下的 localStorage 也
  // 互不可见（实测过），所以配置必须由宿主转发：设置页把改动交给宿主，宿主再
  // 推送到壁纸页。页面 -> 宿主用 document.title（页面无 COM 宿主对象时唯一可读
  // 的通道），宿主 -> 页面用 ExecuteScriptAsync。
  var HOST_BASE_TITLE = document.title;
  var hostPending = null;
  var hostWaiting = false;   // 页面刚发出一条需要宿主应答的消息（pickhtml 用）
  window.__htmlbgHasHost = false;

  function hostSend(kind, payload) { hostPending = { kind: kind, payload: payload || "" }; }

  function reportToHost() {
    try { hostSend("cfg", JSON.stringify(serialize(state))); } catch (e) {}
  }

  // 宿主确认存在。宿主每次推送都会重申一次，所以只在标志真正翻转时重绘，
  // 免得拖滑块时反复重建 DOM。
  //
  // 光靠这个回调还不够：宿主注入的脚本可能在 settings.js 执行「之前」就把
  // __htmlbgHasHost 置成了 true（那时 __htmlbgHostReady 还没定义，`&&` 短路，
  // 回调压根没跑），随后本文件又把标志重置回 false —— 于是「选择文件」按钮
  // 永远停在浏览器分支。所以下面另有一个 400ms 的巡检做兜底。
  window.__htmlbgHostReady = function () {
    window.__htmlbgHasHost = true;
    syncHostAwareUi();
    return "ok";
  };

  // 兜底巡检：只要宿主标志与实际渲染时用的值不一致就重画一次。
  // 保证「选择本地 HTML 文件」和「文件导入」的按钮形态始终一致。
  var renderedHostFlag = null;
  function syncHostAwareUi() {
    if (renderedHostFlag === window.__htmlbgHasHost) return;
    renderedHostFlag = window.__htmlbgHasHost;
    renderFileSlots();
    renderHtmlPick();
  }
  setInterval(syncHostAwareUi, 400);

  // 宿主处理完一条消息后调用，恢复标题以便下一条能被识别为变化
  window.__htmlbgAck = function () {
    hostPending = null;
    hostWaiting = false;
    try { document.title = HOST_BASE_TITLE; } catch (e) {}
    return "ok";
  };

  window.__htmlbgSay = function (msg) {
    var el = document.getElementById("statusLine") || document.body;
    if (el) el.textContent = msg;
    return "ok";
  };

  // 宿主把 config.json / 本地文件内容送回页面
  window.__htmlbgFileReceived = function (encJson) {
    try {
      var data = JSON.parse(decodeURIComponent(encJson));
      state = normalize(merge(defaultConfig(), data));
      syncControls();
      localStorage.setItem(STORAGE_KEY, JSON.stringify(serialize(state)));
      reportToHost();
      window.__htmlbgSay("已载入配置文件");
    } catch (e) {
      window.__htmlbgSay("配置解析失败：" + e.message);
    }
    return "ok";
  };

  // 壁纸里的预设页面改了自己的选项（日期/文档/字号/速度），宿主转发过来
  // 让我们把界面同步成一致
  window.__htmlbgPresetChanged = function (encJson) {
    try {
      var data = JSON.parse(decodeURIComponent(encJson));
      state = normalize(merge(defaultConfig(), data));
      syncControls();
      try { localStorage.setItem(STORAGE_KEY, JSON.stringify(serialize(state))); } catch (e) {}
      window.__htmlbgSay("已同步壁纸上的预设改动");
    } catch (e) {}
    return "ok";
  };

  // 宿主原生文件对话框选好的 Word 文档路径
  window.__htmlbgDocPicked = function (path) {
    try {
      if (path) {
        state.preset.docPath = path;
        $("docPath").value = path;
        save();
        window.__htmlbgSay("已选择文档，正在应用");
      } else {
        window.__htmlbgSay("没有选择文件");
      }
    } catch (e) {}
    return "ok";
  };

  // 宿主扫描当前壁纸 HTML / 页面自己上报的文件槽
  var detectedSlots = [];
  window.__htmlbgSlots = function (encJson) {
    try {
      var data = JSON.parse(decodeURIComponent(encJson));
      var next = (data && data.slots) || [];
      if (JSON.stringify(next.map(function (s) { return [s.key, s.label, s.accept]; })) !==
          JSON.stringify(detectedSlots.map(function (s) { return [s.key, s.label, s.accept]; }))) {
        detectedSlots = next;
        renderFileSlots();
        if (detectedSlots.length) window.__htmlbgSay("发现 " + detectedSlots.length + " 个文件导入点");
      }
    } catch (e) {}
    return "ok";
  };

  // 宿主原生文件对话框选好的文件路径（属于某个文件槽）
  window.__htmlbgFilePicked = function (encKey, encPath) {
    try {
      var key = JSON.parse(decodeURIComponent(encKey));
      var path = JSON.parse(decodeURIComponent(encPath));
      if (!state.files) state.files = {};
      if (path) { state.files[key] = path; window.__htmlbgSay("已绑定：" + path.replace(/^.*[\\\/]/, "")); }
      else { delete state.files[key]; window.__htmlbgSay("已解除绑定"); }
      save();
      renderFileSlots();
    } catch (e) {}
    return "ok";
  };

  // 页面上文件桥的回执：有没有真的把 File 放进 <input type=file>
  window.__htmlbgFileStatus = function (encJson) {
    try {
      var s = JSON.parse(decodeURIComponent(encJson));
      var ext = (s.name || "").split(".").pop().toLowerCase();
      if (s.ok) window.__htmlbgSay("壁纸已载入：" + s.name + "（" + Math.round((s.size || 0) / 1024) + " KB）");
      else window.__htmlbgSay("载入失败：" + (s.error || "未知错误") + "（" + (s.name || ext) + "）");
      setSlotStatus(s.key, s.ok ? "已载入" : (s.error || "失败"), s.ok ? "ok" : "bad");
    } catch (e) {}
    return "ok";
  };

  function setSlotStatus(key, text, cls) {
    var el = document.querySelector('#fileSlots [data-key="' + String(key).replace(/"/g, '\\"') + '"] .slot-state');
    if (el) { el.textContent = text; el.className = "slot-state " + (cls || ""); }
  }

  function renderFileSlots() {
    var box = $("fileSlots");
    if (!box) return;
    // 重绘前保留用户正在填写、尚未绑定的路径，免得宿主推送把输入框清空
    var prevTyped = {};
    box.querySelectorAll(".slot-item").forEach(function (it) {
      var k = it.getAttribute("data-key");
      var inp = it.querySelector(".slot-path-input");
      if (k && inp && inp.value) { prevTyped[k] = inp.value; }
    });
    box.innerHTML = "";
    if (!detectedSlots.length) {
      var none = document.createElement("p");
      none.className = "hint";
      none.innerHTML = '当前页面没有检测到文件导入点。若你刚换过 HTML，点「重新扫描页面」。';
      box.appendChild(none);
      return;
    }
    detectedSlots.forEach(function (s) {
      var slotKey = s.key;
      var bound = state.files && state.files[slotKey];
      var boundPath = (bound && typeof bound === "string") ? bound : "";
      var row = document.createElement("div");
      row.className = "slot-item";
      row.setAttribute("data-key", slotKey);

      // 1) 选择文件 —— 与「选择本地 HTML 文件」同款：文件选择器 + 路径输入框 + 按钮
      var lbl = document.createElement("label");
      lbl.textContent = "选择 " + (s.label || slotKey) + " 文件";
      row.appendChild(lbl);

      var fileWrap = document.createElement("div");
      fileWrap.className = "slot-file-wrap";
      if (window.__htmlbgHasHost) {
        // 真实运行时：用宿主原生对话框选文件（桌面壁纸不可点击，也没法直接取路径）
        var choose = document.createElement("button");
        choose.className = "btn slot-choose";
        choose.textContent = "选择文件";
        choose.addEventListener("click", function () {
          hostSend("pickfile", slotKey);
          window.__htmlbgSay("在弹出的对话框里选择文件…");
        });
        fileWrap.appendChild(choose);
      } else {
        // 浏览器预览：直接用页面里的文件选择器
        var finput = document.createElement("input");
        finput.type = "file";
        finput.accept = s.accept || "";
        finput.addEventListener("change", function (e) {
          var f = e.target.files && e.target.files[0];
          if (!f) return;
          var reader = new FileReader();
          reader.onload = function () {
            state.files = state.files || {};
            state.files[slotKey] = { name: f.name, dataUrl: reader.result };
            save();
            renderFileSlots();
          };
          reader.readAsDataURL(f);
        });
        fileWrap.appendChild(finput);
      }
      row.appendChild(fileWrap);

      // 2) 或填写文件路径（与 HTML 来源里的「或填写文件路径」一致）
      var lbl2 = document.createElement("label");
      lbl2.textContent = "或填写文件路径";
      row.appendChild(lbl2);

      var path = document.createElement("input");
      path.type = "text";
      path.className = "slot-path-input";
      path.placeholder = "相对或绝对路径，例如 C:\\Users\\me\\简历.pdf";
      path.value = boundPath || prevTyped[slotKey] || "";
      row.appendChild(path);

      // 3) 绑定文件 / 清除
      var acts = document.createElement("div");
      acts.className = "config-actions";
      var bind = document.createElement("button");
      bind.className = "btn slot-bind";
      bind.textContent = "绑定文件";
      bind.addEventListener("click", function () {
        var v = path.value.trim();
        if (!v) { window.__htmlbgSay("请先选择文件或填写路径"); return; }
        if (window.__htmlbgHasHost) {
          hostSend("bindpath", JSON.stringify({ key: slotKey, path: v }));
          window.__htmlbgSay("正在绑定：" + v.replace(/^.*[\\\/]/, ""));
        } else {
          state.files = state.files || {};
          state.files[slotKey] = v;
          save();
          renderFileSlots();
        }
      });
      var clear = document.createElement("button");
      clear.className = "btn ghost slot-clear";
      clear.textContent = "清除";
      clear.addEventListener("click", function () {
        if (state.files) delete state.files[slotKey];
        if (window.__htmlbgHasHost) hostSend("unbindfile", slotKey);
        else { save(); renderFileSlots(); }
      });
      acts.appendChild(bind);
      acts.appendChild(clear);
      row.appendChild(acts);

      // 状态行
      var st = document.createElement("div");
      st.className = "slot-state";
      st.textContent = bound ? "已绑定" : "";
      row.appendChild(st);

      box.appendChild(row);
    });
  }

  // 打开设置窗口时主动向宿主要一次同步
  window.__htmlbgRefresh = function () { reportToHost(); return "ok"; };

  // 标题轮询器：有消息待发时把消息塞进标题，等宿主 __htmlbgAck 清空
  setInterval(function () {
    try {
      if (hostPending) {
        document.title = HOST_BASE_TITLE + " [[htmlbg:" + hostPending.kind + ":" + encodeURIComponent(hostPending.payload) + "]]";
      } else {
        if (document.title !== HOST_BASE_TITLE) document.title = HOST_BASE_TITLE;
      }
    } catch (e) {}
  }, 400);

  // 页面可见性变化时也要同步（首次加载即上报一次）
  window.addEventListener("load", function () { setTimeout(reportToHost, 300); });

  function loadInitial() {
    if (ipc) {
      ipc.send("get-config");
      return defaultConfig();
    }
    try {
      var raw = localStorage.getItem(STORAGE_KEY);
      if (raw) return normalize(merge(defaultConfig(), JSON.parse(raw)));
    } catch (e) {}
    // 首次启动：采用 wallpaper.ps1 从 config.json 注入的配置
    if (window.WALLPAPER_CONFIG && typeof window.WALLPAPER_CONFIG === "object") {
      return normalize(merge(defaultConfig(), window.WALLPAPER_CONFIG));
    }
    return defaultConfig();
  }

  // ---------- 来源 ----------
  function setTab(name) {
    document.querySelectorAll("#sourceTabs .tab").forEach(function (t) {
      t.classList.toggle("active", t.getAttribute("data-tab") === name);
    });
    document.querySelectorAll(".panes .pane").forEach(function (p) {
      p.classList.toggle("active", p.getAttribute("data-pane") === name);
    });
  }

  function loadUrl() {
    var v = $("urlInput").value.trim();
    if (!v) return;
    if (!/^https?:\/\//i.test(v)) v = "https://" + v;
    state.source = { type: "url", url: v, file: "", html: "", _blobUrl: null };
    save();
  }

  function onFilePicked(e) {
    var f = e.target.files && e.target.files[0];
    if (!f) return;
    // 内联 HTML 要经 document.title 传给宿主，太大的文件会撑爆这条通道
    if (f.size > 400000) {
      window.__htmlbgSay("这个文件太大（" + Math.round(f.size / 1024) +
        " KB），页面选择器放不下；请点宿主对话框或直接在路径框里填绝对路径");
      return;
    }
    var reader = new FileReader();
    reader.onload = function () {
      // 页面自带的文件选择器拿不到真实路径（浏览器安全限制），所以直接把文件内容当
      // 内联 HTML 载入 —— 至少立刻能看到效果。要走"记住路径、每次启动都加载"那条路，
      // 得用宿主的原生对话框（选中后写进 config.json 的 source.file）。
      state.source = { type: "code", url: "", file: f.name, html: reader.result, _blobUrl: null };
      save();
      window.__htmlbgSay("已载入：" + f.name + "（页面选择器无法保存路径，下次启动请用宿主对话框）");
    };
    reader.readAsText(f);
  }

  // 「选择本地 HTML 文件」：与文件导入同款。真实运行时由宿主打开原生对话框，把绝对
  // 路径回填到路径框并直接加载；浏览器预览里仍用页面自己的 <input type=file>。
  // 页面上始终留一个隐藏的文件选择器作兜底：若点「选择文件」后 1.5 秒内宿主没有任何
  // 应答（消息没送达 / 宿主没这个能力），就直接改用页面自带的选择器，按钮不会"点了没反应"。
  function renderHtmlPick() {
    var box = $("htmlPickWrap");
    if (!box) return;
    box.innerHTML = "";

    var fallback = document.createElement("input");
    fallback.id = "fileInput";
    fallback.type = "file";
    fallback.accept = ".html,.htm";
    fallback.addEventListener("change", onFilePicked);
    fallback.style.display = "none";
    box.appendChild(fallback);

    if (window.__htmlbgHasHost) {
      // 与文件导入槽位一模一样：整行宽的「选择文件」按钮，宿主弹原生对话框
      var choose = document.createElement("button");
      choose.className = "btn slot-choose";
      choose.textContent = "选择文件";
      choose.addEventListener("click", function () {
        hostWaiting = true;          // 宿主的 __htmlbgAck 会把它清掉
        hostSend("pickhtml", "");
        window.__htmlbgSay("正在打开文件对话框…");
        setTimeout(function () {
          if (!hostWaiting) return;  // 宿主已经应答了，正常流程
          hostWaiting = false;
          hostPending = null;
          // 不能在这里 fallback.click()：Chromium 要求文件选择器必须由真实用户手势
          // 触发，定时器里派发的点击会被拦掉。把选择器显示出来让用户自己点。
          fallback.style.display = "";
          window.__htmlbgSay("宿主没有应答，请改用下面的页面选择器");
        }, 1500);
      });
      box.appendChild(choose);
    } else {
      fallback.style.display = "";
    }
  }

  // 与槽位卡片一致的状态行：告诉用户当前壁纸到底在用哪个来源
  function setFileState() {
    var el = $("fileState");
    if (!el) return;
    var s = state.source || {};
    var txt = "", cls = "";
    if (s.type === "file" && s.file) {
      txt = "已加载：" + String(s.file).replace(/^.*[\\\/]/, "");
      cls = "ok";
    } else if (s.type === "code" && s.html) {
      txt = "当前用的是「HTML 代码」里的内容";
    } else if (s.type === "url" && s.url) {
      txt = "当前用的是网址来源";
    } else {
      txt = "未加载文件（内置动画）";
    }
    el.textContent = txt;
    el.className = "slot-state " + cls;
  }

  function loadFilePath() {
    var v = $("filePath").value.trim();
    if (!v) return;
    // 统一成 file:/// URL，壁纸页在 file:// 下才能加载任意路径
    if (/^[A-Za-z]:[\\/]/.test(v) || v.indexOf("file://") === 0) {
      if (v.indexOf("file://") !== 0) v = "file:///" + v.replace(/\\/g, "/").replace(/ /g, "%20");
    } else if (v.indexOf("/") !== 0 && v.indexOf("./") !== 0) {
      v = "./" + v.replace(/\\/g, "/");
    }
    state.source = { type: "file", url: "", file: v, html: "", _blobUrl: null };
    save();
    setFileState();
    window.__htmlbgSay("已加载：" + v.replace(/^.*[\\\/]/, ""));
  }

  function applyCode() {
    state.source = { type: "code", url: "", file: "", html: $("codeInput").value, _blobUrl: null };
    save();
  }

  function useBuiltin() {
    state.source = { type: "builtin", url: "", file: "", html: "", _blobUrl: null };
    save();
  }

  // ---------- 显示/行为/界面 ----------
  function bindLive() {
    $("scale").addEventListener("input", function () {
      state.display.scale = parseFloat(this.value);
      $("scaleVal").textContent = Math.round(state.display.scale * 100) + "%"; save();
    });
    $("opacity").addEventListener("input", function () {
      state.display.opacity = parseFloat(this.value);
      $("opacityVal").textContent = Math.round(state.display.opacity * 100) + "%"; save();
    });
    $("bg").addEventListener("input", function () {
      state.display.background = this.value; save();
    });
    $("reload").addEventListener("input", function () {
      state.behavior.reloadMinutes = Math.max(0, parseInt(this.value, 10) || 0); save();
    });
    $("hideCursor").addEventListener("change", function () {
      state.behavior.hideCursor = this.checked; save();
    });
    $("clickThrough").addEventListener("change", function () {
      state.behavior.clickThrough = this.checked; save();
    });
    $("theme").addEventListener("change", function () {
      state.ui.theme = this.value; save();
    });
    $("accent").addEventListener("input", function () {
      state.ui.accent = this.value; save();
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
    $("urlInput").value = (state.source.url || "");
    $("codeInput").value = (state.source.html || "");
    $("filePath").value = (state.source.file || "");
    setFileState();
    var t = state.source.type;
    if (t !== "url" && t !== "file" && t !== "code") t = "builtin";
    setTab(t);
    syncPreset();
  }

  // ---------- 配置导入/导出 ----------
  function exportConfig() {
    var json = JSON.stringify(serialize(state), null, 2);
    if (window.__htmlbgHasHost) {
      // 交给宿主写成真正的 config.json（浏览器下载会落到下载目录，不是项目目录）
      hostSend("export", json);
    } else {
      var blob = new Blob([json], { type: "application/json" });
      var a = document.createElement("a");
      a.href = URL.createObjectURL(blob);
      a.download = "wallpaper-config.json";
      a.click();
      setTimeout(function () { URL.revokeObjectURL(a.href); }, 1000);
    }
  }

  function importConfig(file) {
    var reader = new FileReader();
    reader.onload = function () {
      try {
        var data = JSON.parse(reader.result);
        state = normalize(merge(defaultConfig(), data));
        syncControls();
        save();
      } catch (e) {
        alert("配置文件解析失败：请确保是有效的 JSON 文件。");
      }
    };
    reader.readAsText(file);
  }

  function loadFromConfigFile() {
    if (window.__htmlbgHasHost) {
      // 让宿主读 config.json（页面在 file:// 下无法自己读任意路径）
      hostSend("readfile", "config.json");
      return;
    }
    try { localStorage.removeItem(STORAGE_KEY); } catch (e) {}
    location.reload();
  }

  function resetConfig() {
    if (!confirm("确定恢复默认设置？")) return;
    state = defaultConfig();
    syncControls();
    save();
  }

  // ---------- 预设页面 ----------
  var PRESETS = window.HTMLBG_PRESETS || [];

  function presetPageUrl(page) {
    // presets/xxx.html -> file:///.../presets/xxx.html（相对当前文件解析，跨目录也能加载）
    try { return new URL(page, location.href).href; } catch (e) { return page; }
  }

  function applyPreset(id) {
    var p = null;
    for (var i = 0; i < PRESETS.length; i++) { if (PRESETS[i].id === id) p = PRESETS[i]; }
    if (!p) return;
    var cfg = JSON.parse(JSON.stringify(p.config));
    // 保留已有的预设选项（考试日期、文档路径…），只换页面和默认外观
    var keep = Object.assign({}, defaultConfig().preset, state.preset || {});
    state.source = cfg.source;
    state.display = merge(state.display, cfg.display || {});
    if (cfg.ui) state.ui = merge(state.ui, cfg.ui);
    state.preset = Object.assign({}, cfg.preset || {}, keep);
    state.preset.id = p.id;
    syncControls();
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

  function bindPreset() {
    $("examDate").addEventListener("change", function () {
      var v = this.value;
      if (/^\d{4}-\d{2}-\d{2}$/.test(v)) { state.preset.examDate = v; save(); }
    });
    $("docFs").addEventListener("input", function () {
      state.preset.fontSize = parseInt(this.value, 10) || 22;
      $("docFsVal").textContent = state.preset.fontSize + "px"; save();
    });
    $("docSp").addEventListener("input", function () {
      state.preset.scrollSpeed = parseInt(this.value, 10) || 0;
      $("docSpVal").textContent = state.preset.scrollSpeed + "px/s"; save();
    });
    $("cdShow").addEventListener("change", function () {
      state.preset.showCountdown = this.checked; save();
    });
    $("fitPanel").addEventListener("change", function () {
      // 宿主收到后会把壁纸窗口裁到面板那一块（或恢复全屏）
      state.preset.fitPanel = this.checked; save();
    });
    $("cdOnly").addEventListener("change", function () {
      state.preset.countdownOnly = this.checked;
      // 「只显示倒计时」和「显示倒计时」互斥时以 countdownOnly 为准，顺手勾上显示
      if (this.checked && !state.preset.showCountdown) {
        state.preset.showCountdown = true;
        $("cdShow").checked = true;
      }
      save();
    });
    $("panelColor").addEventListener("input", function () {
      state.preset.panelColor = this.value.trim(); save();
    });
    $("panelColorPick").addEventListener("input", function () {
      // 取色器不含透明度，写进文本框后可再手动补 rgba(...)
      $("panelColor").value = this.value;
      state.preset.panelColor = this.value; save();
    });
    $("cdLabel").addEventListener("change", function () {
      state.preset.label = this.value.trim() || "距离高考"; save();
    });
    $("docPause").addEventListener("change", function () {
      state.preset.paused = this.checked; save();
    });
    document.querySelectorAll("#posGrid .magnet").forEach(function (b) {
      b.addEventListener("click", function () {
        state.preset.pos = b.getAttribute("data-pos");
        syncPreset();
        save();
      });
    });
    document.querySelectorAll("#sizeRow .chip").forEach(function (b) {
      b.addEventListener("click", function () {
        state.preset.size = b.getAttribute("data-size");
        syncPreset();
        save();
      });
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
    $("docPause").checked = !!p.paused;
    // 「只显示倒计时面板」和「面板背景色」只属于高考倒计时预设
    var examOnly = $("examOnlyOpts");
    if (examOnly) examOnly.classList.toggle("off", p.id !== "exam-dock");
    $("fitPanel").checked = !!p.fitPanel;
    $("cdOnly").checked = !!p.countdownOnly;
    $("panelColor").value = p.panelColor || "";
    document.querySelectorAll("#posGrid .magnet").forEach(function (b) {
      b.classList.toggle("active", b.getAttribute("data-pos") === (p.pos || "right-center"));
    });
    document.querySelectorAll("#sizeRow .chip").forEach(function (b) {
      b.classList.toggle("active", b.getAttribute("data-size") === (p.size || "md"));
    });
    renderFileSlots();
  }

  // ---------- 初始化 ----------
  function build() {
    syncControls();
    bindLive();
    document.querySelectorAll("#sourceTabs .tab").forEach(function (t) {
      t.addEventListener("click", function () { setTab(t.getAttribute("data-tab")); });
    });
    $("loadUrl").addEventListener("click", loadUrl);
    $("urlInput").addEventListener("keydown", function (e) { if (e.key === "Enter") loadUrl(); });
    renderHtmlPick();
    $("loadFile").addEventListener("click", loadFilePath);
    $("filePath").addEventListener("keydown", function (e) { if (e.key === "Enter") loadFilePath(); });
    $("clearFile").addEventListener("click", function () {
      $("filePath").value = "";
      useBuiltin();
      setFileState();
      window.__htmlbgSay("已清除本地文件来源，回到内置动画");
    });
    $("applyCode").addEventListener("click", applyCode);
    $("useBuiltin").addEventListener("click", useBuiltin);
    $("exportBtn").addEventListener("click", exportConfig);
    $("importBtn").addEventListener("click", function () { $("importInput").click(); });
    $("importInput").addEventListener("change", function (e) {
      if (e.target.files && e.target.files[0]) importConfig(e.target.files[0]);
      e.target.value = "";
    });
    $("resetBtn").addEventListener("click", resetConfig);
    $("restoreBtn").addEventListener("click", loadFromConfigFile);
    $("applyBtn").addEventListener("click", function () {
      save();
      if (ipc) ipc.send("save-config", serialize(state));
    });

    buildPresetList();
    bindPreset();
    renderFileSlots();
    $("rescanBtn").addEventListener("click", function () {
      if (window.__htmlbgHasHost) { hostSend("rescan", ""); window.__htmlbgSay("已重新扫描"); }
      else { window.__htmlbgSay("浏览器预览模式下由页面自己上报导入点"); }
    });

    // 探测宿主是否存在：宿主回应 __htmlbgHasHost=true 后，导出/恢复走宿主通道
    hostSend("hello", "");
  }

  state = loadInitial();

  if (ipc) {
    ipc.on("config", function (e, cfg) {
      state = normalize(merge(defaultConfig(), cfg));
      syncControls();
    });
    ipc.on("saved", function () { /* 已保存 */ });
  }

  build();
})();
