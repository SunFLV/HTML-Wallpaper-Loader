/* filebridge.js - injected into every document of the desktop wallpaper
 * (WebView2 AddScriptToExecuteOnDocumentCreated).
 *
 * The desktop layer cannot be clicked (the icon layer sits above the wallpaper), so
 * every file import has to happen in the SETTINGS window.  This bridge is the other
 * half of that deal:
 *
 *   1. it scans the page for <input type="file"> elements (the "slots") and reports
 *      them upwards, so the settings window can list them;
 *   2. when a slot is bound to real file(s) in the settings, the host serves those
 *      bytes at https://htmlbg.local/file/<slot> and tells the bridge to fetch them;
 *      the bridge turns each response into a real File and drops it into the input,
 *      then dispatches change/input - so ANY page that reads file inputs works
 *      unmodified.
 *
 * Nothing here touches the network for real: htmlbg.local is intercepted by the host.
 */
(function () {
  "use strict";
  if (window.__htmlbgBridgeInstalled) return;
  window.__htmlbgBridgeInstalled = true;

  var SERVED = "https://htmlbg.local/file/";

  function up(obj) {
    try { window.parent.postMessage({ htmlbg: obj }, "*"); } catch (e) {}
  }

  function labelFor(el) {
    var txt = "";
    if (el.id) {
      var l = document.querySelector('label[for="' + el.id.replace(/"/g, '\\"') + '"]');
      if (l) txt = (l.textContent || "").trim();
    }
    if (!txt && el.parentNode) {
      var p = el.parentNode.tagName === "LABEL" ? el.parentNode : null;
      if (p) txt = (p.textContent || "").trim();
    }
    return txt.replace(/\s+/g, " ").slice(0, 60);
  }

  function collectSlots() {
    var inputs = document.querySelectorAll('input[type="file"]');
    return Array.prototype.map.call(inputs, function (el, i) {
      var key = el.getAttribute("data-htmlbg-key") || el.id || el.name || ("file" + (i + 1));
      var label = el.getAttribute("data-htmlbg-label") || labelFor(el) ||
        el.getAttribute("aria-label") || el.getAttribute("placeholder") ||
        el.getAttribute("title") || el.accept || el.id || el.name || ("文件 " + (i + 1));
      return {
        key: key,
        label: String(label).slice(0, 60),
        accept: el.getAttribute("accept") || "",
        multiple: el.hasAttribute("multiple"),
        index: i
      };
    });
  }

  function slotInput(key) {
    var inputs = document.querySelectorAll('input[type="file"]');
    for (var i = 0; i < inputs.length; i++) {
      var el = inputs[i];
      if ((el.getAttribute("data-htmlbg-key") || el.id || el.name || ("file" + (i + 1))) === key) return el;
    }
    return null;
  }

  function put(input, blob, name, type) {
    var file;
    try { file = new File([blob], name, { type: type || "application/octet-stream" }); }
    catch (e) { file = blob; try { file.name = name; } catch (e2) {} }
    try {
      var dt = new DataTransfer();
      dt.items.add(file);
      input.files = dt.files;
    } catch (e3) {
      return false;
    }
    try {
      input.dispatchEvent(new Event("change", { bubbles: true }));
      input.dispatchEvent(new Event("input", { bubbles: true }));
    } catch (e4) {}
    return true;
  }

  function b64ToBlob(b64, mime) {
    var bin = atob(b64);
    var len = bin.length;
    var u8 = new Uint8Array(len);
    for (var i = 0; i < len; i++) u8[i] = bin.charCodeAt(i);
    return new Blob([u8], { type: mime || "application/octet-stream" });
  }

  // The page asks the HOST for the bytes (no network involved at all): the host reads
  // the bound file and streams it back as base64 chunks.  Anything else - fetch over a
  // virtual https origin - gets blocked by Chromium on a file:// page.
  var pending = {};

  function finish(p, blob, name, mime) {
    var input = slotInput(p.key);
    if (!input) { p.resolve({ ok: false, error: "slot 不存在" }); return; }
    var ok = put(input, blob, name, mime);
    p.resolve({ ok: ok, error: ok ? "" : "浏览器拒绝写入文件", name: name, size: blob.size });
  }

  function onChunk(msg) {
    var p = pending[msg.key];
    if (!p) return;
    if (msg.i !== p.next) {
      clearTimeout(p.timer);
      delete pending[msg.key];
      p.resolve({ ok: false, error: "数据分片顺序错乱" });
      return;
    }
    p.next++;
    p.parts.push(msg.data);
    if (p.next >= p.chunks) {
      clearTimeout(p.timer);
      delete pending[msg.key];
      try {
        finish(p, b64ToBlob(p.parts.join(""), p.mime), p.name, p.mime);
      } catch (err) {
        p.resolve({ ok: false, error: String(err && err.message || err) });
      }
    }
  }

  function loadKey(key) {
    return new Promise(function (resolve) {
      var p = { key: key, resolve: resolve, parts: [], next: 0, chunks: 0, name: key, mime: "", timer: null };
      pending[key] = p;
      p.timer = setTimeout(function () {
        if (pending[key] !== p) return;
        delete pending[key];
        resolve({ ok: false, error: "宿主未在 30 秒内返回文件" });
      }, 30000);
      up({ kind: "fileread", payload: key });
    });
  }

  function decodeURIComponentSafe(s) {
    try { return decodeURIComponent(s); } catch (e) { return s; }
  }

  // The parent sends either an explicit {type:"files"} or its whole config
  // ({type:"config", files:{...}}) - both mean "these slots have a file now".
  var loaded = {};
  window.addEventListener("message", function (e) {
    var d = e && e.data;
    if (!d || !d.htmlbg) return;
    var msg = d.htmlbg;
    if (msg.type === "__diag") {
      up({ kind: "filestatus", payload: JSON.stringify({ key: "__diag", ok: true, name: String(msg.text || ""), size: 0, error: "" }) });
      return;
    }
    if (msg.type === "filebegin") {
      if (pending[msg.key]) {
        pending[msg.key].chunks = msg.chunks || 0;
        pending[msg.key].name = msg.name || msg.key;
        pending[msg.key].mime = msg.mime || "";
      }
      return;
    }
    if (msg.type === "filechunk") { onChunk(msg); return; }
    if (msg.type === "fileend") {
      // All chunks arrived already -> finish() ran from onChunk.  Nothing left to do
      // unless the host sent fewer than promised, in which case the timeout catches it.
      return;
    }
    if (msg.type === "fileerror") {
      var q = pending[msg.key];
      if (q) {
        clearTimeout(q.timer);
        delete pending[msg.key];
        q.resolve({ ok: false, error: msg.message || "宿主读取文件失败" });
      }
      return;
    }

    var map = null;
    if (msg.type === "files") map = msg.files || {};
    else if (msg.type === "config") map = msg.files || {};
    if (!map) return;
    var keys = Object.keys(map);
    if (!keys.length) return;
    keys.forEach(function (key) {
      var v = map[key] || {};
      var sig = (v.name || "") + "|" + (v.url || "") + "|" + (v.path || "");
      if (loaded[key] === sig) return;
      loaded[key] = sig;
      loadKey(key).then(function (res) {
        up({ kind: "filestatus", payload: JSON.stringify({ key: key, ok: !!res.ok, name: res.name || "", size: res.size || 0, error: res.error || "" }) });
      });
    });
  });

  // Clicking a file input would open Chromium's own dialog and hand the page a file
  // the host never sees (so it could not remember it).  Route it through the host.
  document.addEventListener("click", function (e) {
    var el = e.target;
    if (el && el.tagName === "INPUT" && String(el.type).toLowerCase() === "file") {
      e.preventDefault();
      e.stopPropagation();
      up({ kind: "pickfile", payload: keyOf(el) });
    }
  }, true);

  function keyOf(el) {
    var inputs = document.querySelectorAll('input[type="file"]');
    for (var i = 0; i < inputs.length; i++) {
      if (inputs[i] === el) return el.getAttribute("data-htmlbg-key") || el.id || el.name || ("file" + (i + 1));
    }
    return "";
  }

  function report(force) {
    var slots = collectSlots();
    var sig = JSON.stringify(slots);
    if (!force && sig === lastSig) return;
    lastSig = sig;
    up({ kind: "slots", payload: JSON.stringify({ slots: slots, href: location.href }) });
  }
  var lastSig = "";

  function attach() {
    // the host page itself has no file inputs and must stay quiet
    if (window.__htmlbgWallpaperHost || window.__htmlbgSkipBridge) return;
    report(true);
    if (window.MutationObserver) {
      var t = null;
      new MutationObserver(function () {
        clearTimeout(t);
        t = setTimeout(function () { report(false); }, 600);
      }).observe(document.documentElement || document.body, { childList: true, subtree: true });
    }
  }

  window.HTMLBG = {
    slots: collectSlots,
    rescan: function () { report(true); },
    request: function (key) { up({ kind: "pickfile", payload: key }); },
    status: function (key, ok, detail) {
      up({ kind: "filestatus", payload: JSON.stringify({ key: key, ok: !!ok, name: detail || "", size: 0, error: ok ? "" : (detail || "") }) });
    }
  };

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", attach);
  else attach();
})();
