/**
 * text-format.ts — 사람이 읽고 고칠 수 있는 텍스트 모델 형식.
 *
 * 그래픽 편집기를 거치지 않고 절점 좌표나 하중을 바꾸고 싶을 때 쓴다.
 * 한 줄에 한 항목, 첫 낱말이 종류, '#' 뒤는 주석이다.
 *
 * 이 파일의 인코딩·디코딩 규칙은 dedtext.py 와 같다. 둘 중 하나를
 * 고치면 다른 하나도 함께 고쳐야 한다.
 */

import { modelStore } from '../store/model.svelte';
import { uiStore } from '../store/ui.svelte';
import { historyStore } from '../store/history.svelte';
import { resultsStore } from '../store/results.svelte';
import { downloadText } from '../store/file';

export const TEXT_FORMAT_VERSION = '1';

const RELEASE_KEYS = ['my', 'mz', 't'] as const;

const SUPPORT_TYPES = new Set([
  'fixed', 'pinned', 'rollerX', 'rollerZ', 'rollerY', 'spring', 'inclinedRoller',
]);

/** 위치 인자로 표현하는 필드. 나머지는 줄 끝에 key=value 로 보존한다. */
const KNOWN: Record<string, Set<string>> = {
  NODE: new Set(['id', 'x', 'y', 'z']),
  MATERIAL: new Set(['id', 'name', 'e', 'nu', 'rho', 'fy']),
  SECTION: new Set(['id', 'name', 'a', 'iy', 'iz', 'j', 'b', 'h', 'shape']),
  ELEMENT: new Set(['id', 'type', 'nodeI', 'nodeJ', 'materialId', 'sectionId',
    'releaseI', 'releaseJ']),
  SUPPORT: new Set(['id', 'nodeId', 'type']),
};

/** 텍스트로 옮기는 스냅샷 키. 그 밖은 EXTRA 로 원본 보존. */
const MODELLED = new Set([
  'name', 'nodes', 'materials', 'sections', 'elements',
  'supports', 'loads', 'loadCases', 'combinations', 'nextId',
]);

// ─────────────────────────────────────────────────────────────────────
// 도우미
// ─────────────────────────────────────────────────────────────────────

function num(v: unknown): string {
  const f = Number(v ?? 0);
  if (!Number.isFinite(f)) return '0';
  return Number.isInteger(f) ? String(f) : String(Number(f.toPrecision(12)));
}

function quote(s: unknown): string {
  const t = s == null ? '' : String(s);
  return (t === '' || /[\s"#]/.test(t)) ? `"${t}"` : t;
}

function pad(s: string, n: number): string {
  return s.length >= n ? s : s + ' '.repeat(n - s.length);
}

function padStart(s: string, n: number): string {
  return s.length >= n ? s : ' '.repeat(n - s.length) + s;
}

/** [[id, obj], ...] → Map */
function toMap(entries: unknown): Map<number, any> {
  const m = new Map<number, any>();
  if (!Array.isArray(entries)) return m;
  for (const item of entries) {
    if (Array.isArray(item) && item.length === 2 && item[1] && typeof item[1] === 'object') {
      m.set(Number(item[0]), item[1]);
    } else if (item && typeof item === 'object' && 'id' in (item as any)) {
      m.set(Number((item as any).id), item);
    }
  }
  return m;
}

function releaseStr(rel: any): string {
  if (!rel) return '-';
  const on = RELEASE_KEYS.filter((k) => rel[k]);
  return on.length ? on.join(',') : '-';
}

function parseRelease(tok: string): Record<string, boolean> {
  const out: Record<string, boolean> = { my: false, mz: false, t: false };
  if (!tok || tok === '-' || tok === 'none') return out;
  for (const p of tok.split(',')) {
    const k = p.trim();
    if (!k) continue;
    if (!(RELEASE_KEYS as readonly string[]).includes(k)) {
      throw new Error(`알 수 없는 해제 기호 '${k}'`);
    }
    out[k] = true;
  }
  return out;
}

function extraTail(obj: any, kind: string): string {
  const known = KNOWN[kind];
  const parts: string[] = [];
  for (const k of Object.keys(obj).sort()) {
    if (known.has(k) || obj[k] == null) continue;
    const v = obj[k];
    if (typeof v === 'boolean') parts.push(`${k}=${v ? 'true' : 'false'}`);
    else if (typeof v === 'number') parts.push(`${k}=${num(v)}`);
    else if (typeof v === 'string') parts.push(`${k}=${quote(v)}`);
    else parts.push(`${k}=@${JSON.stringify(v)}`);
  }
  return parts.length ? '  ' + parts.join('  ') : '';
}

function absorbExtras(obj: any, kvs: Record<string, string>, line: number): any {
  for (const [k, v] of Object.entries(kvs)) {
    if (v.startsWith('@')) {
      try { obj[k] = JSON.parse(v.slice(1)); }
      catch { throw new Error(`${line}행: '${k}=' 의 값을 읽을 수 없습니다.`); }
    } else if (v === 'true' || v === 'false') {
      obj[k] = v === 'true';
    } else {
      const f = Number(v);
      obj[k] = Number.isFinite(f) && v.trim() !== '' ? f : v;
    }
  }
  return obj;
}

/** 따옴표를 존중하며 낱말로 나눈다. '#' 뒤는 버린다. */
function splitLine(line: string): string[] {
  const out: string[] = [];
  let cur = '';
  let inQuote = false;
  let has = false;
  for (let i = 0; i < line.length; i++) {
    const c = line[i];
    if (inQuote) {
      if (c === '"') { inQuote = false; } else { cur += c; }
      continue;
    }
    if (c === '"') { inQuote = true; has = true; continue; }
    if (c === '#') break;
    if (c === ' ' || c === '\t') {
      if (has || cur) { out.push(cur); cur = ''; has = false; }
      continue;
    }
    cur += c;
  }
  if (inQuote) throw new Error('따옴표가 닫히지 않았습니다.');
  if (has || cur) out.push(cur);
  return out;
}

function kvFrom(tokens: string[], start: number, line: number): Record<string, string> {
  const out: Record<string, string> = {};
  for (let i = start; i < tokens.length; i++) {
    const t = tokens[i];
    const eq = t.indexOf('=');
    if (eq < 0) throw new Error(`${line}행: 'key=value' 형태가 아닌 '${t}' 입니다.`);
    out[t.slice(0, eq).trim()] = t.slice(eq + 1).trim();
  }
  return out;
}

function requireNum(tok: string | undefined, field: string, line: number): number {
  const f = Number(tok);
  if (tok === undefined || tok === '' || !Number.isFinite(f)) {
    throw new Error(`${line}행: '${field}' 에 숫자가 와야 하는데 '${tok ?? ''}' 입니다.`);
  }
  return f;
}

// ─────────────────────────────────────────────────────────────────────
// 내보내기
// ─────────────────────────────────────────────────────────────────────

export function modelToText(): string {
  const snap: any = modelStore.snapshot();
  const nodes = toMap(snap.nodes);
  const mats = toMap(snap.materials);
  const secs = toMap(snap.sections);
  const elems = toMap(snap.elements);
  const sups = toMap(snap.supports);
  const cases: any[] = snap.loadCases ?? [];
  const combos: any[] = snap.combinations ?? [];
  const loads: any[] = snap.loads ?? [];

  const L: string[] = [];
  const w = (s = '') => L.push(s.replace(/\s+$/, ''));
  const sortedKeys = (m: Map<number, any>) => [...m.keys()].sort((a, b) => a - b);

  w(`# Stabileo 모델 텍스트 형식 v${TEXT_FORMAT_VERSION}`);
  w('#');
  w('# 이 파일을 고친 뒤 다시 불러오면 모델이 바뀝니다.');
  w('# 프로젝트 → 가져오기 → 텍스트 열기');
  w('#');
  w("# '#' 뒤는 주석입니다. 빈 줄과 줄 순서는 상관없습니다.");
  w('# 값에 공백이 있으면 큰따옴표로 감싸세요.');
  w('');
  w(`MODEL   name=${quote(modelStore.model.name)}   mode=${uiStore.analysisMode}`);
  w('');

  w('# 절점    NODE  <번호>  <x, m>  <z, m>');
  w('#         z 가 연직 방향입니다. 위쪽이 +.');
  for (const i of sortedKeys(nodes)) {
    const n = nodes.get(i);
    const z = n.z ?? n.y ?? 0;
    w(`NODE    ${padStart(String(i), 4)}  ${padStart(num(n.x), 10)}  ${padStart(num(z), 10)}`
      + extraTail(n, 'NODE'));
  }
  w('');

  w('# 재료    MATERIAL  <번호>  <이름>  <E, MPa>  <포아송비>  <단위중량, kN/m3>  <fy, MPa>');
  for (const i of sortedKeys(mats)) {
    const m = mats.get(i);
    w(`MATERIAL ${padStart(String(i), 3)}  ${pad(quote(m.name ?? `MAT${i}`), 14)}`
      + `  ${num(m.e)}  ${num(m.nu)}  ${num(m.rho)}  ${num(m.fy)}`
      + extraTail(m, 'MATERIAL'));
  }
  w('');

  w('# 단면    SECTION  <번호>  <이름>  <A, m2>  <Iy, m4>  <Iz, m4>  <J, m4>  <b, m>  <h, m>  [형상]');
  w('#         Iy 가 면내 휨(강축)에 쓰입니다.');
  for (const i of sortedKeys(secs)) {
    const s = secs.get(i);
    w(`SECTION ${padStart(String(i), 4)}  ${pad(quote(s.name ?? `SEC${i}`), 14)}`
      + `  ${num(s.a)}  ${num(s.iy)}  ${num(s.iz)}  ${num(s.j)}`
      + `  ${num(s.b)}  ${num(s.h)}  ${quote(s.shape ?? '-')}`
      + extraTail(s, 'SECTION'));
  }
  w('');

  w('# 부재    ELEMENT  <번호>  <frame|truss>  <절점I>  <절점J>  <재료>  <단면>  [해제I]  [해제J]');
  w("#         해제는 my, mz, t 를 쉼표로. 없으면 '-'.");
  for (const i of sortedKeys(elems)) {
    const e = elems.get(i);
    w(`ELEMENT ${padStart(String(i), 4)}  ${pad(String(e.type ?? 'frame'), 6)}`
      + `  ${padStart(String(e.nodeI), 4)}  ${padStart(String(e.nodeJ), 4)}`
      + `  ${padStart(String(e.materialId ?? 1), 3)}  ${padStart(String(e.sectionId ?? 1), 3)}`
      + `  ${pad(releaseStr(e.releaseI), 8)}  ${releaseStr(e.releaseJ)}`
      + extraTail(e, 'ELEMENT'));
  }
  w('');

  w('# 지점    SUPPORT  <절점>  <종류>  [key=value ...]');
  w('#         종류: fixed  pinned  rollerX  rollerZ  spring  inclinedRoller');
  w('#         스프링은 kx=, kz=, 경사롤러는 angle=(라디안)');
  for (const i of sortedKeys(sups)) {
    const s = sups.get(i);
    w(`SUPPORT ${padStart(String(s.nodeId), 4)}  ${pad(String(s.type ?? 'pinned'), 14)}`
      + extraTail(s, 'SUPPORT'));
  }
  w('');

  w('# 하중케이스  LOADCASE  <번호>  <종류>  <이름>        종류: D L W S E T');
  for (const c of cases) {
    w(`LOADCASE ${padStart(String(c.id), 3)}  ${pad(String(c.type ?? 'D'), 3)}`
      + `  ${quote(c.name ?? `CASE${c.id}`)}`);
  }
  w('');

  w('# 하중    LOAD  <종류>  key=value ...');
  w('#   nodal  node=  case=  fx=  fz=  my=            절점하중 (kN, kN·m)');
  w('#   dist   elem=  case=  qI=  qJ=  [a=]  [b=]     등분포/사다리꼴 (kN/m)');
  w('#   point  elem=  case=  a=  [p=]  [px=]  [my=]   부재상 집중하중');
  w('#   temp   elem=  case=  dt=  dtg=                온도 (균일, 구배)');
  for (const ld of loads) {
    const d = ld.data ?? {};
    const c = d.caseId ?? 1;
    if (ld.type === 'nodal') {
      w(`LOAD    nodal   node=${d.nodeId}  case=${c}`
        + `  fx=${num(d.fx)}  fz=${num(d.fz)}  my=${num(d.my)}`);
    } else if (ld.type === 'distributed') {
      let ab = '';
      if (d.a != null) ab += `  a=${num(d.a)}`;
      if (d.b != null) ab += `  b=${num(d.b)}`;
      w(`LOAD    dist    elem=${d.elementId}  case=${c}`
        + `  qI=${num(d.qI)}  qJ=${num(d.qJ)}${ab}`);
    } else if (ld.type === 'pointOnElement') {
      let opt = '';
      for (const k of ['p', 'px', 'my']) if (d[k]) opt += `  ${k}=${num(d[k])}`;
      w(`LOAD    point   elem=${d.elementId}  case=${c}  a=${num(d.a)}${opt}`);
    } else if (ld.type === 'thermal') {
      w(`LOAD    temp    elem=${d.elementId}  case=${c}`
        + `  dt=${num(d.dtUniform)}  dtg=${num(d.dtGradient)}`);
    } else {
      w(`# (변환되지 않은 하중: ${ld.type})`);
    }
  }
  w('');

  w('# 조합    COMBO  <번호>  <이름>  <케이스:계수> ...');
  for (const cb of combos) {
    const terms = (cb.factors ?? [])
      .map((f: any) => `${f.caseId}:${num(f.factor)}`).join(' ');
    w(`COMBO   ${padStart(String(cb.id), 4)}  ${pad(quote(cb.name ?? ''), 20)}  ${terms}`);
  }
  w('');

  // 텍스트로 표현하지 않는 설정을 그대로 실어 왕복에서 잃지 않게 한다.
  // 값이 undefined 인 키는 건너뛴다. JSON.stringify(undefined) 는 문자열이
  // 아니라 undefined 를 돌려주므로, 그대로 쓰면 'undefined' 라는 글자가
  // 파일에 남아 다시 읽을 때 JSON.parse 가 실패한다.
  const extras: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(snap)) {
    if (!MODELLED.has(k) && v !== undefined) extras[k] = v;
  }
  if (uiStore.appMode !== undefined) extras['__top__appMode'] = uiStore.appMode;
  if (uiStore.axisConvention3D !== undefined) extras['__top__axisConvention3D'] = uiStore.axisConvention3D;
  if (uiStore.viewportPresentation3D !== undefined) extras['__top__viewportPresentation3D'] = uiStore.viewportPresentation3D;

  w('# ─────────────────────────────────────────────────────────');
  w('# 아래는 프로그램 설정입니다. 편집하지 마세요.');
  w('# (지우면 기본값으로 되돌아갈 뿐, 파일은 그대로 열립니다)');
  for (const k of Object.keys(extras).sort()) {
    const json = JSON.stringify(extras[k]);
    if (json === undefined) continue;   // 함수/심볼 등 직렬화 불가한 값
    w(`EXTRA   ${k}  ${json}`);
  }
  w('');

  return L.join('\n');
}

// ─────────────────────────────────────────────────────────────────────
// 가져오기
// ─────────────────────────────────────────────────────────────────────

export interface TextParseResult {
  ok: boolean;
  errors: string[];
  file?: any;
  counts?: { nodes: number; elements: number; loads: number };
}

export function textToProjectFile(text: string): TextParseResult {
  const errors: string[] = [];
  const nodes = new Map<number, any>();
  const mats = new Map<number, any>();
  const secs = new Map<number, any>();
  const elems = new Map<number, any>();
  const sups = new Map<number, any>();
  const cases = new Map<number, any>();
  const combos: any[] = [];
  const loads: any[] = [];
  const extras: Record<string, any> = {};
  const topExtras: Record<string, any> = {};
  let name = 'Model';
  let mode = '2d';

  const lines = text.split(/\r?\n/);
  for (let li = 0; li < lines.length; li++) {
    const lineno = li + 1;
    const raw = lines[li];
    const trimmed = raw.trim();

    // EXTRA 는 값이 JSON 이라 낱말 분해를 거치면 따옴표가 벗겨진다.
    if (/^EXTRA[\s]/i.test(trimmed)) {
      const rest = trimmed.slice(5).trim();
      const sp = rest.indexOf(' ');
      const key = sp < 0 ? rest : rest.slice(0, sp);
      const payload = sp < 0 ? '' : rest.slice(sp + 1).trim();
      // 값이 비었거나 'undefined' 면 그 설정이 없었다는 뜻이다. 이전
      // 빌드가 내보낸 파일에도 이런 줄이 있을 수 있으므로 조용히 넘긴다.
      if (payload === '' || payload === 'undefined') continue;
      try {
        const val = JSON.parse(payload);
        if (key.startsWith('__top__')) topExtras[key.slice(7)] = val;
        else extras[key] = val;
      } catch {
        errors.push(`${lineno}행: EXTRA '${key}' 의 값을 읽을 수 없습니다.`);
      }
      continue;
    }

    let tok: string[];
    try { tok = splitLine(raw); }
    catch (e: any) { errors.push(`${lineno}행: ${e.message}`); continue; }
    if (!tok.length) continue;

    const kind = tok[0].toUpperCase();
    try {
      if (kind === 'MODEL') {
        const d = kvFrom(tok, 1, lineno);
        if (d.name) name = d.name;
        if (d.mode) mode = d.mode;

      } else if (kind === 'NODE') {
        if (tok.length < 4) throw new Error(`${lineno}행: NODE 는 번호, x, z 가 필요합니다.`);
        const id = requireNum(tok[1], '번호', lineno);
        nodes.set(id, absorbExtras(
          { id, x: requireNum(tok[2], 'x', lineno), y: requireNum(tok[3], 'z', lineno) },
          kvFrom(tok, 4, lineno), lineno));

      } else if (kind === 'MATERIAL') {
        if (tok.length < 4) throw new Error(`${lineno}행: MATERIAL 은 번호, 이름, E 가 필요합니다.`);
        const id = requireNum(tok[1], '번호', lineno);
        mats.set(id, absorbExtras({
          id, name: tok[2], e: requireNum(tok[3], 'E', lineno),
          nu: tok.length > 4 ? requireNum(tok[4], '포아송비', lineno) : 0.3,
          rho: tok.length > 5 ? requireNum(tok[5], '단위중량', lineno) : 0,
          fy: tok.length > 6 ? requireNum(tok[6], 'fy', lineno) : 0,
        }, kvFrom(tok, 7, lineno), lineno));

      } else if (kind === 'SECTION') {
        if (tok.length < 5) throw new Error(`${lineno}행: SECTION 은 번호, 이름, A, Iy 가 필요합니다.`);
        const id = requireNum(tok[1], '번호', lineno);
        const g = (i: number, f: string) => (tok.length > i ? requireNum(tok[i], f, lineno) : 0);
        const sec: any = {
          id, name: tok[2], a: requireNum(tok[3], 'A', lineno),
          iy: requireNum(tok[4], 'Iy', lineno),
          iz: g(5, 'Iz'), j: g(6, 'J'), b: g(7, 'b'), h: g(8, 'h'),
        };
        if (tok.length > 9 && tok[9] !== '-' && tok[9] !== '') sec.shape = tok[9];
        secs.set(id, absorbExtras(sec, kvFrom(tok, 10, lineno), lineno));

      } else if (kind === 'ELEMENT') {
        if (tok.length < 7) {
          throw new Error(`${lineno}행: ELEMENT 는 번호, 종류, 절점I, 절점J, 재료, 단면이 필요합니다.`);
        }
        const id = requireNum(tok[1], '번호', lineno);
        const type = tok[2].toLowerCase();
        if (type !== 'frame' && type !== 'truss') {
          throw new Error(`${lineno}행: 부재 종류는 frame 또는 truss 입니다 ('${tok[2]}').`);
        }
        elems.set(id, absorbExtras({
          id, type,
          nodeI: requireNum(tok[3], '절점I', lineno),
          nodeJ: requireNum(tok[4], '절점J', lineno),
          materialId: requireNum(tok[5], '재료', lineno),
          sectionId: requireNum(tok[6], '단면', lineno),
          releaseI: parseRelease(tok[7] ?? '-'),
          releaseJ: parseRelease(tok[8] ?? '-'),
        }, kvFrom(tok, 9, lineno), lineno));

      } else if (kind === 'SUPPORT') {
        if (tok.length < 3) throw new Error(`${lineno}행: SUPPORT 는 절점과 종류가 필요합니다.`);
        if (!SUPPORT_TYPES.has(tok[2])) {
          throw new Error(`${lineno}행: 알 수 없는 지점 종류 '${tok[2]}' 입니다. `
            + `가능한 값: ${[...SUPPORT_TYPES].join(', ')}`);
        }
        const id = sups.size + 1;
        sups.set(id, absorbExtras(
          { id, nodeId: requireNum(tok[1], '절점', lineno), type: tok[2] },
          kvFrom(tok, 3, lineno), lineno));

      } else if (kind === 'LOADCASE') {
        if (tok.length < 3) throw new Error(`${lineno}행: LOADCASE 는 번호와 종류가 필요합니다.`);
        const id = requireNum(tok[1], '번호', lineno);
        cases.set(id, { id, type: tok[2], name: tok[3] ?? `CASE${id}` });

      } else if (kind === 'LOAD') {
        if (tok.length < 2) throw new Error(`${lineno}행: LOAD 는 종류가 필요합니다.`);
        const sub = tok[1].toLowerCase();
        const d = kvFrom(tok, 2, lineno);
        const n = (k: string, dflt = 0) => (d[k] === undefined ? dflt : requireNum(d[k], k, lineno));
        const need = (k: string) => {
          if (d[k] === undefined) throw new Error(`${lineno}행: ${sub} 에 '${k}=' 가 필요합니다.`);
          return requireNum(d[k], k, lineno);
        };
        const caseId = n('case', 1);
        const id = loads.length + 1;

        if (sub === 'nodal') {
          loads.push({ type: 'nodal', data: { id, nodeId: need('node'), fx: n('fx'), fz: n('fz'), my: n('my'), caseId } });
        } else if (sub === 'dist' || sub === 'distributed') {
          const data: any = { id, elementId: need('elem'), qI: n('qI'), qJ: n('qJ'), caseId };
          if (d.a !== undefined) data.a = n('a');
          if (d.b !== undefined) data.b = n('b');
          loads.push({ type: 'distributed', data });
        } else if (sub === 'point' || sub === 'pointonelement') {
          const data: any = { id, elementId: need('elem'), a: n('a'), caseId };
          for (const k of ['p', 'px', 'my']) if (d[k] !== undefined) data[k] = n(k);
          loads.push({ type: 'pointOnElement', data });
        } else if (sub === 'temp' || sub === 'thermal') {
          loads.push({ type: 'thermal', data: { id, elementId: need('elem'), dtUniform: n('dt'), dtGradient: n('dtg'), caseId } });
        } else {
          throw new Error(`${lineno}행: 하중 종류는 nodal, dist, point, temp 입니다 ('${tok[1]}').`);
        }

      } else if (kind === 'COMBO') {
        if (tok.length < 3) throw new Error(`${lineno}행: COMBO 는 번호와 이름이 필요합니다.`);
        const factors = [];
        for (let i = 3; i < tok.length; i++) {
          const t = tok[i];
          const c = t.indexOf(':');
          if (c < 0) throw new Error(`${lineno}행: 조합 항은 '케이스:계수' 형태입니다 ('${t}').`);
          factors.push({
            caseId: requireNum(t.slice(0, c), '케이스', lineno),
            factor: requireNum(t.slice(c + 1), '계수', lineno),
          });
        }
        combos.push({ id: requireNum(tok[1], '번호', lineno), name: tok[2], factors });

      } else {
        errors.push(`${lineno}행: 알 수 없는 항목 '${tok[0]}' 입니다.`);
      }
    } catch (e: any) {
      errors.push(e.message);
    }
  }

  // 참조 무결성 — 여기서 걸러야 로더가 조용히 파일을 거부하지 않는다.
  for (const [id, e] of elems) {
    for (const side of ['nodeI', 'nodeJ'] as const) {
      if (!nodes.has(e[side])) errors.push(`부재 ${id}: 절점 ${e[side]} 가 정의되지 않았습니다.`);
    }
    if (!mats.has(e.materialId)) errors.push(`부재 ${id}: 재료 ${e.materialId} 가 정의되지 않았습니다.`);
    if (!secs.has(e.sectionId)) errors.push(`부재 ${id}: 단면 ${e.sectionId} 가 정의되지 않았습니다.`);
  }
  for (const s of sups.values()) {
    if (!nodes.has(s.nodeId)) errors.push(`지점: 절점 ${s.nodeId} 가 정의되지 않았습니다.`);
  }
  for (const ld of loads) {
    const d = ld.data;
    if (d.nodeId !== undefined && !nodes.has(d.nodeId)) errors.push(`하중: 절점 ${d.nodeId} 가 정의되지 않았습니다.`);
    if (d.elementId !== undefined && !elems.has(d.elementId)) errors.push(`하중: 부재 ${d.elementId} 가 정의되지 않았습니다.`);
    if (cases.size && !cases.has(d.caseId)) errors.push(`하중: 하중케이스 ${d.caseId} 가 정의되지 않았습니다.`);
  }
  if (!nodes.size) errors.push('절점이 하나도 없습니다.');

  if (errors.length) {
    return { ok: false, errors: [...new Set(errors)] };
  }

  if (!cases.size) cases.set(1, { id: 1, type: 'D', name: 'Dead Load' });

  const maxOf = (m: Map<number, any>) => (m.size ? Math.max(...m.keys()) : 0);
  const nextId = {
    ...(extras.nextId ?? {}),
    node: maxOf(nodes) + 1,
    element: maxOf(elems) + 1,
    material: maxOf(mats) + 1,
    section: maxOf(secs) + 1,
    support: maxOf(sups) + 1,
    load: loads.length + 1,
    loadCase: maxOf(cases) + 1,
    combination: combos.reduce((a, c) => Math.max(a, c.id), 0) + 1,
  };

  const pairs = (m: Map<number, any>) =>
    [...m.keys()].sort((a, b) => a - b).map((k) => [k, m.get(k)]);

  const snapshot: any = {
    name,
    nodes: pairs(nodes),
    materials: pairs(mats),
    sections: pairs(secs),
    elements: pairs(elems),
    supports: pairs(sups),
    loads,
    loadCases: [...cases.keys()].sort((a, b) => a - b).map((k) => cases.get(k)),
    combinations: combos,
    plates: [], quads: [], constraints: [], connectors: [],
    nextId,
    localAxisConvention: 'zUpStrongAxis',
  };
  for (const [k, v] of Object.entries(extras)) if (k !== 'nextId') snapshot[k] = v;

  const file: any = {
    version: '2.0',
    name,
    timestamp: new Date().toISOString(),
    snapshot,
    analysisMode: mode,
    ...topExtras,
  };

  return {
    ok: true,
    errors: [],
    file,
    counts: { nodes: nodes.size, elements: elems.size, loads: loads.length },
  };
}

// ─────────────────────────────────────────────────────────────────────
// UI 진입점
// ─────────────────────────────────────────────────────────────────────

function safeName(n: string): string {
  const cleaned = (n || '').replace(/[^a-zA-Z0-9 _-]/g, '').trim();
  return cleaned || 'model';
}

export function downloadModelText(): void {
  downloadText(modelToText(), `${safeName(modelStore.model.name)}.txt`, 'text/plain');
}

/**
 * 텍스트를 읽어 모델을 교체한다. .ded 열기와 같은 경로를 쓰되,
 * 파일을 거부하는 대신 무엇이 잘못됐는지 행 번호로 알려준다.
 */
export async function openModelText(file: File): Promise<{ ok: boolean; message: string }> {
  const text = await file.text();
  const res = textToProjectFile(text);

  if (!res.ok) {
    const head = res.errors.slice(0, 8).map((e) => '  · ' + e).join('\n');
    const more = res.errors.length > 8 ? `\n  ... 외 ${res.errors.length - 8}건` : '';
    return { ok: false, message: `텍스트를 읽는 중 문제가 있습니다.\n${head}${more}` };
  }

  historyStore.pushState();
  modelStore.restore(res.file.snapshot);
  modelStore.model.name = res.file.name;
  if (res.file.analysisMode) uiStore.analysisMode = res.file.analysisMode;
  if (res.file.axisConvention3D) uiStore.axisConvention3D = res.file.axisConvention3D;
  if (res.file.viewportPresentation3D) uiStore.viewportPresentation3D = res.file.viewportPresentation3D;
  resultsStore.clear();

  const c = res.counts!;
  return { ok: true, message: `불러왔습니다. 절점 ${c.nodes}, 부재 ${c.elements}, 하중 ${c.loads}` };
}
