#!/usr/bin/env bash
# Build one test file for a rating-flow run, on the runner, from nothing an app repo owns.
# usage: make-fixture.sh <kind> <out-dir>       kinds: mbox gpx xlsx stl zip m4a pdfpin
set -euo pipefail
kind="${1:?kind}"; out="${2:?out dir}"; mkdir -p "$out"

case "$kind" in
  mbox)
    python3 - "$out/verify-inbox.mbox" <<'PY'
import sys
msgs = [
    ("alice@example.test", "Bob Example <bob@example.test>", "Quarterly numbers", "Mon, 8 Sep 2026 09:15:00 +0000",
     "The quarterly numbers are attached in the sheet we discussed.\nAlice\n"),
    ("bob@example.test", "Alice Example <alice@example.test>", "Re: Quarterly numbers", "Mon, 8 Sep 2026 11:02:00 +0000",
     "Got them, thanks. I will read through this afternoon.\nBob\n"),
    ("carol@example.test", "Alice Example <alice@example.test>", "Team offsite", "Tue, 9 Sep 2026 08:40:00 +0000",
     "Sending the offsite plan so everyone has the dates.\nCarol\n"),
]
out = []
for frm, to, subj, date, body in msgs:
    out.append(f"From {frm} {date[:-6]}\nFrom: {frm}\nTo: {to}\nSubject: {subj}\nDate: {date}\n"
               f"Message-ID: <{abs(hash(subj))}@example.test>\nContent-Type: text/plain; charset=utf-8\n\n{body}\n")
open(sys.argv[1], "w").write("".join(out))
PY
    ;;
  gpx)
    python3 - "$out/ridge-walk-real.gpx" <<'PY'
import sys, math, datetime
t0 = datetime.datetime(2026, 6, 14, 7, 30, 0)
pts = []
for i in range(240):
    lat = 47.3769 + 0.0009 * i * math.cos(i / 40.0)
    lon = 8.5417 + 0.0011 * i
    ele = 410 + 80 * math.sin(i / 30.0)
    t = (t0 + datetime.timedelta(seconds=15 * i)).strftime("%Y-%m-%dT%H:%M:%SZ")
    pts.append(f'<trkpt lat="{lat:.6f}" lon="{lon:.6f}"><ele>{ele:.1f}</ele><time>{t}</time></trkpt>')
open(sys.argv[1], "w").write(
    '<?xml version="1.0" encoding="UTF-8"?>\n<gpx version="1.1" creator="rating-verify" '
    'xmlns="http://www.topografix.com/GPX/1/1"><metadata><name>Ridge walk</name></metadata>'
    '<trk><name>Ridge walk</name><trkseg>' + "".join(pts) + "</trkseg></trk></gpx>\n")
PY
    ;;
  xlsx)
    python3 - "$out/budget-real.xlsx" <<'PY'
import sys, zipfile
rows = [["Region", "Revenue", "Cost", "Margin"], ["North", 128450, 74300, 54150], ["South", 98200, 61050, 37150],
        ["East", 143900, 80110, 63790], ["West", 87600, 52900, 34700], ["Total", 458150, 268360, 189790]]
strings, cols, sheet = [], "ABCD", []
def sidx(s):
    if s not in strings: strings.append(s)
    return strings.index(s)
for r, row in enumerate(rows, 1):
    cells = []
    for c, v in enumerate(row):
        ref = f"{cols[c]}{r}"
        cells.append(f'<c r="{ref}" t="s"><v>{sidx(v)}</v></c>' if isinstance(v, str) else f'<c r="{ref}"><v>{v}</v></c>')
    sheet.append(f'<row r="{r}">{"".join(cells)}</row>')
NS = 'xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"'
RNS = 'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"'
files = {
 "[Content_Types].xml": '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/></Types>',
 "_rels/.rels": '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>',
 "xl/workbook.xml": f'<?xml version="1.0" encoding="UTF-8" standalone="yes"?><workbook {NS} {RNS}><sheets><sheet name="Q3 Budget" sheetId="1" r:id="rId1"/></sheets></workbook>',
 "xl/_rels/workbook.xml.rels": '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings" Target="sharedStrings.xml"/></Relationships>',
 "xl/worksheets/sheet1.xml": f'<?xml version="1.0" encoding="UTF-8" standalone="yes"?><worksheet {NS}><sheetData>{"".join(sheet)}</sheetData></worksheet>',
}
files["xl/sharedStrings.xml"] = (f'<?xml version="1.0" encoding="UTF-8" standalone="yes"?><sst {NS} count="{len(strings)}" '
                                 f'uniqueCount="{len(strings)}">' + "".join(f"<si><t>{s}</t></si>" for s in strings) + "</sst>")
with zipfile.ZipFile(sys.argv[1], "w", zipfile.ZIP_DEFLATED) as z:
    for name in ["[Content_Types].xml", "_rels/.rels", "xl/workbook.xml", "xl/_rels/workbook.xml.rels",
                 "xl/worksheets/sheet1.xml", "xl/sharedStrings.xml"]:
        z.writestr(name, files[name])
PY
    ;;
  stl)
    python3 - "$out/bracket-real.stl" <<'PY'
import sys, struct
# A closed tetrahedron: a real mesh with normals, small enough to load anywhere.
v = [(0, 0, 0), (40, 0, 0), (20, 35, 0), (20, 12, 30)]
tris = [(0, 2, 1), (0, 1, 3), (1, 2, 3), (2, 0, 3)]
def normal(a, b, c):
    u = [b[i] - a[i] for i in range(3)]; w = [c[i] - a[i] for i in range(3)]
    n = [u[1]*w[2]-u[2]*w[1], u[2]*w[0]-u[0]*w[2], u[0]*w[1]-u[1]*w[0]]
    m = sum(x*x for x in n) ** 0.5 or 1.0
    return [x / m for x in n]
with open(sys.argv[1], "wb") as f:
    f.write(b"rating-verify bracket".ljust(80, b" "))
    f.write(struct.pack("<I", len(tris)))
    for a, b, c in tris:
        f.write(struct.pack("<3f", *normal(v[a], v[b], v[c])))
        for idx in (a, b, c):
            f.write(struct.pack("<3f", *v[idx]))
        f.write(struct.pack("<H", 0))
PY
    ;;
  zip)
    python3 - "$out/damaged-archive.zip" <<'PY'
import sys, zipfile, io
buf = io.BytesIO()
with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
    for i in (1, 2, 3):
        z.writestr(f"report-{i}.txt", (f"Report {i}\n" + "line of recovered text\n" * 200))
data = buf.getvalue()
# Cut the central directory off: the entries stay complete, the index is gone — a damaged archive
# a scan can still recover, which is what this app is for.
cut = data.rfind(b"PK\x01\x02")
open(sys.argv[1], "wb").write(data[:cut])
PY
    ;;
  m4a)
    say -o "$out/.chapter.aiff" "Chapter one. The lighthouse keeper climbed the stairs at dusk and lit the lamp."
    afconvert -f m4af -d aac "$out/.chapter.aiff" "$out/chapter-one.m4a"
    rm -f "$out/.chapter.aiff"
    ;;
  pdfpin)
    python3 - "$out/.plain.pdf" <<'PY'
import sys
# A minimal one-page PDF, written by hand so nothing has to be installed for it.
objs = [
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>",
    None,
    "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
]
stream = b"BT /F1 18 Tf 72 760 Td (Quarterly report) Tj 0 -28 Td (Locked with a PIN for the recovery check.) Tj ET"
out, offsets = bytearray(b"%PDF-1.4\n"), []
for i, o in enumerate(objs, 1):
    offsets.append(len(out))
    if o is None:
        out += f"{i} 0 obj\n<< /Length {len(stream)} >>\nstream\n".encode() + stream + b"\nendstream\nendobj\n"
    else:
        out += f"{i} 0 obj\n{o}\nendobj\n".encode()
xref = len(out)
out += f"xref\n0 {len(objs)+1}\n0000000000 65535 f \n".encode()
for off in offsets:
    out += f"{off:010d} 00000 n \n".encode()
out += f"trailer\n<< /Size {len(objs)+1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode()
open(sys.argv[1], "wb").write(bytes(out))
PY
    command -v qpdf >/dev/null || brew install qpdf >/dev/null
    qpdf --encrypt 1234 "owner-$RANDOM" 256 -- "$out/.plain.pdf" "$out/pin-real.pdf"
    rm -f "$out/.plain.pdf"
    ;;
  *) echo "unknown fixture kind: $kind" >&2; exit 1 ;;
esac
ls -l "$out" | tail -n +2 | awk '{print $5, $9}'
