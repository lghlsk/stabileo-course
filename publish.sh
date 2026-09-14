#!/usr/bin/env bash
#
# publish.sh — 이 폴더를 GitHub 저장소로 올린다.
#
# gh CLI 를 써서 저장소 생성과 push 까지 한 번에 처리한다.
# 올리기 전에 무엇이 올라가는지 보여주고 확인을 받는다.
#
# 사용법:
#   ./publish.sh                       대화식으로 진행
#   ./publish.sh --name stabileo-course
#   ./publish.sh --name x --private
#   ./publish.sh --dry-run             올리지 않고 점검만
#
# 두 번째 실행부터는 저장소를 새로 만들지 않고 변경분만 올린다.

set -euo pipefail

REPO_NAME=""
VISIBILITY=""
DRY_RUN=0
MESSAGE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)    REPO_NAME="${2:?--name 뒤에 저장소 이름이 필요합니다}"; shift 2 ;;
    --public)  VISIBILITY="public";  shift ;;
    --private) VISIBILITY="private"; shift ;;
    --message|-m) MESSAGE="${2:?-m 뒤에 커밋 메시지가 필요합니다}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "알 수 없는 옵션: $1" >&2; exit 1 ;;
  esac
done

step() { printf '\n\033[1;36m▶ %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
die()  { printf '\n\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── 1. 도구 확인 ────────────────────────────────────────────────────

step "도구 확인"

command -v git >/dev/null 2>&1 || die "git 이 필요합니다."
command -v gh  >/dev/null 2>&1 || die "gh CLI 가 필요합니다.

  macOS   brew install gh
  Ubuntu  sudo apt install gh
  그 밖에  https://cli.github.com"

if ! gh auth status >/dev/null 2>&1; then
  die "gh 에 로그인되어 있지 않습니다.

    gh auth login

  를 먼저 실행하세요. 브라우저로 인증하는 방식이 가장 간단합니다."
fi

GH_USER="$(gh api user --jq .login 2>/dev/null)" || die "GitHub 사용자 정보를 가져오지 못했습니다."
ok "gh 로그인: $GH_USER"

# ─── 2. 커밋 신원 확인 ───────────────────────────────────────────────
# 없으면 커밋 자체가 실패한다. 여기서 미리 잡아 준다.

GIT_NAME="$(git config --get user.name  || true)"
GIT_MAIL="$(git config --get user.email || true)"

if [[ -z "$GIT_NAME" || -z "$GIT_MAIL" ]]; then
  warn "git 커밋 신원이 설정되어 있지 않습니다."
  echo
  echo "  이름은 커밋에 표시될 문자열입니다 (GitHub ID 와 무관)."
  echo "  이메일은 커밋을 계정에 연결하는 열쇠이므로, GitHub 에 등록된"
  echo "  주소여야 합니다. 실제 주소를 감추고 싶다면 다음을 쓰세요:"
  echo "    <숫자>+${GH_USER}@users.noreply.github.com"
  echo "    (GitHub → Settings → Emails 에서 확인)"
  echo
  [[ -n "$GIT_NAME" ]] || { read -r -p "  이름: " GIT_NAME; git config --global user.name "$GIT_NAME"; }
  [[ -n "$GIT_MAIL" ]] || { read -r -p "  이메일: " GIT_MAIL; git config --global user.email "$GIT_MAIL"; }
fi
ok "커밋 신원: $GIT_NAME <$GIT_MAIL>"

# ─── 3. 올릴 내용 점검 ───────────────────────────────────────────────

step "올릴 내용 점검"

for f in README.md LICENSE .gitignore; do
  [[ -f "$f" ]] || warn "$f 가 없습니다."
done

if [[ ! -d .git ]]; then
  git init -q -b main
  ok "git 저장소 초기화"
fi

git add -A

FILES="$(git diff --cached --name-only)"
if [[ -z "$FILES" ]] && [[ -n "$(git log -1 2>/dev/null || true)" ]]; then
  ok "변경 사항이 없습니다."
  NOTHING_TO_COMMIT=1
else
  NOTHING_TO_COMMIT=0
fi

echo
git diff --cached --name-only | sed 's/^/    /'
TOTAL="$(git diff --cached --name-only | wc -l | tr -d ' ')"
# 폴더 전체가 아니라 실제로 커밋될 파일만 센다. 무시 목록에 걸린
# WASM 캐시나 zip 이 용량에 잡히면 오해를 부른다.
SIZE="$(git diff --cached --name-only -z \
        | xargs -0 -r du -ch 2>/dev/null | tail -1 | cut -f1 || echo '?')"
echo
ok "파일 ${TOTAL}개, 약 ${SIZE}"

# 큰 파일과 개인 자료가 섞이지 않았는지 본다.
BIG="$(git diff --cached --name-only -z | xargs -0 -I{} sh -c 'test -f "{}" && find "{}" -size +2M' 2>/dev/null || true)"
if [[ -n "$BIG" ]]; then
  warn "2MB 가 넘는 파일이 있습니다:"
  echo "$BIG" | sed 's/^/      /'
  warn "WASM 캐시나 빌드 결과물이라면 .gitignore 를 확인하세요."
fi

if git diff --cached --name-only | grep -q '^examples/'; then
  warn "examples/ 폴더가 포함됩니다. 학생 자료나 실제 강의 파일이"
  warn "섞여 있지 않은지 확인하세요."
fi

# ─── 4. 저장소 이름과 공개 범위 ──────────────────────────────────────

step "저장소 설정"

if [[ -z "$REPO_NAME" ]]; then
  DEFAULT_NAME="$(basename "$PWD" | tr ' ' '-')"
  read -r -p "  저장소 이름 [$DEFAULT_NAME]: " REPO_NAME
  REPO_NAME="${REPO_NAME:-$DEFAULT_NAME}"
fi

if [[ -z "$VISIBILITY" ]]; then
  echo
  echo "  공개(public) 로 두면 저장소 주소 자체가 AGPL 의 '대응 소스"
  echo "  입수 경로' 가 되어, 학생 배포 시 의무가 깔끔하게 충족됩니다."
  echo
  read -r -p "  공개 범위 [public/private] (기본 public): " VISIBILITY
  VISIBILITY="${VISIBILITY:-public}"
fi
[[ "$VISIBILITY" == "public" || "$VISIBILITY" == "private" ]] \
  || die "공개 범위는 public 또는 private 이어야 합니다."

ok "대상: ${GH_USER}/${REPO_NAME} (${VISIBILITY})"

# ─── 5. 확인 ─────────────────────────────────────────────────────────

if [[ "$DRY_RUN" -eq 1 ]]; then
  printf '\n\033[1;33m점검만 했습니다. 올리지 않았습니다.\033[0m\n\n'
  git reset -q
  exit 0
fi

echo
if [[ "$VISIBILITY" == "public" ]]; then
  printf '  \033[1;33m이 내용이 인터넷에 공개됩니다.\033[0m\n'
fi
read -r -p "  계속할까요? [y/N]: " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { git reset -q; die "취소했습니다."; }

# ─── 6. 커밋 ─────────────────────────────────────────────────────────

step "커밋"

if [[ "$NOTHING_TO_COMMIT" -eq 0 ]]; then
  if [[ -z "$MESSAGE" ]]; then
    if git log -1 >/dev/null 2>&1; then
      MESSAGE="Update build scripts and patches"
    else
      MESSAGE="Stabileo 강의용 빌드 도구

Windows, macOS, Linux 배포본을 한 번에 만드는 빌드 스크립트와,
단계별 강성법 NaN 수정 / 한국어 활성화 / 텍스트 형식 입출력 패치."
    fi
  fi
  git commit -q -m "$MESSAGE"
  ok "$(git log -1 --format='%h %s' | head -1)"
else
  ok "커밋할 변경이 없어 건너뜁니다."
fi

# ─── 7. 저장소 생성 또는 push ────────────────────────────────────────

step "GitHub 에 올리기"

if git remote get-url origin >/dev/null 2>&1; then
  ok "기존 remote 사용: $(git remote get-url origin)"
  git push -u origin HEAD
elif gh repo view "${GH_USER}/${REPO_NAME}" >/dev/null 2>&1; then
  warn "같은 이름의 저장소가 이미 있습니다. 거기에 연결합니다."
  git remote add origin "https://github.com/${GH_USER}/${REPO_NAME}.git"
  git push -u origin HEAD
else
  gh repo create "$REPO_NAME" \
    --"$VISIBILITY" \
    --source=. \
    --remote=origin \
    --push \
    --description "Stabileo 강의용 빌드 도구 — Windows/macOS/Linux 오프라인 배포본 생성"
  ok "저장소 생성 및 push 완료"
fi

URL="https://github.com/${GH_USER}/${REPO_NAME}"

# ─── 8. 마무리 ───────────────────────────────────────────────────────

printf '\n\033[1;32m━━━ 완료 ━━━\033[0m\n\n'
echo "  $URL"
echo
echo "  학생 배포본의 라이선스안내.txt 에 이 주소를 함께 적어 두면"
echo "  AGPL 의 소스 제공 의무가 충족됩니다."
echo
echo "  다음부터는 파일을 고친 뒤 이 스크립트를 다시 실행하면"
echo "  변경분만 올라갑니다."
echo
