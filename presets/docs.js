/* docs.js - one parser for every document type we accept.
 *
 * Used by:
 *   - the desktop wallpaper (the file is handed to the page as a real File object,
 *     see filebridge.js), and
 *   - the browser preview (index.html), where the user picks files normally.
 *
 * read(file) -> Promise<doc>
 *   doc = { name, ext, kind, blocks, text, dataUrl, meta, truncated, note }
 *   kind : 'blocks' (text layout) | 'image' | 'audio' | 'video' | 'unknown'
 *   blocks: [{ level:0..6, list:bool, text:string, tag?:'h'|'sheet'|'slide'|'page'|'note' }]
 *
 * No dependencies, no network.  Everything runs on what the browser already has:
 * JSZip-equivalent code below (central directory scan + DecompressionStream) and a
 * small hand-written PDF text extractor.
 */
(function (global) {
  "use strict";

  var MAX_BLOCKS = 6000;
  var MAX_CHARS = 220000;

  var TEXT_EXTS = ["txt", "md", "markdown", "log", "json", "xml", "yaml", "yml", "ini", "cfg", "sql", "csv", "tsv", "htm", "html", "css", "js", "py", "vbs", "ps1", "bat"];
  var IMAGE_EXTS = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "svg", "ico", "avif"];
  var MEDIA_EXTS = ["mp4", "webm", "mov", "m4v", "mp3", "wav", "m4a", "ogg"];

  function extOf(name) {
    var i = String(name || "").lastIndexOf(".");
    return i < 0 ? "" : String(name).slice(i + 1).toLowerCase();
  }

  function supported() {
    return ["docx", "doc", "xlsx", "xlsm", "pptx", "ppt", "pdf", "csv", "tsv", "txt", "md"]
      .concat(TEXT_EXTS).concat(IMAGE_EXTS).concat(MEDIA_EXTS);
  }

  function cap(blocks) {
    var out = [], chars = 0, truncated = false;
    for (var i = 0; i < blocks.length; i++) {
      out.push(blocks[i]);
      chars += (blocks[i].text || "").length;
      if (out.length >= MAX_BLOCKS || chars >= MAX_CHARS) { truncated = true; break; }
    }
    return { blocks: out, truncated: truncated };
  }

  function b(level, list, text, tag) {
    return { level: level || 0, list: !!list, text: String(text || ""), tag: tag || "" };
  }

  function readText(file) {
    // utf-8 first; if the bytes are clearly not utf-8 fall back to gbk via TextDecoder
    return file.arrayBuffer().then(function (buf) {
      var u8 = new Uint8Array(buf);
      if (u8.length >= 3 && u8[0] === 0xEF && u8[1] === 0xBB && u8[2] === 0xBF) u8 = u8.subarray(3);
      var enc = "utf-8";
      if (looksGb(u8)) {
        try { new TextDecoder("gb18030"); enc = "gb18030"; } catch (e) {}
      }
      return new TextDecoder(enc).decode(u8);
    });
  }

  // crude but effective: a utf-8 violation is a strong hint this is a legacy ANSI file
  function looksGb(u8) {
    var bad = 0, i = 0, n = Math.min(u8.length, 65536);
    while (i < n) {
      var c = u8[i];
      if (c < 0x80) { i++; continue; }
      if (c >= 0xC2 && c <= 0xDF) { if (i + 1 >= n || (u8[i + 1] & 0xC0) !== 0x80) { bad++; } i += 2; continue; }
      if (c >= 0xE0 && c <= 0xEF) {
        var ok = i + 2 < n && (u8[i + 1] & 0xC0) === 0x80 && (u8[i + 2] & 0xC0) === 0x80;
        if (!ok) bad++;
        i += 3; continue;
      }
      if (c >= 0xF0 && c <= 0xF4) { i += 4; continue; }
      bad++; i++;
    }
    return bad > 8;
  }

  // ---------------------------------------------------------------- zip ----------
  function zipEntries(buf) {
    var u8 = new Uint8Array(buf), dv = new DataView(buf), i, out = {};
    var eocd = -1;
    for (i = u8.length - 22; i >= 0 && i >= u8.length - 66000; i--) {
      if (dv.getUint32(i, true) === 0x06054b50) { eocd = i; break; }
    }
    if (eocd < 0) throw new Error("这个文件不是有效的 Office / zip 文档。");
    var count = dv.getUint16(eocd + 10, true), p = dv.getUint32(eocd + 16, true);
    for (var n = 0; n < count; n++) {
      if (dv.getUint32(p, true) !== 0x02014b50) break;
      var namLen = dv.getUint16(p + 28, true);
      var extLen = dv.getUint16(p + 30, true);
      var comLen = dv.getUint16(p + 32, true);
      var lh = dv.getUint32(p + 42, true);
      var name = new TextDecoder("utf-8").decode(u8.subarray(p + 46, p + 46 + namLen));
      var method = dv.getUint16(p + 10, true);
      var compSize = dv.getUint32(p + 20, true);
      var nl = dv.getUint16(lh + 26, true), el = dv.getUint16(lh + 28, true);
      var start = lh + 30 + nl + el;
      out[name] = { method: method, start: start, size: compSize, base: buf };
      p += 46 + namLen + extLen + comLen;
    }
    return out;
  }

  function zipText(entries, name) {
    var e = entries[name];
    if (!e) return Promise.resolve("");
    if (e.method === 0) {
      return Promise.resolve(new TextDecoder("utf-8").decode(new Uint8Array(e.base, e.start, e.size)));
    }
    var stream = new Blob([new Uint8Array(e.base, e.start, e.size)]).stream().pipeThrough(new DecompressionStream("deflate-raw"));
    return new Response(stream).arrayBuffer().then(function (x) { return new TextDecoder("utf-8").decode(x); });
  }

  function xmlOf(text) {
    return new DOMParser().parseFromString(text.replace(/^﻿/, ""), "application/xml");
  }

  function txt(tag) {
    var s = "";
    for (var i = 0; i < tag.childNodes.length; i++) {
      var n = tag.childNodes[i];
      if (n.nodeType === 3) s += n.nodeValue;
      else if (n.nodeType === 1) s += txt(n);
    }
    return s;
  }

  function nodeList(doc, ns, local) {
    return doc.getElementsByTagName(ns + ":" + local);
  }

  // --------------------------------------------------------------- docx ----------
  function readDocx(file) {
    return file.arrayBuffer().then(function (buf) {
      var entries = zipEntries(buf);
      return zipText(entries, "word/document.xml").then(function (xml) {
        if (!xml) throw new Error("word/document.xml 不存在，可能不是 .docx。");
        var doc = xmlOf(xml);
        var blocks = [];
        var ps = nodeList(doc, "w", "p");
        for (var i = 0; i < ps.length; i++) {
          var p = ps[i], text = "";
          var ts = nodeList(p, "w", "t");
          for (var j = 0; j < ts.length; j++) text += ts[j].textContent;
          var brs = nodeList(p, "w", "br");
          if (brs.length && !text) text = "";
          text = text.replace(/\s+$/, "");
          if (!text) continue;
          var level = 0;
          var st = nodeList(p, "w", "pStyle")[0];
          if (st) {
            var v = st.getAttribute("w:val") || "";
            var m = /(?:heading|标题)\s*([1-6])/i.exec(v) || /^\s*([1-6])\s*$/.exec(v);
            if (m) level = parseInt(m[1], 10);
          }
          if (!level) {
            var ol = nodeList(p, "w", "outlineLvl")[0];
            if (ol) {
              var n = parseInt(ol.getAttribute("w:val"), 10);
              if (!isNaN(n) && n >= 0 && n <= 5) level = n + 1;
            }
          }
          blocks.push(b(level, nodeList(p, "w", "numPr").length > 0, text));
        }
        var capped = cap(blocks);
        if (!capped.blocks.length) throw new Error("文档里没有可读的文字。");
        return { kind: "blocks", blocks: capped.blocks, truncated: capped.truncated };
      });
    });
  }

  // --------------------------------------------------------------- xlsx ----------
  function colIndex(ref) {
    var s = String(ref || "").replace(/\d/g, ""), n = 0;
    for (var i = 0; i < s.length; i++) n = n * 26 + (s.charCodeAt(i) - 64);
    return n - 1;
  }

  function readXlsx(file) {
    return file.arrayBuffer().then(function (buf) {
      var entries = zipEntries(buf);
      return zipText(entries, "xl/workbook.xml").then(function (wbXml) {
        var sheetNames = [], sheetIds = [];
        if (wbXml) {
          var wb = xmlOf(wbXml);
          // The sheet elements carry no prefix ("<sheet …>", default namespace), and
          // getElementsByTagName must be given that qualified name, not ":sheet".
          var sh = wb.getElementsByTagName("sheet");
          if (!sh.length) sh = wb.getElementsByTagNameNS("*", "sheet");
          for (var i = 0; i < sh.length; i++) {
            sheetNames.push(sh[i].getAttribute("name") || ("Sheet" + (i + 1)));
            sheetIds.push(sh[i].getAttribute("r:id") || sh[i].getAttributeNS("http://schemas.openxmlformats.org/officeDocument/2006/relationships", "id"));
          }
        }
        return zipText(entries, "xl/_rels/workbook.xml.rels").then(function (relXml) {
          var targets = {};
          if (relXml) {
            var rel = xmlOf(relXml).getElementsByTagName("Relationship");
            for (var r = 0; r < rel.length; r++) {
              targets[rel[r].getAttribute("Id")] = rel[r].getAttribute("Target");
            }
          }
          return zipText(entries, "xl/sharedStrings.xml").then(function (ssXml) {
            var shared = [];
            if (ssXml) {
              var si = xmlOf(ssXml).getElementsByTagName("si");
              for (var k = 0; k < si.length; k++) { shared.push(txt(si[k])); }
            }
            var order = sheetIds.map(function (id, i) {
              var t = targets[id] || ("worksheets/sheet" + (i + 1) + ".xml");
              if (t.charAt(0) === "/") t = t.slice(1);
              if (t.indexOf("xl/") !== 0) t = "xl/" + t.replace(/^\.\//, "");
              return { name: sheetNames[i] || ("Sheet" + (i + 1)), path: t };
            });
            if (!order.length) order = [{ name: "Sheet1", path: "xl/worksheets/sheet1.xml" }];
            var queue = order.slice(0, 24);
            return Promise.all(queue.map(function (s) { return zipText(entries, s.path); })).then(function (texts) {
              var blocks = [], truncated = false;
              texts.forEach(function (xml, si2) {
                if (!xml) return;
                var doc = xmlOf(xml);
                if (texts.length > 1) blocks.push(b(3, false, queue[si2].name, "sheet"));
                var rows = doc.getElementsByTagName("row");
                var emptyRun = 0;
                for (var ri = 0; ri < rows.length; ri++) {
                  var cells = rows[ri].getElementsByTagName("c");
                  var vals = [];
                  for (var ci = 0; ci < cells.length; ci++) {
                    var c = cells[ci], t = c.getAttribute("t"), raw = "";
                    if (t === "inlineStr") {
                      var is = c.getElementsByTagName("t");
                      for (var q = 0; q < is.length; q++) raw += is[q].textContent;
                    } else {
                      var vNode = c.getElementsByTagName("v")[0];
                      raw = vNode ? vNode.textContent : "";
                      if (t === "s") raw = shared[parseInt(raw, 10)] || "";
                    }
                    vals[colIndex(c.getAttribute("r"))] = String(raw || "").trim();
                  }
                  var line = [];
                  for (var vi = 0; vi < vals.length; vi++) line.push(vals[vi] === undefined ? "" : vals[vi]);
                  while (line.length && line[line.length - 1] === "") line.pop();
                  var rowText = line.join("  |  ").trim();
                  if (!rowText) { if (++emptyRun > 3) continue; }
                  emptyRun = 0;
                  var isFirstRow = ri === 0;
                  blocks.push(b(isFirstRow && texts.length <= 1 ? 4 : 0, false, rowText));
                  if (blocks.length >= MAX_BLOCKS) { truncated = true; break; }
                }
              });
              if (!blocks.length) throw new Error("表格是空的（或没有可读的工作表）。");
              return { kind: "blocks", blocks: blocks, truncated: truncated, meta: { sheets: sheetNames } };
            });
          });
        });
      });
    });
  }

  // --------------------------------------------------------------- pptx ----------
  function readPptx(file) {
    return file.arrayBuffer().then(function (buf) {
      var entries = zipEntries(buf);
      var names = Object.keys(entries).filter(function (n) { return /^ppt\/slides\/slide\d+\.xml$/.test(n); });
      names.sort(function (a, c) {
        return parseInt(a.replace(/\D/g, ""), 10) - parseInt(c.replace(/\D/g, ""), 10);
      });
      if (!names.length) throw new Error("ppt/slides/slideN.xml 不存在，可能不是 .pptx。");
      names = names.slice(0, 300);
      return Promise.all(names.map(function (n) { return zipText(entries, n); })).then(function (texts) {
        var blocks = [], truncated = false;
        texts.forEach(function (xml, i) {
          if (!xml) return;
          if (texts.length > 1) blocks.push(b(3, false, "第 " + (i + 1) + " 页", "slide"));
          var doc = xmlOf(xml);
          var ps = doc.getElementsByTagName("a:p");
          for (var pi = 0; pi < ps.length; pi++) {
            var s = txt(ps[pi]).replace(/\s+/g, " ").trim();
            if (!s) continue;
            var lvl = (ps[pi].getAttribute("lvl") || "0") | 0;
            blocks.push(b(0, lvl > 0, s));
            if (blocks.length >= MAX_BLOCKS) { truncated = true; break; }
          }
        });
        if (!blocks.length) throw new Error("幻灯片里没有可读的文字。");
        return { kind: "blocks", blocks: blocks, truncated: truncated, meta: { slides: texts.length } };
      });
    });
  }

  // ---------------------------------------------------------------- pdf ----------
  function rawStringFromBytes(u8) {
    var s = "", step = 32768;
    for (var i = 0; i < u8.length; i += step) {
      s += String.fromCharCode.apply(null, u8.subarray(i, Math.min(i + step, u8.length)));
    }
    return s;
  }

  function inflateU8(u8, start, size) {
    var slice = new Uint8Array(u8.buffer, start, size);
    try {
      var ds = new DecompressionStream("deflate-raw");
      // DecompressionStream needs a stream; do it synchronously-less via Response later.
      return { wait: true, slice: slice };
    } catch (e) {
      return { wait: false, u8: slice };
    }
  }

  function inflateBytes(bytes) {
    var stream = new Blob([bytes]).stream().pipeThrough(new DecompressionStream("deflate-raw"));
    return new Response(stream).arrayBuffer().then(function (x) { return new Uint8Array(x); });
  }

  // Very small PDF structural parser: enough to reach the page content streams and
  // the ToUnicode CMaps of a Word/LibreOffice/LaTeX exported PDF.
  function readPdfObjects(u8) {
    var s = rawStringFromBytes(u8);
    var objs = {};
    var re = /(\d+)\s+(\d+)\s+obj\b/g, m;
    while ((m = re.exec(s))) {
      var num = parseInt(m[1], 10);
      var bodyStart = m.index + m[0].length;
      var end = s.indexOf("endobj", bodyStart);
      if (end < 0) end = s.length;
      var streamIdx = s.indexOf("stream", bodyStart);
      var dict = "", dataStart = -1, dataEnd = -1;
      if (streamIdx >= 0 && streamIdx < end) {
        dict = s.slice(bodyStart, streamIdx);
        dataStart = streamIdx + 6;
        if (s.charCodeAt(dataStart) === 13) dataStart++;
        if (s.charCodeAt(dataStart) === 10) dataStart++;
        dataEnd = s.indexOf("endstream", dataStart);
        if (dataEnd < 0 || dataEnd > end) dataEnd = end;
      } else {
        dict = s.slice(bodyStart, end);
      }
      objs[num] = { dict: dict, start: dataStart, end: dataEnd };
      re.lastIndex = bodyStart;
    }
    return { s: s, objs: objs };
  }

  // /Resources may be a reference OR an inline dictionary with nested dictionaries
  // ("<< /Font << /F1 5 0 R >> >>"), so brace counting, not a flat regex.
  function inlineDict(s, key) {
    var idx = s.indexOf("/" + key);
    if (idx < 0) return "";
    var i = s.indexOf("<<", idx);
    if (i < 0) return "";
    var depth = 0, start = i;
    while (i < s.length) {
      if (s.substr(i, 2) === "<<") { depth++; i += 2; continue; }
      if (s.substr(i, 2) === ">>") { depth--; i += 2; if (depth === 0) return s.slice(start, i); continue; }
      i++;
    }
    return "";
  }

  function resourceDictOf(objs, dict, depth) {
    if (!dict) return "";
    depth = depth || 0;
    var inline = inlineDict(dict, "Resources");
    if (inline) return inline;
    var r = refOf(dict, "Resources");
    if (r >= 0 && objs[r]) return objs[r].dict;
    // a page may inherit everything from its /Pages parent
    if (depth < 4) {
      var p = refOf(dict, "Parent");
      if (p >= 0 && objs[p]) return resourceDictOf(objs, objs[p].dict, depth + 1);
    }
    return "";
  }

  function refOf(dict, key) {
    var m = new RegExp("\\/" + key + "\\s+(\\d+)\\s+\\d+\\s+R").exec(dict);
    return m ? parseInt(m[1], 10) : -1;
  }

  function refListOf(dict, key) {
    var out = [];
    var arr = new RegExp("\\/" + key + "\\s*\\[([^\\]]*)\\]").exec(dict);
    if (arr) {
      var re = /(\d+)\s+\d+\s+R/g, m;
      while ((m = re.exec(arr[1]))) out.push(parseInt(m[1], 10));
      return out;
    }
    var one = refOf(dict, key);
    if (one >= 0) out.push(one);
    return out;
  }

  function streamBytes(u8, obj) {
    if (!obj || obj.start < 0) return Promise.resolve(new Uint8Array(0));
    var size = obj.end - obj.start;
    var bytes = new Uint8Array(u8.buffer, obj.start, size);
    if (/\/FlateDecode/.test(obj.dict)) return inflateBytes(bytes);
    return Promise.resolve(bytes);
  }

  function parseCmap(txt2) {
    var map = {};
    var reChar = /beginbfchar([\s\S]*?)endbfchar/g, m;
    while ((m = reChar.exec(txt2))) {
      var r2 = /<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]*)>/g, x;
      while ((x = r2.exec(m[1]))) map[x[1].toLowerCase()] = hexToStr(x[2]);
    }
    var reRange = /beginbfrange([\s\S]*?)endbfrange/g;
    while ((m = reRange.exec(txt2))) {
      var r3 = /<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>/g, y;
      while ((y = r3.exec(m[1]))) {
        var lo = parseInt(y[1], 16), hi = parseInt(y[2], 16), base = parseInt(y[3], 16);
        for (var c = lo; c <= hi && c - lo < 65536; c++) map[c.toString(16)] = String.fromCharCode(base + (c - lo));
      }
      var r4 = /<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>\s*\[([\s\S]*?)\]/g, z;
      while ((z = r4.exec(m[1]))) {
        var lo2 = parseInt(z[1], 16), parts = z[3].match(/<([0-9A-Fa-f]*)>/g) || [];
        for (var k = 0; k < parts.length; k++) map[(lo2 + k).toString(16)] = hexToStr(parts[k].replace(/[<>]/g, ""));
      }
    }
    return map;
  }

  function hexToStr(h) {
    var out = "", i;
    for (i = 0; i + 3 < h.length; i += 4) out += String.fromCharCode(parseInt(h.substr(i, 4), 16));
    return out;
  }

  function pdfTokenToString(tok, cmap) {
    if (!tok) return "";
    if (tok.charAt(0) === "<") {
      var h = tok.slice(1, -1).replace(/[^0-9A-Fa-f]/g, "");
      if (h.length % 2) h += "0";
      var bytes = [];
      for (var i = 0; i < h.length; i += 2) bytes.push(parseInt(h.substr(i, 2), 16));
      return decodeBytes(bytes, cmap);
    }
    return decodeLiteral(tok, cmap);
  }

  function decodeBytes(bytes, cmap) {
    if (!cmap) {
      var s2 = "";
      for (var j = 0; j < bytes.length; j++) s2 += String.fromCharCode(bytes[j]);
      return s2;
    }
    // ToUnicode keys are hex WITHOUT leading zeros; normalise everything to the
    // width the map actually uses (4 digits for CID fonts, 2 for simple ones).
    var wide = false, key;
    for (var k0 in cmap) { if (k0.length > 2) { wide = true; break; } }
    var out = "", i = 0;
    while (i < bytes.length) {
      if (wide && i + 1 < bytes.length) {
        key = pad4((bytes[i] << 8) | (bytes[i + 1] || 0));
        if (cmap[key] !== undefined) { out += cmap[key]; i += 2; continue; }
      }
      key = pad2(bytes[i]);
      if (cmap[key] !== undefined) { out += cmap[key]; i++; continue; }
      key = pad4(bytes[i]);
      if (cmap[key] !== undefined) { out += cmap[key]; i++; continue; }
      out += String.fromCharCode(bytes[i]); i++;
    }
    return out;
  }

  function pad4(n) { var s3 = n.toString(16); while (s3.length < 4) s3 = "0" + s3; return s3; }
  function pad2(n) { var s4 = n.toString(16); while (s4.length < 2) s4 = "0" + s4; return s4; }

  function decodeLiteral(lit, cmap) {
    var s = lit.slice(1, -1).replace(/\\([nrtbf()\\])/g, function (m2, c) {
      return { n: "\n", r: "\r", t: "\t", b: "\b", f: "\f", "(": "(", ")": ")", "\\": "\\" }[c];
    });
    if (!cmap) return s;
    var bytes = [];
    for (var i = 0; i < s.length; i++) bytes.push(s.charCodeAt(i) & 0xFF);
    if (!bytes.some(function (v) { return v > 0x7F; })) return s;
    return decodeBytes(bytes, cmap);
  }

  function readPdf(file) {
    return file.arrayBuffer().then(function (buf) {
      var u8 = new Uint8Array(buf);
      var parsed = readPdfObjects(u8);
      var objs = parsed.objs;

      // the trailer tells us where /Root is; fall back to scanning for Catalog
      var root = -1;
      var tr = /\/Root\s+(\d+)\s+\d+\s+R/.exec(parsed.s);
      if (tr) root = parseInt(tr[1], 10);
      var pageNums = [];
      if (root >= 0 && objs[root]) {
        var kids = refListOf(objs[root].dict, "Kids");
        kids.forEach(function (k) {
          if (!objs[k]) return;
          if (/\/Type\s*\/Pages/.test(objs[k].dict)) refListOf(objs[k].dict, "Kids").forEach(function (p2) { pageNums.push(p2); });
          else pageNums.push(k);
        });
      }
      if (!pageNums.length) {
        Object.keys(objs).forEach(function (n) {
          if (/\/Type\s*\/Page[^s]/.test(objs[n].dict)) pageNums.push(parseInt(n, 10));
        });
        pageNums.sort(function (a, c) { return a - c; });
      }
      if (!pageNums.length) throw new Error("没有找到 PDF 页面对象。");
      pageNums = pageNums.slice(0, 400);

      var tasks = pageNums.map(function (pn) {
        var dict = objs[pn].dict;
        var resDict = resourceDictOf(objs, dict);
        var fonts = {};
        if (resDict) {
          var fdict = inlineDict(resDict, "Font");
          if (fdict) {
            var fn = /\/([A-Za-z0-9_.#+-]+)\s+(\d+)\s+\d+\s+R/g, fm;
            while ((fm = fn.exec(fdict))) fonts[fm[1]] = parseInt(fm[2], 10);
          } else {
            var fr = refOf(resDict, "Font");
            if (fr >= 0 && objs[fr]) {
              var frx = /\/([A-Za-z0-9_.#+-]+)\s+(\d+)\s+\d+\s+R/g, fmx;
              while ((fmx = frx.exec(objs[fr].dict))) fonts[fmx[1]] = parseInt(fmx[2], 10);
            }
          }
        }
        var contents = refListOf(dict, "Contents");
        return Promise.all(contents.map(function (c) { return streamBytes(u8, objs[c]); })).then(function (parts) {
          return { parts: parts, fonts: fonts };
        });
      });

      return Promise.all(tasks).then(function (pages) {
        // collect /ToUnicode cmaps per font number (cache across pages)
        var cmaps = {};
        var need = [];
        pages.forEach(function (p) {
          Object.keys(p.fonts).forEach(function (name) {
            var fnum = p.fonts[name];
            if (cmaps[fnum] === undefined) {
              cmaps[fnum] = null;
              var fo = objs[fnum];
              if (fo) {
                var uni = refOf(fo.dict, "ToUnicode");
                if (uni >= 0) need.push([fnum, uni]);
              }
            }
          });
        });
        return Promise.all(need.map(function (pair) {
          return streamBytes(u8, objs[pair[1]]).then(function (bytes) {
            cmaps[pair[0]] = parseCmap(rawStringFromBytes(bytes));
          }).catch(function () { cmaps[pair[0]] = null; });
        })).then(function () { return { pages: pages, cmaps: cmaps }; });
      }).then(function (info) {
        var blocks = [], chars = 0, truncated = false;
        var multiPage = info.pages.length > 1;
        info.pages.forEach(function (p, pi) {
          var lines = [];
          p.parts.forEach(function (part) { extractLines(rawStringFromBytes(part), p.fonts, info.cmaps, lines); });
          if (multiPage) {
            blocks.push(b(3, false, "第 " + (pi + 1) + " 页 / 共 " + info.pages.length + " 页", "page"));
          }
          lines.forEach(function (ln) {
            if (!ln.replace(/\s+/g, "")) return;
            blocks.push(b(0, false, ln.replace(/\s+/g, " ").trim()));
            chars += ln.length;
            if (blocks.length >= MAX_BLOCKS || chars >= MAX_CHARS) { truncated = true; }
          });
        });
        if (!blocks.length) throw new Error("这个 PDF 里没找到文字（可能是扫描件图片）。");
        var total = blocks.reduce(function (n, x) { return n + (x.tag ? 0 : x.text.length); }, 0);
        var note = total < 60 ? "提取到的文字很少，可能是扫描版 PDF 或使用了不支持的字体。" : "";
        return { kind: "blocks", blocks: blocks, truncated: truncated, note: note, meta: { pages: info.pages.length } };
      });
    });
  }

  function extractLines(content, fonts, cmaps, lines) {
    var cur = "", cmap = null;
    var reFont = /\/([A-Za-z0-9_.#+-]+)\s+[\d.]+\s+Tf/g;
    var pos = 0;
    // Walk the content and handle the operators we care about.
    var tok = /(?:(\/([A-Za-z0-9_.#+-]+)\s+[\d.]+\s+Tf)|(\((?:\\.|[^\\()])*\))|(<[0-9A-Fa-f\s]*>)|(\[\s*(?:[^\[\]])*\])|(\bT[jJ*'"\d]*)|([\d.\-\s]+(?:Td|TD|Tm|TL))|(ET|BT))/g;
    var m;
    while ((m = tok.exec(content))) {
      if (m[1]) cmap = cmaps[fonts[m[2]]] || null;
      else if (m[3]) cur += pdfTokenToString(m[3], cmap);
      else if (m[4]) cur += pdfTokenToString(m[4].replace(/\s+/g, ""), cmap);
      else if (m[5]) {
        if (/^T[jJ'"]$/.test(m[5])) {
          if (cur.trim()) { lines.push(cur); cur = ""; }
        }
      } else if (m[6]) {
        if (cur.trim()) { lines.push(cur); cur = ""; }
      } else if (m[7] === "ET") {
        if (cur.trim()) { lines.push(cur); cur = ""; }
      }
      pos = tok.lastIndex;
    }
    if (cur.trim()) lines.push(cur);
  }

  // --------------------------------------------------------------- csv -----------
  function splitCsvLine(line, d) {
    var out = [], cur = "", q = false;
    for (var i = 0; i < line.length; i++) {
      var c = line[i];
      if (q) {
        if (c === '"') { if (line[i + 1] === '"') { cur += '"'; i++; } else q = false; }
        else cur += c;
      } else if (c === '"') q = true;
      else if (c === d) { out.push(cur); cur = ""; }
      else cur += c;
    }
    out.push(cur);
    return out;
  }

  function readDelimited(text, ext, forced) {
    var line = text.split(/\r?\n/)[0] || "";
    var delim = forced;
    if (!delim) {
      var cands = [",", "\t", ";", "|"];
      var best = ",", bestN = -1;
      cands.forEach(function (c) {
        var n = line.split(c).length - 1;
        if (n > bestN) { bestN = n; best = c; }
      });
      delim = best;
    }
    var lines = text.split(/\r?\n/);
    var blocks = [], truncated = false;
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].replace(/\s/g, "") === "" && blocks.length && i > lines.length - 5) continue;
      var cells = splitCsvLine(lines[i], delim).map(function (s) { return s.trim(); });
      var row = cells.join("  |  ").replace(/\s+$/, "");
      blocks.push(b(i === 0 ? 4 : 0, false, row));
      if (blocks.length >= MAX_BLOCKS) { truncated = true; break; }
    }
    return { kind: "blocks", blocks: blocks, truncated: truncated, meta: { rows: lines.length } };
  }

  function readPlain(text) {
    var lines = text.split(/\r?\n/), blocks = [], truncated = false, blank = 0;
    for (var i = 0; i < lines.length; i++) {
      var s = lines[i].replace(/\s+$/, "");
      if (!s.trim()) { if (++blank > 2) continue; blocks.push(b(0, false, "")); continue; }
      blank = 0;
      var level = 0;
      var h = /^(#{1,6})\s+/.exec(s);
      if (h) { level = h[1].length; s = s.replace(/^#+\s+/, ""); }
      blocks.push(b(level, /^([-*+]\s|\d+[.)]\s|[-–—]\s)/.test(s), s.replace(/^([-*+]\s|\d+[.)]\s)/, "")));
      if (blocks.length >= MAX_BLOCKS) { truncated = true; break; }
    }
    while (blocks.length && !blocks[blocks.length - 1].text) blocks.pop();
    return { kind: "blocks", blocks: blocks, truncated: truncated };
  }

  function readAsDataUrl(file) {
    return new Promise(function (res, rej) {
      var fr = new FileReader();
      fr.onload = function () { res({ kind: "image", dataUrl: fr.result, blocks: [] }); };
      fr.onerror = function () { rej(new Error("图片读取失败。")); };
      fr.readAsDataURL(file);
    });
  }

  // ---------------------------------------------------------------- api ----------
  function read(file) {
    var ext = extOf(file.name);
    var base = { name: file.name, ext: ext, blocks: [], text: "", dataUrl: "", meta: {}, truncated: false, note: "" };

    if (ext === "doc" || ext === "ppt" || ext === "xls") {
      return Promise.reject(new Error("." + ext + " 是老版二进制格式，请先用 Office/WPS 另存为 ." +
        (ext === "doc" ? "docx" : ext === "ppt" ? "pptx" : "xlsx") + " 再导入。"));
    }
    if (IMAGE_EXTS.indexOf(ext) >= 0) {
      return readAsDataUrl(file).then(function (r) { return Object.assign(base, r); });
    }
    if (MEDIA_EXTS.indexOf(ext) >= 0) {
      var kind2 = ["mp3", "wav", "m4a", "ogg"].indexOf(ext) >= 0 ? "audio" : "video";
      return readAsDataUrl(file).then(function (r) { return Object.assign(base, r, { kind: kind2 }); });
    }
    if (ext === "docx") return readDocx(file).then(function (r) { return Object.assign(base, r); });
    if (ext === "xlsx" || ext === "xlsm") return readXlsx(file).then(function (r) { return Object.assign(base, r); });
    if (ext === "pptx") return readPptx(file).then(function (r) { return Object.assign(base, r); });
    if (ext === "pdf") return readPdf(file).then(function (r) { return Object.assign(base, r); });

    return readText(file).then(function (text) {
      if (ext === "csv") return Object.assign(base, readDelimited(text, ext, ","));
      if (ext === "tsv") return Object.assign(base, readDelimited(text, ext, "\t"));
      if (TEXT_EXTS.indexOf(ext) >= 0) {
        if (ext === "htm" || ext === "html" || ext === "xml") {
          text = text.replace(/<script[\s\S]*?<\/script>/gi, " ").replace(/<style[\s\S]*?<\/style>/gi, " ")
            .replace(/<[^>]+>/g, "\n").replace(/&nbsp;/g, " ").replace(/&amp;/g, "&").replace(/&lt;/g, "<").replace(/&gt;/g, ">");
        }
        return Object.assign(base, readPlain(text), { text: text.slice(0, 4000) });
      }
      // unknown extension: try text if it looks printable, else read the raw bytes
      var probe = new Uint8Array(file.size ? 512 : 0);
      var bin = false;
      for (var i = 0; i < text.length; i++) { if (text.charCodeAt(i) === 0) { bin = true; break; } }
      if (bin) throw new Error("暂不支持这个文件类型（." + (ext || "未知") + "）。");
      return Object.assign(base, readPlain(text));
    });
  }

  global.HTMLBGDocs = { read: read, supported: supported, extOf: extOf, MAX_BLOCKS: MAX_BLOCKS };
})(window);
