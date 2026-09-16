#!/usr/bin/env bash
#
# prepare-pr.sh — apply the DSM nodal-load fix to a clone of stabileo,
# ready to commit and open a pull request upstream.
#
# This is the English-commented version of apply-dsm-fix.sh. The course
# build uses the Korean one; upstream gets this.
#
# Usage:
#   ./prepare-pr.sh /path/to/your/stabileo-fork
#
# Safe to run more than once.

set -euo pipefail

REPO="${1:?usage: ./prepare-pr.sh <path-to-stabileo-clone>}"

ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

SD="$REPO/web/src/lib/engine/solver-detailed.ts"
TESTDIR="$REPO/web/src/lib/engine/__tests__"

[[ -f "$SD" ]]     || die "not found: $SD"
[[ -d "$TESTDIR" ]] || die "not found: $TESTDIR"

if grep -q "const { nodeId, fx, fz, my } = load.data;" "$SD"; then
  ok "solver-detailed.ts already patched"
else
  python3 - "$SD" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()

# 1. The actual defect: SolverNodalLoad is { fx, fz, my }. Reading fy and mz
#    yields undefined, and undefined reaches the load vector as NaN.
subs = [
    ("const { nodeId, fx, fy, mz } = load.data;",
     "const { nodeId, fx, fz, my } = load.data;"),
    ("addLC(1, fy, `Fy nodal en nodo ${nodeId}`);",
     "addLC(1, fz, `Fz nodal en nodo ${nodeId}`);"),
    ("if (dofsPerNode >= 3) addLC(2, mz, `Mz nodal en nodo ${nodeId}`);",
     "if (dofsPerNode >= 3) addLC(2, my, `My nodal en nodo ${nodeId}`);"),
]
for old, new in subs:
    if old not in s:
        sys.exit(f"pattern not found: {old[:60]}")
    s = s.replace(old, new, 1)

# 2. The zero-skip guard let the bad value through. Math.abs(undefined) is
#    NaN and NaN < 1e-15 is false, so a missing term was not skipped as a
#    zero — it was written into the vector as NaN. Check finiteness first.
old_guard = """      const addLC = (ld: number, val: number, desc: string) => {
        if (Math.abs(val) < 1e-15) return;"""
new_guard = """      const addLC = (ld: number, val: number, desc: string) => {
        // Finiteness first. Math.abs(undefined) is NaN and NaN < 1e-15 is
        // false, so without this a missing term is not skipped as a zero:
        // it lands in the load vector as NaN and spreads to every later step.
        if (!Number.isFinite(val)) return;
        if (Math.abs(val) < 1e-15) return;"""
if old_guard not in s:
    sys.exit("addLC guard not found")
s = s.replace(old_guard, new_guard, 1)

# 3. Same blindness in the singularity checks. `a < b` is false for NaN, so
#    a poisoned matrix silently produced NaN displacements instead of
#    raising. `!(a >= b)` catches NaN as well as genuinely small pivots.
old_piv = "    if (maxVal < singularityTol) throw new Error(t('detailed.singularMatrix'));"
new_piv = ("    // !(a >= b) rather than a < b: the latter is false for NaN, which let a\n"
           "    // poisoned matrix through and returned NaN instead of raising.\n"
           "    if (!(maxVal >= singularityTol)) throw new Error(t('detailed.singularMatrix'));")
if old_piv not in s:
    sys.exit("pivot check not found")
s = s.replace(old_piv, new_piv, 1)

old_last = ("  if (Math.abs(a[(n - 1) * n + (n - 1)]) < singularityTol) "
            "throw new Error(t('detailed.singularHypostatic'));")
new_last = ("  if (!(Math.abs(a[(n - 1) * n + (n - 1)]) >= singularityTol)) "
            "throw new Error(t('detailed.singularHypostatic'));")
if old_last not in s:
    sys.exit("final pivot check not found")
s = s.replace(old_last, new_last, 1)

open(p, 'w', encoding='utf-8').write(s)
print("  field names + three guards")
PY
  ok "solver-detailed.ts patched"
fi

TEST="$TESTDIR/solver-detailed-nodal-load.test.ts"
if [[ -f "$TEST" ]]; then
  ok "regression test already present"
else
  cat > "$TEST" <<'TS'
import { describe, it, expect } from 'vitest';
import { solveDetailed } from '../solver-detailed';
import type { SolverInput } from '../types';

/**
 * Nodal loads in the step-by-step wizard.
 *
 * There was no test on this path, which is why `solveDetailed` went on
 * destructuring nodal loads as `{ fx, fy, mz }` after the 2D solver moved
 * from (x, y) to (x, z). The interface is `{ fx, fz, my }`, so `fy` and `mz`
 * were undefined; `Math.abs(undefined) < 1e-15` is false, so instead of being
 * skipped as zeros they were written into the load vector as NaN. From step 5
 * the NaN spread to the displacements and the reactions, and the singularity
 * checks in solveLU — also written as `a < b` — let it pass rather than
 * raising, so it surfaced on screen as NaN.
 *
 * A cantilever gives closed-form values to check against:
 *   tip deflection  δ = PL³/3EI
 */
function cantilever(L: number, P: number): SolverInput {
  return {
    nodes: new Map([
      [1, { id: 1, x: 0, z: 0 }],
      [2, { id: 2, x: L, z: 0 }],
    ]),
    materials: new Map([[1, { id: 1, e: 200_000, rho: 78.5 }]]),
    sections: new Map([[1, { id: 1, a: 0.01, iz: 1e-4 }]]),
    elements: new Map([
      [1, { id: 1, nodeI: 1, nodeJ: 2, materialId: 1, sectionId: 1, type: 'frame' }],
    ]),
    supports: new Map([[1, { nodeId: 1, type: 'fixed' }]]),
    loads: [{ type: 'nodal', data: { nodeId: 2, fx: 0, fz: P, my: 0 } }],
  } as unknown as SolverInput;
}

describe('solveDetailed — nodal loads', () => {
  const L = 4;
  const P = -10;
  const E = 200_000 * 1000; // kN/m²
  const I = 1e-4;           // m⁴

  it('produces no NaN at any step', () => {
    const d = solveDetailed(cantilever(L, P));
    const vectors: ReadonlyArray<readonly [string, number[]]> = [
      ['F', d.F], ['Ff', d.Ff], ['FfMod', d.FfMod],
      ['uFree', d.uFree], ['uAll', d.uAll], ['reactionsRaw', d.reactionsRaw],
    ];
    for (const [name, v] of vectors) {
      expect(v.every((x) => Number.isFinite(x)), `${name} contains NaN`).toBe(true);
    }
  });

  it('carries the vertical component into the load vector', () => {
    const d = solveDetailed(cantilever(L, P));
    // P must appear exactly once, on whichever DOF the numbering assigns.
    expect(d.F.filter((x) => Math.abs(x - P) < 1e-9).length).toBe(1);
  });

  it('matches PL³/3EI at the tip', () => {
    const d = solveDetailed(cantilever(L, P));
    const expected = (P * L ** 3) / (3 * E * I);
    const got = Math.min(...d.uAll.filter((x) => x < 0));
    expect(got).toBeCloseTo(expected, 8);
  });

  it('returns finite reactions', () => {
    const d = solveDetailed(cantilever(L, P));
    expect(d.reactionsRaw.every((x) => Number.isFinite(x))).toBe(true);
  });
});
TS
  ok "regression test added"
fi

grep -q "const { nodeId, fx, fz, my } = load.data;" "$SD" || die "verification failed"
grep -q "Number.isFinite(val)" "$SD"                      || die "guard verification failed"

cat <<'EOF'

Done. Suggested next steps:

  cd <your fork>
  git checkout -b fix/dsm-nodal-load-nan
  cd web && npm run test -- solver-detailed        # confirm green
  cd .. && git add -A
  git commit -F /path/to/COMMIT_MSG.txt
  git push -u origin fix/dsm-nodal-load-nan

EOF
