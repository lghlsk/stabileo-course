#!/usr/bin/env python3
"""check-textio-i18n.py — textio.* 키가 네 언어에서 어긋나지 않았는지 본다.

왜 따로 두는가
    상류의 basic-mode-coverage.test.ts 는 `t('키')` 만 정규식으로 찾는다.
    `tp('키', {...})` 는 `t(` 가 아니라 `p(` 로 끝나므로 그 검사에 걸리지
    않는다. 치환 자리가 있는 문구는 전부 tp() 라서, 이 파일의 오류 문구는
    상류 게이트가 전혀 보지 못한다. 그래서 여기서 본다.

무엇을 보는가
    1. text-format.ts 가 부르는 키가 표에 모두 있는가
    2. 표에 있는데 아무도 부르지 않는 키가 있는가
    3. 네 언어의 {치환자리} 집합이 같은가
    4. 코드가 넘기는 인자와 문구의 {치환자리} 가 맞는가
    5. text-format.ts 에 한글이 남아 있지 않은가

사용법:  ./check-textio-i18n.py [textio-strings.tsv] [text-format.ts]
"""

import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
LANGS = ['en', 'es', 'pt', 'ko']

RED, GREEN, YELLOW, RESET = '\033[1;31m', '\033[32m', '\033[33m', '\033[0m'


def load_table(path):
    """TSV → {key: {lang: value}}.  중복 키는 그 자리에서 오류."""
    rows, order, dupes = {}, [], []
    for lineno, raw in enumerate(path.read_text(encoding='utf-8').splitlines(), 1):
        line = raw.rstrip('\n')
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        cells = line.split('\t')
        if len(cells) != 1 + len(LANGS):
            sys.exit(f"{RED}✗ {path.name} {lineno}행: 열이 "
                     f"{len(cells)}개입니다 (key + {len(LANGS)}개 언어여야 함){RESET}")
        key, *vals = cells
        if key in rows:
            dupes.append(key)
        rows[key] = dict(zip(LANGS, vals))
        order.append(key)
    if dupes:
        sys.exit(f"{RED}✗ 표에 중복된 키: {', '.join(sorted(set(dupes)))}{RESET}")
    return rows, order


def balanced_object(src, start):
    """src[start] 가 '{' 일 때 짝이 맞는 '}' 까지의 조각을 돌려준다."""
    depth = 0
    for i in range(start, len(src)):
        if src[i] == '{':
            depth += 1
        elif src[i] == '}':
            depth -= 1
            if depth == 0:
                return src[start:i + 1]
    return ''


def used_keys(src):
    """{key: set(넘긴 인자 이름)}.  t() 는 빈 집합."""
    used = {}
    for m in re.finditer(r"\bt\(\s*'([\w.]+)'\s*\)", src):
        used.setdefault(m.group(1), set())
    for m in re.finditer(r"\btp\(\s*'([\w.]+)'\s*,\s*", src):
        key = m.group(1)
        obj = balanced_object(src, m.end())
        if not obj:
            sys.exit(f"{RED}✗ tp('{key}', ...) 의 인자를 읽지 못했습니다.{RESET}")
        # { line, key: k, got: tok[2] }  →  line, key, got
        #
        # 정규식 하나로 훑으면 안 된다. 구분자인 쉼표까지 먹어 버려서
        # 다음 이름이 시작 구분자를 잃고 통째로 빠진다. 최상위 쉼표에서
        # 자른 뒤 각 조각의 앞 이름만 본다.
        names = set()
        for part in split_top(obj[1:-1]):
            head = part.split(':', 1)[0].strip()
            if re.fullmatch(r'[A-Za-z_]\w*', head):
                names.add(head)
        used.setdefault(key, set()).update(names)
    return used


def split_top(s):
    """괄호·따옴표 안의 쉼표는 건드리지 않고 최상위 쉼표에서만 자른다."""
    parts, depth, quote, cur = [], 0, '', ''
    for ch in s:
        if quote:
            cur += ch
            if ch == quote:
                quote = ''
            continue
        if ch in '\'"`':
            quote = ch
        elif ch in '([{':
            depth += 1
        elif ch in ')]}':
            depth -= 1
        elif ch == ',' and depth == 0:
            parts.append(cur)
            cur = ''
            continue
        cur += ch
    if cur.strip():
        parts.append(cur)
    return parts


def placeholders(text):
    return set(re.findall(r'\{(\w+)\}', text))


def main():
    tsv = Path(sys.argv[1]) if len(sys.argv) > 1 else HERE / 'textio-strings.tsv'
    ts = Path(sys.argv[2]) if len(sys.argv) > 2 else HERE / 'text-format.ts'
    for p in (tsv, ts):
        if not p.is_file():
            sys.exit(f"{RED}✗ 파일이 없습니다: {p}{RESET}")

    table, order = load_table(tsv)
    src = ts.read_text(encoding='utf-8')
    used = used_keys(src)
    problems = []

    # 1. 부르는데 표에 없는 키
    for key in sorted(k for k in used if k not in table):
        problems.append(f"{ts.name} 가 부르지만 표에 없는 키: {key}")

    # 2. 표에 있는데 아무도 부르지 않는 키
    #    textio.* 만 본다. project.* 는 툴바 .svelte 에서 불리는데,
    #    그 파일은 패치가 상류 저장소 안에서 고치는 것이라 여기 없다.
    for key in order:
        if key.startswith('textio.') and key not in used:
            problems.append(f"표에만 있고 쓰이지 않는 키: {key}")

    # 3. 언어 간 치환자리 집합
    for key in order:
        ref = placeholders(table[key]['en'])
        for lang in LANGS[1:]:
            got = placeholders(table[key][lang])
            if got != ref:
                problems.append(
                    f"{key} [{lang}]: 치환자리가 en 과 다릅니다 "
                    f"({sorted(ref)} vs {sorted(got)})")
        for lang in LANGS:
            if not table[key][lang].strip():
                problems.append(f"{key} [{lang}]: 값이 비었습니다")

    # 4. 코드가 넘기는 인자와 문구의 치환자리
    for key, args in sorted(used.items()):
        if key not in table:
            continue
        need = placeholders(table[key]['en'])
        if args != need:
            missing = sorted(need - args)
            extra = sorted(args - need)
            detail = []
            if missing:
                detail.append(f"코드가 안 넘김: {', '.join(missing)}")
            if extra:
                detail.append(f"문구에 없는 인자: {', '.join(extra)}")
            problems.append(f"{key}: " + ' / '.join(detail))

    # 5. 코드에 남은 한글
    for i, line in enumerate(src.splitlines(), 1):
        if re.search(r'[가-힣]', line):
            problems.append(f"{ts.name} {i}행에 한글이 남아 있습니다: {line.strip()[:60]}")

    if problems:
        print(f"{RED}✗ {len(problems)}건{RESET}")
        for p in problems:
            print(f"  · {p}")
        return 1

    print(f"{GREEN}✓{RESET} 키 {len(order)}개, 언어 {len(LANGS)}개 — 어긋난 곳 없음")
    n_tp = sum(1 for k in used if used[k])
    print(f"  t() {len(used) - n_tp}개 · tp() {n_tp}개")
    return 0


if __name__ == '__main__':
    sys.exit(main())
