#!/usr/bin/env bash
#
# Stabileo 배포 패키지 빌드 스크립트 (윈도 / macOS / 리눅스)
# 리눅스 또는 macOS 에서 실행하여 학생 배포용 패키지를 생성합니다.
#
# 사용법:
#   ./build-stabileo.sh                       세 OS 모두
#   ./build-stabileo.sh --os win              윈도만
#   ./build-stabileo.sh --os mac              macOS만
#   ./build-stabileo.sh --os linux            리눅스만
#   ./build-stabileo.sh --os win,linux        여러 개는 쉼표로 구분
#   ./build-stabileo.sh --commit abc1234      특정 커밋으로 고정
#   ./build-stabileo.sh --wasm                Rust/WASM 솔버 빌드 (필수)
#   ./build-stabileo.sh --wasm-cache ~/wasm   WASM 결과물 보관/재사용 (Rust 불필요)
#   ./build-stabileo.sh --no-wasm             솔버 없이 빌드 (해석 불가, 화면 확인용)
#   ./build-stabileo.sh --sign "Developer ID Application: ..."   (macOS 호스트 전용)
#   ./build-stabileo.sh --no-patches          소스 패치 없이 원본 그대로 빌드
#   ./build-stabileo.sh --keep                작업 폴더 유지
#
# 필요: git, node>=18, npm, go>=1.20, zip, tar
# 불필요: wine, 윈도 머신
# macOS 호스트: lipo 와 codesign 이 기본 제공되어 임시 서명까지 자동 적용됩니다.
# 리눅스 호스트: llvm-lipo 설치를 권장합니다 (유니버설 바이너리).

set -euo pipefail

# 스크립트가 놓인 폴더. 반드시 여기서 한 번 확정해야 한다.
# 아래에서 pushd 로 작업 디렉터리를 옮기기 때문에, 나중에 계산하면
# './build-stabileo.sh' 로 실행했을 때 dirname 이 돌려주는 '.' 이
# 엉뚱한 폴더를 가리키게 된다.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── 설정 ────────────────────────────────────────────────────────────

REPO_URL="https://github.com/lambdaclass/stabileo.git"
WORK_DIR="${PWD}/stabileo-build"
PKG_NAME="Stabileo"
BUNDLE_ID="org.stabileo.local"
PORT_FIRST=8099
PORT_LAST=8110

COMMIT=""
TARGET_OS="all"
BUILD_WASM=0
WASM_CACHE=""
KEEP_WORK=0
SIGN_ID=""
PATCHES=1
STRIP_TURNSTILE=1
NO_WASM=0

# ─── 인자 처리 ───────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
  case "$1" in
    --os)     TARGET_OS="${2:?--os 뒤에 win, mac, both 중 하나가 필요합니다}"; shift 2 ;;
    --commit) COMMIT="${2:?--commit 뒤에 커밋 해시가 필요합니다}"; shift 2 ;;
    --wasm)   BUILD_WASM=1; shift ;;
    --wasm-cache) WASM_CACHE="${2:?--wasm-cache 뒤에 폴더 경로가 필요합니다}"; BUILD_WASM=1; shift 2 ;;
    --keep)   KEEP_WORK=1; shift ;;
    --no-wasm) NO_WASM=1; shift ;;
    --no-patches) PATCHES=0; shift ;;
    --sign)   SIGN_ID="${2:?--sign 뒤에 서명 ID 가 필요합니다 (임시 서명은 - )}"; shift 2 ;;
    --online) STRIP_TURNSTILE=0; shift ;;
    -h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "알 수 없는 옵션: $1  (--help 참고)" >&2; exit 1 ;;
  esac
done

# 솔버 없는 빌드는 실수로 나오면 안 된다. 빌드도 성공하고 편집기도 열리며
# 해석 버튼에서만 실패하므로, 배포한 뒤에야 알게 된다 (인수인계 §5.1).
# 그래서 --wasm / --wasm-cache 가 없으면 여기서 멈추고, 정말 원할 때만
# --no-wasm 으로 고르게 한다.
if [[ "$BUILD_WASM" -eq 0 && "$NO_WASM" -eq 0 ]]; then
  cat >&2 <<'MSG'
✗ 솔버 WASM 을 어떻게 할지 지정하지 않았습니다.

  WASM 없이 빌드하면 빌드는 성공하고 편집기도 열리지만, 해석 버튼을
  누르는 순간 "WASM solver not initialized" 로 실패합니다. JS 폴백
  솔버는 존재하지 않습니다.

  둘 중 하나를 고르세요.

    --wasm-cache <폴더>    보관해 둔 솔버 재사용 (Rust 불필요, 빠름)
    --wasm                 솔버를 새로 컴파일 (rustup 필요, 10~20분)

  화면만 확인할 목적이라면  --no-wasm  을 쓰세요.
MSG
  exit 1
fi
if [[ "$NO_WASM" -eq 1 ]]; then
  BUILD_WASM=0
fi

BUILD_WIN=0; BUILD_MAC=0; BUILD_LINUX=0

IFS=',' read -ra _os_list <<< "$TARGET_OS"
for _o in ${_os_list[@]+"${_os_list[@]}"}; do
  case "${_o// /}" in
    all|both) BUILD_WIN=1; BUILD_MAC=1; BUILD_LINUX=1 ;;
    win|windows) BUILD_WIN=1 ;;
    mac|macos|darwin) BUILD_MAC=1 ;;
    linux) BUILD_LINUX=1 ;;
    "") ;;
    *) echo "--os 값이 올바르지 않습니다: ${_o}" >&2
       echo "사용 가능: win, mac, linux, all (쉼표로 여러 개 지정 가능)" >&2
       exit 1 ;;
  esac
done

if [[ $((BUILD_WIN + BUILD_MAC + BUILD_LINUX)) -eq 0 ]]; then
  echo "빌드할 대상이 없습니다. --os 를 확인하세요." >&2; exit 1
fi

# ─── 출력 도우미 ─────────────────────────────────────────────────────

step()  { printf '\n\033[1;36m▶ %s\033[0m\n' "$*"; }
ok()    { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn()  { printf '  \033[33m!\033[0m %s\n' "$*"; }
die()   { printf '\n\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

# ─── 호스트 OS 판별 ──────────────────────────────────────────────────
# 이 스크립트는 리눅스와 macOS 어느 쪽에서도 실행할 수 있다.
# 두 환경의 차이는 여기서 흡수하고, 이후 로직은 동일하게 둔다.

HOST_OS="$(uname -s)"
case "$HOST_OS" in
  Linux)  HOST_LABEL="Linux" ;;
  Darwin) HOST_LABEL="macOS" ;;
  *)      HOST_LABEL="$HOST_OS"
          echo "경고: 검증되지 않은 호스트 OS 입니다 ($HOST_OS)" >&2 ;;
esac

# BSD sed 는 -i 에 백업 접미사를 반드시 요구한다. GNU sed 는 받지 않는다.
sedi() {
  if [[ "$HOST_OS" == "Darwin" ]]; then
    sed -i '' "$@"
  else
    sed -i "$@"
  fi
}

# 패키지 설치 안내도 호스트에 맞춰 바꾼다.
pkg_hint() { # $1=패키지명
  if [[ "$HOST_OS" == "Darwin" ]]; then
    echo "brew install $1"
  else
    echo "sudo apt install $1"
  fi
}

# ─── 사전 점검 ───────────────────────────────────────────────────────

step "필수 도구 확인"

ok "호스트: ${HOST_LABEL} ($(uname -m))"

for cmd in git node npm go; do
  command -v "$cmd" >/dev/null 2>&1 || die "$cmd 이(가) 설치되어 있지 않습니다.
    $(pkg_hint "$cmd")"
done

NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
[[ "$NODE_MAJOR" -ge 18 ]] || die "Node.js 18 이상이 필요합니다. 현재: $(node -v)"
ok "node $(node -v)"
ok "go $(go version | awk '{print $3}')"

command -v zip >/dev/null 2>&1 || die "zip 이 필요합니다.
    $(pkg_hint zip)"
if [[ "$BUILD_LINUX" -eq 1 ]]; then
  command -v tar >/dev/null 2>&1 || die "tar 가 필요합니다."
fi

LIPO=""
CODESIGN=""
if [[ "$BUILD_MAC" -eq 1 ]]; then
  # macOS 에는 lipo 가 기본 포함(Xcode CLT)되고, 리눅스에서는 llvm-lipo 를 쓴다.
  for c in lipo llvm-lipo llvm-lipo-18 llvm-lipo-17 llvm-lipo-16; do
    if command -v "$c" >/dev/null 2>&1; then LIPO="$c"; break; fi
  done
  if [[ -n "$LIPO" ]]; then
    ok "$LIPO 발견 — 유니버설 바이너리를 생성합니다 (Intel + Apple Silicon)"
  elif [[ "$HOST_OS" == "Darwin" ]]; then
    warn "lipo 없음 — Xcode 명령행 도구를 설치하세요:  xcode-select --install"
    warn "우선 arm64 / Intel 을 별도 패키지로 만듭니다."
  else
    warn "llvm-lipo 없음 — arm64 / Intel 을 별도 패키지로 만듭니다."
    warn "권장:  $(pkg_hint llvm)"
  fi

  # 코드 서명은 macOS 에서만 가능하다. Apple Silicon 은 임시(ad-hoc) 서명이라도
  # 있어야 실행되므로, 맥에서 빌드할 때는 반드시 서명해 두는 편이 안전하다.
  if [[ "$HOST_OS" == "Darwin" ]] && command -v codesign >/dev/null 2>&1; then
    CODESIGN="codesign"
    [[ -z "$SIGN_ID" ]] && SIGN_ID="-"
    if [[ "$SIGN_ID" == "-" ]]; then
      ok "코드 서명: 임시(ad-hoc) 서명을 적용합니다"
    else
      ok "코드 서명: $SIGN_ID"
    fi
  elif [[ -n "$SIGN_ID" ]]; then
    warn "--sign 은 macOS 에서만 동작합니다. 무시합니다."
    SIGN_ID=""
  fi
fi

if [[ "$BUILD_WASM" -eq 1 ]]; then
  # 캐시가 준비되어 있으면 Rust 툴체인 자체가 필요 없다.
  USE_CACHE=0
  # .wasm 만 보면 안 된다. 로더가 실제로 import 하는 것은 wasm-pack 이
  # 함께 뽑는 JS 글루(dedaliano_engine.js)이고, 그것이 없으면 브라우저에서
  # 동적 import 가 실패해 해석 시점에야 드러난다.
  if [[ -n "$WASM_CACHE" && -d "$WASM_CACHE" ]] && compgen -G "$WASM_CACHE/*.wasm" >/dev/null 2>&1; then
    if ! compgen -G "$WASM_CACHE/*.js" >/dev/null 2>&1; then
      die "캐시가 반쪽입니다: $WASM_CACHE

  .wasm 은 있으나 JS 글루(*.js)가 없습니다. wasm-pack 출력 한 벌이
  통째로 있어야 합니다. 폴더를 다시 복사하거나 --wasm 으로 새로 빌드하세요."
    fi
    USE_CACHE=1
    ok "WASM 캐시 사용: $WASM_CACHE  (Rust 불필요)"
    if [[ -f "$WASM_CACHE/COMMIT" ]]; then
      _cc="$(cat "$WASM_CACHE/COMMIT")"
      ok "캐시 커밋: ${_cc:0:12}"
      if [[ -n "$COMMIT" && "${_cc:0:${#COMMIT}}" != "$COMMIT" ]]; then
        die "캐시와 --commit 이 다릅니다.

  캐시  ${_cc:0:12}
  요청  ${COMMIT}

  WASM 과 JS 글루 코드는 같은 커밋에서 나온 한 쌍이어야 합니다.
  어긋나면 오류 없이 잘못된 해석 결과가 나올 수 있습니다.

  --commit ${_cc:0:12} 로 맞추거나, --wasm 만 써서 새로 빌드하세요."
      fi
    else
      warn "캐시에 COMMIT 표식이 없습니다. 커밋 일치 여부를 직접 확인하세요."
    fi
  elif [[ -n "$WASM_CACHE" ]]; then
    warn "캐시 폴더가 비어 있습니다: $WASM_CACHE"
    warn "이번에 새로 빌드한 뒤 이 폴더에 저장합니다."
  fi
fi

if [[ "$BUILD_WASM" -eq 1 && "${USE_CACHE:-0}" -eq 0 ]]; then
  command -v cargo >/dev/null 2>&1 || die "--wasm 을 쓰려면 Rust 가 필요합니다. rustup 으로 설치하세요:
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    source \"\$HOME/.cargo/env\""

  # engine/rust-toolchain.toml 은 nightly 와 rust-src 를 요구한다.
  # 이 파일은 rustup 전용 규약이라, apt 로 설치한 cargo 는 무시하고
  # 배포판 기본 버전으로 빌드하다가 의존 크레이트에서 실패한다.
  if ! command -v rustup >/dev/null 2>&1; then
    die "rustup 이 없습니다. 현재 cargo: $(command -v cargo)

  배포판 패키지(apt install rustc cargo)로 설치된 Rust 는
  engine/rust-toolchain.toml 의 nightly 지정을 무시하기 때문에
  wasm-bindgen 계열 의존성 컴파일에서 실패합니다.

  다음으로 교체하세요:
    sudo apt remove rustc cargo
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    source \"\$HOME/.cargo/env\"
    cargo install wasm-pack"
  fi

  command -v wasm-pack >/dev/null 2>&1 || { warn "wasm-pack 설치 중..."; cargo install wasm-pack; }
  ok "rustup $(rustup --version 2>/dev/null | head -1 | awk '{print $2}')"
  ok "$(rustc --version)"

  # engine/.cargo/config.toml 이 호스트 타깃 링커를 clang + mold 로 지정한다.
  # WASM 과 무관해 보이지만, 빌드 스크립트와 proc-macro 크레이트는 호스트용으로
  # 컴파일되므로 이 링커가 없으면 전부 실패한다.
  # 없으면 설치를 요구하는 대신 해당 설정을 제거한다 (결과물에 영향 없음).
  PATCH_LINKER=0
  if ! command -v clang >/dev/null 2>&1 || ! command -v mold >/dev/null 2>&1; then
    PATCH_LINKER=1
    warn "clang / mold 없음 — 저장소의 호스트 링커 설정을 제거하고 기본 링커를 씁니다."
  else
    ok "링커 clang + mold 확인"
  fi
fi

# ─── 1. 소스 내려받기 ────────────────────────────────────────────────

step "GitHub 에서 소스 내려받기"

if [[ -d "$WORK_DIR/.git" ]]; then
  ok "기존 작업 폴더 재사용"
  # 앞선 빌드가 --commit 없이 돌았다면 이 폴더는 --depth 1 얕은 클론이다.
  # fetch --all 은 깊이를 늘리지 않으므로 옛 커밋을 체크아웃할 수 없다.
  if [[ -n "$COMMIT" ]] && [[ -f "$WORK_DIR/.git/shallow" ]]; then
    ok "얕은 클론을 전체 이력으로 넓히는 중..."
    git -C "$WORK_DIR" fetch --unshallow --quiet || git -C "$WORK_DIR" fetch --all --quiet
  fi
  git -C "$WORK_DIR" fetch --all --tags --quiet
  # 패치는 매번 깨끗한 트리를 전제한다. 앞선 빌드가 중간에 실패했다면
  # 수정된 파일이 남아 체크아웃을 막거나 조용히 얹혀 간다.
  git -C "$WORK_DIR" reset --hard --quiet HEAD
  git -C "$WORK_DIR" clean -fdq
else
  rm -rf "$WORK_DIR"
  if [[ -n "$COMMIT" ]]; then
    git clone --quiet "$REPO_URL" "$WORK_DIR"
  else
    git clone --quiet --depth 1 "$REPO_URL" "$WORK_DIR"
  fi
  ok "클론 완료"
fi

[[ -n "$COMMIT" ]] && { git -C "$WORK_DIR" checkout --quiet "$COMMIT" || die "커밋 $COMMIT 없음"; }

BUILD_COMMIT="$(git -C "$WORK_DIR" rev-parse HEAD)"
BUILD_DATE="$(date +%Y-%m-%d)"
STAMP="$(date +%Y%m%d)"
ok "빌드 기준 커밋: ${BUILD_COMMIT:0:12}"

[[ -f "$WORK_DIR/web/package.json" ]] || die "저장소 구조가 예상과 다릅니다."

# ─── 2~4. 웹 앱 빌드 ─────────────────────────────────────────────────

step "npm 의존성 설치"
pushd "$WORK_DIR/web" >/dev/null
if [[ -f package-lock.json ]]; then
  npm ci --no-audit --no-fund 2>&1 | tail -2 || npm install --no-audit --no-fund 2>&1 | tail -2
else
  npm install --no-audit --no-fund 2>&1 | tail -2
fi
ok "설치 완료"

WASM_OUT="$WORK_DIR/web/src/lib/wasm"

if [[ "$BUILD_WASM" -eq 1 && "${USE_CACHE:-0}" -eq 1 ]]; then
  step "WASM 캐시 복원"
  mkdir -p "$WASM_OUT"
  cp -r "$WASM_CACHE"/. "$WASM_OUT"/
  rm -f "$WASM_OUT/COMMIT"
  ok "복원 완료: $(find "$WASM_OUT" -name '*.wasm' | wc -l) 개 wasm 파일"

elif [[ "$BUILD_WASM" -eq 1 ]]; then
  # 호스트 링커 지정 제거. build-std 등 나머지 설정은 반드시 보존한다.
  # build-std 는 WASM 에서 Instant::now() 패닉을 막는 설정이라 지우면 안 된다.
  ENGINE_CARGO="$WORK_DIR/engine/.cargo/config.toml"
  if [[ "$PATCH_LINKER" -eq 1 && -f "$ENGINE_CARGO" ]]; then
    if grep -q '^\[target\.x86_64-unknown-linux-gnu\]' "$ENGINE_CARGO"; then
      cp "$ENGINE_CARGO" "$ENGINE_CARGO.orig"
      awk '
        /^\[target\.x86_64-unknown-linux-gnu\]/ { skip=1; next }
        /^\[/ { skip=0 }
        !skip
      ' "$ENGINE_CARGO.orig" > "$ENGINE_CARGO"
      ok "호스트 링커 설정 제거 (원본: config.toml.orig)"
      if ! grep -q 'build-std' "$ENGINE_CARGO"; then
        die "패치 중 build-std 설정이 사라졌습니다. $ENGINE_CARGO.orig 로 복구하세요."
      fi
    fi
  fi

  step "Rust/WASM 솔버 빌드 (첫 빌드는 10~20분 소요)"
  WASM_LOG="${WORK_DIR}/wasm-build.log"
  set +e
  npm run wasm 2>&1 | tee "$WASM_LOG"
  _rc=${PIPESTATUS[0]}
  set -e
  if [[ "$_rc" -ne 0 ]]; then
    die "WASM 빌드 실패 (전체 로그: $WASM_LOG)

  위 출력에서 첫 번째 error 줄을 확인하세요. 자주 나오는 원인:

  · linker `clang` / `mold` not found
      → engine/.cargo/config.toml 의 [target.x86_64-unknown-linux-gnu]
        블록을 지우거나, sudo apt install clang mold
  · rustversion / wasm-bindgen 컴파일 실패
      → Rust 버전이 낮습니다.  rustup update
  · 그 밖의 linker 관련 오류
      → sudo apt install build-essential
  · wasm32-unknown-unknown 타깃 없음
      → rustup target add wasm32-unknown-unknown"
  fi
  ok "WASM 솔버 빌드 완료"

  # 다음 빌드에서 Rust 없이 재사용할 수 있도록 결과물을 보관한다.
  if [[ -n "$WASM_CACHE" ]]; then
    mkdir -p "$WASM_CACHE"
    cp -r "$WASM_OUT"/. "$WASM_CACHE"/
    echo "$BUILD_COMMIT" > "$WASM_CACHE/COMMIT"
    ok "WASM 캐시 저장: $WASM_CACHE ($(du -sh "$WASM_CACHE" | cut -f1))"
    ok "다음부터는  --wasm-cache $WASM_CACHE --commit ${BUILD_COMMIT:0:12}"
  fi
else
  warn "WASM 없이 빌드합니다."
  warn "해석 기능이 동작하지 않습니다. 편집기만 열립니다."
  warn "실제 사용하려면 --wasm 이 반드시 필요합니다."
fi

# ── 텍스트 입출력 기능 추가 ──────────────────────────────────────────
# 저장소를 매번 새로 클론하므로 UI 수정은 여기서 다시 적용한다.

# ── 패치 적용 ────────────────────────────────────────────────────────
# 저장소를 매번 새로 클론하므로 소스 수정은 여기서 다시 적용한다.
# 스크립트와 같은 폴더의 apply-*.sh 를 이름 순으로 모두 실행한다.
# 각 패치는 저장소 경로를 인자로 받고, 재실행해도 안전해야 한다.

if [[ "$PATCHES" -eq 1 ]]; then
  _patches=()
  for _p in "$SCRIPT_DIR"/apply-*.sh; do
    [[ -f "$_p" ]] && _patches+=("$_p")
  done

  if [[ ${#_patches[@]} -gt 0 ]]; then
    step "소스 패치 적용 (${#_patches[@]}개)"
    for _p in "${_patches[@]}"; do
      printf '\n  \033[1m%s\033[0m\n' "$(basename "$_p")"
      bash "$_p" "$WORK_DIR" || die "패치 실패: $(basename "$_p")"
    done
  else
    warn "적용할 패치가 없습니다. 찾은 위치: $SCRIPT_DIR"
    warn "apply-*.sh 를 이 스크립트와 같은 폴더에 두세요."
  fi
fi

step "웹 앱 빌드"
npm run build:only 2>&1 | tail -3
[[ -f dist/index.html ]] || die "dist/index.html 이 생성되지 않았습니다."

# WASM 이 실제로 번들에 들어갔는지 확인한다. 이 검사가 없으면
# 해석이 안 되는 패키지를 만들어 배포한 뒤에야 알게 된다.
if [[ "$BUILD_WASM" -eq 1 ]]; then
  if ! find dist -name "*.wasm" | grep -qv "web-ifc"; then
    die "솔버 WASM 이 dist 에 포함되지 않았습니다.
  src/lib/wasm/ 생성 여부와 위 빌드 로그를 확인하세요."
  fi
  ok "솔버 WASM 번들 확인"
else
  warn "솔버 WASM 없이 빌드했습니다 (--no-wasm). 이 배포본은 해석할 수 없습니다."
fi
ok "dist 생성: $(du -sh dist | cut -f1)"
popd >/dev/null

# 외부 CDN 스크립트 제거 (원본 dist 에서 한 번만)
if [[ "$STRIP_TURNSTILE" -eq 1 ]] && grep -q 'challenges\.cloudflare\.com' "$WORK_DIR/web/dist/index.html" 2>/dev/null; then
  sedi '/challenges\.cloudflare\.com/d' "$WORK_DIR/web/dist/index.html"
  ok "외부 CDN 스크립트 제거 (완전 오프라인 동작)"
fi

# ─── 5. 서버 소스 생성 ───────────────────────────────────────────────

step "정적 서버 크로스 컴파일"

SRC_DIR="$(mktemp -d)"

cat > "$SRC_DIR/server.go" <<'GOEOF'
// Stabileo 로컬 실행용 정적 서버.
// 실행 파일 옆의 dist 또는 macOS 앱 번들의 Contents/Resources/dist 를 서빙하고,
// 준비되면 브라우저를 자동으로 연다.
package main

import (
	"fmt"
	"log"
	"mime"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"
)

const (
	firstPort = __PORT_FIRST__
	lastPort  = __PORT_LAST__
)

// dist 폴더를 찾는다. 일반 폴더 배포와 macOS 앱 번들 양쪽을 지원한다.
func findDist() (string, error) {
	exe, err := os.Executable()
	if err != nil {
		return "", err
	}
	if resolved, err := filepath.EvalSymlinks(exe); err == nil {
		exe = resolved
	}
	dir := filepath.Dir(exe)

	candidates := []string{
		filepath.Join(dir, "dist"),                     // 폴더 배포 (윈도)
		filepath.Join(dir, "..", "Resources", "dist"),  // macOS .app 번들
		filepath.Join(dir, "..", "..", "dist"),         // 예비
	}
	for _, c := range candidates {
		if st, err := os.Stat(filepath.Join(c, "index.html")); err == nil && !st.IsDir() {
			return filepath.Clean(c), nil
		}
	}
	return "", fmt.Errorf("dist 폴더를 찾을 수 없습니다 (실행 위치: %s)", dir)
}

// 브라우저를 연다. 크롬 계열이 있으면 주소창 없는 앱 모드로 연다.
func openBrowser(url string) {
	switch runtime.GOOS {
	case "darwin":
		// open -a 는 앱이 없어도 open 자체는 실행되므로 Start() 로는
		// 실패를 알 수 없다. 윈도와 동일하게 실행 파일 존재를 먼저 본다.
		for _, p := range []string{
			"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
			"/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
			"/Applications/Brave Browser.app/Contents/MacOS/Brave Browser",
			os.Getenv("HOME") + "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
		} {
			if _, err := os.Stat(p); err == nil {
				if err := exec.Command(p, "--app="+url).Start(); err == nil {
					return
				}
			}
		}
		// 크롬 계열이 없으면 기본 브라우저(주로 Safari)로 연다.
		_ = exec.Command("open", url).Start()
	case "windows":
		for _, p := range []string{
			os.Getenv("ProgramFiles(x86)") + `\Microsoft\Edge\Application\msedge.exe`,
			os.Getenv("ProgramFiles") + `\Google\Chrome\Application\chrome.exe`,
			os.Getenv("ProgramFiles(x86)") + `\Google\Chrome\Application\chrome.exe`,
		} {
			if _, err := os.Stat(p); err == nil {
				_ = exec.Command(p, "--app="+url).Start()
				return
			}
		}
		_ = exec.Command("rundll32", "url.dll,FileProtocolHandler", url).Start()
	default:
		_ = exec.Command("xdg-open", url).Start()
	}
}

func main() {
	base, err := findDist()
	if err != nil {
		log.Fatal(err)
	}
	index := filepath.Join(base, "index.html")

	// 윈도와 일부 환경은 MIME 을 시스템에서 읽으므로 .wasm 이 누락될 수 있다.
	// 타입이 틀리면 WASM 로딩이 실패한다.
	mime.AddExtensionType(".wasm", "application/wasm")
	mime.AddExtensionType(".js", "text/javascript")
	mime.AddExtensionType(".mjs", "text/javascript")
	mime.AddExtensionType(".css", "text/css")
	mime.AddExtensionType(".svg", "image/svg+xml")
	mime.AddExtensionType(".woff2", "font/woff2")
	mime.AddExtensionType(".json", "application/json")

	files := http.FileServer(http.Dir(base))

	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		clean := filepath.Clean(strings.TrimPrefix(r.URL.Path, "/"))
		target := filepath.Join(base, clean)

		if !strings.HasPrefix(target, base) {
			http.Error(w, "잘못된 경로입니다", http.StatusBadRequest)
			return
		}

		// build:only 는 프리렌더를 하지 않으므로 /pro, /educativo 가
		// 파일로 존재하지 않는다. 확장자 없는 경로는 index.html 로 폴백한다.
		if info, err := os.Stat(target); err != nil || info.IsDir() {
			if r.URL.Path != "/" && filepath.Ext(clean) != "" {
				http.NotFound(w, r)
				return
			}
			w.Header().Set("Content-Type", "text/html; charset=utf-8")
			http.ServeFile(w, r, index)
			return
		}
		files.ServeHTTP(w, r)
	})

	for port := firstPort; port <= lastPort; port++ {
		addr := fmt.Sprintf("127.0.0.1:%d", port)
		ln, err := net.Listen("tcp", addr)
		if err != nil {
			continue // 포트 사용 중
		}
		url := "http://" + addr
		fmt.Printf("Stabileo 실행 중 →  %s\n", url)
		fmt.Println("이 창을 닫으면 프로그램이 종료됩니다.")

		go func() {
			time.Sleep(400 * time.Millisecond)
			openBrowser(url)
		}()

		log.Fatal(http.Serve(ln, handler))
	}

	log.Fatalf("%d~%d 포트가 모두 사용 중입니다.", firstPort, lastPort)
}
GOEOF

sedi "s/__PORT_FIRST__/$PORT_FIRST/; s/__PORT_LAST__/$PORT_LAST/" "$SRC_DIR/server.go"

cat > "$SRC_DIR/go.mod" <<'MODEOF'
module stabileo-server

go 1.20
MODEOF

gobuild() { # $1=GOOS $2=GOARCH $3=출력경로
  ( cd "$SRC_DIR" && GOOS="$1" GOARCH="$2" CGO_ENABLED=0 \
      go build -ldflags="-s -w" -o "$3" server.go )
}

# ─── 공통 문서 생성 함수 ─────────────────────────────────────────────

write_license_notice() { # $1=대상폴더
  cat > "$1/라이선스안내.txt" <<TXTEOF
AGPL-3.0 라이선스 고지
====================================

이 프로그램은 아래 오픈소스 프로젝트를 빌드한 것입니다.

  프로젝트   Stabileo
  원본 주소   https://github.com/lambdaclass/stabileo
  빌드 커밋   ${BUILD_COMMIT}
  빌드 일자   ${BUILD_DATE}

GNU Affero General Public License v3.0 에 따라 배포되며,
대응 소스코드는 위 주소에서 해당 커밋으로 받을 수 있습니다.

  git clone https://github.com/lambdaclass/stabileo.git
  cd stabileo
  git checkout ${BUILD_COMMIT}

라이선스 전문은 LICENSE 파일에 있습니다.
제3자 구성요소 고지는 dist/third-party-notices.txt 를 참고하세요.

* 소스를 수정하여 배포하는 경우, 수정된 소스코드도 함께
  제공해야 라이선스 의무를 충족합니다.
TXTEOF
}

write_usage_common() { # $1=대상파일 (append)
  cat >> "$1" <<TXTEOF

[ 파일 저장과 열기 ]

  저장   Ctrl(⌘)+S          현재 탭을 .ded 파일로 저장
  세션   Ctrl(⌘)+Shift+S    열려 있는 모든 탭을 한 파일로 저장
  열기   Ctrl(⌘)+O          .ded 불러오기 (단일/세션 자동 인식)

  * 모델 이름은 영문과 숫자로 지정하세요. 파일 이름 생성 시
    한글이 제거되어 모두 같은 이름이 됩니다.
    예) 2026-1_hw3_202512345

  * 파일을 창에 끌어다 놓는 방식은 DXF 만 지원합니다.
    .ded 는 반드시 열기 명령을 사용하세요.

[ 결과 내보내기 ]

  화면 왼쪽 위, 저장 아이콘 바로 왼쪽의 문서 모양 아이콘을 누르면
  오른쪽 패널이 열립니다. "내보내기 / 가져오기" 항목에서
  Excel, PDF, DXF, SVG, PNG, CSV 로 내보낼 수 있습니다.

  PNG 는 화면에 보이는 그대로 캡처됩니다. 해석을 먼저 실행하고
  원하는 선도를 표시한 뒤 내보내세요. 창을 크게 할수록 해상도가
  올라갑니다. 보고서 삽입용으로는 확대해도 깨지지 않는 SVG 를
  권장합니다. (SVG 와 DXF 는 2D 모드 전용)

[ 참고 ]

  단축키가 안 먹으면 입력란에 커서가 있는 경우입니다.
  캔버스를 한 번 클릭한 뒤 다시 시도하세요.

  서버는 내 컴퓨터(127.0.0.1)에만 열리며 외부에서 접근할 수 없습니다.

[ 라이선스 ]

  이 프로그램은 Stabileo 를 빌드한 것으로 AGPL-3.0 을 따릅니다.
  LICENSE 및 라이선스안내.txt 를 참고하세요.
TXTEOF
}

# ─── 6. 윈도 패키지 ──────────────────────────────────────────────────

if [[ "$BUILD_WIN" -eq 1 ]]; then
  step "윈도 패키지 조립"

  WOUT="${PWD}/${PKG_NAME}-win"
  rm -rf "$WOUT"; mkdir -p "$WOUT"

  gobuild windows amd64 "$WOUT/server.exe"
  ok "server.exe ($(du -h "$WOUT/server.exe" | cut -f1))"

  cp -r "$WORK_DIR/web/dist" "$WOUT/"
  [[ -f "$WORK_DIR/LICENSE" ]] && cp "$WORK_DIR/LICENSE" "$WOUT/"
  write_license_notice "$WOUT"

  # 서버가 브라우저를 직접 열므로 배치 파일은 실행만 담당한다.
  cat > "$WOUT/${PKG_NAME} 실행.bat" <<BATEOF
@echo off
chcp 65001 >nul
cd /d "%~dp0"
start "" /min server.exe
exit
BATEOF
  sedi 's/$/\r/' "$WOUT/${PKG_NAME} 실행.bat"

  cat > "$WOUT/읽어보세요.txt" <<TXTEOF
${PKG_NAME} — 구조해석 프로그램 (Windows)
====================================

[ 실행 방법 ]

  "${PKG_NAME} 실행.bat" 을 더블클릭하세요.
  설치 과정이 없고 관리자 권한도 필요 없습니다.
  브라우저 창과 검은 서버 창을 모두 닫으면 종료됩니다.

  * 방화벽 경고가 뜨면 "취소" 를 눌러도 정상 동작합니다.
  * 화면이 하얗게 뜨면 dist 폴더가 server.exe 와 같은 위치에
    있는지 확인하세요.
TXTEOF
  write_usage_common "$WOUT/읽어보세요.txt"
  sedi 's/Ctrl(⌘)/Ctrl/g' "$WOUT/읽어보세요.txt"

  WZIP="${PKG_NAME}-${STAMP}-windows.zip"
  rm -f "$WZIP"
  ( cd "$(dirname "$WOUT")" && mv "$(basename "$WOUT")" "$PKG_NAME" \
    && zip -rq "$WZIP" "$PKG_NAME" && mv "$PKG_NAME" "$(basename "$WOUT")" )
  ok "$WZIP ($(du -h "$WZIP" | cut -f1))"
fi

# ─── 7. macOS 패키지 ─────────────────────────────────────────────────

if [[ "$BUILD_MAC" -eq 1 ]]; then
  step "macOS 앱 번들 조립"

  MOUT="${PWD}/${PKG_NAME}-mac"
  rm -rf "$MOUT"; mkdir -p "$MOUT"

  APP="$MOUT/${PKG_NAME}.app"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

  # .app 번들은 정해진 구조의 폴더일 뿐이라 리눅스에서도 만들 수 있다.
  # Apple Silicon 맥에 Intel 바이너리를 주면 Rosetta 경고가 뜨므로,
  # lipo 가 없더라도 arm64 를 반드시 네이티브로 제공한다.
  if [[ -n "$LIPO" ]]; then
    gobuild darwin amd64 "$SRC_DIR/mac-amd64"
    gobuild darwin arm64 "$SRC_DIR/mac-arm64"
    "$LIPO" -create -output "$APP/Contents/MacOS/${PKG_NAME}" \
      "$SRC_DIR/mac-amd64" "$SRC_DIR/mac-arm64"
    ok "유니버설 바이너리 생성 (Intel + Apple Silicon 모두 네이티브)"
    MAC_VARIANTS=("universal")
  else
    gobuild darwin arm64 "$APP/Contents/MacOS/${PKG_NAME}"
    ok "arm64(Apple Silicon) 바이너리 생성"
    warn "llvm-lipo 가 없어 Intel 용을 별도 패키지로 만듭니다."
    warn "권장: apt install llvm  → 하나의 유니버설 패키지로 합쳐집니다."
    MAC_VARIANTS=("arm64" "intel")
  fi
  chmod +x "$APP/Contents/MacOS/${PKG_NAME}"

  cp -r "$WORK_DIR/web/dist" "$APP/Contents/Resources/"

  cat > "$APP/Contents/Info.plist" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>${PKG_NAME}</string>
	<key>CFBundleDisplayName</key>
	<string>${PKG_NAME}</string>
	<key>CFBundleExecutable</key>
	<string>${PKG_NAME}</string>
	<key>CFBundleIdentifier</key>
	<string>${BUNDLE_ID}</string>
	<key>CFBundleVersion</key>
	<string>${STAMP}</string>
	<key>CFBundleShortVersionString</key>
	<string>${BUILD_DATE}</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>LSMinimumSystemVersion</key>
	<string>10.15</string>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
PLISTEOF

  [[ -f "$WORK_DIR/LICENSE" ]] && cp "$WORK_DIR/LICENSE" "$MOUT/"
  write_license_notice "$MOUT"

  # Gatekeeper 격리 속성 해제용 도우미 스크립트
  cat > "$MOUT/처음 한 번만 실행.command" <<'CMDEOF'
#!/bin/bash
cd "$(dirname "$0")"
echo "Stabileo 실행 준비 중..."
xattr -dr com.apple.quarantine ./Stabileo.app 2>/dev/null
echo ""
echo "완료되었습니다."
echo "이제 Stabileo.app 을 더블클릭해서 사용하세요."
echo ""
echo "이 창은 닫으셔도 됩니다."
CMDEOF
  chmod +x "$MOUT/처음 한 번만 실행.command"

  cat > "$MOUT/읽어보세요.txt" <<TXTEOF
${PKG_NAME} — 구조해석 프로그램 (macOS)
====================================

[ 처음 한 번만 — 중요 ]

  이 프로그램은 Apple 개발자 서명이 없어 macOS 가 실행을 막습니다.
  아래 중 한 가지 방법으로 한 번만 허용해 주세요.

  방법 1 (권장)
    "처음 한 번만 실행.command" 를 더블클릭합니다.
    터미널 창이 열리고 몇 초 뒤 완료 메시지가 나옵니다.
    이 파일도 차단된다면 방법 2 를 사용하세요.

  방법 2
    Stabileo.app 을 더블클릭 → 차단 경고가 뜸 → 확인을 누른 뒤
    시스템 설정 → 개인정보 보호 및 보안 → 아래로 스크롤 →
    "Stabileo 을(를) 그래도 열기" 버튼을 누릅니다.

  한 번 허용하면 이후로는 그냥 더블클릭으로 실행됩니다.

[ 실행 방법 ]

  Stabileo.app 을 더블클릭하세요.
  잠시 후 브라우저가 자동으로 열립니다.
  종료하려면 브라우저 창을 닫고, 상단 메뉴 막대나 Dock 에서
  Stabileo 를 종료하세요.

  응용 프로그램 폴더로 옮겨서 사용해도 됩니다.
TXTEOF
  write_usage_common "$MOUT/읽어보세요.txt"
  sedi 's/Ctrl(⌘)/⌘/g' "$MOUT/읽어보세요.txt"

  MZIPS=()
  for _v in ${MAC_VARIANTS[@]+"${MAC_VARIANTS[@]}"}; do
    if [[ "$_v" == "intel" ]]; then
      # arm64 패키지를 복제해 실행 파일만 Intel 용으로 교체한다.
      gobuild darwin amd64 "$APP/Contents/MacOS/${PKG_NAME}"
      chmod +x "$APP/Contents/MacOS/${PKG_NAME}"
      MZIP="${PKG_NAME}-${STAMP}-macos-intel.zip"
    elif [[ "$_v" == "arm64" ]]; then
      MZIP="${PKG_NAME}-${STAMP}-macos-applesilicon.zip"
    else
      MZIP="${PKG_NAME}-${STAMP}-macos.zip"
    fi
    # Apple Silicon 은 서명 없는 바이너리를 실행하지 않는다. 맥에서 빌드할 때는
    # 임시 서명이라도 반드시 붙여야 "손상된 파일" 오류를 피할 수 있다.
    if [[ -n "$CODESIGN" ]]; then
      "$CODESIGN" --force --deep --sign "$SIGN_ID" "$APP" >/dev/null 2>&1 \
        && ok "서명 완료 ($_v)" \
        || warn "서명 실패 ($_v) — 학생 PC 에서 실행이 막힐 수 있습니다."
    fi

    rm -f "$MZIP"
    # -y 로 심볼릭 링크를 보존하고, 맥에서 만든 부산물은 제외한다.
    ( cd "$(dirname "$MOUT")" && mv "$(basename "$MOUT")" "$PKG_NAME" \
      && zip -ryq "$MZIP" "$PKG_NAME" -x '*.DS_Store' '*__MACOSX*' \
      && mv "$PKG_NAME" "$(basename "$MOUT")" )
    MZIPS+=("$MZIP")
    ok "$MZIP ($(du -h "$MZIP" | cut -f1))"
  done
fi

# ─── 8. 리눅스 패키지 ────────────────────────────────────────────────

if [[ "$BUILD_LINUX" -eq 1 ]]; then
  step "리눅스 패키지 조립"

  LZIPS=()

  for LARCH in amd64 arm64; do
    LOUT="${PWD}/${PKG_NAME}-linux-${LARCH}"
    rm -rf "$LOUT"; mkdir -p "$LOUT"

    gobuild linux "$LARCH" "$LOUT/stabileo"
    chmod +x "$LOUT/stabileo"

    cp -r "$WORK_DIR/web/dist" "$LOUT/"
    [[ -f "$WORK_DIR/LICENSE" ]] && cp "$WORK_DIR/LICENSE" "$LOUT/"
    write_license_notice "$LOUT"

    # 데스크톱 환경 메뉴에 등록하는 선택적 스크립트.
    # Exec 경로가 설치 위치에 따라 달라지므로 실행 시점에 생성한다.
    cat > "$LOUT/바로가기 등록.sh" <<'DESKEOF'
#!/usr/bin/env bash
# 데스크톱 메뉴에 Stabileo 를 등록합니다. 관리자 권한이 필요 없습니다.
set -e
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPS="$HOME/.local/share/applications"
mkdir -p "$APPS"

cat > "$APPS/stabileo.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Stabileo
GenericName=Structural Analysis
Comment=구조해석 프로그램
Exec="$DIR/stabileo"
Path=$DIR
Terminal=true
Categories=Education;Science;Engineering;
Keywords=structural;analysis;fem;beam;frame;
EOF

chmod +x "$APPS/stabileo.desktop"
command -v update-desktop-database >/dev/null 2>&1 && \
  update-desktop-database "$APPS" 2>/dev/null || true

echo "등록되었습니다."
echo "응용 프로그램 메뉴에서 Stabileo 를 찾을 수 있습니다."
echo "(메뉴에 바로 안 보이면 로그아웃 후 다시 로그인하세요)"
DESKEOF
    chmod +x "$LOUT/바로가기 등록.sh"

    cat > "$LOUT/읽어보세요.txt" <<TXTEOF
${PKG_NAME} — 구조해석 프로그램 (Linux ${LARCH})
====================================

[ 실행 방법 ]

  터미널에서 압축을 푼 폴더로 이동한 뒤 실행합니다.

    ./stabileo

  잠시 후 기본 브라우저가 자동으로 열립니다.
  터미널에서 Ctrl+C 를 누르거나 터미널 창을 닫으면 종료됩니다.

  파일 관리자에서 더블클릭으로 실행하고 싶다면
  "바로가기 등록.sh" 를 한 번 실행해 메뉴에 등록하세요.

[ 실행 권한이 없다는 오류가 나면 ]

  압축 해제 과정에서 권한이 사라진 경우입니다.

    chmod +x stabileo

  를 실행한 뒤 다시 시도하세요.

[ 아키텍처 ]

  이 패키지는 ${LARCH} 용입니다.
  현재 시스템 확인:  uname -m
    x86_64  → amd64 패키지
    aarch64 → arm64 패키지
TXTEOF
    write_usage_common "$LOUT/읽어보세요.txt"
    sedi 's/Ctrl(⌘)/Ctrl/g' "$LOUT/읽어보세요.txt"

    # tar.gz 를 쓰는 이유: 실행 권한을 확실히 보존한다.
    LTAR="${PKG_NAME}-${STAMP}-linux-${LARCH}.tar.gz"
    rm -f "$LTAR"
    ( cd "$(dirname "$LOUT")" && mv "$(basename "$LOUT")" "$PKG_NAME" \
      && tar czf "$LTAR" "$PKG_NAME" && mv "$PKG_NAME" "$(basename "$LOUT")" )
    LZIPS+=("$LTAR")
    ok "$LTAR ($(du -h "$LTAR" | cut -f1))"
  done
fi

# ─── 정리 ────────────────────────────────────────────────────────────

rm -rf "$SRC_DIR"
[[ "$KEEP_WORK" -eq 0 ]] && rm -rf "$WORK_DIR" || warn "작업 폴더 유지: $WORK_DIR"

# ─── 완료 ────────────────────────────────────────────────────────────

printf '\n\033[1;32m━━━ 빌드 완료 ━━━\033[0m\n\n'
[[ "$BUILD_WIN" -eq 1 ]] && printf '  Windows   %s\n' "${WZIP}"
if [[ "$BUILD_MAC" -eq 1 ]]; then
  for _t in ${MZIPS[@]+"${MZIPS[@]}"}; do printf '  macOS     %s\n' "$_t"; done
fi
if [[ "$BUILD_LINUX" -eq 1 ]]; then
  for _t in ${LZIPS[@]+"${LZIPS[@]}"}; do printf '  Linux     %s\n' "$_t"; done
fi
printf '  커밋      %s\n' "${BUILD_COMMIT:0:12}"
printf '  솔버      %s\n' "$([[ "$BUILD_WASM" -eq 1 ]] && echo 'Rust/WASM' || echo 'JavaScript')"
printf '\n  같은 버전으로 다시 빌드:\n    ./%s --commit %s\n\n' \
  "$(basename "$0")" "${BUILD_COMMIT:0:12}"

if [[ "$BUILD_MAC" -eq 1 ]]; then
  printf '  \033[33m※ macOS 는 서명이 없어 첫 실행 시 허용 절차가 필요합니다.\n'
  printf '     학생에게 "읽어보세요.txt" 를 꼭 안내하세요.\033[0m\n\n'
fi
