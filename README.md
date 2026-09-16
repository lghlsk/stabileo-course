# Stabileo 강의용 빌드 도구

학부 구조해석 강의에서 [Stabileo](https://github.com/lambdaclass/stabileo)를
오프라인 실행 파일로 배포하기 위한 빌드 스크립트와 패치 모음입니다.

리눅스 또는 macOS 한 대에서 **Windows · macOS · Linux 배포본을 한꺼번에**
만듭니다. 학생 PC에는 설치 과정도, 인터넷 연결도, 계정도 필요하지 않습니다.

---

## 빠른 시작

```bash
git clone https://github.com/<사용자명>/<저장소명>.git
cd <저장소명>
./build-stabileo.sh --wasm
```

처음 한 번은 Rust/WASM 솔버 컴파일 때문에 10~20분 걸립니다. 결과물을
보관해 두면 다음부터는 Rust 없이 2분이면 끝납니다.

```bash
./build-stabileo.sh --wasm-cache ~/stabileo-wasm --commit <커밋해시>
```

| 옵션 | 설명 |
|---|---|
| `--os win,mac,linux` | 대상 선택 (기본: 전부) |
| `--commit <해시>` | 학기 중 버전 고정 |
| `--wasm` | 솔버 빌드 — **해석에 필수** |
| `--wasm-cache <경로>` | 솔버 결과물 보관·재사용 (Rust 불필요) |
| `--no-wasm` | 솔버 없이 빌드 — **해석 불가**, 화면 확인용 |
| `--sign <ID>` | macOS 코드 서명 (맥에서 빌드할 때) |
| `--no-patches` | 아래 패치 없이 원본 그대로 빌드 |
| `--keep` | 작업 폴더 유지 (재빌드 가속) |

### 필요한 것

`git`, `node` 18+, `npm`, `go` 1.20+, `zip`, `tar`

`--wasm`, `--wasm-cache`, `--no-wasm` 중 하나는 반드시 골라야 합니다.
WASM 없이 빌드하면 편집기는 열리지만 해석 버튼에서 실패하고, 그 사실은
배포한 뒤에야 드러납니다.

- **`--wasm`을 쓸 때**: Rust를 **rustup으로** 설치해야 합니다. 배포판
  패키지(`apt install rustc`)는 `rust-toolchain.toml`의 nightly 지정을
  무시해 컴파일이 실패합니다.
- **유니버설 macOS 바이너리**: `llvm-lipo` (리눅스) 또는 Xcode 명령행
  도구 (macOS). 없으면 Intel/Apple Silicon 패키지를 따로 만듭니다.

---

## 패치

`apply-*.sh`는 이름 순으로 자동 적용됩니다. 저장소를 매번 새로 클론하므로
소스 수정은 재적용 가능한 형태여야 합니다. 모두 여러 번 실행해도 안전합니다.

### `apply-dsm-fix.sh` — 단계별 강성법의 NaN 수정

Advanced의 단계별 설명에서 7단계 이후 변위와 반력이 모두 `NaN`으로
나오던 문제입니다.

`solver-detailed.ts`가 절점하중을 `{ fx, fy, mz }`로 읽는데 실제
인터페이스는 `{ fx, fz, my }`입니다. 2D 솔버가 `(x, y)`에서 `(x, z)`로
바뀔 때 이 호출부만 갱신되지 않았습니다.

오류 없이 화면까지 가는 이유는 방어 장치가 `NaN`을 통과시키기 때문입니다.
`Math.abs(undefined) < 1e-15`도, LU 분해의 `maxVal < tol`도 `NaN`에서는
`false`가 되어 조기 반환도 예외도 일어나지 않습니다.

- 필드명 교정
- 하중 적용부와 LU 분해의 가드 3곳을 `NaN` 인식하도록 보강
- 절점하중 회귀 테스트 추가 (캔틸레버 `PL³/3EI` 검산)

### `apply-dz-naming.sh` — 2D 지점 강제변위 표기

2D에서 지점 침하를 입력할 때 연직 성분이 `dy`로 표시되고 있었습니다. 앱의
2D 어휘는 `[ux, uz, ry]`이고 결과표도 `uz`·`rz`를 쓰므로, `y`를 연직으로
오해하기 쉬운 자리였습니다.

저장 필드는 이미 `dz`가 정본이고 `dy`는 옛 파일용 별칭인데, 입력 UI만
여전히 `dy`에 쓰고 `dy`에서 읽고 있었습니다. 한 지점에 둘 다 있으면 해석은
`dz`를, 화면은 `dy`를 보여 서로 다른 값을 가리킵니다.

네 화면(지점 표·속성 패널·선택 패널·지점 도구 옵션)이 `dz`에 쓰고
`dz ?? dy ?? 0`으로 읽도록 고쳤습니다. 옛 파일은 그대로 열립니다.

> 3D에서 `dy`는 실제로 존재하는 별개의 자유도라 건드리지 않습니다.

### `apply-korean.sh` — 한국어 활성화

저장소에 `ko.ts`가 이미 있지만 `OFFERED_LOCALES`가 `es/en/pt`로 좁혀져
있어 번들에 포함조차 되지 않습니다. 이를 등록하고, `ko.ts`에 빠진
**186개 키를 `ko-extra.ts`로 보충**합니다.

원본을 직접 고치지 않고 오버레이로 두어, 상류가 갱신돼도 이 파일만 다시
얹으면 됩니다. 누락분은 영어로 자동 대체되므로 화면이 깨지지 않습니다.

> `locales/steel/`에는 es·en·pt만 있어 철골 설계 검토 화면 198개 키는
> 영어로 표시됩니다.

### `apply-light-png.sh` — 밝은 배경 PNG

화면은 어두운 바탕에 밝은 선으로 그려집니다. 그대로 내보내면 보고서나
인쇄물에서 검은 사각형이 되어 읽기 어렵고 토너도 많이 듭니다.

색상과 채도는 두고 명도만 뒤집습니다. 배경은 밝아지고 부재와 글자는
어두워지며, 인장 빨강과 압축 파랑은 중간 명도라 그대로 남습니다. 배경만은
예외로 순백으로 만듭니다. 2D와 3D 모두에 통합니다.

> 보고서용으로는 벡터인 SVG를 권합니다(2D 전용).

### `apply-multibody.sh` — 분리된 구조물 허용

서로 떨어진 두 구조물(예: 똑같은 단순보가 위아래로 놓인 경우)을 해석하면
"비연결 구조물 … 모든 구간을 연결하세요"로 거부당했습니다.

막던 것은 솔버가 아니라 `solver-service.ts`의 사전 검증입니다. 절점 하나에서
너비우선 탐색을 돌려 전부 닿지 않으면 반환합니다. 솔버 쪽에는 그런 요구가
없습니다. 강성행렬이 블록 대각이 되어 각 블록이 구속되어 있으면 그대로
풀립니다.

연결성 요구를 없애는 대신 성분별 검사로 바꿨습니다. 덩어리마다 구속 자유도와
반력 평형행렬 랭크를 보고, 못 막는 덩어리가 있으면 그 절점 번호를 짚어
알려줍니다. 덩어리가 하나면 아무것도 달라지지 않습니다.

문구는 `multibody-strings.tsv`에 네 언어로 들어 있습니다.

### `apply-text-io.sh` — 텍스트 형식 입출력

그래픽 편집기를 거치지 않고 모델을 고칠 수 있도록, 사람이 읽는 텍스트
형식의 내보내기·가져오기를 추가합니다.

```
MODEL   name=Frame   mode=2d

NODE       1           0           0
NODE       2          10           0

SECTION    1  "IPN 300"   0.0069  9.8e-05  4.51e-06  4.666e-07  0.125  0.3  I

ELEMENT    1  frame      1     2    1    1  -         -
SUPPORT    1  pinned
LOAD    nodal   node=3  case=1  fx=10  fz=0  my=0
```

프로젝트 패널의 내보내기/가져오기에 버튼이 생깁니다. 잘못 편집하면 행
번호와 함께 무엇이 틀렸는지 알려줍니다.

문구는 `textio-strings.tsv` 한 곳에 모여 있고 영어·스페인어·포르투갈어·
한국어 네 언어가 채워져 있습니다. 내보낸 파일의 머리말도 그때의 UI
언어로 나옵니다. 문구를 고친 뒤에는 `./check-textio-i18n.py` 로 키와
치환 자리가 어긋나지 않았는지 확인하세요.

---

## `dedtext.py` — 명령행 변환기

프로그램 없이 `.ded`와 텍스트를 오갑니다. 여러 학생 파일을 일괄 처리하거나
스크립트로 모델을 생성할 때 씁니다.

```bash
python3 dedtext.py Model.ded     # → Model.txt
python3 dedtext.py Model.txt     # → Model.ded
python3 dedtext.py Model.ded --check   # 왕복 무손실 검사
```

텍스트로 표현하지 않는 설계기준·상세 설정은 파일 끝 `EXTRA` 영역에
보존되므로 왕복 변환에서 잃지 않습니다.

---

## 학생 배포

| 대상 | 실행 방법 |
|---|---|
| Windows | `Stabileo 실행.bat` 더블클릭 |
| macOS | `처음 한 번만 실행.command` 한 번 → 이후 앱 더블클릭 |
| Linux | `./stabileo` 또는 `바로가기 등록.sh` |

서버는 `127.0.0.1`에만 바인딩되므로 외부에서 접근할 수 없고, 해석은
학생 PC의 브라우저에서 WebAssembly로 실행됩니다.

macOS는 Apple 개발자 서명이 없으면 Gatekeeper가 막습니다. 배포본에 해제
절차를 안내해 두었고, 인증서가 있다면 `--sign`으로 정식 서명할 수 있습니다.

---

## 라이선스

Stabileo는 **AGPL-3.0**입니다. 이 저장소의 패치와 번역은 Stabileo와
결합해 동작하는 파생물이므로 **같은 AGPL-3.0**을 따릅니다.

빌드 결과물을 배포할 때는 대응 소스의 입수 경로를 함께 제공해야 합니다.
빌드 스크립트가 `LICENSE`와 빌드 커밋 해시가 적힌 `라이선스안내.txt`를
패키지에 자동으로 넣습니다.

- 원본: https://github.com/lambdaclass/stabileo
- 원본 라이선스: [AGPL-3.0](https://github.com/lambdaclass/stabileo/blob/main/LICENSE)

`build-stabileo.sh`, `server.go`, `dedtext.py`처럼 Stabileo 코드를 포함하지
않는 독립 도구도 편의를 위해 같은 라이선스로 배포합니다.
