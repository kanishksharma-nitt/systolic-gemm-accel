#!/usr/bin/env python3
"""VCD toggle counter (stdlib only).

Usage: toggle_count.py <in.vcd> <out_report.txt>

Counts per-bit signal transitions in a VCD, aggregates per hierarchy prefix
and reports the top nets: the switching-activity term of dynamic power
(P ~ a*C*V^2*f). Absolute power needs the Yosys/OpenSTA flow in flow/
(capacitances from the liberty file); toggle counts are what the
open-source-only comparison uses.
"""

import sys
from collections import defaultdict


def main(vcd_path, out_path):
    names = {}          # id -> hierarchical name
    width = {}
    last = {}
    toggles = defaultdict(int)
    scope = []

    with open(vcd_path) as f:
        # ---- header ------------------------------------------------------
        for line in f:
            tok = line.split()
            if not tok:
                continue
            if tok[0] == "$scope":
                scope.append(tok[2])
            elif tok[0] == "$upscope":
                scope.pop()
            elif tok[0] == "$var":
                sid = tok[3]
                names[sid] = ".".join(scope + [tok[4]])
                width[sid] = int(tok[2])
            elif tok[0] == "$enddefinitions":
                break

        # ---- value changes ------------------------------------------------
        for line in f:
            if not line or line[0] in "#$":
                continue
            line = line.strip()
            if not line:
                continue
            c = line[0]
            if c in "01xz":
                sid, val = line[1:], c
            elif c in "bB":
                val, sid = line[1:].split()
            else:
                continue
            if sid in last and last[sid] != val:
                o, n = last[sid], val
                if len(o) == len(n):
                    toggles[sid] += sum(1 for a, b in zip(o, n)
                                        if a != b and "x" not in (a, b)
                                        and "z" not in (a, b))
                else:
                    toggles[sid] += width[sid]   # conservative
            last[sid] = val

    total = sum(toggles.values())
    by_prefix = defaultdict(int)
    for sid, n in toggles.items():
        parts = names[sid].split(".")
        for d in range(2, min(len(parts), 4)):
            by_prefix[".".join(parts[:d])] += n

    # clock nets deserve their own section: in the VCD a clock is ONE net,
    # but physically it fans out to every flop clock pin in its domain, so
    # its toggle count must be read as (toggles x fanout). Comparing
    # clk vs gclk_* toggles is how the clock-gating win is quantified.
    clocks = {sid: n for sid, n in toggles.items()
              if names[sid].split(".")[-1].endswith("clk")}

    with open(out_path, "w") as f:
        f.write(f"total_toggles {total}\n\n")
        f.write("clock nets (x fanout = clock-tree activity):\n")
        for sid in sorted(clocks, key=lambda s: names[s]):
            f.write(f"  {clocks[sid]:>12d}  {names[sid]}\n")
        f.write("\nper-hierarchy:\n")
        for p in sorted(by_prefix, key=by_prefix.get, reverse=True):
            f.write(f"  {by_prefix[p]:>12d}  {p}\n")
        f.write("\ntop nets:\n")
        for sid in sorted(toggles, key=toggles.get, reverse=True)[:25]:
            f.write(f"  {toggles[sid]:>12d}  {names[sid]}\n")
    print(f"{total} total toggles -> {out_path}")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
