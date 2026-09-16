#!/usr/bin/env bash
#
# apply-dz-naming.sh — 2D 지점 강제변위의 연직 성분을 dz 로 통일한다.
#
# 무엇이 문제였나
#   2D 에서 지점의 강제변위(침하)를 입력할 때 연직 방향이 화면에 "dy" 로
#   나온다. 앱의 2D 어휘는 [ux, uz, ry] 이고 결과표도 uz·rz 로 쓴다.
#   연직이 dy 로만 나오면 학생이 y 를 연직으로 오해하기 쉽다.
#   인수인계 §5.9 의 축 혼동이 화면에 그대로 드러난 자리다.
#
#   저장 필드도 같은 문제를 겪었다. 이름 정리가 이미 절반쯤 되어 있다.
#
#     dz?: number; // prescribed uz (m)
#     dy?: number; // legacy alias for prescribed uz (m)
#     const canonicalSupportDz = (s) => s.dz ?? s.dy;
#
#   즉 dz 가 정본이고 dy 는 옛 파일용 별칭인데, 입력 UI 는 아직 dy 에
#   쓰고 dy 에서 읽는다. 지금은 canonicalSupportDz 가 둘 다 받아 주어
#   동작하지만, 한 지점에 dz 와 dy 가 함께 있으면 해석은 dz 를 쓰고
#   화면은 dy 를 보여 주어 서로 다른 값을 가리킨다.
#
# 무엇을 바꾸나
#   네 화면이 dz 에 쓰도록 고친다. 읽을 때는 `dz ?? dy ?? 0` 으로
#   옛 파일도 그대로 보이게 한다. 라벨이 아직 dy 인 두 곳은 dz 로 바꾼다.
#
#   손대는 곳은 전부 2D 분기다. 3D 에서 dy 는 실제로 존재하는 별개의
#   자유도라 건드리지 않는다.
#
# 손대지 않는 것
#   uiStore.supportDy 는 이름 그대로 둔다. 3D 뷰포트도 이 값을 읽는데
#   (Viewport3D.svelte 에서 opts.dy 로), 거기서는 dy 가 맞는 축이다.
#   2D 생성 경로(Viewport.svelte)는 이미 presc.dz 로 쓰고 있다.
#
#   i18n 키 이름(prop.imposedDyTitle, float.prescribedDy)도 그대로 둔다.
#   문구 자체는 네 언어 모두 "연직/vertical" 로 이미 맞게 쓰여 있어
#   사용자에게 보이는 것은 달라지지 않는다. 키를 바꾸면 사전 네 개를
#   건드려야 하고 얻을 것이 없다.
#
# 사용법:  ./apply-dz-naming.sh <저장소경로>
# 여러 번 실행해도 안전하다.

set -euo pipefail

REPO="${1:?사용법: ./apply-dz-naming.sh <저장소경로>}"

ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

SRC="$REPO/web/src"
[[ -d "$SRC" ]] || die "web/src 를 찾을 수 없습니다: $SRC"

python3 - "$SRC" <<'PY'
import sys
from pathlib import Path

src = Path(sys.argv[1])

# (파일, 찾을 것, 바꿀 것, 설명)
EDITS = [
    (
        'components/tables/SupportsTable.svelte',
        """value={sup.dy ?? 0} onchange={(e) => updateSupportSpring(sup.id, 'dy', e.currentTarget.value)}""",
        """value={sup.dz ?? sup.dy ?? 0} onchange={(e) => updateSupportSpring(sup.id, 'dz', e.currentTarget.value)}""",
        '지점 표',
    ),
    (
        'components/property/SupportDetails.svelte',
        """value={sup.dy ?? 0} class="prop-input" onchange={(e) => updateSpringField(supId, 'dy', e.currentTarget.value)}""",
        """value={sup.dz ?? sup.dy ?? 0} class="prop-input" onchange={(e) => updateSpringField(supId, 'dz', e.currentTarget.value)}""",
        '속성 패널',
    ),
    (
        'components/floating-tools/SelectedEntityPanel.svelte',
        """          <span>dy:</span>\n          <input type="number" step="0.001" value={selectedSup.dy ?? 0} onchange={(e) => updateSupportField(selectedSup.id, 'dy', e.currentTarget.value)} />""",
        """          <span>dz:</span>\n          <input type="number" step="0.001" value={selectedSup.dz ?? selectedSup.dy ?? 0} onchange={(e) => updateSupportField(selectedSup.id, 'dz', e.currentTarget.value)} />""",
        '선택 패널',
    ),
    (
        'components/floating-tools/ToolSupportOptions.svelte',
        """        <span>dy:</span>\n        <input type="number" bind:value={uiStore.supportDy} step="0.001" />""",
        """        <span>dz:</span>\n        <input type="number" bind:value={uiStore.supportDy} step="0.001" />""",
        '지점 도구 옵션',
    ),
]

changed, already = [], []
for rel, old, new, label in EDITS:
    p = src / rel
    if not p.is_file():
        sys.exit(f"✗ 파일이 없습니다: {rel}")
    text = p.read_text(encoding='utf-8')
    if new in text:
        already.append(label)
        continue
    if old not in text:
        sys.exit(f"✗ {rel} 에서 바꿀 곳을 찾지 못했습니다 ({label}).\n"
                 f"  상류가 그 줄을 고쳤을 수 있습니다. 직접 확인하세요.")
    if text.count(old) != 1:
        sys.exit(f"✗ {rel} 에서 {text.count(old)}곳이 걸렸습니다 ({label}). "
                 f"한 곳이어야 합니다.")
    p.write_text(text.replace(old, new, 1), encoding='utf-8')
    changed.append(label)

for label in changed:
    print(f"  \033[32m✓\033[0m {label}")
for label in already:
    print(f"  \033[32m✓\033[0m {label} (이미 적용됨)")
PY

ok "2D 지점 강제변위 표기를 dz 로 통일"

echo
echo "dz 표기 적용 완료"
echo "  네 화면 모두 dz 에 쓰고, 옛 파일의 dy 도 그대로 읽습니다."
