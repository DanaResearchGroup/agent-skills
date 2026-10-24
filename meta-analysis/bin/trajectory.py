#!/usr/bin/env python3
"""Render the meta-analysis trajectory chart (PNG) from a trajectory JSON file.

Usage:
    trajectory.py TRAJECTORY.json OUT.png

JSON shape (the same file feeds report_html.py's interactive chart):
    {
      "title": "...", "y_label": "...",
      "sources": {"U": {"name": "User", "color": "#2a78d6", "marker": "o"}, ...},
      "events": [{"time": "22.10 19:12", "source": "U", "depth": 1.0,
                  "label": "short label", "detail": "hover text", "key": true}, ...],
      "markers": [{"after": 9, "label": "overnight", "style": "dotted"},
                  {"after": 16, "label": "compaction 1", "style": "dashed"}]
    }
Events are chronological; "depth" is the analyst's judged 0-10 score; "key"
events get a letter callout keyed under the plot. Markers draw a vertical line
between event `after` and the next one. Markers are matplotlib codes
(o s D ^); report_html.py maps them to SVG shapes.
"""
import json
import sys

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402

INK, MUTED, GRID = "#1f1f1e", "#6b6a64", "#e6e5e0"


def main(src, out):
    d = json.load(open(src, encoding="utf-8"))
    ev = d["events"]
    plt.rcParams.update({"font.family": "DejaVu Sans", "font.size": 10})
    fig, ax = plt.subplots(figsize=(14, 8.4), dpi=200)
    fig.subplots_adjust(left=0.07, right=0.98, top=0.94, bottom=0.33)
    xs = list(range(1, len(ev) + 1))
    ax.plot(xs, [e["depth"] for e in ev], color="#b9b8b0", lw=2, zorder=1, drawstyle="steps-post")
    for x, e in zip(xs, ev):
        s = d["sources"][e["source"]]
        ax.scatter([x], [e["depth"]], s=70, color=s["color"], marker=s["marker"],
                   edgecolor="white", linewidth=2, zorder=3)
    for m in d.get("markers", []):
        dashed = m.get("style") == "dashed"
        ax.axvline(m["after"] + 0.5, color=MUTED if dashed else INK, lw=1,
                   ls=(0, (3, 3)) if dashed else (0, (1, 2)), zorder=0)
        ax.text(m["after"] + 0.55, 10.1 if dashed else 0.2, m["label"], color=MUTED, fontsize=8,
                rotation=90 if dashed else 0, va="top" if dashed else "bottom")
    keys = []
    for x, e in zip(xs, ev):
        if e.get("key"):
            letter = chr(ord("A") + len(keys))
            keys.append(f"{letter}  [{x}] {e['label']}")
            ax.text(x, e["depth"] + 0.32, letter, ha="center", va="bottom", fontsize=9,
                    fontweight="bold", color=INK)
    half = (len(keys) + 1) // 2
    for col, chunk in enumerate((keys[:half], keys[half:])):
        fig.text(0.06 + 0.47 * col, 0.235, "\n".join(chunk), ha="left", va="top", fontsize=8.4,
                 color=INK, linespacing=1.55)
    ax.set_xlim(0.3, len(ev) + 0.7)
    ax.set_ylim(0, 10.2)
    ax.set_xticks(xs)
    ax.set_xticklabels([str(i) for i in xs], fontsize=8, color=MUTED)
    ax.set_xlabel("Interaction (chronological; letters keyed below)", color=MUTED)
    ax.set_ylabel(d.get("y_label", "Depth and novelty (judged, 0–10)"), color=MUTED)
    for sp in ("top", "right"):
        ax.spines[sp].set_visible(False)
    for sp in ("left", "bottom"):
        ax.spines[sp].set_color(GRID)
    ax.grid(axis="y", color=GRID, lw=0.8)
    ax.set_axisbelow(True)
    ax.tick_params(colors=MUTED)
    handles = [plt.Line2D([], [], color=s["color"], marker=s["marker"], ls="", markersize=8,
                          markeredgecolor="white", label=s["name"]) for s in d["sources"].values()]
    ax.legend(handles=handles, loc="lower right", bbox_to_anchor=(1.0, 0.04), frameon=False, fontsize=8.5)
    ax.set_title(d["title"], loc="left", color=INK, fontsize=12)
    fig.savefig(out)
    print(out)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
