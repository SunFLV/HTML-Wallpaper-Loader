/* presets.js - the built-in preset pages, shared by the settings UI (settings.js),
 * the browser preview (app.js) and the desktop host (wallpaper.ps1).
 *
 * A preset is an ordinary source page (type=file) plus a bag of options the page
 * reads through postMessage.  Applying a preset only writes normal config fields,
 * so config.json stays plain and portable.
 */
(function () {
  "use strict";

  var EXAM = {
    id: "exam-dock",
    name: "高考倒计时 + 文档滚动预览",
    desc: "倒计时（天数 + 时分秒）在上，下面自动向上滚动预览你选的文档，支持 Word / PDF / PPT / Excel / CSV / 文本 / 图片。",
    page: "presets/exam-dock.html",
    config: {
      source: { type: "file", url: "", file: "presets/exam-dock.html", html: "" },
      display: { scale: 1, opacity: 1, background: "#0a0a12" },
      ui: { theme: "dark", accent: "#7c5cff" },
      preset: {
        id: "exam-dock",
        examDate: "2027-06-07",
        fontSize: 22,
        scrollSpeed: 26,
        showCountdown: true,
        countdownOnly: false,
        fitPanel: false,
        tilt3d: false,
        parallax: false,
        panelColor: "",
        label: "距离高考",
        pos: "right-center",
        size: "md",
        paused: false
      },
      files: {}
    }
  };

  var AURORA = {
    id: "builtin",
    name: "内置极光动画",
    desc: "恢复默认的极光光晕动画背景（不显示任何面板）。",
    page: "",
    config: {
      source: { type: "builtin", url: "", file: "", html: "" },
      display: { scale: 1, opacity: 1, background: "#0a0a12" },
      ui: { theme: "dark", accent: "#7c5cff" },
      preset: {
        id: "", examDate: "2027-06-07", fontSize: 22, scrollSpeed: 26,
        showCountdown: true, label: "距离高考", pos: "right-center", size: "md", paused: false
      },
      files: {}
    }
  };

  var HTMLBG_PRESETS = [EXAM, AURORA];

  function presetById(id) {
    for (var i = 0; i < HTMLBG_PRESETS.length; i++) {
      if (HTMLBG_PRESETS[i].id === id) return HTMLBG_PRESETS[i];
    }
    return null;
  }

  window.HTMLBG_PRESETS = HTMLBG_PRESETS;
  window.HTMLBG_PRESET_BY_ID = presetById;
})();
