# -*- coding: utf-8 -*-
"""Build multi-format test fixtures for HTMLBG (docx/xlsx/pptx/pdf/csv/txt).

Everything is written by hand (no third-party libs), so the fixtures double as a
check that our hand-written parsers handle the real Office/PDF structures.
"""
import zipfile, os, zlib, io

HERE = os.path.dirname(os.path.abspath(__file__))

# ----------------------------------------------------------------- docx -------
DOCX_XML = u"""<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
 <w:body>
  <w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>第一章 二次函数</w:t></w:r></w:p>
  <w:p><w:r><w:t>设 f(x)=x^2+2x，求 f(x) 的极小值。</w:t></w:r></w:p>
  <w:p><w:pPr><w:pStyle w:val="Heading2"/></w:pPr><w:r><w:t>解：配方是最直接的办法</w:t></w:r></w:p>
  <w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr></w:pPr><w:r><w:t>f(x) = (x+1)^2 - 1</w:t></w:r></w:p>
  <w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr></w:pPr><w:r><w:t>所以极小值为 -1，取到位置 x = -1。</w:t></w:r></w:p>
  <w:p/>
  <w:p><w:r><w:t>定理：</w:t></w:r><w:r><w:t>若 a&gt;0，则 ax^2+bx+c 的最小值为 c-b^2/(4a)。</w:t></w:r></w:p>
  <w:p><w:pPr><w:outlineLvl w:val="2"/></w:pPr><w:r><w:t>结论与结论推广</w:t></w:r></w:p>
  <w:p><w:r><w:t>超链接里的文字</w:t></w:r></w:p>
  <w:p><w:r><w:t>引号与反斜杠：\" \\ 制表符\t都在这里。</w:t></w:r></w:p>
 </w:body>
</w:document>"""

# ----------------------------------------------------------------- xlsx -------
WB = u"""<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"
 xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
 <sheets><sheet name="成绩单" sheetId="1" r:id="rId1"/><sheet name="汇总" sheetId="2" r:id="rId2"/></sheets>
</workbook>"""
WB_RELS = u"""<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
 <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
 <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet2.xml"/>
 <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings" Target="sharedStrings.xml"/>
</Relationships>"""
SS = u"""<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="6" uniqueCount="6">
 <si><t>姓名</t></si><si><t>语文</t></si><si><t>数学</t></si>
 <si><t>张三</t></si><si><t>李四</t></si><si><t>王五</t></si>
</sst>"""
SHEET1 = u"""<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>
 <row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c><c r="C1" t="s"><v>2</v></c></row>
 <row r="2"><c r="A2" t="s"><v>3</v></c><c r="B2"><v>92</v></c><c r="C2"><v>88</v></c></row>
 <row r="3"><c r="A3" t="s"><v>4</v></c><c r="B3"><v>77</v></c><c r="C3"><v>95</v></c></row>
 <row r="4"><c r="A4" t="s"><v>5</v></c><c r="B4"><v>84</v></c><c r="C4"><v>91</v></c></row>
 <row r="5"><c r="A5" t="inlineStr"><is><t>合计（内联字符串）</t></is></c><c r="B5"><v>253</v></c><c r="C5"><v>274</v></c></row>
</sheetData></worksheet>"""
SHEET2 = u"""<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>
 <row r="1"><c r="A1" t="s"><v>1</v></c><c r="B1" t="s"><v>2</v></c></row>
 <row r="2"><c r="A2"><v>253</v></c><c r="B2"><v>274</v></c></row>
</sheetData></worksheet>"""

# ----------------------------------------------------------------- pptx -------
def slide(title, bullets):
    paras = u'<a:p><a:r><a:rPr lang="zh-CN"/><a:t>%s</a:t></a:r></a:p>' % title
    for b in bullets:
        paras += u'<a:p lvl="1"><a:r><a:t>%s</a:t></a:r></a:p>' % b
    return (u'<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
            u'<p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" '
            u'xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:cSld><p:spTree>'
            + paras +
            u'</p:spTree></p:cSld></p:sld>')

SLIDES = [
    slide(u"二次函数复习", [u"定义与图像", u"顶点式与交点式", u"最值问题"]),
    slide(u"三角函数", [u"诱导公式", u"和差化积", u"解三角形"]),
    slide(u"概率统计", [u"古典概型", u"分布列与期望", u"正态分布"]),
]

# ------------------------------------------------------------------ csv -------
CSV = u"姓名,语文,数学,备注\r\n张三,92,88,\"含,逗号的内容\"\r\n李四,77,95,\"带\"\"引号\"\"的内容\"\r\n王五,84,91,正常\r\n"

# ------------------------------------------------------------------ txt -------
TXT = u"# 高三数学冲刺计划\n\n- 每天一套选填+一道大题\n- 错题当天整理\n\n## 时间安排\n\n1. 早读 30 分钟公式\n2. 晚自习 90 分钟套卷\n\n距离只有一条语录：坚持住。\n"


def build_docx(path):
    with zipfile.ZipFile(path, 'w', zipfile.ZIP_DEFLATED) as z:
        z.writestr('[Content_Types].xml', u'<?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"/>')
        z.writestr('_rels/.rels', u'<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"/>')
        z.writestr('word/document.xml', DOCX_XML.encode('utf-8'))


def build_xlsx(path):
    with zipfile.ZipFile(path, 'w', zipfile.ZIP_DEFLATED) as z:
        z.writestr('[Content_Types].xml', u'<?xml version="1.0" encoding="UTF-8"?><Types/>')
        z.writestr('_rels/.rels', u'<?xml version="1.0" encoding="UTF-8"?><Relationships/>')
        z.writestr('xl/workbook.xml', WB.encode('utf-8'))
        z.writestr('xl/_rels/workbook.xml.rels', WB_RELS.encode('utf-8'))
        z.writestr('xl/sharedStrings.xml', SS.encode('utf-8'))
        z.writestr('xl/worksheets/sheet1.xml', SHEET1.encode('utf-8'))
        z.writestr('xl/worksheets/sheet2.xml', SHEET2.encode('utf-8'))


def build_pptx(path):
    with zipfile.ZipFile(path, 'w', zipfile.ZIP_DEFLATED) as z:
        z.writestr('[Content_Types].xml', u'<?xml version="1.0" encoding="UTF-8"?><Types/>')
        z.writestr('_rels/.rels', u'<?xml version="1.0" encoding="UTF-8"?><Relationships/>')
        z.writestr('ppt/presentation.xml', u'<?xml version="1.0" encoding="UTF-8"?><p:presentation/>')
        for i, s in enumerate(SLIDES, 1):
            z.writestr('ppt/slides/slide%d.xml' % i, s.encode('utf-8'))


def build_pdf(path):
    """A small hand-made PDF with TWO fonts:
       F1 -> WinAnsi literal strings (ASCII only)
       F2 -> Identity-H with a ToUnicode CMap (2-byte CID codes for Chinese)
       This is exactly the shape Word/LibreOffice exports use."""
    lines = []
    lines.append((1, [(u"Gaokao Revision Notes", False)]))
    lines.append((1, [(u"Chapter 1 Quadratic function", False)]))
    lines.append((2, [u"\u7b2c\u4e00\u7ae0 \u4e8c\u6b21\u51fd\u6570"]))
    lines.append((2, [u"f(x) = (x+1)^2 - 1\uff0c\u6781\u5c0f\u503c\u4e3a -1\u3002"]))
    lines.append((2, [u"\u5b9a\u7406\uff1a\u82e5 a>0\uff0c\u5219 ax^2+bx+c \u7684\u6700\u5c0f\u503c\u4e3a c-b^2/(4a)\u3002"]))
    lines.append((1, [(u"End of page one", False)]))

    # content stream
    cs = u"BT\n"
    y = 720
    for font, chunks in lines:
        cs += u"/F%d 14 Tf\n1 0 0 1 72 %d Tm\n" % (font, y)
        for c in chunks:
            if isinstance(c, tuple):  # (ascii text, ignored)
                cs += u"(%s) Tj\n" % c[0]
            else:
                # map every char through our own CID table
                hexs = "".join("%04X" % cid_of(ch) for ch in c)
                cs += u"<%s> Tj\n" % hexs
        y -= 22
    cs += u"ET\n"
    cs_bytes = cs.encode('latin-1')
    stream = cs_bytes

    # ToUnicode CMap for F2
    cmap = u"/CIDInit /ProcSet findresource begin\n12 dict begin\nbegincmap\n"
    cmap += u"/CMapName /A-0 def\n/CMapType 2 def\n1 begincodespacerange\n<0000> <FFFF>\nendcodespacerange\n"
    cmap += u"%d beginbfchar\n" % len(CID2CH)
    for ch, cid in sorted(CID2CH.items(), key=lambda kv: kv[1]):
        cmap += u"<%04X> <%04X>\n" % (cid, ord(ch))
    cmap += u"endbfchar\nendcmap\nCMapName currentdict /CMap defineresource pop\nend\nend\n"
    cmap_bytes = cmap.encode('latin-1')

    objs = {}
    objs[1] = b"<< /Type /Catalog /Pages 2 0 R >>"
    objs[2] = b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>"
    objs[3] = (b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] "
               b"/Resources << /Font << /F1 5 0 R /F2 6 0 R >> >> /Contents 4 0 R >>")
    objs[4] = (b"<< /Length %d >>\nstream\n" % len(stream)) + stream + b"\nendstream"
    objs[5] = b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"
    objs[6] = (b"<< /Type /Font /Subtype /Type0 /BaseFont /STSong-Light "
               b"/Encoding /Identity-H /DescendantFonts [7 0 R] /ToUnicode 8 0 R >>")
    objs[7] = b"<< /Type /Font /Subtype /CIDFontType0 /BaseFont /STSong-Light /CIDSystemInfo << /Registry (Adobe) /Ordering (GB1) /Supplement 2 >> >>"
    objs[8] = (b"<< /Length %d >>\nstream\n" % len(cmap_bytes)) + cmap_bytes + b"\nendstream"

    out = bytearray(b"%PDF-1.4\n")
    offsets = {}
    for num in sorted(objs):
        offsets[num] = len(out)
        out += b"%d 0 obj\n" % num + objs[num] + b"\nendobj\n"
    xref = len(out)
    out += b"xref\n0 %d\n" % (max(objs) + 1)
    out += b"0000000000 65535 f \n"
    for num in sorted(objs):
        out += b"%010d 00000 n \n" % offsets[num]
    out += b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (max(objs) + 1, xref)
    open(path, 'wb').write(bytes(out))


CID2CH = {}


def cid_of(ch):
    """stable CID per character, starting at 0x0100"""
    if ch not in CID2CH:
        CID2CH[ch] = 0x0100 + len(CID2CH)
    return CID2CH[ch]


if __name__ == '__main__':
    build_docx(os.path.join(HERE, 'test_sample.docx'))
    build_xlsx(os.path.join(HERE, 'test_sample.xlsx'))
    build_pptx(os.path.join(HERE, 'test_sample.pptx'))
    build_pdf(os.path.join(HERE, 'test_sample.pdf'))
    io.open(os.path.join(HERE, 'test_sample.csv'), 'w', encoding='utf-8-sig', newline='').write(CSV)
    io.open(os.path.join(HERE, 'test_sample.txt'), 'w', encoding='utf-8-sig', newline='').write(TXT)
    print('fixtures written')
