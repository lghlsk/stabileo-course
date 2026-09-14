#!/usr/bin/env bash
#
# apply-korean.sh — Stabileo 에 한국어를 활성화한다.
#
# 저장소에는 ko.ts 가 이미 있지만 OFFERED_LOCALES 가 es/en/pt 로 좁혀져
# 있어 번들에 포함조차 되지 않는다. 이 스크립트는
#
#   1. ko 를 dicts 와 OFFERED_LOCALES 에 등록하고
#   2. ko.ts 에 빠진 키를 ko-extra.ts 로 덮어 채운다.
#
# 사용법:  ./apply-korean.sh <저장소경로> [ko-extra.ts 경로]
# 여러 번 실행해도 안전하다.

set -euo pipefail

REPO="${1:?사용법: ./apply-korean.sh <저장소경로> [ko-extra.ts]}"
EXTRA_SRC="${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ko-extra.ts}"

ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

I18N="$REPO/web/src/lib/i18n"
STORE="$I18N/store.svelte.ts"

[[ -f "$STORE" ]]           || die "i18n 스토어를 찾을 수 없습니다: $STORE"
[[ -f "$I18N/locales/ko.ts" ]] || die "ko.ts 가 없습니다. 저장소 구조가 바뀌었습니다."

# ── 1. 보충 번역 배치 ────────────────────────────────────────────

if [[ -f "$EXTRA_SRC" ]]; then
  cp "$EXTRA_SRC" "$I18N/locales/ko-extra.ts"
  ok "ko-extra.ts 배치 ($(grep -cE "^\s*'[a-zA-Z0-9_.]+':" "$EXTRA_SRC") 개 키)"
else
  warn "ko-extra.ts 가 없어 보충 번역 없이 진행합니다: $EXTRA_SRC"
fi

# ── 2. 스토어 수정 ───────────────────────────────────────────────

if grep -q "OFFERED_LOCALES = \['es', 'en', 'pt', 'ko'\]" "$STORE"; then
  ok "이미 적용되어 있습니다."
else
  python3 - "$STORE" "$I18N/locales/ko-extra.ts" <<'PY'
import re, sys, os

store, extra_path = sys.argv[1], sys.argv[2]
s = open(store, encoding='utf-8').read()
has_extra = os.path.exists(extra_path)

# (a) import 추가 — 기존 로케일 import 뒤에 붙인다.
anchor = re.search(r"^import pt from '\./locales/pt';\s*$", s, re.M)
if not anchor:
    sys.exit("locales/pt import 줄을 찾지 못했습니다. 저장소 구조가 바뀌었습니다.")
ins = "\nimport ko from './locales/ko';"
if has_extra:
    ins += "\nimport koExtra from './locales/ko-extra';"
s = s[:anchor.end()] + ins + s[anchor.end():]

# (b) dicts 에 등록.
#     ko.ts 에 없는 키는 koExtra 로 채우고, 그래도 없으면 tAt 이
#     영어로 대체하므로 화면이 깨지지는 않는다.
#     steel/* 는 es/en/pt 만 있어 해당 키는 영어로 나온다.
dict_anchor = "  pt: { ...pt, ...steelPt },\n"
if dict_anchor not in s:
    sys.exit("dicts 의 pt 줄을 찾지 못했습니다.")
ko_line = "  ko: { ...ko, ...koExtra },\n" if has_extra else "  ko: { ...ko },\n"
s = s.replace(dict_anchor, dict_anchor + ko_line, 1)

# (c) 제공 목록에 추가.
old_offered = "export const OFFERED_LOCALES = ['es', 'en', 'pt'] as const;"
if old_offered not in s:
    sys.exit("OFFERED_LOCALES 선언을 찾지 못했습니다.")
s = s.replace(old_offered,
              "export const OFFERED_LOCALES = ['es', 'en', 'pt', 'ko'] as const;", 1)

open(store, 'w', encoding='utf-8').write(s)
print("  스토어 수정 완료")
PY
  ok "ko 등록 및 OFFERED_LOCALES 추가"
fi

# ── 3. 언어 이름 표시 ────────────────────────────────────────────
# 선택기가 코드별 표시 이름을 들고 있으면 한국어도 넣어 준다.

for f in "$REPO"/web/src/components/**/*.svelte "$REPO"/web/src/components/*.svelte; do
  [[ -f "$f" ]] || continue
  if grep -q "pt: 'Português'" "$f" && ! grep -q "ko: '한국어'" "$f"; then
    python3 - "$f" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
s = s.replace("pt: 'Português'", "pt: 'Português', ko: '한국어'", 1)
open(p, 'w', encoding='utf-8').write(s)
PY
    ok "언어 표시명 추가: $(basename "$f")"
  fi
done

# ── 4. 확인 ──────────────────────────────────────────────────────

grep -q "'ko'" "$STORE" || die "적용 확인 실패: 스토어에 ko 가 없습니다."
ok "한국어 활성화 완료"
