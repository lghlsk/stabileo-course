#!/usr/bin/env bash
#
# apply-light-png.sh — PNG 내보내기를 밝은 배경으로 바꾼다.
#
# 화면은 어두운 바탕에 밝은 선으로 그려진다. 그대로 내보내면 보고서나
# 인쇄물에서 검은 사각형이 되어 읽기 어렵고 토너도 많이 든다.
#
# 색상과 채도는 두고 명도만 뒤집는다. 배경은 밝아지고 부재와 글자는
# 어두워지며, 인장 빨강과 압축 파랑은 중간 명도라 그대로 남는다.
# 배경만은 예외로 순백으로 만들어 흰 문서에 자국이 남지 않게 한다.
#
# 결과 이미지를 다루므로 2D 캔버스와 3D(Three.js) 캔버스에 똑같이
# 통한다. 3D 는 색이 하드코딩되어 있고 글자가 스프라이트 텍스처라
# 테마 교체로는 손대기 어렵다.
#
# 사용법:  ./apply-light-png.sh <저장소경로> [light-png.ts 경로]
# 여러 번 실행해도 안전하다.

set -euo pipefail

REPO="${1:?사용법: ./apply-light-png.sh <저장소경로> [light-png.ts]}"
SRC_TS="${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/light-png.ts}"

ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

SRC="$REPO/web/src"
APP="$SRC/App.svelte"

[[ -f "$APP" ]]    || die "App.svelte 를 찾을 수 없습니다: $APP"
[[ -f "$SRC_TS" ]] || die "light-png.ts 를 찾을 수 없습니다: $SRC_TS"

mkdir -p "$SRC/lib/io"
cp "$SRC_TS" "$SRC/lib/io/light-png.ts"
ok "lib/io/light-png.ts 배치"

if grep -q "toLightCanvas" "$APP"; then
  ok "이미 적용되어 있습니다."
  exit 0
fi

python3 - "$APP" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()

# ── import 추가 ────────────────────────────────────────────────
anchor = re.search(r"^\s*import \{[^}]*\} from '\./lib/store/file';\s*$", s, re.M)
if not anchor:
    sys.exit("file 모듈 import 줄을 찾지 못했습니다.")
s = (s[:anchor.end()]
     + "\n  import { toLightCanvas } from './lib/io/light-png';"
     + s[anchor.end():])

# ── 내보내기 핸들러 교체 ───────────────────────────────────────
old = """  function handleExportPNG() {
    const canvas = document.querySelector('.viewport-container canvas') as HTMLCanvasElement | null;
    if (canvas) downloadCanvasPNG(canvas);
  }"""
new = """  function handleExportPNG() {
    const canvas = document.querySelector('.viewport-container canvas') as HTMLCanvasElement | null;
    if (!canvas) return;
    // 화면은 어두운 바탕이다. 보고서와 인쇄물에 쓰려면 밝은 바탕이어야
    // 하므로, 색상과 채도는 두고 명도만 뒤집은 사본을 내보낸다.
    // 화면 자체는 건드리지 않는다.
    downloadCanvasPNG(toLightCanvas(canvas, canvasTheme().surface));
  }"""
if old not in s:
    sys.exit("handleExportPNG 를 찾지 못했습니다.")
s = s.replace(old, new, 1)

# ── canvasTheme 이 이미 들어와 있는지 확인, 없으면 추가 ────────
if not re.search(r"import \{[^}]*canvasTheme[^}]*\} from '\./lib/canvas/theme'", s):
    m = re.search(r"^\s*import \{ toLightCanvas \} from '\./lib/io/light-png';\s*$", s, re.M)
    s = (s[:m.end()]
         + "\n  import { canvasTheme } from './lib/canvas/theme';"
         + s[m.end():])

open(p, 'w', encoding='utf-8').write(s)
print("  핸들러 교체")
PY

grep -q "toLightCanvas" "$APP" || die "적용 확인 실패"
grep -q "canvasTheme" "$APP"   || die "canvasTheme import 실패"
ok "PNG 내보내기가 밝은 배경으로 바뀌었습니다."
