/**
 * light-png.ts — 인쇄와 문서 첨부에 쓸 밝은 배경 PNG.
 *
 * 화면은 어두운 바탕에 밝은 선으로 그려진다. 그대로 내보내면 보고서나
 * 인쇄물에서 검은 사각형이 되고 토너도 많이 든다.
 *
 * 접근
 *   색상(H)과 채도(S)는 그대로 두고 명도(L)만 뒤집는다. 배경은 어두우니
 *   밝아지고, 부재와 글자는 밝으니 어두워진다. 인장 빨강과 압축 파랑은
 *   중간 명도라 거의 그대로 남아 서로 구분된다.
 *
 *     배경   #0c1620 → #dfe9f3      부재   #c7d3dd → #222e38
 *     글자   #f4f7fa → #05080b      인장   #e5482a → #d5381a
 *                                   압축   #2c6cb4 → #4b8bd3
 *
 * 이 방식은 2D 캔버스와 3D(Three.js) 캔버스에 똑같이 통한다. 3D 쪽은
 * 색이 하드코딩되어 있고 글자가 스프라이트 텍스처라 테마를 갈아끼우기
 * 어려운데, 결과 이미지를 다루면 그 구분이 필요 없다.
 *
 * 배경만은 예외로 순백으로 만든다. 명도만 뒤집으면 연한 청회색이 되어
 * 흰 문서에 붙였을 때 사각형 자국이 남는다.
 */

/** 배경으로 간주할 색과의 허용 오차. 안티에일리어싱 여유를 둔다. */
const BG_TOLERANCE = 10;

function rgbToHsl(r: number, g: number, b: number): [number, number, number] {
  r /= 255; g /= 255; b /= 255;
  const mx = Math.max(r, g, b);
  const mn = Math.min(r, g, b);
  const l = (mx + mn) / 2;
  if (mx === mn) return [0, 0, l];
  const d = mx - mn;
  const s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn);
  let h: number;
  if (mx === r) h = (g - b) / d + (g < b ? 6 : 0);
  else if (mx === g) h = (b - r) / d + 2;
  else h = (r - g) / d + 4;
  return [h / 6, s, l];
}

function hslToRgb(h: number, s: number, l: number): [number, number, number] {
  if (s === 0) {
    const v = Math.round(l * 255);
    return [v, v, v];
  }
  const q = l < 0.5 ? l * (1 + s) : l + s - l * s;
  const p = 2 * l - q;
  const f = (t: number): number => {
    t = (t + 1) % 1;
    if (t < 1 / 6) return p + (q - p) * 6 * t;
    if (t < 1 / 2) return q;
    if (t < 2 / 3) return p + (q - p) * (2 / 3 - t) * 6;
    return p;
  };
  return [
    Math.round(f(h + 1 / 3) * 255),
    Math.round(f(h) * 255),
    Math.round(f(h - 1 / 3) * 255),
  ];
}

function parseColor(css: string): [number, number, number] | null {
  const s = css.trim();
  let m = /^#([0-9a-f]{6})$/i.exec(s);
  if (m) {
    const n = parseInt(m[1], 16);
    return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
  }
  m = /^#([0-9a-f]{3})$/i.exec(s);
  if (m) {
    const [a, b, c] = m[1].split('');
    return [parseInt(a + a, 16), parseInt(b + b, 16), parseInt(c + c, 16)];
  }
  m = /^rgba?\(\s*([\d.]+)[\s,]+([\d.]+)[\s,]+([\d.]+)/i.exec(s);
  if (m) return [Math.round(+m[1]), Math.round(+m[2]), Math.round(+m[3])];
  return null;
}

/**
 * 화면 캡처를 밝은 배경으로 바꾼 캔버스를 돌려준다.
 *
 * @param src      뷰포트 캔버스
 * @param bgColor  배경으로 간주해 흰색으로 바꿀 색. 없으면 왼쪽 위
 *                 모서리 픽셀을 배경으로 본다.
 */
export function toLightCanvas(
  src: HTMLCanvasElement,
  bgColor?: string,
): HTMLCanvasElement {
  const w = src.width;
  const h = src.height;

  const out = document.createElement('canvas');
  out.width = w;
  out.height = h;
  const octx = out.getContext('2d');
  if (!octx) return src;

  // WebGL 캔버스는 getContext('2d') 를 쓸 수 없으므로 일단 복사한다.
  octx.drawImage(src, 0, 0);

  let img: ImageData;
  try {
    img = octx.getImageData(0, 0, w, h);
  } catch {
    // 교차 출처 오염 등으로 픽셀을 읽을 수 없으면 원본을 그대로 쓴다.
    return src;
  }
  const d = img.data;

  // 배경색 결정. 지정이 없으면 왼쪽 위 픽셀을 쓴다. 뷰포트 모서리는
  // 모델이 닿지 않는 것이 보통이다.
  let bg = bgColor ? parseColor(bgColor) : null;
  if (!bg) bg = [d[0], d[1], d[2]];

  for (let i = 0; i < d.length; i += 4) {
    if (d[i + 3] === 0) {
      // 투명한 곳은 흰 종이로 채운다.
      d[i] = 255; d[i + 1] = 255; d[i + 2] = 255; d[i + 3] = 255;
      continue;
    }

    const r = d[i], g = d[i + 1], b = d[i + 2];

    if (Math.abs(r - bg[0]) <= BG_TOLERANCE
      && Math.abs(g - bg[1]) <= BG_TOLERANCE
      && Math.abs(b - bg[2]) <= BG_TOLERANCE) {
      d[i] = 255; d[i + 1] = 255; d[i + 2] = 255;
      continue;
    }

    const [hh, ss, ll] = rgbToHsl(r, g, b);
    const [nr, ng, nb] = hslToRgb(hh, ss, 1 - ll);
    d[i] = nr; d[i + 1] = ng; d[i + 2] = nb;
  }

  octx.putImageData(img, 0, 0);
  return out;
}
