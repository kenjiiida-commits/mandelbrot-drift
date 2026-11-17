#version 460 core
#include <flutter/runtime_effect.glsl>

precision highp float;

// 並び順は Dart 側の setFloat の番号と一致させること
uniform vec2 uRes;      // 0,1   描画する画像の大きさ（ピクセル）
uniform vec2 uCenter;   // 2,3   画面中央の複素数
uniform vec2 uJ;        // 4,5   ジュリア集合の c
uniform float uScale;   // 6     画面の高さの半分が複素平面でどれだけか
uniform float uRot;     // 7     回転角
uniform float uShift;   // 8     色の流れ
uniform float uIter;    // 9     最大反復回数
uniform float uMode;    // 10    0=マンデルブロ 1=ジュリア
uniform vec3 uA;        // 11-13 配色（コサインパレット）
uniform vec3 uB;        // 14-16
uniform vec3 uC;        // 17-19
uniform vec3 uD;        // 20-22
uniform float uTime;    // 23    経過時間（波・ボロノイ・ニュートン法の動き）

out vec4 fragColor;

const int MAXI = 1100;

vec3 pal(float t) {
  return uA + uB * cos(6.2831853 * (uC * t + uD));
}

vec2 cmul(vec2 a, vec2 b) { return vec2(a.x * b.x - a.y * b.y, a.x * b.y + a.y * b.x); }
vec2 cdiv(vec2 a, vec2 b) { return vec2(a.x * b.x + a.y * b.y, a.y * b.x - a.x * b.y) / dot(b, b); }
float hash(float n) { return fract(sin(n * 127.1 + 3.7) * 43758.5453); }

// ── ニュートン法フラクタル：z^3 = 1 の3つの解のどれにたどり着くかで色分け ──
vec3 newton(vec2 z) {
  vec2 a = vec2(1.0 + 0.45 * sin(uTime * 0.11), 0.35 * sin(uTime * 0.07));
  vec2 r1 = vec2(1.0, 0.0);
  vec2 r2 = vec2(-0.5, 0.8660254);
  vec2 r3 = vec2(-0.5, -0.8660254);
  float mPrev = 1.0;
  float it = -1.0;
  float root = 0.0;
  for (int i = 0; i < 80; i++) {
    vec2 z2 = cmul(z, z);
    vec2 f = cmul(z2, z) - vec2(1.0, 0.0);
    vec2 fp = 3.0 * z2;
    if (dot(fp, fp) < 1e-10) break;
    z -= cmul(a, cdiv(f, fp));
    float d1 = dot(z - r1, z - r1);
    float d2 = dot(z - r2, z - r2);
    float d3 = dot(z - r3, z - r3);
    float m = min(d1, min(d2, d3));
    if (m < 1e-6) {
      root = (m == d1) ? 0.0 : ((m == d2) ? 1.0 : 2.0);
      float fr = clamp((log(1e-6) - log(mPrev)) / (log(m) - log(mPrev)), 0.0, 1.0);
      it = float(i) + fr;
      break;
    }
    mPrev = m;
  }
  if (it < 0.0) return vec3(0.02);
  vec3 col = pal(root / 3.0 + it * 0.045 + uShift);
  return col * (0.3 + 0.7 * exp(-it * 0.07));
}

// ── 波の干渉：動く5つの波源から広がる波を足し合わせる ──
vec3 waves(vec2 p) {
  float s = 0.0;
  for (int i = 0; i < 3; i++) {
    float fi = float(i);
    float ang = fi * 2.0944 + uTime * 0.04 * (1.0 + 0.4 * fi);
    float rad = 0.35 + 0.2 * sin(uTime * 0.06 + fi * 1.7);
    vec2 src = vec2(cos(ang), sin(ang)) * rad;
    float d = length(p - src);
    s += cos(d * 70.0 - uTime * 2.0);
  }
  // s は -3〜3：波が強め合う所は明るく、打ち消し合う所は暗くなる
  float bright = s * s / 9.0;
  vec3 col = pal(0.45 * bright + uShift + 0.3 * length(p));
  return col * (0.05 + 0.95 * sqrt(bright));
}

// ── ボロノイ図：いちばん近い種で領域を分け、境目を鉛の枠のように暗くする ──
vec3 voronoi(vec2 p) {
  float ax = max(uRes.x / uRes.y, 1.0);
  float d1 = 1e9;
  float d2 = 1e9;
  float id = 0.0;
  for (int i = 0; i < 40; i++) {
    float fi = float(i);
    vec2 b = vec2(hash(fi) * 2.0 - 1.0, hash(fi + 31.7) * 2.0 - 1.0) * vec2(ax * 1.15, 1.15);
    vec2 sp = b + 0.2 * vec2(sin(uTime * (0.15 + 0.3 * hash(fi + 3.0)) + fi),
                             cos(uTime * (0.15 + 0.3 * hash(fi + 7.0)) + fi * 1.3));
    float d = length(p - sp);
    if (d < d1) { d2 = d1; d1 = d; id = fi; }
    else if (d < d2) { d2 = d; }
  }
  vec3 col = pal(hash(id + 11.0) * 0.8 + uShift);
  col *= 0.6 + 0.5 * (1.0 - smoothstep(0.0, 0.45, d1));
  return mix(vec3(0.02), col, smoothstep(0.010, 0.020, d2 - d1));
}

// ── 万華鏡：扇形に鏡で折り返し、その中で「折り返し＋反転」を繰り返して宝石のような模様を描く ──
// uJ.x = 鏡で分ける数、uJ.y = 明るさ（鏡の数が替わるときに暗くする）
vec3 kaleido(vec2 p) {
  float r = length(p);
  float a = atan(p.y, p.x);
  float seg = 6.2831853 / uJ.x;
  a = mod(a, seg);
  a = abs(a - 0.5 * seg);
  vec2 z = r * vec2(cos(a), sin(a));
  z = z * (1.2 + 0.25 * sin(uTime * 0.05)) + vec2(0.15 * sin(uTime * 0.03), 0.0);
  vec2 k = vec2(0.82 + 0.12 * sin(uTime * 0.071), 0.55 + 0.12 * cos(uTime * 0.053));
  float tr = 1e9;
  float tl = 1e9;
  for (int i = 0; i < 9; i++) {
    z = abs(z) / max(dot(z, z), 1e-4) - k;
    float m = length(z);
    tr = min(tr, abs(m - 0.5));
    tl = min(tl, abs(z.y));
  }
  vec3 col = pal(tl * 1.5 + tr + uShift) * (1.0 - smoothstep(0.0, 0.35, tr)) * 1.1
           + pal(tl * 3.0 + uShift + 0.5) * exp(-tl * 12.0) * 0.6;
  return col * uJ.y;
}

vec3 escapeTime(vec2 pos) {
  vec2 z;
  vec2 c;
  if (uMode < 0.5) {
    z = vec2(0.0);
    c = pos;
  } else {
    z = pos;
    c = uJ;
  }

  float n = -1.0;
  float trap = 1e9;
  bool inside = false;
  if (uMode < 0.5) {
    // 本体のハート形と左の円の内側は計算しなくても黒とわかる
    float xq = c.x - 0.25;
    float q = xq * xq + c.y * c.y;
    if (q * (q + xq) < 0.25 * c.y * c.y || (c.x + 1.0) * (c.x + 1.0) + c.y * c.y < 0.0625) {
      inside = true;
    }
  }

  if (!inside) {
    for (int i = 0; i < MAXI; i++) {
      if (float(i) >= uIter) break;
      z = vec2(z.x * z.x - z.y * z.y, 2.0 * z.x * z.y) + c;
      float m = dot(z, z);
      trap = min(trap, abs(z.x * z.y));
      if (m > 256.0) {
        // 色の境目が段々にならない「なめらかな反復回数」
        n = float(i) + 1.0 - log2(0.5 * log2(m));
        break;
      }
    }
  }

  vec3 col;
  if (n >= 0.0) {
    col = pal(sqrt(n) * 0.32 + uShift);
    col *= 0.75 + 0.25 * smoothstep(0.0, 6.0, n);
  } else if (uMode > 0.5) {
    col = pal(sqrt(trap) * 1.4 + uShift + 0.5) * 0.18;
  } else {
    col = vec3(0.0);
  }
  return col;
}

void main() {
  vec2 fc = FlutterFragCoord().xy;
  vec2 p = (fc - 0.5 * uRes) / uRes.y * 2.0;
  p.y = -p.y;  // 上を虚軸のプラス方向にする
  float cs = cos(uRot);
  float sn = sin(uRot);
  p = vec2(cs * p.x - sn * p.y, sn * p.x + cs * p.y);
  vec2 pos = uCenter + p * uScale;

  // 0,1=マンデルブロ・ジュリア 2=ニュートン法 3=波の干渉 4=ボロノイ図 5=万華鏡
  vec3 col;
  if (uMode < 1.5) col = escapeTime(pos);
  else if (uMode < 2.5) col = newton(pos);
  else if (uMode < 3.5) col = waves(pos);
  else if (uMode < 4.5) col = voronoi(pos);
  else col = kaleido(pos);
  fragColor = vec4(pow(clamp(col, 0.0, 1.0), vec3(0.95)), 1.0);
}
