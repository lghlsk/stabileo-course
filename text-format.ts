/**
 * text-format.ts — a model format a person can read and edit.
 *
 * For changing a coordinate or a load without going through the graphical
 * editor. One entry per line, the first word says what kind, and anything
 * after '#' is a comment.
 *
 * Every string the user sees goes through `t()` / `tp()`. The file this
 * writes is localised too: its header comments explain the format, and a
 * reader who cannot read them cannot edit the file. The keys live under
 * `textio.*`; the format's own words — NODE, MATERIAL, fx, qI — are not
 * translated, because they are syntax rather than prose.
 *
 * The encoding and decoding rules here are the same as dedtext.py's. Change
 * one and the other has to follow.
 */

import { modelStore } from '../store/model.svelte';
import { uiStore } from '../store/ui.svelte';
import { historyStore } from '../store/history.svelte';
import { resultsStore } from '../store/results.svelte';
import { downloadText } from '../store/file';
import { t, tp } from '../i18n';

export const TEXT_FORMAT_VERSION = '1';

const RELEASE_KEYS = ['my', 'mz', 't'] as const;

const SUPPORT_TYPES = new Set([
  'fixed', 'pinned', 'rollerX', 'rollerZ', 'rollerY', 'spring', 'inclinedRoller',
]);

/** Fields carried as positional arguments. The rest survive as trailing key=value. */
const KNOWN: Record<string, Set<string>> = {
  NODE: new Set(['id', 'x', 'y', 'z']),
  MATERIAL: new Set(['id', 'name', 'e', 'nu', 'rho', 'fy']),
  SECTION: new Set(['id', 'name', 'a', 'iy', 'iz', 'j', 'b', 'h', 'shape']),
  ELEMENT: new Set(['id', 'type', 'nodeI', 'nodeJ', 'materialId', 'sectionId',
    'releaseI', 'releaseJ']),
  SUPPORT: new Set(['id', 'nodeId', 'type']),
};

/** Snapshot keys the text carries. Everything else is preserved verbatim as EXTRA. */
const MODELLED = new Set([
  'name', 'nodes', 'materials', 'sections', 'elements',
  'supports', 'loads', 'loadCases', 'combinations', 'nextId',
]);

// ─────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────

function num(v: unknown): string {
  const f = Number(v ?? 0);
  if (!Number.isFinite(f)) return '0';
  return Number.isInteger(f) ? String(f) : String(Number(f.toPrecision(12)));
}

function quote(s: unknown): string {
  // Not named `t`: that is the translation function, imported above.
  const str = s == null ? '' : String(s);
  return (str === '' || /[\s"#]/.test(str)) ? `"${str}"` : str;
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
      throw new Error(tp('textio.err.unknownRelease', { flag: k }));
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
      catch { throw new Error(tp('textio.err.badValue', { line, key: k })); }
    } else if (v === 'true' || v === 'false') {
      obj[k] = v === 'true';
    } else {
      const f = Number(v);
      obj[k] = Number.isFinite(f) && v.trim() !== '' ? f : v;
    }
  }
  return obj;
}

/** Split into words, honouring quotes. Anything after '#' is dropped. */
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
  if (inQuote) throw new Error(t('textio.err.unclosedQuote'));
  if (has || cur) out.push(cur);
  return out;
}

function kvFrom(tokens: string[], start: number, line: number): Record<string, string> {
  const out: Record<string, string> = {};
  for (let i = start; i < tokens.length; i++) {
    const tok = tokens[i];
    const eq = tok.indexOf('=');
    if (eq < 0) throw new Error(tp('textio.err.notKeyValue', { line, token: tok }));
    out[tok.slice(0, eq).trim()] = tok.slice(eq + 1).trim();
  }
  return out;
}

/**
 * `field` arrives already translated.
 *
 * Most call sites pass the format's own name — 'x', 'E', 'Iy', 'fx' — which is
 * the same word in every language and is what the user sees in the file. The
 * ones that would otherwise read as prose pass `t('textio.field.*')`.
 */
function requireNum(tok: string | undefined, field: string, line: number): number {
  const f = Number(tok);
  if (tok === undefined || tok === '' || !Number.isFinite(f)) {
    throw new Error(tp('textio.err.needNumber', { line, field, got: tok ?? '' }));
  }
  return f;
}

// ─────────────────────────────────────────────────────────────────────
// Export
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

  w('# ' + tp('textio.head.title', { version: TEXT_FORMAT_VERSION }));
  w('#');
  w('# ' + t('textio.head.edit'));
  w('# ' + t('textio.head.path'));
  w('#');
  w('# ' + t('textio.head.comment'));
  w('# ' + t('textio.head.quote'));
  w('');
  w(`MODEL   name=${quote(modelStore.model.name)}   mode=${uiStore.analysisMode}`);
  w('');

  w('# ' + t('textio.head.node'));
  w('#         ' + t('textio.head.nodeAxis'));
  for (const i of sortedKeys(nodes)) {
    const n = nodes.get(i);
    const z = n.z ?? n.y ?? 0;
    w(`NODE    ${padStart(String(i), 4)}  ${padStart(num(n.x), 10)}  ${padStart(num(z), 10)}`
      + extraTail(n, 'NODE'));
  }
  w('');

  w('# ' + t('textio.head.material'));
  for (const i of sortedKeys(mats)) {
    const m = mats.get(i);
    w(`MATERIAL ${padStart(String(i), 3)}  ${pad(quote(m.name ?? `MAT${i}`), 14)}`
      + `  ${num(m.e)}  ${num(m.nu)}  ${num(m.rho)}  ${num(m.fy)}`
      + extraTail(m, 'MATERIAL'));
  }
  w('');

  w('# ' + t('textio.head.section'));
  w('#         ' + t('textio.head.sectionAxis'));
  for (const i of sortedKeys(secs)) {
    const s = secs.get(i);
    w(`SECTION ${padStart(String(i), 4)}  ${pad(quote(s.name ?? `SEC${i}`), 14)}`
      + `  ${num(s.a)}  ${num(s.iy)}  ${num(s.iz)}  ${num(s.j)}`
      + `  ${num(s.b)}  ${num(s.h)}  ${quote(s.shape ?? '-')}`
      + extraTail(s, 'SECTION'));
  }
  w('');

  w('# ' + t('textio.head.element'));
  w('#         ' + t('textio.head.elementRelease'));
  for (const i of sortedKeys(elems)) {
    const e = elems.get(i);
    w(`ELEMENT ${padStart(String(i), 4)}  ${pad(String(e.type ?? 'frame'), 6)}`
      + `  ${padStart(String(e.nodeI), 4)}  ${padStart(String(e.nodeJ), 4)}`
      + `  ${padStart(String(e.materialId ?? 1), 3)}  ${padStart(String(e.sectionId ?? 1), 3)}`
      + `  ${pad(releaseStr(e.releaseI), 8)}  ${releaseStr(e.releaseJ)}`
      + extraTail(e, 'ELEMENT'));
  }
  w('');

  w('# ' + t('textio.head.support'));
  w('#         ' + t('textio.head.supportTypes'));
  w('#         ' + t('textio.head.supportParams'));
  for (const i of sortedKeys(sups)) {
    const s = sups.get(i);
    w(`SUPPORT ${padStart(String(s.nodeId), 4)}  ${pad(String(s.type ?? 'pinned'), 14)}`
      + extraTail(s, 'SUPPORT'));
  }
  w('');

  w('# ' + t('textio.head.loadcase'));
  for (const lc of cases) {
    w(`LOADCASE ${padStart(String(lc.id), 3)}  ${pad(String(lc.type ?? 'D'), 3)}`
      + `  ${quote(lc.name ?? `CASE${lc.id}`)}`);
  }
  w('');

  w('# ' + t('textio.head.load'));
  w('#   ' + t('textio.head.loadNodal'));
  w('#   ' + t('textio.head.loadDist'));
  w('#   ' + t('textio.head.loadPoint'));
  w('#   ' + t('textio.head.loadTemp'));
  for (const ld of loads) {
    const d = ld.data ?? {};
    const caseId = d.caseId ?? 1;
    if (ld.type === 'nodal') {
      w(`LOAD    nodal   node=${d.nodeId}  case=${caseId}`
        + `  fx=${num(d.fx)}  fz=${num(d.fz)}  my=${num(d.my)}`);
    } else if (ld.type === 'distributed') {
      let ab = '';
      if (d.a != null) ab += `  a=${num(d.a)}`;
      if (d.b != null) ab += `  b=${num(d.b)}`;
      w(`LOAD    dist    elem=${d.elementId}  case=${caseId}`
        + `  qI=${num(d.qI)}  qJ=${num(d.qJ)}${ab}`);
    } else if (ld.type === 'pointOnElement') {
      let opt = '';
      for (const k of ['p', 'px', 'my']) if (d[k]) opt += `  ${k}=${num(d[k])}`;
      w(`LOAD    point   elem=${d.elementId}  case=${caseId}  a=${num(d.a)}${opt}`);
    } else if (ld.type === 'thermal') {
      w(`LOAD    temp    elem=${d.elementId}  case=${caseId}`
        + `  dt=${num(d.dtUniform)}  dtg=${num(d.dtGradient)}`);
    } else {
      w('# ' + tp('textio.head.loadSkipped', { type: ld.type }));
    }
  }
  w('');

  w('# ' + t('textio.head.combo'));
  for (const cb of combos) {
    const terms = (cb.factors ?? [])
      .map((f: any) => `${f.caseId}:${num(f.factor)}`).join(' ');
    w(`COMBO   ${padStart(String(cb.id), 4)}  ${pad(quote(cb.name ?? ''), 20)}  ${terms}`);
  }
  w('');

  // Settings the text does not model, carried verbatim so a round trip loses nothing.
  // Keys whose value is `undefined` are skipped: JSON.stringify(undefined) returns
  // undefined rather than a string, so writing it puts the word 'undefined' in the
  // file and JSON.parse fails on the way back in.
  const extras: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(snap)) {
    if (!MODELLED.has(k) && v !== undefined) extras[k] = v;
  }
  if (uiStore.appMode !== undefined) extras['__top__appMode'] = uiStore.appMode;
  if (uiStore.axisConvention3D !== undefined) extras['__top__axisConvention3D'] = uiStore.axisConvention3D;
  if (uiStore.viewportPresentation3D !== undefined) extras['__top__viewportPresentation3D'] = uiStore.viewportPresentation3D;

  w('# ─────────────────────────────────────────────────────────');
  w('# ' + t('textio.head.extra'));
  w('# ' + t('textio.head.extraNote'));
  for (const k of Object.keys(extras).sort()) {
    const json = JSON.stringify(extras[k]);
    if (json === undefined) continue;   // functions, symbols — not serialisable
    w(`EXTRA   ${k}  ${json}`);
  }
  w('');

  return L.join('\n');
}

// ─────────────────────────────────────────────────────────────────────
// Import
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

    // EXTRA carries JSON, which would lose its quotes if it went through the word split.
    if (/^EXTRA[\s]/i.test(trimmed)) {
      const rest = trimmed.slice(5).trim();
      const sp = rest.indexOf(' ');
      const key = sp < 0 ? rest : rest.slice(0, sp);
      const payload = sp < 0 ? '' : rest.slice(sp + 1).trim();
      // An empty value, or the word 'undefined', means the setting was absent.
      // Files written by an earlier build can carry such a line, so pass over it.
      if (payload === '' || payload === 'undefined') continue;
      try {
        const val = JSON.parse(payload);
        if (key.startsWith('__top__')) topExtras[key.slice(7)] = val;
        else extras[key] = val;
      } catch {
        errors.push(tp('textio.err.badExtra', { line: lineno, key }));
      }
      continue;
    }

    let tok: string[];
    try { tok = splitLine(raw); }
    catch (e: any) {
      errors.push(tp('textio.err.atLine', { line: lineno, message: e.message }));
      continue;
    }
    if (!tok.length) continue;

    const kind = tok[0].toUpperCase();
    try {
      if (kind === 'MODEL') {
        const d = kvFrom(tok, 1, lineno);
        if (d.name) name = d.name;
        if (d.mode) mode = d.mode;

      } else if (kind === 'NODE') {
        if (tok.length < 4) throw new Error(tp('textio.err.nodeFields', { line: lineno }));
        const id = requireNum(tok[1], t('textio.field.id'), lineno);
        nodes.set(id, absorbExtras(
          { id, x: requireNum(tok[2], 'x', lineno), y: requireNum(tok[3], 'z', lineno) },
          kvFrom(tok, 4, lineno), lineno));

      } else if (kind === 'MATERIAL') {
        if (tok.length < 4) throw new Error(tp('textio.err.materialFields', { line: lineno }));
        const id = requireNum(tok[1], t('textio.field.id'), lineno);
        mats.set(id, absorbExtras({
          id, name: tok[2], e: requireNum(tok[3], 'E', lineno),
          nu: tok.length > 4 ? requireNum(tok[4], t('textio.field.poisson'), lineno) : 0.3,
          rho: tok.length > 5 ? requireNum(tok[5], t('textio.field.unitWeight'), lineno) : 0,
          fy: tok.length > 6 ? requireNum(tok[6], 'fy', lineno) : 0,
        }, kvFrom(tok, 7, lineno), lineno));

      } else if (kind === 'SECTION') {
        if (tok.length < 5) throw new Error(tp('textio.err.sectionFields', { line: lineno }));
        const id = requireNum(tok[1], t('textio.field.id'), lineno);
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
          throw new Error(tp('textio.err.elementFields', { line: lineno }));
        }
        const id = requireNum(tok[1], t('textio.field.id'), lineno);
        const type = tok[2].toLowerCase();
        if (type !== 'frame' && type !== 'truss') {
          throw new Error(tp('textio.err.elementType', { line: lineno, got: tok[2] }));
        }
        elems.set(id, absorbExtras({
          id, type,
          nodeI: requireNum(tok[3], t('textio.field.nodeI'), lineno),
          nodeJ: requireNum(tok[4], t('textio.field.nodeJ'), lineno),
          materialId: requireNum(tok[5], t('textio.field.material'), lineno),
          sectionId: requireNum(tok[6], t('textio.field.section'), lineno),
          releaseI: parseRelease(tok[7] ?? '-'),
          releaseJ: parseRelease(tok[8] ?? '-'),
        }, kvFrom(tok, 9, lineno), lineno));

      } else if (kind === 'SUPPORT') {
        if (tok.length < 3) throw new Error(tp('textio.err.supportFields', { line: lineno }));
        if (!SUPPORT_TYPES.has(tok[2])) {
          throw new Error(tp('textio.err.supportType', {
            line: lineno, got: tok[2], valid: [...SUPPORT_TYPES].join(', '),
          }));
        }
        const id = sups.size + 1;
        sups.set(id, absorbExtras(
          { id, nodeId: requireNum(tok[1], t('textio.field.node'), lineno), type: tok[2] },
          kvFrom(tok, 3, lineno), lineno));

      } else if (kind === 'LOADCASE') {
        if (tok.length < 3) throw new Error(tp('textio.err.loadcaseFields', { line: lineno }));
        const id = requireNum(tok[1], t('textio.field.id'), lineno);
        cases.set(id, { id, type: tok[2], name: tok[3] ?? `CASE${id}` });

      } else if (kind === 'LOAD') {
        if (tok.length < 2) throw new Error(tp('textio.err.loadFields', { line: lineno }));
        const sub = tok[1].toLowerCase();
        const d = kvFrom(tok, 2, lineno);
        const n = (k: string, dflt = 0) => (d[k] === undefined ? dflt : requireNum(d[k], k, lineno));
        const need = (k: string) => {
          if (d[k] === undefined) {
            throw new Error(tp('textio.err.loadNeedsKey', { line: lineno, sub, key: k }));
          }
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
          throw new Error(tp('textio.err.loadType', { line: lineno, got: tok[1] }));
        }

      } else if (kind === 'COMBO') {
        if (tok.length < 3) throw new Error(tp('textio.err.comboFields', { line: lineno }));
        const factors = [];
        for (let i = 3; i < tok.length; i++) {
          const term = tok[i];
          const colon = term.indexOf(':');
          if (colon < 0) {
            throw new Error(tp('textio.err.comboTerm', { line: lineno, got: term }));
          }
          factors.push({
            caseId: requireNum(term.slice(0, colon), t('textio.field.case'), lineno),
            factor: requireNum(term.slice(colon + 1), t('textio.field.factor'), lineno),
          });
        }
        combos.push({
          id: requireNum(tok[1], t('textio.field.id'), lineno),
          name: tok[2],
          factors,
        });

      } else {
        errors.push(tp('textio.err.unknownKind', { line: lineno, got: tok[0] }));
      }
    } catch (e: any) {
      errors.push(e.message);
    }
  }

  // Referential integrity — caught here, because the loader rejects a bad file silently.
  for (const [id, e] of elems) {
    for (const side of ['nodeI', 'nodeJ'] as const) {
      if (!nodes.has(e[side])) errors.push(tp('textio.err.refNode', { id, ref: e[side] }));
    }
    if (!mats.has(e.materialId)) errors.push(tp('textio.err.refMaterial', { id, ref: e.materialId }));
    if (!secs.has(e.sectionId)) errors.push(tp('textio.err.refSection', { id, ref: e.sectionId }));
  }
  for (const s of sups.values()) {
    if (!nodes.has(s.nodeId)) errors.push(tp('textio.err.refSupportNode', { ref: s.nodeId }));
  }
  for (const ld of loads) {
    const d = ld.data;
    if (d.nodeId !== undefined && !nodes.has(d.nodeId)) errors.push(tp('textio.err.refLoadNode', { ref: d.nodeId }));
    if (d.elementId !== undefined && !elems.has(d.elementId)) errors.push(tp('textio.err.refLoadElement', { ref: d.elementId }));
    if (cases.size && !cases.has(d.caseId)) errors.push(tp('textio.err.refLoadCase', { ref: d.caseId }));
  }
  if (!nodes.size) errors.push(t('textio.err.noNodes'));

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
    combination: combos.reduce((a, cb) => Math.max(a, cb.id), 0) + 1,
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
// UI entry points
// ─────────────────────────────────────────────────────────────────────

function safeName(n: string): string {
  const cleaned = (n || '').replace(/[^a-zA-Z0-9 _-]/g, '').trim();
  return cleaned || 'model';
}

export function downloadModelText(): void {
  downloadText(modelToText(), `${safeName(modelStore.model.name)}.txt`, 'text/plain');
}

/**
 * Read a text file and replace the model.
 *
 * Takes the same path as opening a .ded, but instead of refusing the file it
 * says what is wrong and on which line.
 */
export async function openModelText(file: File): Promise<{ ok: boolean; message: string }> {
  const text = await file.text();
  const res = textToProjectFile(text);

  if (!res.ok) {
    const head = res.errors.slice(0, 8).map((e) => '  · ' + e).join('\n');
    const more = res.errors.length > 8
      ? '\n  ' + tp('textio.msg.andMore', { n: res.errors.length - 8 })
      : '';
    return { ok: false, message: `${t('textio.msg.parseFailed')}\n${head}${more}` };
  }

  historyStore.pushState();
  modelStore.restore(res.file.snapshot);
  modelStore.model.name = res.file.name;
  if (res.file.analysisMode) uiStore.analysisMode = res.file.analysisMode;
  if (res.file.axisConvention3D) uiStore.axisConvention3D = res.file.axisConvention3D;
  if (res.file.viewportPresentation3D) uiStore.viewportPresentation3D = res.file.viewportPresentation3D;
  resultsStore.clear();

  const c = res.counts!;
  return {
    ok: true,
    message: tp('textio.msg.loaded', { nodes: c.nodes, elements: c.elements, loads: c.loads }),
  };
}
