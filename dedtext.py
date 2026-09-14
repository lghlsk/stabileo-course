#!/usr/bin/env python3
"""
dedtext.py — Stabileo 모델을 사람이 읽고 고칠 수 있는 텍스트로 오가는 변환기

    python3 dedtext.py Test.ded              →  Test.txt   (내보내기)
    python3 dedtext.py Test.txt              →  Test.ded   (가져오기)
    python3 dedtext.py Test.ded -o out.txt
    python3 dedtext.py Test.ded --check      왕복 변환이 무손실인지 검사만

방향은 확장자로 판단합니다.

텍스트 형식은 한 줄에 한 항목이고, 첫 낱말이 종류입니다.
'#' 뒤는 주석이며 빈 줄은 무시합니다. 줄 순서는 자유입니다.

    NODE      1   0.0   0.0
    ELEMENT   1   frame   1   2   1   1
    SUPPORT   1   pinned
    LOAD      nodal   node=3   case=1   fx=10

값에 공백이 있으면 큰따옴표로 감쌉니다.  예) "Dead Load"
"""

from __future__ import annotations

import argparse
import json
import shlex
import sys
from datetime import datetime, timezone
from pathlib import Path

TEXT_FORMAT_VERSION = "1"
DED_VERSION = "2.0"

# 텍스트로 표현하는 스냅샷 키. 나머지는 EXTRA 로 원본 그대로 보존한다.
MODELLED_KEYS = {
    "name", "nodes", "materials", "sections", "elements",
    "supports", "loads", "loadCases", "combinations", "nextId",
}


# ─────────────────────────────────────────────────────────────────────
# 공통
# ─────────────────────────────────────────────────────────────────────

def as_dict(entries):
    """[[id, obj], ...] 또는 [obj, ...] → {id: obj}"""
    out = {}
    for item in entries or []:
        if isinstance(item, list) and len(item) == 2 and isinstance(item[1], dict):
            out[int(item[0])] = item[1]
        elif isinstance(item, dict) and "id" in item:
            out[int(item["id"])] = item
    return out


def num(v):
    """숫자를 짧고 읽기 좋게. 정수는 정수로, 실수는 불필요한 0 없이."""
    if v is None:
        return "0"
    f = float(v)
    if f == int(f) and abs(f) < 1e15:
        return str(int(f))
    s = repr(round(f, 12))
    return s


def quote(s):
    s = "" if s is None else str(s)
    return f'"{s}"' if (s == "" or any(c in s for c in ' \t"#')) else s


def parse_num(tok, field, lineno):
    try:
        f = float(tok)
    except ValueError:
        raise ValueError(f"{lineno}행: '{field}' 에 숫자가 와야 하는데 '{tok}' 입니다.")
    return int(f) if f == int(f) and abs(f) < 1e15 else f


# ─────────────────────────────────────────────────────────────────────
# .ded  →  텍스트
# ─────────────────────────────────────────────────────────────────────

RELEASE_KEYS = ("my", "mz", "t")

SUPPORT_TYPES = ("fixed", "pinned", "rollerX", "rollerZ", "rollerY",
                 "spring", "inclinedRoller")


def release_str(rel):
    if not rel:
        return "-"
    on = [k for k in RELEASE_KEYS if rel.get(k)]
    return ",".join(on) if on else "-"


# 각 항목이 위치 인자로 표현하는 필드. 그 밖의 필드는 줄 끝에
# key=value 로 덧붙여 왕복 변환에서 잃지 않게 한다. 단면의 tw/tf 처럼
# 형상별로만 존재하는 값들이 여기 해당한다.
KNOWN_FIELDS = {
    "NODE": {"id", "x", "y", "z"},
    "MATERIAL": {"id", "name", "e", "nu", "rho", "fy"},
    "SECTION": {"id", "name", "a", "iy", "iz", "j", "b", "h", "shape"},
    "ELEMENT": {"id", "type", "nodeI", "nodeJ", "materialId", "sectionId",
                "releaseI", "releaseJ"},
    "SUPPORT": {"id", "nodeId", "type"},
}


def extra_tail(obj, kind):
    """위치 인자로 담지 못한 필드를 key=value 낱말들로."""
    out = []
    for k in sorted(obj):
        if k in KNOWN_FIELDS[kind] or obj[k] is None:
            continue
        v = obj[k]
        if isinstance(v, bool):
            out.append(f"{k}={'true' if v else 'false'}")
        elif isinstance(v, (int, float)):
            out.append(f"{k}={num(v)}")
        elif isinstance(v, str):
            out.append(f"{k}={quote(v)}")
        else:
            out.append(f"{k}=@{json.dumps(v, ensure_ascii=False, separators=(',', ':'))}")
    return ("  " + "  ".join(out)) if out else ""


def absorb_extras(obj, extras, lineno):
    """줄 끝 key=value 를 객체에 되돌린다."""
    for k, v in extras.items():
        if v.startswith("@"):
            try:
                obj[k] = json.loads(v[1:])
            except json.JSONDecodeError:
                raise ValueError(f"{lineno}행: '{k}=' 의 값을 읽을 수 없습니다.")
        elif v in ("true", "false"):
            obj[k] = (v == "true")
        else:
            try:
                obj[k] = parse_num(v, k, lineno)
            except ValueError:
                obj[k] = v
    return obj


def to_text(ded: dict) -> str:
    snap = ded.get("snapshot", {})
    nodes = as_dict(snap.get("nodes"))
    mats = as_dict(snap.get("materials"))
    secs = as_dict(snap.get("sections"))
    elems = as_dict(snap.get("elements"))
    sups = as_dict(snap.get("supports"))
    cases = {int(c["id"]): c for c in (snap.get("loadCases") or []) if "id" in c}
    combos = snap.get("combinations") or []
    loads = snap.get("loads") or []

    L = []
    w = lambda line="": L.append(line.rstrip())

    w(f"# Stabileo 모델 텍스트 형식 v{TEXT_FORMAT_VERSION}")
    w("#")
    w("# 이 파일을 고친 뒤 다시 .ded 로 변환하면 프로그램에서 열립니다.")
    w("#   내보내기:  python3 dedtext.py 모델.ded")
    w("#   가져오기:  python3 dedtext.py 모델.txt")
    w("#")
    w("# '#' 뒤는 주석입니다. 빈 줄과 줄 순서는 상관없습니다.")
    w("# 값에 공백이 있으면 큰따옴표로 감싸세요.")
    w("")

    w(f"MODEL   name={quote(ded.get('name') or snap.get('name') or 'Model')}"
      f"   mode={ded.get('analysisMode', '2d')}")
    w("")

    w("# 절점    NODE  <번호>  <x, m>  <z, m>")
    w("#         z 가 연직 방향입니다. 위쪽이 +.")
    for i in sorted(nodes):
        n = nodes[i]
        z = n.get("z", n.get("y", 0))
        w(f"NODE    {i:>4}  {num(n.get('x')):>10}  {num(z):>10}"
          + extra_tail(n, "NODE"))
    w("")

    w("# 재료    MATERIAL  <번호>  <이름>  <E, MPa>  <포아송비>  <단위중량, kN/m3>  <fy, MPa>")
    for i in sorted(mats):
        m = mats[i]
        w(f"MATERIAL {i:>3}  {quote(m.get('name') or f'MAT{i}'):<14}"
          f"  {num(m.get('e'))}  {num(m.get('nu'))}"
          f"  {num(m.get('rho'))}  {num(m.get('fy'))}"
          + extra_tail(m, "MATERIAL"))
    w("")

    w("# 단면    SECTION  <번호>  <이름>  <A, m2>  <Iy, m4>  <Iz, m4>  <J, m4>  <b, m>  <h, m>  [형상]")
    w("#         Iy 가 면내 휨(강축)에 쓰입니다.")
    for i in sorted(secs):
        s = secs[i]
        w(f"SECTION {i:>4}  {quote(s.get('name') or f'SEC{i}'):<14}"
          f"  {num(s.get('a'))}  {num(s.get('iy'))}  {num(s.get('iz'))}"
          f"  {num(s.get('j'))}  {num(s.get('b'))}  {num(s.get('h'))}"
          f"  {quote(s.get('shape') or '-')}"
          + extra_tail(s, "SECTION"))
    w("")

    w("# 부재    ELEMENT  <번호>  <frame|truss>  <절점I>  <절점J>  <재료>  <단면>  [해제I]  [해제J]")
    w("#         해제는 my, mz, t 를 쉼표로. 없으면 '-'.")
    for i in sorted(elems):
        e = elems[i]
        w(f"ELEMENT {i:>4}  {str(e.get('type', 'frame')):<6}"
          f"  {e.get('nodeI'):>4}  {e.get('nodeJ'):>4}"
          f"  {e.get('materialId', 1):>3}  {e.get('sectionId', 1):>3}"
          f"  {release_str(e.get('releaseI')):<8}"
          f"  {release_str(e.get('releaseJ'))}"
          + extra_tail(e, "ELEMENT"))
    w("")

    w("# 지점    SUPPORT  <절점>  <종류>  [key=value ...]")
    w("#         종류: fixed  pinned  rollerX  rollerZ  spring  inclinedRoller")
    w("#         스프링은 kx=, kz=, 경사롤러는 angle=(라디안), 강제변위는 dx= dz= dry=")
    for i in sorted(sups):
        s = sups[i]
        w(f"SUPPORT {s.get('nodeId'):>4}  {str(s.get('type', 'pinned')):<14}"
          + extra_tail(s, "SUPPORT"))
    w("")

    w("# 하중케이스  LOADCASE  <번호>  <종류>  <이름>        종류: D L W S E T")
    for i in sorted(cases):
        c = cases[i]
        w(f"LOADCASE {i:>3}  {str(c.get('type', 'D')):<3}  {quote(c.get('name') or f'CASE{i}')}")
    w("")

    w("# 하중    LOAD  <종류>  key=value ...")
    w("#   nodal  node=  case=  fx=  fz=  my=            절점하중 (kN, kN·m)")
    w("#   dist   elem=  case=  qI=  qJ=  [a=]  [b=]     등분포/사다리꼴 (kN/m, 부재 직각)")
    w("#   point  elem=  case=  a=  [p=]  [px=]  [my=]   부재상 집중하중")
    w("#   temp   elem=  case=  dt=  dtg=                온도 (균일, 구배)")
    for ld in loads:
        kind, d = ld.get("type"), (ld.get("data") or {})
        if kind == "nodal":
            w(f"LOAD    nodal   node={d.get('nodeId')}  case={d.get('caseId', 1)}"
              f"  fx={num(d.get('fx'))}  fz={num(d.get('fz'))}  my={num(d.get('my'))}")
        elif kind == "distributed":
            ab = ""
            if d.get("a") is not None:
                ab += f"  a={num(d['a'])}"
            if d.get("b") is not None:
                ab += f"  b={num(d['b'])}"
            w(f"LOAD    dist    elem={d.get('elementId')}  case={d.get('caseId', 1)}"
              f"  qI={num(d.get('qI'))}  qJ={num(d.get('qJ'))}{ab}")
        elif kind == "pointOnElement":
            opt = "".join(f"  {k}={num(d[k])}" for k in ("p", "px", "my") if d.get(k))
            w(f"LOAD    point   elem={d.get('elementId')}  case={d.get('caseId', 1)}"
              f"  a={num(d.get('a'))}{opt}")
        elif kind == "thermal":
            w(f"LOAD    temp    elem={d.get('elementId')}  case={d.get('caseId', 1)}"
              f"  dt={num(d.get('dtUniform'))}  dtg={num(d.get('dtGradient'))}")
        else:
            w(f"# (변환되지 않은 하중: {kind})")
    w("")

    w("# 조합    COMBO  <번호>  <이름>  <케이스:계수> ...")
    for cb in combos:
        terms = " ".join(f"{f.get('caseId')}:{num(f.get('factor'))}"
                         for f in (cb.get("factors") or []))
        w(f"COMBO   {cb.get('id'):>4}  {quote(cb.get('name') or ''):<20}  {terms}")
    w("")

    # ── 보존 영역 ────────────────────────────────────────────────
    # 텍스트로 표현하지 않는 설정(설계기준, 상세, 기초 등)을 그대로
    # 실어 두어 왕복 변환에서 잃지 않게 한다.
    extras = {k: v for k, v in snap.items() if k not in MODELLED_KEYS}
    for k in ("appMode", "axisConvention3D", "viewportPresentation3D"):
        if k in ded:
            extras["__top__" + k] = ded[k]
    if extras:
        w("# ─────────────────────────────────────────────────────────")
        w("# 아래는 프로그램 설정입니다. 편집하지 마세요.")
        w("# (지우면 기본값으로 되돌아갈 뿐, 파일은 그대로 열립니다)")
        for k in sorted(extras):
            w(f"EXTRA   {k}  {json.dumps(extras[k], ensure_ascii=False, separators=(',', ':'))}")
        w("")

    return "\n".join(L)


# ─────────────────────────────────────────────────────────────────────
# 텍스트  →  .ded
# ─────────────────────────────────────────────────────────────────────

def split_line(line):
    """주석을 떼고 따옴표를 존중하며 낱말로 나눈다."""
    lex = shlex.shlex(line, posix=True)
    lex.whitespace_split = True
    lex.commenters = "#"
    return list(lex)


def kv(tokens, start, lineno):
    """key=value 낱말들을 사전으로."""
    out = {}
    for tok in tokens[start:]:
        if "=" not in tok:
            raise ValueError(f"{lineno}행: 'key=value' 형태가 아닌 '{tok}' 입니다.")
        k, v = tok.split("=", 1)
        out[k.strip()] = v.strip()
    return out


def need(d, key, lineno, kind):
    if key not in d:
        raise ValueError(f"{lineno}행: {kind} 에 '{key}=' 가 필요합니다.")
    return d[key]


def parse_release(tok):
    if tok in ("-", "", "none"):
        return {k: False for k in RELEASE_KEYS}
    on = {p.strip() for p in tok.split(",") if p.strip()}
    bad = on - set(RELEASE_KEYS)
    if bad:
        raise ValueError(f"알 수 없는 해제 기호: {', '.join(sorted(bad))}")
    return {k: (k in on) for k in RELEASE_KEYS}


def from_text(text: str) -> dict:
    name, mode = "Model", "2d"
    nodes, mats, secs, elems, sups = {}, {}, {}, {}, {}
    cases, combos, loads = {}, [], []
    extras, top_extras = {}, {}
    errors = []

    for lineno, raw in enumerate(text.splitlines(), 1):
        # EXTRA 는 값이 JSON 이라 따옴표와 중괄호를 그대로 보존해야 한다.
        # 낱말 분해를 거치면 따옴표가 벗겨지므로 먼저 걸러낸다.
        stripped = raw.strip()
        if stripped[:6].upper() == "EXTRA " or stripped[:6].upper() == "EXTRA\t":
            rest = stripped[6:].strip()
            key, _, payload = rest.partition(" ")
            payload = payload.strip()
            # 앱이 내보낸 파일에는 값이 없는 설정이 'undefined' 로 적혀
            # 있을 수 있다. 그 설정이 없었다는 뜻이므로 조용히 넘긴다.
            if payload in ("", "undefined"):
                continue
            try:
                val = json.loads(payload)
            except json.JSONDecodeError:
                errors.append(f"{lineno}행: EXTRA '{key}' 의 값을 읽을 수 없습니다.")
                continue
            if key.startswith("__top__"):
                top_extras[key[len("__top__"):]] = val
            else:
                extras[key] = val
            continue

        try:
            tok = split_line(raw)
        except ValueError as e:
            errors.append(f"{lineno}행: 따옴표가 닫히지 않았습니다 ({e}).")
            continue
        if not tok:
            continue
        kind = tok[0].upper()

        try:
            if kind == "MODEL":
                d = kv(tok, 1, lineno)
                name = d.get("name", name)
                mode = d.get("mode", mode)

            elif kind == "NODE":
                if len(tok) < 4:
                    raise ValueError(f"{lineno}행: NODE 는 번호, x, z 가 필요합니다.")
                nid = int(parse_num(tok[1], "번호", lineno))
                nodes[nid] = absorb_extras(
                    {"id": nid,
                     "x": parse_num(tok[2], "x", lineno),
                     "y": parse_num(tok[3], "z", lineno)},
                    kv(tok, 4, lineno), lineno)

            elif kind == "MATERIAL":
                if len(tok) < 4:
                    raise ValueError(f"{lineno}행: MATERIAL 은 번호, 이름, E 가 필요합니다.")
                mid = int(parse_num(tok[1], "번호", lineno))
                mats[mid] = {"id": mid, "name": tok[2],
                             "e": parse_num(tok[3], "E", lineno),
                             "nu": parse_num(tok[4], "포아송비", lineno) if len(tok) > 4 else 0.3,
                             "rho": parse_num(tok[5], "단위중량", lineno) if len(tok) > 5 else 0,
                             "fy": parse_num(tok[6], "fy", lineno) if len(tok) > 6 else 0}
                absorb_extras(mats[mid], kv(tok, 7, lineno), lineno)

            elif kind == "SECTION":
                if len(tok) < 5:
                    raise ValueError(f"{lineno}행: SECTION 은 번호, 이름, A, Iy 가 필요합니다.")
                sid = int(parse_num(tok[1], "번호", lineno))
                g = lambda i, f: parse_num(tok[i], f, lineno) if len(tok) > i else 0
                sec = {"id": sid, "name": tok[2],
                       "a": parse_num(tok[3], "A", lineno),
                       "iy": parse_num(tok[4], "Iy", lineno),
                       "iz": g(5, "Iz"), "j": g(6, "J"),
                       "b": g(7, "b"), "h": g(8, "h")}
                if len(tok) > 9 and tok[9] not in ("-", ""):
                    sec["shape"] = tok[9]
                secs[sid] = absorb_extras(sec, kv(tok, 10, lineno), lineno)

            elif kind == "ELEMENT":
                if len(tok) < 7:
                    raise ValueError(
                        f"{lineno}행: ELEMENT 는 번호, 종류, 절점I, 절점J, 재료, 단면이 필요합니다.")
                eid = int(parse_num(tok[1], "번호", lineno))
                etype = tok[2].lower()
                if etype not in ("frame", "truss"):
                    raise ValueError(f"{lineno}행: 부재 종류는 frame 또는 truss 입니다 ('{tok[2]}').")
                elems[eid] = {
                    "id": eid, "type": etype,
                    "nodeI": int(parse_num(tok[3], "절점I", lineno)),
                    "nodeJ": int(parse_num(tok[4], "절점J", lineno)),
                    "materialId": int(parse_num(tok[5], "재료", lineno)),
                    "sectionId": int(parse_num(tok[6], "단면", lineno)),
                    "releaseI": parse_release(tok[7]) if len(tok) > 7 else parse_release("-"),
                    "releaseJ": parse_release(tok[8]) if len(tok) > 8 else parse_release("-"),
                }
                absorb_extras(elems[eid], kv(tok, 9, lineno), lineno)

            elif kind == "SUPPORT":
                if len(tok) < 3:
                    raise ValueError(f"{lineno}행: SUPPORT 는 절점과 종류가 필요합니다.")
                sid = len(sups) + 1
                stype = tok[2]
                if stype not in SUPPORT_TYPES:
                    raise ValueError(
                        f"{lineno}행: 알 수 없는 지점 종류 '{stype}' 입니다. "
                        f"가능한 값: {', '.join(SUPPORT_TYPES)}")
                sup = {"id": sid,
                       "nodeId": int(parse_num(tok[1], "절점", lineno)),
                       "type": stype}
                absorb_extras(sup, kv(tok, 3, lineno), lineno)
                sups[sid] = sup

            elif kind == "LOADCASE":
                if len(tok) < 3:
                    raise ValueError(f"{lineno}행: LOADCASE 는 번호와 종류가 필요합니다.")
                cid = int(parse_num(tok[1], "번호", lineno))
                cases[cid] = {"id": cid, "type": tok[2],
                              "name": tok[3] if len(tok) > 3 else f"CASE{cid}"}

            elif kind == "LOAD":
                if len(tok) < 2:
                    raise ValueError(f"{lineno}행: LOAD 는 종류가 필요합니다.")
                sub = tok[1].lower()
                d = kv(tok, 2, lineno)
                n = lambda k, dflt=0: parse_num(d.get(k, dflt), k, lineno)
                cid = int(n("case", 1))
                if sub == "nodal":
                    loads.append({"type": "nodal", "data": {
                        "id": len(loads) + 1,
                        "nodeId": int(parse_num(need(d, "node", lineno, "nodal"), "node", lineno)),
                        "fx": n("fx"), "fz": n("fz"), "my": n("my"), "caseId": cid}})
                elif sub in ("dist", "distributed"):
                    data = {"id": len(loads) + 1,
                            "elementId": int(parse_num(need(d, "elem", lineno, "dist"), "elem", lineno)),
                            "qI": n("qI"), "qJ": n("qJ"), "caseId": cid}
                    if "a" in d:
                        data["a"] = n("a")
                    if "b" in d:
                        data["b"] = n("b")
                    loads.append({"type": "distributed", "data": data})
                elif sub in ("point", "pointonelement"):
                    data = {"id": len(loads) + 1,
                            "elementId": int(parse_num(need(d, "elem", lineno, "point"), "elem", lineno)),
                            "a": n("a"), "caseId": cid}
                    for k in ("p", "px", "my"):
                        if k in d:
                            data[k] = n(k)
                    loads.append({"type": "pointOnElement", "data": data})
                elif sub in ("temp", "thermal"):
                    loads.append({"type": "thermal", "data": {
                        "id": len(loads) + 1,
                        "elementId": int(parse_num(need(d, "elem", lineno, "temp"), "elem", lineno)),
                        "dtUniform": n("dt"), "dtGradient": n("dtg"), "caseId": cid}})
                else:
                    raise ValueError(
                        f"{lineno}행: 하중 종류는 nodal, dist, point, temp 입니다 ('{tok[1]}').")

            elif kind == "COMBO":
                if len(tok) < 3:
                    raise ValueError(f"{lineno}행: COMBO 는 번호와 이름이 필요합니다.")
                factors = []
                for t in tok[3:]:
                    if ":" not in t:
                        raise ValueError(f"{lineno}행: 조합 항은 '케이스:계수' 형태입니다 ('{t}').")
                    c, f = t.split(":", 1)
                    factors.append({"caseId": int(parse_num(c, "케이스", lineno)),
                                    "factor": parse_num(f, "계수", lineno)})
                combos.append({"id": int(parse_num(tok[1], "번호", lineno)),
                               "name": tok[2], "factors": factors})

            else:
                errors.append(f"{lineno}행: 알 수 없는 항목 '{tok[0]}' 입니다.")

        except ValueError as e:
            errors.append(str(e))

    # ── 참조 무결성 ───────────────────────────────────────────────
    for eid, e in elems.items():
        for side in ("nodeI", "nodeJ"):
            if e[side] not in nodes:
                errors.append(f"부재 {eid}: 절점 {e[side]} 가 정의되지 않았습니다.")
        if e["materialId"] not in mats:
            errors.append(f"부재 {eid}: 재료 {e['materialId']} 가 정의되지 않았습니다.")
        if e["sectionId"] not in secs:
            errors.append(f"부재 {eid}: 단면 {e['sectionId']} 가 정의되지 않았습니다.")
    for s in sups.values():
        if s["nodeId"] not in nodes:
            errors.append(f"지점: 절점 {s['nodeId']} 가 정의되지 않았습니다.")
    for ld in loads:
        d = ld["data"]
        if "nodeId" in d and d["nodeId"] not in nodes:
            errors.append(f"하중: 절점 {d['nodeId']} 가 정의되지 않았습니다.")
        if "elementId" in d and d["elementId"] not in elems:
            errors.append(f"하중: 부재 {d['elementId']} 가 정의되지 않았습니다.")
        if cases and d.get("caseId") not in cases:
            errors.append(f"하중: 하중케이스 {d.get('caseId')} 가 정의되지 않았습니다.")

    if not nodes:
        errors.append("절점이 하나도 없습니다.")

    if errors:
        raise ValueError("\n".join("  · " + e for e in dict.fromkeys(errors)))

    if not cases:
        cases = {1: {"id": 1, "type": "D", "name": "Dead Load"}}

    # nextId 는 로더가 요구한다. 가장 큰 번호 다음부터.
    nxt = {
        "node": max(nodes) + 1 if nodes else 1,
        "element": max(elems) + 1 if elems else 1,
        "material": max(mats) + 1 if mats else 1,
        "section": max(secs) + 1 if secs else 1,
        "support": max(sups) + 1 if sups else 1,
        "load": len(loads) + 1,
        "loadCase": max(cases) + 1 if cases else 1,
        "combination": max((c["id"] for c in combos), default=0) + 1,
    }
    if isinstance(extras.get("nextId"), dict):
        nxt = {**extras["nextId"], **nxt}

    snapshot = {
        "name": name,
        "nodes": [[i, nodes[i]] for i in sorted(nodes)],
        "materials": [[i, mats[i]] for i in sorted(mats)],
        "sections": [[i, secs[i]] for i in sorted(secs)],
        "elements": [[i, elems[i]] for i in sorted(elems)],
        "supports": [[i, sups[i]] for i in sorted(sups)],
        "loads": loads,
        "loadCases": [cases[i] for i in sorted(cases)],
        "combinations": combos,
        "plates": [], "quads": [], "constraints": [], "connectors": [],
        "nextId": nxt,
        "localAxisConvention": "zUpStrongAxis",
    }
    snapshot.update({k: v for k, v in extras.items() if k != "nextId"})

    ded = {
        "version": DED_VERSION,
        "name": name,
        "timestamp": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "snapshot": snapshot,
        "analysisMode": mode,
    }
    ded.update(top_extras)
    return ded


# ─────────────────────────────────────────────────────────────────────

def roundtrip_report(original: dict) -> list[str]:
    """왕복 변환에서 달라진 부분을 찾아 돌려준다."""
    back = from_text(to_text(original))
    diffs = []
    a, b = original.get("snapshot", {}), back.get("snapshot", {})

    def norm(v):
        return json.loads(json.dumps(v, sort_keys=True))

    for key in sorted(set(a) | set(b)):
        if key in ("nextId",):
            continue
        if norm(a.get(key)) != norm(b.get(key)):
            diffs.append(key)
    return diffs


def main():
    ap = argparse.ArgumentParser(
        description="Stabileo .ded ↔ 편집용 텍스트 변환기")
    ap.add_argument("input", type=Path)
    ap.add_argument("-o", "--output", type=Path)
    ap.add_argument("--check", action="store_true",
                    help="왕복 변환이 무손실인지 검사만 하고 끝냅니다")
    args = ap.parse_args()

    if not args.input.exists():
        sys.exit(f"파일을 찾을 수 없습니다: {args.input}")

    suffix = args.input.suffix.lower()
    raw = args.input.read_text(encoding="utf-8")

    if suffix in (".ded", ".json"):
        ded = json.loads(raw)
        if args.check:
            diffs = roundtrip_report(ded)
            if diffs:
                print("왕복 변환에서 달라진 항목:")
                for d in diffs:
                    print("  ·", d)
                sys.exit(1)
            print("왕복 변환 무손실 확인")
            return
        out = args.output or args.input.with_suffix(".txt")
        out.write_text(to_text(ded), encoding="utf-8")
        snap = ded.get("snapshot", {})
        print(f"내보내기 완료: {out}")
        print(f"  절점 {len(snap.get('nodes') or [])}  "
              f"부재 {len(snap.get('elements') or [])}  "
              f"하중 {len(snap.get('loads') or [])}")

    elif suffix in (".txt", ".text"):
        try:
            ded = from_text(raw)
        except ValueError as e:
            sys.exit(f"텍스트를 읽는 중 문제가 있습니다.\n{e}")
        out = args.output or args.input.with_suffix(".ded")
        out.write_text(json.dumps(ded, ensure_ascii=False), encoding="utf-8")
        snap = ded["snapshot"]
        print(f"가져오기 완료: {out}")
        print(f"  절점 {len(snap['nodes'])}  부재 {len(snap['elements'])}  "
              f"하중 {len(snap['loads'])}")
        print("프로그램에서 열기(Ctrl+O)로 불러오세요.")

    else:
        sys.exit(f"확장자로 방향을 판단할 수 없습니다: {suffix}\n"
                 f".ded 또는 .txt 를 넣어주세요.")


if __name__ == "__main__":
    main()
