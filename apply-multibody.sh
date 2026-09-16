#!/usr/bin/env bash
#
# apply-multibody.sh — 서로 분리된 구조물을 해석할 수 있게 한다.
#
# 무엇이 문제였나
#   서로 떨어진 두 구조물(예: 똑같은 단순보가 위아래로 놓인 경우)을
#   해석하면 "비연결 구조물: 절점 …가 나머지에서 분리되었습니다.
#   모든 구간을 연결하세요" 로 거부당한다.
#
#   막는 것은 Rust 솔버가 아니라 앱 쪽 사전 검증이다.
#   solver-service.ts 의 prepareSolve2D() 가 절점 하나에서 너비우선
#   탐색을 돌려 전부 닿지 않으면 그대로 반환한다. 주석에도
#   "structure must be a single connected component" 라고 적혀 있다.
#
#   솔버에는 그런 요구가 없다. 덩어리가 여럿이면 강성행렬은 블록
#   대각이 되고, 각 블록이 구속되어 있으면 촐레스키가 그대로 통과한다.
#   engine/src/solver/pre_solve_gates.rs 의 게이트들도 전부 경고일 뿐
#   해석을 멈추지 않는다. 즉 제약은 앱이 스스로 건 것이다.
#
# 무엇을 바꾸나
#   연결성 요구를 없애는 대신 성분별 검사로 바꾼다. 탐색을 모든 절점이
#   소진될 때까지 돌려 덩어리 목록을 만들고, 덩어리마다 지점이 강체운동
#   셋을 다 막는지 본다. 못 막는 덩어리가 있으면 그 절점 번호를 짚어
#   알려준다.
#
#   덩어리가 하나면 아무것도 달라지지 않는다. 기존 모델은 그대로다.
#
# 왜 성분별이어야 하나
#   prepareSolve2D 의 기존 검사들(구속 자유도 합계, 반력 평형행렬 랭크)은
#   모든 지점을 한 덩어리로 묶어 계산한다. 보 A 에 핀+롤러가 있고 보 B 에
#   지점이 없으면 합계는 3 이라 통과한다. 지금까지는 연결성 검사가 그
#   뒤에서 걸러 주고 있었을 뿐이다. 연결성 검사만 빼면 곧장 솔버까지
#   가서 "Singular stiffness matrix" 를 받게 되는데, 지금보다 나쁜
#   안내다. 그래서 두 변경은 반드시 함께 간다.
#
# 사용법:  ./apply-multibody.sh <저장소경로> [문구표.tsv]
# 여러 번 실행해도 안전하다.

set -euo pipefail

# pushd 가 끼기 전에 잡는다 (인수인계 §5.11).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

REPO="${1:?사용법: ./apply-multibody.sh <저장소경로> [문구표.tsv]}"
STRINGS="${2:-$SCRIPT_DIR/multibody-strings.tsv}"

ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

SRC="$REPO/web/src"
SVC="$SRC/lib/engine/solver-service.ts"
LOCALES="$SRC/lib/i18n/locales"

[[ -f "$SVC" ]]      || die "solver-service.ts 를 찾을 수 없습니다: $SVC"
[[ -d "$LOCALES" ]]  || die "locales 폴더를 찾을 수 없습니다: $LOCALES"
[[ -f "$STRINGS" ]]  || die "문구표를 찾을 수 없습니다: $STRINGS"
[[ -f "$SCRIPT_DIR/locale-insert.py" ]] || die "locale-insert.py 가 없습니다."

if grep -q "componentInstability2D" "$SVC"; then
  ok "이미 적용되어 있습니다."
else

echo "  연결성 검사를 성분별 검사로 교체"

python3 - "$SVC" <<'PY'
import sys
from pathlib import Path

p = Path(sys.argv[1])
src = p.read_text(encoding='utf-8')

# ── 1. 도우미 함수를 prepareSolve2D 앞에 넣는다 ────────────────────
HELPER = '''/**
 * Is one connected body of a 2D model held still?
 *
 * This is the test `prepareSolve2D` already runs over the whole model, applied
 * to a single body. A model with several bodies passes the whole-model test as
 * soon as any one body is restrained — pooling the supports of two beams gives
 * a full-rank reaction matrix even when one of the beams floats free — so the
 * check has to be per body.
 *
 * Returns null when the body is fine.
 */
function componentInstability2D(
  sups: Array<{ nodeId: number; type: string; kx?: number; ky?: number; kz?: number }>,
  nodes: Map<number, { x: number; y: number }>,
  hasFrames: boolean,
): 'noSupport' | 'fewDofs' | 'unstable' | null {
  if (sups.length === 0) return 'noSupport';

  let dofs = 0;
  for (const sup of sups) {
    if (sup.type === 'fixed') dofs += hasFrames ? 3 : 2;
    else if (sup.type === 'pinned') dofs += 2;
    else if (sup.type === 'spring') {
      if (sup.kx && sup.kx > 0) dofs++;
      if (sup.ky && sup.ky > 0) dofs++;
      if (hasFrames && sup.kz && sup.kz > 0) dofs++;
    } else dofs += 1; // roller
  }
  if (dofs < 3) return 'fewDofs';

  const pts: Array<{ x: number; z: number; type: string; kx?: number; ky?: number; kz?: number }> = [];
  for (const sup of sups) {
    const nd = nodes.get(sup.nodeId);
    if (nd) pts.push({
      x: nd.x, z: nd.y,
      type: sup.type === 'rollerY' ? 'rollerZ' : sup.type,
      kx: sup.kx, ky: sup.ky, kz: sup.kz,
    });
  }
  if (!pts.length) return 'noSupport';

  let cx = 0, cz = 0;
  for (const s of pts) { cx += s.x; cz += s.z; }
  cx /= pts.length; cz /= pts.length;

  // One column per reaction direction, written in the rigid-body basis
  // [translation x, translation z, rotation about the support centroid].
  const cols: Array<[number, number, number]> = [];
  for (const s of pts) {
    const rx = s.x - cx, rz = s.z - cz;
    switch (s.type) {
      case 'fixed':
        cols.push([1, 0, -rz]);
        cols.push([0, 1, rx]);
        if (hasFrames) cols.push([0, 0, 1]);
        break;
      case 'pinned':
        cols.push([1, 0, -rz]);
        cols.push([0, 1, rx]);
        break;
      case 'rollerX':
        cols.push([0, 1, rx]);
        break;
      case 'rollerZ':
        cols.push([1, 0, -rz]);
        break;
      case 'spring':
        if (s.kx && s.kx > 0) cols.push([1, 0, -rz]);
        if (s.ky && s.ky > 0) cols.push([0, 1, rx]);
        if (hasFrames && s.kz && s.kz > 0) cols.push([0, 0, 1]);
        break;
    }
  }
  if (cols.length < 3) return 'fewDofs';

  const G = [[0, 0, 0], [0, 0, 0], [0, 0, 0]];
  for (const c of cols) {
    for (let i = 0; i < 3; i++)
      for (let j = 0; j < 3; j++)
        G[i][j] += c[i] * c[j];
  }
  const det = G[0][0] * (G[1][1] * G[2][2] - G[1][2] * G[2][1])
            - G[0][1] * (G[1][0] * G[2][2] - G[1][2] * G[2][0])
            + G[0][2] * (G[1][0] * G[2][1] - G[1][1] * G[2][0]);
  const tr = G[0][0] + G[1][1] + G[2][2];
  const relDet = tr > 1e-20 ? Math.abs(det) / (tr * tr * tr) : 0;
  return relDet < 1e-10 ? 'unstable' : null;
}

'''

anchor = 'function prepareSolve2D('
i = src.find(anchor)
if i < 0:
    sys.exit("prepareSolve2D 를 찾지 못했습니다.")
src = src[:i] + HELPER + src[i:]

# ── 2. 연결성 블록을 성분 분해로 바꾼다 ───────────────────────────
OLD_HEAD = '  // ── Graph connectivity: structure must be a single connected component ──'
if OLD_HEAD not in src:
    sys.exit("연결성 검사 블록의 머리말을 찾지 못했습니다.\n"
             "상류가 그 줄을 고쳤을 수 있습니다. solver-service.ts 를 직접 확인하세요.")

start = src.index(OLD_HEAD)
# 블록은 주석 다음 줄의 '{' 에서 시작해 짝이 맞는 '}' 로 끝난다.
brace = src.index('{', start)
depth = 0
end = -1
for k in range(brace, len(src)):
    if src[k] == '{':
        depth += 1
    elif src[k] == '}':
        depth -= 1
        if depth == 0:
            end = k + 1
            break
if end < 0:
    sys.exit("연결성 검사 블록의 끝을 찾지 못했습니다.")

old_block = src[start:end]
if 'svc.disconnectedGraph' not in old_block:
    sys.exit("연결성 검사 블록에서 svc.disconnectedGraph 를 찾지 못했습니다.")

NEW_BLOCK = '''  // ── Connected components: every body has to stand on its own ──
  //
  // A model may legitimately hold several separate structures — two beams one
  // above the other, a set of comparison cases side by side. The solver has no
  // connectivity requirement: the stiffness matrix is block diagonal and each
  // block factors on its own. What it does require is that no block is free to
  // move, so the test is per body rather than one walk over the whole graph.
  {
    const adj = new Map<number, Set<number>>();
    for (const nid of connectedNodes) {
      adj.set(nid, new Set());
    }
    for (const elem of model.elements.values()) {
      adj.get(elem.nodeI)!.add(elem.nodeJ);
      adj.get(elem.nodeJ)!.add(elem.nodeI);
    }
    if (model.connectors) {
      for (const conn of model.connectors.values()) {
        adj.get(conn.nodeI)?.add(conn.nodeJ);
        adj.get(conn.nodeJ)?.add(conn.nodeI);
      }
    }
    // Rigid constraints tie nodes together as firmly as an element does, so a
    // body held only by a constraint must not be reported as floating.
    addConstraintAdjacency(adj, constraints2D);

    const seen = new Set<number>();
    const components: number[][] = [];
    for (const start of connectedNodes) {
      if (seen.has(start)) continue;
      const queue = [start];
      seen.add(start);
      // Index-based queue: shift() would make the walk O(n²) in node moves.
      for (let qi = 0; qi < queue.length; qi++) {
        for (const nb of adj.get(queue[qi])!) {
          if (!seen.has(nb)) {
            seen.add(nb);
            queue.push(nb);
          }
        }
      }
      components.push(queue);
    }

    // One body: the whole-model checks above already said everything there is
    // to say, and running them again would only risk disagreeing with them.
    if (components.length > 1) {
      for (const comp of components) {
        const member = new Set(comp);
        const compSups = [...model.supports.values()].filter(s => member.has(s.nodeId));
        const why = componentInstability2D(compSups, model.nodes, hasFrames);
        if (why) {
          // Naming every node of a large body helps nobody; the first few are
          // enough to find it on screen.
          const shown = comp.slice(0, 8).sort((a, b) => a - b).join(', ');
          const ids = comp.length > 8 ? shown + ', …' : shown;
          if (why === 'noSupport') return t('svc.componentNoSupport').replace('{ids}', ids);
          if (why === 'fewDofs') return t('svc.componentFewDofs').replace('{ids}', ids);
          return t('svc.componentUnstable').replace('{ids}', ids);
        }
      }
    }
  }'''

src = src[:start] + NEW_BLOCK + src[end:]
p.write_text(src, encoding='utf-8')
print("  solver-service.ts 수정")
PY

ok "성분별 안정성 검사로 교체"

fi

python3 "$SCRIPT_DIR/locale-insert.py" "$STRINGS" "$LOCALES"
ok "문구 추가 (en, es, pt, ko)"

echo
echo "분리 구조물 허용 적용 완료"
echo "  덩어리마다 지점이 강체운동을 막는지 검사합니다."
echo "  못 막는 덩어리가 있으면 그 절점 번호를 알려줍니다."
