#!/usr/bin/env python3
"""Compare two toggle_count.py reports (baseline vs optimized).

Usage: toggle_compare.py <baseline.txt> <optimized.txt>
"""

import sys


def parse(path):
    total = 0
    hier = {}
    nets = {}
    clocks = {}
    section = None
    with open(path) as f:
        for line in f:
            if line.startswith("total_toggles"):
                total = int(line.split()[1])
            elif line.startswith("clock nets"):
                section = "c"
            elif line.startswith("per-hierarchy"):
                section = "h"
            elif line.startswith("top nets"):
                section = "n"
            elif line.strip() and section:
                n, name = line.split()
                {"h": hier, "n": nets, "c": clocks}[section][name] = int(n)
    return total, hier, nets, clocks


def main(base_path, opt_path):
    bt, bh, bn, bc = parse(base_path)
    ot, oh, on_, oc = parse(opt_path)

    print(f"total data toggles: {bt} -> {ot}  "
          f"({100 * (bt - ot) / bt:.1f}% reduction)\n")

    # clock-tree activity: gated-clock toggles vs the free-running clock;
    # each avoided toggle is avoided on EVERY flop clock pin in the domain
    ref = max(bc.values()) if bc else 0
    if ref and oc:
        print("clock domains (toggles; x fanout = clock-tree power):")
        for name in sorted(oc):
            leaf = name.split(".")[-1]
            if leaf == "clk":
                continue
            print(f"  {name:<34s} {oc[name]:>8d} vs free-running {ref}"
                  f"  ({100 * (ref - oc[name]) / ref:.1f}% of edges gated)")
        print()
    print(f"{'hierarchy':<28s} {'baseline':>12s} {'optimized':>12s} {'red.':>7s}")
    for name in sorted(bh, key=bh.get, reverse=True):
        b, o = bh[name], oh.get(name, 0)
        if b > 0:
            print(f"{name:<28s} {b:>12d} {o:>12d} {100*(b-o)/b:>6.1f}%")

    print("\ntop toggle reductions (nets):")
    deltas = {n: bn[n] - on_.get(n, 0) for n in bn}
    for name in sorted(deltas, key=deltas.get, reverse=True)[:10]:
        print(f"  {deltas[name]:>12d}  {name}")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
