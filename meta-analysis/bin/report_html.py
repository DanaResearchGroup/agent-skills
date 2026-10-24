#!/usr/bin/env python3
"""Render meta-analysis Markdown into one self-contained, interactive HTML page.

Usage:
    report_html.py OUT.html FIRST.md [MORE.md ...] [--chart TRAJECTORY.json]

The first file is the reader-facing summary; later files follow as appendices.
With --chart, the first image in the first file is replaced by an interactive
SVG trajectory chart drawn from the same JSON that trajectory.py renders to
PNG: hovering (or focusing) a point shows its time, source, score, label and
detail, and a data table sits under the chart. Other images are embedded as
base64. ==highlight== renders as <mark>; a wholly highlighted paragraph as a
key-finding box. Light and dark modes follow the reader's system setting.
Standard library only.
"""
import argparse
import base64
import html
import json
import mimetypes
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from mdlite import inline_html, is_highlight, parse  # noqa: E402


def para(text, tag="p"):
    inner = is_highlight(text)
    if inner:
        return f'<div class="key">{inline_html(inner)}</div>'
    return f"<{tag}>{inline_html(text)}</{tag}>"


def render(md_path, chart_json, appendix):
    out, stack, chart_used = [], [], chart_json is None

    def close(depth=0):
        # each open list level has one open <li>; nested lists live inside it
        while len(stack) > depth:
            out.append(f"</li></{stack.pop()}>")

    for b in parse(md_path.read_text(encoding="utf-8")):
        if b[0] != "li":
            close()
        if b[0] == "h":
            text = inline_html(b[2])
            if b[1] == 1:
                out.append(f'<h1 class="{"appendix" if appendix else "title"}">'
                           f'{"Appendix: " if appendix else ""}{text}</h1>')
            else:
                out.append(f"<h{b[1]}>{text}</h{b[1]}>")
        elif b[0] == "p":
            out.append(para(b[1]))
        elif b[0] == "li":
            _, depth, kind, text = b
            close(depth)
            if len(stack) == depth and stack[-1] != kind:
                close(depth - 1)
            if len(stack) == depth:
                out.append("</li>")
            while len(stack) < depth:
                stack.append(kind); out.append(f"<{kind}>")
            out.append(f"<li>{inline_html(text)}")
        elif b[0] == "table":
            rows = b[1]
            head = "".join(f"<th>{inline_html(c)}</th>" for c in rows[0])
            body = "".join("<tr>" + "".join(f"<td>{inline_html(c)}</td>" for c in r) + "</tr>" for r in rows[1:])
            out.append(f'<div class="tw"><table><thead><tr>{head}</tr></thead><tbody>{body}</tbody></table></div>')
        elif b[0] == "img":
            if not chart_used:
                out.append('<figure id="chart"></figure>')
                chart_used = True
                continue
            p = (md_path.parent / b[2]).resolve()
            if p.exists():
                mime = mimetypes.guess_type(p.name)[0] or "image/png"
                data = base64.b64encode(p.read_bytes()).decode()
                out.append(f'<figure><img alt="{html.escape(b[1])}" src="data:{mime};base64,{data}"></figure>')
        elif b[0] == "quote":
            out.append(f"<blockquote>{para(b[1], 'span')}</blockquote>")
        elif b[0] == "code":
            out.append(f"<pre><code>{html.escape(b[1])}</code></pre>")
    close()
    return "\n".join(out)


CSS = """
:root{--bg:#fcfcfb;--ink:#1f1f1e;--muted:#6b6a64;--grid:#e6e5e0;--line:#b9b8b0;--card:#f3f2ee;--hl:#fff2a8;--hlb:#b8a64a}
@media (prefers-color-scheme:dark){:root{--bg:#1a1a19;--ink:#f0efec;--muted:#a9a89f;--grid:#33332f;--line:#6b6a64;--card:#252523;--hl:#5c5214;--hlb:#a8963a}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:16px/1.6 Georgia,'DejaVu Serif',serif}
main{max-width:980px;margin:0 auto;padding:32px 24px 80px}
h1,h2,h3,h4{font-family:system-ui,'DejaVu Sans',sans-serif;line-height:1.25}
h1.title{font-size:30px;margin:0 0 8px}h1.appendix{font-size:24px;margin-top:64px;padding-top:24px;border-top:2px solid var(--grid)}
h2{font-size:21px;margin-top:36px}h3{font-size:17px}
code{font-family:'DejaVu Sans Mono',monospace;font-size:.86em;background:var(--card);padding:1px 4px;border-radius:3px}
pre{background:var(--card);padding:12px;overflow:auto;border-radius:6px}pre code{background:none;padding:0}
mark{background:var(--hl);color:inherit;padding:1px 2px;border-radius:2px}
.key{background:var(--hl);border-left:4px solid var(--hlb);padding:10px 14px;border-radius:4px;margin:12px 0}
blockquote{margin:12px 0;padding:4px 16px;border-left:3px solid var(--grid);color:var(--muted);font-style:italic}
.tw{overflow-x:auto}table{border-collapse:collapse;width:100%;font-size:14px;margin:12px 0}
th,td{text-align:left;vertical-align:top;padding:6px 8px;border-bottom:1px solid var(--grid)}th{font-family:system-ui,sans-serif}
figure{margin:20px 0}figure img{max-width:100%}
#chart>svg{width:100%;height:auto;display:block}
.legend svg,#tip svg{width:14px;height:14px;flex:none}
#chart .pt{cursor:pointer;outline:none}#chart .pt:hover use,#chart .pt:focus use{stroke:var(--ink)}
#tip{position:fixed;pointer-events:none;max-width:340px;background:var(--card);color:var(--ink);border:1px solid var(--grid);
 border-radius:6px;padding:8px 10px;font:13px/1.45 system-ui,sans-serif;box-shadow:0 4px 14px rgba(0,0,0,.18);display:none;z-index:9}
#tip .h{display:flex;gap:6px;align-items:center;font-weight:600}#tip .m{color:var(--muted);font-size:12px}
.legend{display:flex;flex-wrap:wrap;gap:6px 18px;font:13px system-ui,sans-serif;color:var(--muted);margin-top:6px}
.legend span{display:inline-flex;align-items:center;gap:6px}

.keys{columns:2;column-gap:28px;font:13px/1.6 system-ui,sans-serif;margin-top:10px}.keys b{display:inline-block;width:1.2em}
details{margin-top:8px;font:13px system-ui,sans-serif}summary{cursor:pointer;color:var(--muted)}
"""

JS = r"""
(function(){
const D=JSON.parse(document.getElementById('trajdata').textContent);const fig=document.getElementById('chart');if(!fig)return;
const W=960,H=430,L=58,R=16,T=34,B=46,ev=D.events,n=ev.length;
const x=i=>L+(i+0.5)*(W-L-R)/n, y=v=>T+(1-v/10.2)*(H-T-B);
const shapes={o:'<circle r="5.5"/>',s:'<rect x="-5" y="-5" width="10" height="10"/>',D:'<rect x="-5" y="-5" width="10" height="10" transform="rotate(45)"/>','^':'<path d="M0,-6.5L6,4.5L-6,4.5Z"/>'};
let s=`<svg viewBox="0 0 ${W} ${H}" role="img" aria-label="${esc(D.title)}"><defs>`;
for(const [k,v] of Object.entries(D.sources))s+=`<g id="m-${k}" fill="${v.color}" stroke="var(--bg)" stroke-width="2">${shapes[v.marker]||shapes.o}</g>`;
s+=`</defs><text x="${L}" y="18" font-size="15" font-family="system-ui,sans-serif" fill="var(--ink)">${esc(D.title)}</text>`;
for(let v=0;v<=10;v+=2)s+=`<line x1="${L}" x2="${W-R}" y1="${y(v)}" y2="${y(v)}" stroke="var(--grid)"/><text x="${L-8}" y="${y(v)+4}" text-anchor="end" font-size="11" fill="var(--muted)" font-family="system-ui">${v}</text>`;
for(const m of D.markers||[]){const xm=(x(m.after-1)+x(m.after))/2,dash=m.style==='dashed';
 s+=`<line x1="${xm}" x2="${xm}" y1="${T}" y2="${H-B}" stroke="var(--muted)" stroke-dasharray="${dash?'4 4':'1 3'}"/><text x="${xm+4}" y="${dash?T+10:H-B-6}" font-size="10" fill="var(--muted)" font-family="system-ui">${esc(m.label)}</text>`;}
let p='';ev.forEach((e,i)=>{p+=(i?`H${x(i)}V${y(e.depth)}`:`M${x(0)},${y(e.depth)}`)});p+=`H${x(n-1)+8}`;
s+=`<path d="${p}" fill="none" stroke="var(--line)" stroke-width="2"/>`;
let k=0;ev.forEach((e,i)=>{s+=`<text x="${x(i)}" y="${H-B+16}" text-anchor="middle" font-size="10" fill="var(--muted)" font-family="system-ui">${i+1}</text>`;
 if(e.key){s+=`<text x="${x(i)}" y="${y(e.depth)-11}" text-anchor="middle" font-size="11" font-weight="700" fill="var(--ink)" font-family="system-ui">${String.fromCharCode(65+k++)}</text>`;}
 s+=`<g class="pt" tabindex="0" data-i="${i}" transform="translate(${x(i)},${y(e.depth)})"><circle r="12" fill="transparent"/><use href="#m-${e.source}"/></g>`;});
s+=`<text x="${(L+W-R)/2}" y="${H-6}" text-anchor="middle" font-size="12" fill="var(--muted)" font-family="system-ui">Interaction (chronological) — hover or tab to a point for details</text>`;
s+=`<text transform="translate(16,${(T+H-B)/2}) rotate(-90)" text-anchor="middle" font-size="12" fill="var(--muted)" font-family="system-ui">${esc((D.y_label||'Depth (judged, 0–10)').replace(/\n/g,' '))}</text></svg>`;
let lg='<div class="legend">';for(const [k2,v] of Object.entries(D.sources))lg+=`<span><svg width="14" height="14" viewBox="-8 -8 16 16"><use href="#m-${k2}"/></svg>${esc(v.name)}</span>`;lg+='</div>';
let ky='<div class="keys">';let kk=0;ev.forEach((e,i)=>{if(e.key)ky+=`<div><b>${String.fromCharCode(65+kk++)}</b> [${i+1}] ${esc(e.label)}</div>`});ky+='</div>';
let tb='<details><summary>Data table</summary><div class="tw"><table><thead><tr><th>#</th><th>Time</th><th>Source</th><th>Depth</th><th>Event</th><th>Detail</th></tr></thead><tbody>';
ev.forEach((e,i)=>tb+=`<tr><td>${i+1}</td><td>${esc(e.time)}</td><td>${esc(D.sources[e.source].name)}</td><td>${e.depth}</td><td>${esc(e.label)}</td><td>${esc(e.detail||'')}</td></tr>`);
fig.innerHTML=s+lg+ky+tb+'</tbody></table></div></details>';
const tip=document.createElement('div');tip.id='tip';document.body.appendChild(tip);
function show(g,cx,cy){const e=ev[+g.dataset.i],src=D.sources[e.source];
 tip.innerHTML=`<div class="h"><svg width="12" height="12" viewBox="-8 -8 16 16"><use href="#m-${e.source}"/></svg>#${+g.dataset.i+1} · ${esc(e.label)}</div><div class="m">${esc(e.time)} · ${esc(src.name)} · depth ${e.depth}</div>${e.detail?`<div>${esc(e.detail)}</div>`:''}`;
 tip.style.display='block';const r=tip.getBoundingClientRect();let lx=cx+14,ly=cy+14;
 if(lx+r.width>innerWidth-8)lx=cx-r.width-14;if(ly+r.height>innerHeight-8)ly=cy-r.height-14;tip.style.left=lx+'px';tip.style.top=ly+'px';}
fig.querySelectorAll('.pt').forEach(g=>{g.addEventListener('mousemove',ev2=>show(g,ev2.clientX,ev2.clientY));
 g.addEventListener('mouseleave',()=>tip.style.display='none');
 g.addEventListener('focus',()=>{const r=g.getBoundingClientRect();show(g,r.right,r.bottom)});g.addEventListener('blur',()=>tip.style.display='none');});
function esc(t){return String(t).replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]))}
})();
"""


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("out")
    ap.add_argument("sources", nargs="+")
    ap.add_argument("--chart", help="trajectory JSON (see trajectory.py)")
    a = ap.parse_args()
    chart = json.loads(pathlib.Path(a.chart).read_text(encoding="utf-8")) if a.chart else None
    srcs = [pathlib.Path(s).resolve() for s in a.sources]
    body = "\n".join(render(p, chart if k == 0 else None, k > 0) for k, p in enumerate(srcs))
    title = html.escape(chart["title"] if chart else srcs[0].stem)
    data = json.dumps(chart or {}, ensure_ascii=False).replace("</", "<\\/")
    page = (f'<!doctype html><html lang="en"><head><meta charset="utf-8">'
            f'<meta name="viewport" content="width=device-width,initial-scale=1"><title>{title}</title>'
            f"<style>{CSS}</style></head><body><main>{body}</main>"
            f'<script type="application/json" id="trajdata">{data}</script>'
            f"<script>{JS if chart else ''}</script></body></html>")
    pathlib.Path(a.out).write_text(page, encoding="utf-8")
    print(a.out)


if __name__ == "__main__":
    main()
