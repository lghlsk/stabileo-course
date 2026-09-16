#!/usr/bin/env python3
"""locale-insert.py — 문구표(TSV)를 앱의 사전 네 개에 넣는다.

여러 패치가 같은 일을 한다. 각자 들고 있으면 한 곳을 고칠 때 나머지가
남아 사전이 서로 어긋난다. 실제로 apply-text-io.sh 가 ko 와 en 에만
문구를 넣어서 es·pt 가 비었고, 그 상태로는 상류 CI 가 떨어졌다.

es 와 pt 를 반드시 채우는 이유: 앱이 제공하는 세 언어라서
basic-mode-coverage.test.ts 가 en·es·pt 전부에 키가 있는지 본다.

사용법:  ./locale-insert.py <문구표.tsv> <locales 폴더>
TSV 형식:  key <탭> en <탭> es <탭> pt <탭> ko
'#' 로 시작하는 줄과 빈 줄은 건너뛴다.
"""

import re
import sys
from pathlib import Path

LANGS = ['en', 'es', 'pt', 'ko']

# 이 줄 앞에 넣는다. 사전 어디에 넣든 동작은 같지만, 한 곳으로 정해 두면
# 나중에 diff 를 읽기 쉽다.
ANCHOR = "'project.openDed':"


def read_table(tsv):
    rows = []
    for lineno, line in enumerate(tsv.read_text(encoding='utf-8').splitlines(), 1):
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        cells = line.split('\t')
        if len(cells) != 1 + len(LANGS):
            sys.exit(f"✗ {tsv.name} {lineno}행: 열이 {len(cells)}개입니다 "
                     f"(key + {len(LANGS)}개 언어여야 합니다).")
        rows.append((cells[0], dict(zip(LANGS, cells[1:]))))
    if not rows:
        sys.exit(f"✗ {tsv.name} 에 문구가 없습니다.")
    return rows


def lit(v):
    """TS 작은따옴표 문자열로. 역슬래시를 먼저 바꿔야 한다."""
    return "'" + v.replace('\\', '\\\\').replace("'", "\\'") + "'"


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    tsv, locales = Path(sys.argv[1]), Path(sys.argv[2])
    if not tsv.is_file():
        sys.exit(f"✗ 문구표가 없습니다: {tsv}")
    if not locales.is_dir():
        sys.exit(f"✗ locales 폴더가 없습니다: {locales}")

    rows = read_table(tsv)
    added = []

    for lang in LANGS:
        path = locales / f'{lang}.ts'
        if not path.is_file():
            print(f"  ! {lang}.ts 가 없어 건너뜁니다.")
            continue
        src = path.read_text(encoding='utf-8')
        # 이미 있는 키는 다시 넣지 않는다. 중복 키는 뒤엣것이 조용히 이기고,
        # 앞엣것을 고쳐도 아무 일이 없다.
        have = set(re.findall(r"""^\s*['"]([^'"]+)['"]\s*:""", src, re.M))
        todo = [(k, v[lang]) for k, v in rows if k not in have]
        if not todo:
            continue
        i = src.find(ANCHOR)
        if i < 0:
            print(f"  ! {lang}.ts: 기준 줄({ANCHOR})을 찾지 못해 건너뜁니다.")
            continue
        block = ''.join(f"  {lit(k)}: {lit(v)},\n" for k, v in todo)
        path.write_text(src[:i] + block + '  ' + src[i:].lstrip(), encoding='utf-8')
        added.append(f"{lang} {len(todo)}")

    print('  문구 삽입: ' + (', '.join(added) if added else '없음 (이미 최신)'))


if __name__ == '__main__':
    main()
