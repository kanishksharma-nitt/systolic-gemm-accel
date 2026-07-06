#!/usr/bin/env python3
"""Bit-exact golden model for the INT8 systolic GEMM accelerator.

Computes C = requant(A x B) with the identical integer arithmetic as the RTL:
  acc     = sum_k A[m][k] * B[k][c]          (exact, fits INT32)
  shifted = (acc * scale) >> shift           (Python >> = arithmetic shift)
  q       = sat8(relu(shifted))

Emits test/cases.mem, a single hex file the testbench walks through:
  word 0: number of cases
  per case: M, SCALE, SHIFT, RELU, 4 B-row words, M A-row words,
            M expected C-row words (rows packed 4 signed bytes per word).

Stdlib only; fixed seed, so the output is deterministic.
"""

import random
import os

N = 4
SEED = 20260704


def sat8(x):
    return max(-128, min(127, x))


def requant(acc, scale, shift, relu):
    s = (acc * scale) >> shift          # arithmetic shift, like Verilog >>>
    if relu and s < 0:
        s = 0
    return sat8(s)


def gemm(a, b, scale, shift, relu):
    m_rows = len(a)
    c = [[0] * N for _ in range(m_rows)]
    for m in range(m_rows):
        for n in range(N):
            acc = sum(a[m][k] * b[k][n] for k in range(N))
            assert -(1 << 31) <= acc < (1 << 31), "accumulator overflow"
            c[m][n] = requant(acc, scale, shift, relu)
    return c


def pack_row(row):
    """4 signed bytes -> one 32-bit word, byte k = element k."""
    w = 0
    for k, v in enumerate(row):
        w |= (v & 0xFF) << (8 * k)
    return w


def rand_mat(rng, rows):
    return [[rng.randint(-128, 127) for _ in range(N)] for _ in range(rows)]


def main():
    rng = random.Random(SEED)
    cases = []

    # 1) small random GEMM, no ReLU
    cases.append(("random_m8", rand_mat(rng, 8), rand_mat(rng, N),
                  127, 16, 0))
    # 2) full-depth random GEMM with ReLU
    cases.append(("random_m64_relu", rand_mat(rng, 64), rand_mat(rng, N),
                  127, 16, 1))
    # 3) all -128: worst-case positive accumulator, must saturate to +127
    cases.append(("all_min", [[-128] * N for _ in range(N)],
                  [[-128] * N for _ in range(N)], 1, 9, 0))
    # 4) all +127
    cases.append(("all_max", [[127] * N for _ in range(N)],
                  [[127] * N for _ in range(N)], 1, 9, 0))
    # 5) identity B with unity requant (scale/2^shift = 1): C must equal A
    ident = [[1 if r == c else 0 for c in range(N)] for r in range(N)]
    a5 = rand_mat(rng, 16)
    cases.append(("identity", a5, ident, 256, 8, 0))
    # 6) zeros
    cases.append(("zeros", [[0] * N for _ in range(8)],
                  [[0] * N for _ in range(N)], 127, 16, 1))

    words = [len(cases)]
    for name, a, b, scale, shift, relu in cases:
        c = gemm(a, b, scale, shift, relu)

        # analytic self-checks on the model itself
        if name == "identity":
            assert c == a, "identity case must return A unchanged"
        if name == "all_min":
            assert all(v == 127 for row in c for v in row), \
                "all -128 case must saturate to +127"
        if name == "zeros":
            assert all(v == 0 for row in c for v in row)

        words += [len(a), scale, shift, relu]
        words += [pack_row(r) for r in b]
        words += [pack_row(r) for r in a]
        words += [pack_row(r) for r in c]
        print(f"  {name:16s} M={len(a):2d} scale={scale} shift={shift} "
              f"relu={relu}")

    out = os.path.join(os.path.dirname(__file__), "..", "test", "cases.mem")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w") as f:
        for w in words:
            f.write(f"{w & 0xFFFFFFFF:08x}\n")
    print(f"wrote {len(words)} words, {len(cases)} cases -> test/cases.mem")


if __name__ == "__main__":
    main()
