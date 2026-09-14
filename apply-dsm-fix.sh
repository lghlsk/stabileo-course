#!/usr/bin/env bash
#
# apply-dsm-fix.sh — 단계별 강성법 화면의 NaN 을 고친다.
#
# 증상
#   Advanced → 단계별 설명에서 7단계 이후 변위와 반력이 모두 NaN.
#
# 원인
#   solver-detailed.ts 가 절점하중을 { fx, fy, mz } 로 읽는다.
#   실제 인터페이스는 { fx, fz, my } 이므로 fy 와 mz 는 undefined 가 되고,
#   F[idx] += undefined 로 하중벡터(5단계)에 NaN 이 들어간다.
#   2D 솔버가 (x,y) 에서 (x,z) 로 바뀔 때 이 호출부만 갱신되지 않았다.
#   같은 파일 128행 주석에 nodeDistance 의 동일한 사고가 기록되어 있다.
#
#   NaN 이 오류 없이 화면까지 가는 이유는 방어 장치가 NaN 을 통과시키기
#   때문이다. Math.abs(undefined) < 1e-15 도, maxVal < tol 도 NaN 에서는
#   false 가 되어 조기 반환도 예외도 일어나지 않는다.
#
# 사용법:  ./apply-dsm-fix.sh <저장소경로>
# 여러 번 실행해도 안전하다.

set -euo pipefail

REPO="${1:?사용법: ./apply-dsm-fix.sh <저장소경로>}"

ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

SD="$REPO/web/src/lib/engine/solver-detailed.ts"
[[ -f "$SD" ]] || die "solver-detailed.ts 를 찾을 수 없습니다: $SD"

if grep -q "const { nodeId, fx, fz, my } = load.data;" "$SD"; then
  ok "이미 적용되어 있습니다."
  exit 0
fi

python3 - "$SD" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
before = s

# ── 1. 필드명 교정 (근본 원인) ─────────────────────────────────
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
        sys.exit(f"찾지 못한 코드: {old[:50]}")
    s = s.replace(old, new, 1)

# ── 2. 하중 적용부를 NaN 인식하도록 ────────────────────────────
# Math.abs(undefined) 는 NaN 이고 NaN < 1e-15 는 false 라, 값이 없을 때
# 오히려 통과해 벡터를 오염시켰다. 유한한 값만 더한다.
old_guard = """      const addLC = (ld: number, val: number, desc: string) => {
        if (Math.abs(val) < 1e-15) return;"""
new_guard = """      const addLC = (ld: number, val: number, desc: string) => {
        // 유한성 검사가 먼저다. Math.abs(undefined) 는 NaN 이고
        // NaN < 1e-15 는 false 이므로, 이 검사가 없으면 값이 없는 항이
        // 0 으로 건너뛰이는 대신 NaN 으로 기록된다.
        if (!Number.isFinite(val)) return;
        if (Math.abs(val) < 1e-15) return;"""
if old_guard not in s:
    sys.exit("addLC 가드를 찾지 못했습니다.")
s = s.replace(old_guard, new_guard, 1)

# ── 3. LU 분해의 특이성 검사도 NaN 인식하도록 ──────────────────
# 부등호를 뒤집으면 NaN 도 걸린다. NaN >= tol 은 false 이므로
# !(maxVal >= tol) 은 true 가 되어 예외가 발생한다.
old_piv = "    if (maxVal < singularityTol) throw new Error(t('detailed.singularMatrix'));"
new_piv = ("    // !(a >= b) 로 쓰면 NaN 도 걸린다. NaN < b 는 false 라\n"
           "    // 기존 형태는 오염된 행렬을 조용히 통과시켰다.\n"
           "    if (!(maxVal >= singularityTol)) throw new Error(t('detailed.singularMatrix'));")
if old_piv not in s:
    sys.exit("피벗 검사를 찾지 못했습니다.")
s = s.replace(old_piv, new_piv, 1)

old_last = ("  if (Math.abs(a[(n - 1) * n + (n - 1)]) < singularityTol) "
            "throw new Error(t('detailed.singularHypostatic'));")
new_last = ("  if (!(Math.abs(a[(n - 1) * n + (n - 1)]) >= singularityTol)) "
            "throw new Error(t('detailed.singularHypostatic'));")
if old_last not in s:
    sys.exit("마지막 피벗 검사를 찾지 못했습니다.")
s = s.replace(old_last, new_last, 1)

assert s != before
open(p, 'w', encoding='utf-8').write(s)
print("  필드명 교정 + 가드 3곳 보강")
PY

ok "solver-detailed.ts 수정"

# ── 회귀 테스트 추가 ─────────────────────────────────────────────
# 기존 테스트는 등분포하중만 다룬다. 절점하중 경로가 비어 있었던 것이
# 이 버그가 오래 남은 이유이므로, 같은 폴더에 짝을 채워 둔다.

TESTDIR="$REPO/web/src/lib/engine/__tests__"
if [[ -d "$TESTDIR" && ! -f "$TESTDIR/solver-detailed-nodal-load.test.ts" ]]; then
  cat > "$TESTDIR/solver-detailed-nodal-load.test.ts" <<'TS'
import { describe, it, expect } from 'vitest';
import { solveDetailed } from '../solver-detailed';
import type { SolverInput } from '../types';

/**
 * 단계별 마법사의 절점하중 경로.
 *
 * 이 테스트가 없어서 `solveDetailed` 가 절점하중을 { fx, fy, mz } 로
 * 읽는 것이 오래 남아 있었다. 실제 인터페이스는 { fx, fz, my } 이므로
 * fy 와 mz 는 undefined 가 되고, `Math.abs(undefined) < 1e-15` 가 false 인
 * 탓에 0 으로 건너뛰이는 대신 NaN 이 하중벡터에 기록됐다. 그 NaN 은
 * 7단계 변위와 8단계 반력까지 번졌고, LU 분해의 특이성 검사 역시
 * NaN 을 통과시켜 예외 대신 화면의 NaN 으로 나타났다.
 *
 * 캔틸레버 보 끝단에 연직하중 P 를 걸면 손으로 검산할 수 있다.
 *   처짐  δ = PL³/3EI      회전  θ = PL²/2EI
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

describe('solveDetailed — 절점하중', () => {
  const L = 4, P = -10;
  const E = 200_000 * 1000, I = 1e-4;   // kN/m², m⁴

  it('어느 단계에도 NaN 이 없다', () => {
    const d = solveDetailed(cantilever(L, P));
    for (const [name, v] of [
      ['F', d.F], ['Ff', d.Ff], ['FfMod', d.FfMod],
      ['uFree', d.uFree], ['uAll', d.uAll], ['reactionsRaw', d.reactionsRaw],
    ] as const) {
      expect(v.every((x: number) => Number.isFinite(x)), `${name} 에 NaN`).toBe(true);
    }
  });

  it('연직하중이 하중벡터에 실린다', () => {
    const d = solveDetailed(cantilever(L, P));
    // 어느 자유도든 P 가 정확히 한 번 나타나야 한다.
    expect(d.F.filter((x: number) => Math.abs(x - P) < 1e-9).length).toBe(1);
  });

  it('끝단 처짐이 PL³/3EI 와 일치한다', () => {
    const d = solveDetailed(cantilever(L, P));
    const expected = (P * L ** 3) / (3 * E * I);
    const got = Math.min(...d.uAll.filter((x: number) => x < 0));
    expect(got).toBeCloseTo(expected, 8);
  });

  it('반력이 하중과 평형을 이룬다', () => {
    const d = solveDetailed(cantilever(L, P));
    const sum = d.reactionsRaw.reduce((a: number, b: number) => a + b, 0);
    expect(Number.isFinite(sum)).toBe(true);
  });
});
TS
  ok "회귀 테스트 추가 (solver-detailed-nodal-load.test.ts)"
fi

# ── 확인 ─────────────────────────────────────────────────────────

grep -q "const { nodeId, fx, fz, my } = load.data;" "$SD" || die "적용 확인 실패"
grep -q "Number.isFinite(val)" "$SD"                      || die "가드 보강 실패"
ok "단계별 강성법 NaN 수정 완료"
