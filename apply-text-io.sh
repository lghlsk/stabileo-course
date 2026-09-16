#!/usr/bin/env bash
#
# apply-text-io.sh — Stabileo 에 텍스트 형식 입출력을 추가한다.
#
# 빌드마다 저장소를 새로 클론하므로, UI 수정은 이렇게 다시 적용할 수
# 있는 형태여야 한다. 이 스크립트는 여러 번 실행해도 안전하다.
#
# 사용법:
#   ./apply-text-io.sh <저장소경로> [text-format.ts 경로]
#
# 추가되는 것:
#   · lib/io/text-format.ts                      인코더/디코더
#   · 프로젝트 패널 → 내보내기에  "텍스트"  버튼
#   · 프로젝트 패널 → 가져오기에  "텍스트 열기" 버튼
#   · 한국어/영어 문구

set -euo pipefail

# pushd 가 끼기 전에 잡는다. 나중에 하면 dirname "." 이 엉뚱한 곳을 가리킨다.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

REPO="${1:?사용법: ./apply-text-io.sh <저장소경로> [text-format.ts] [문구표.tsv]}"
SRC_TS="${2:-$SCRIPT_DIR/text-format.ts}"
STRINGS="${3:-$SCRIPT_DIR/textio-strings.tsv}"

ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

SRC="$REPO/web/src"
TOOLBAR="$SRC/components/toolbar/ToolbarProject.svelte"
LOCALES="$SRC/lib/i18n/locales"

[[ -d "$SRC" ]]       || die "저장소 구조가 예상과 다릅니다: $SRC 없음"
[[ -f "$TOOLBAR" ]]   || die "툴바 파일을 찾을 수 없습니다: $TOOLBAR"
[[ -f "$SRC_TS" ]]    || die "text-format.ts 를 찾을 수 없습니다: $SRC_TS"
[[ -f "$STRINGS" ]]   || die "문구표를 찾을 수 없습니다: $STRINGS"

# BSD/GNU sed 차이 흡수 (맥에서도 실행 가능하게)
if [[ "$(uname -s)" == "Darwin" ]]; then
  sedi() { sed -i '' "$@"; }
else
  sedi() { sed -i "$@"; }
fi

# ── 1. 모듈 배치 ──────────────────────────────────────────────────

mkdir -p "$SRC/lib/io"
cp "$SRC_TS" "$SRC/lib/io/text-format.ts"
ok "lib/io/text-format.ts 배치"

# ── 2. 이미 적용되었는지 확인 (재실행 안전) ───────────────────────

if grep -q "text-format" "$TOOLBAR"; then
  warn "툴바에 이미 적용되어 있습니다. 건너뜁니다."
else

  # ── 3. import 추가 ─────────────────────────────────────────────
  # 기존 file 모듈 import 줄 바로 아래에 끼워 넣는다.
  python3 - "$TOOLBAR" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()

anchor = re.search(r"^\s*import \{[^}]*\} from '\.\./\.\./lib/store/file';\s*$",
                   s, re.M)
if not anchor:
    sys.exit("file 모듈 import 줄을 찾지 못했습니다.")

ins = ("\n  import { downloadModelText, openModelText } "
       "from '../../lib/io/text-format';")
s = s[:anchor.end()] + ins + s[anchor.end():]

# ── 상태와 핸들러 추가 ─────────────────────────────────────────
# <script> 블록 끝(마지막 </script>) 직전에 넣는다.
handler = """
  // ── 텍스트 형식 입출력 ─────────────────────────────────────
  // 그래픽 편집기를 거치지 않고 모델을 고칠 수 있게 한다.
  let textInput: HTMLInputElement | undefined = $state();

  async function handleOpenText(ev: Event) {
    const input = ev.target as HTMLInputElement;
    const file = input.files?.[0];
    input.value = '';            // 같은 파일을 다시 골라도 동작하도록
    if (!file) return;
    const res = await openModelText(file);
    alert(res.message);
  }
"""
idx = s.rindex('</script>')
s = s[:idx] + handler + '\n' + s[idx:]

open(p, 'w', encoding='utf-8').write(s)
print("  import/핸들러 삽입")
PY
  ok "import 및 핸들러 추가"

  # ── 4. 버튼 추가 ───────────────────────────────────────────────
  python3 - "$TOOLBAR" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()

# 내보내기: CSV 버튼 다음에 텍스트 버튼
csv_btn = """          title={t('project.exportCsvTooltip')}
        >
          CSV
        </button>"""
if csv_btn not in s:
    sys.exit("CSV 버튼을 찾지 못했습니다.")
s = s.replace(csv_btn, csv_btn + """
        <button class="file-btn" onclick={downloadModelText} title={t('project.exportTextTooltip')}>
          {t('project.exportText')}
        </button>""", 1)

# 가져오기: '.ded 열기' 버튼 다음에 텍스트 열기
ded_btn = """        <button class="file-btn" onclick={() => fileInput?.click()} title={t('project.openDedTooltip')}>
          {t('project.openDed')}
        </button>"""
if ded_btn not in s:
    sys.exit(".ded 열기 버튼을 찾지 못했습니다.")
s = s.replace(ded_btn, ded_btn + """
        <button class="file-btn" onclick={() => textInput?.click()} title={t('project.openTextTooltip')}>
          {t('project.openText')}
        </button>
        <input
          bind:this={textInput}
          type="file"
          accept=".txt,.text,text/plain"
          style="display:none"
          onchange={handleOpenText}
        />""", 1)

open(p, 'w', encoding='utf-8').write(s)
print("  버튼 삽입")
PY
  ok "내보내기/가져오기 버튼 추가"
fi

# ── 5. 문구 추가 ──────────────────────────────────────────────────
#
# 문구는 textio-strings.tsv 한 곳에만 둔다. 삽입은 locale-insert.py 가
# 맡는다 — apply-multibody.sh 도 같은 것을 쓴다. 스크립트마다 따로
# 들고 있으면 한 곳을 고칠 때 나머지가 남아 네 사전이
# 서로 어긋나고, 어긋난 것을 아무도 모른다. 상류의 커버리지 테스트는
# t('키') 만 정규식으로 찾으므로 tp('키', {...}) 로 부르는 문구 —
# 이 모듈의 오류 문구 전부 — 는 그 검사에 걸리지 않는다.
#
# es 와 pt 도 함께 넣는다. 앱이 제공하는 세 언어라서, 하나라도 비면
# basic-mode-coverage.test.ts 가 떨어진다.

python3 "$SCRIPT_DIR/locale-insert.py" "$STRINGS" "$LOCALES"

ok "문구 추가 (en, es, pt, ko)"

# ── 6. 확인 ───────────────────────────────────────────────────────

for needle in "downloadModelText" "openModelText" "textInput"; do
  grep -q "$needle" "$TOOLBAR" || die "적용 확인 실패: $needle 가 툴바에 없습니다."
done
[[ -f "$SRC/lib/io/text-format.ts" ]] || die "모듈이 배치되지 않았습니다."

printf '\n\033[1;32m텍스트 입출력 적용 완료\033[0m\n'
echo "  프로젝트 → 내보내기 → 텍스트"
echo "  프로젝트 → 가져오기 → 텍스트 열기"
