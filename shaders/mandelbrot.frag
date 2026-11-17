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
uniform float uVar;     // 24    万華鏡の種類（0〜9）

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

// ═══════ 万華鏡 10種類 ═══════
// uJ.x = 鏡で分ける数（双曲の鏡では多角形の角の数）、uJ.y = 明るさ、uVar = 種類（0〜9）

vec2 kfold(vec2 p, float n) {
  float r = length(p);
  float a = atan(p.y, p.x);
  float seg = 6.2831853 / n;
  a = mod(a, seg);
  a = abs(a - 0.5 * seg);
  return r * vec2(cos(a), sin(a));
}

vec2 rot2(vec2 p, float a) {
  float c = cos(a);
  float s = sin(a);
  return vec2(c * p.x - s * p.y, s * p.x + c * p.y);
}

vec2 hash2(vec2 p) {
  p = vec2(dot(p, vec2(127.1, 311.7)), dot(p, vec2(269.5, 183.3)));
  return fract(sin(p) * 43758.5453);
}

float vnoise(vec2 p) {
  vec2 i = floor(p);
  vec2 f = fract(p);
  vec2 u = f * f * (3.0 - 2.0 * f);
  float a = hash2(i).x;
  float b = hash2(i + vec2(1.0, 0.0)).x;
  float c = hash2(i + vec2(0.0, 1.0)).x;
  float d = hash2(i + vec2(1.0, 1.0)).x;
  return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

float fbm(vec2 p) {
  float s = 0.0;
  float w = 0.5;
  for (int i = 0; i < 4; i++) {
    s += w * vnoise(p);
    p = rot2(p, 0.6) * 2.03 + vec2(1.7, 9.2);
    w *= 0.5;
  }
  return s;
}

// 緑と青の宝石の色（エメラルド・サファイア・アクアマリン）
vec3 gemColor(float h) {
  if (h < 0.42) return vec3(0.02, 0.62, 0.30);
  if (h < 0.84) return vec3(0.06, 0.22, 0.85);
  return vec3(0.10, 0.70, 0.80);
}

// 緑と青の宝石らしい色の流れ（深い青→エメラルド→アクア→金のきらめき）
vec3 jewel(float t) {
  t = fract(t);
  vec3 navy = vec3(0.01, 0.03, 0.14);
  vec3 sapphire = vec3(0.05, 0.25, 0.85);
  vec3 emerald = vec3(0.02, 0.62, 0.32);
  vec3 aqua = vec3(0.35, 0.9, 0.9);
  if (t < 0.25) return mix(navy, sapphire, t / 0.25);
  if (t < 0.5) return mix(sapphire, emerald, (t - 0.25) / 0.25);
  if (t < 0.75) return mix(emerald, aqua, (t - 0.5) / 0.25);
  return mix(aqua, navy, (t - 0.75) / 0.25);
}

// 0. 宝石のレース：折り返しと反転を繰り返す
vec3 k0Lace(vec2 p) {
  vec2 z = kfold(p, uJ.x);
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
  return pal(tl * 1.5 + tr + uShift) * (1.0 - smoothstep(0.0, 0.35, tr)) * 1.1
       + pal(tl * 3.0 + uShift + 0.5) * exp(-tl * 12.0) * 0.6;
}

// 1. エメラルドとサファイア：多面カットの宝石を金の枠に散りばめる
vec3 k1Gems(vec2 p) {
  vec2 q = kfold(p, uJ.x);
  q = rot2(q, uTime * 0.04) * 4.5 + vec2(uTime * 0.12, uTime * 0.05);
  vec2 g = floor(q);
  vec2 f = fract(q);
  float d1 = 9.0;
  float d2 = 9.0;
  vec2 cid = vec2(0.0);
  vec2 cv = vec2(0.0);
  for (int j = -1; j <= 1; j++) {
    for (int i = -1; i <= 1; i++) {
      vec2 o = vec2(float(i), float(j));
      vec2 h = hash2(g + o);
      vec2 r = o + 0.5 + 0.3 * sin(uTime * 0.25 + 6.2831 * h) - f;
      float d = dot(r, r);
      if (d < d1) { d2 = d1; d1 = d; cid = g + o; cv = r; }
      else if (d < d2) { d2 = d; }
    }
  }
  d1 = sqrt(d1);
  d2 = sqrt(d2);
  vec2 h = hash2(cid + 7.0);
  vec3 base = gemColor(h.x);
  float fa = atan(cv.y, cv.x);
  float facet = floor((fa + 3.1416) / 0.7854);
  float shade = 0.45 + 0.55 * hash(facet + h.y * 17.0);
  float table = 1.0 - smoothstep(0.12, 0.18, d1);
  float spark = pow(max(0.0, cos(fa - uTime * 0.8 - h.y * 6.28)), 20.0) * (1.0 - smoothstep(0.0, 0.45, d1));
  vec3 col = base * (shade * (1.0 - table) + 1.35 * table) * (0.6 + 0.8 * (1.0 - smoothstep(0.0, 0.5, d1)));
  col += vec3(0.85, 1.0, 1.0) * spark * 1.4;
  float edge = smoothstep(0.03, 0.09, d2 - d1);
  return mix(vec3(0.55, 0.42, 0.15) * (0.5 + 0.5 * sin(uTime + d1 * 20.0)), col, edge);
}

// 2. 星屑：青と緑のきらめきが流れる
vec3 k2Stars(vec2 p) {
  vec2 q = kfold(p, uJ.x);
  float neb = fbm(q * 2.5 + vec2(uTime * 0.04, 0.0));
  vec3 col = vec3(0.0, 0.015, 0.04) + mix(vec3(0.0, 0.12, 0.10), vec3(0.02, 0.06, 0.22), neb) * neb * 1.6;
  for (int l = 0; l < 4; l++) {
    float fl = float(l);
    float sc = 3.0 + fl * 2.5;
    vec2 z = rot2(q, uTime * 0.02 * (fl + 1.0)) * sc + vec2(0.0, uTime * 0.25 * (fl + 1.0));
    vec2 g = floor(z);
    vec2 f = fract(z) - 0.5;
    vec2 h = hash2(g + fl * 13.0);
    vec2 r = f - (h - 0.5) * 0.7;
    float d = length(r);
    float tw = 0.4 + 0.6 * sin(uTime * 2.5 + h.x * 40.0);
    float glow = exp(-d * d * 60.0) * 1.6 + 0.02 / (d + 0.03);
    float flare = exp(-abs(r.x) * 50.0) * exp(-abs(r.y) * 6.0) + exp(-abs(r.y) * 50.0) * exp(-abs(r.x) * 6.0);
    vec3 c = h.y < 0.5 ? vec3(0.2, 1.0, 0.55) : vec3(0.3, 0.55, 1.0);
    col += c * (glow + flare * 0.7) * tw * (h.x > 0.2 ? 1.0 : 0.0) / (1.0 + 0.5 * fl);
  }
  return col;
}

// 3. 無限トンネル：どこまでも奥へ続く鏡
vec3 k3Tunnel(vec2 p) {
  float r = length(p) + 1e-4;
  float a = atan(p.y, p.x);
  vec2 lp = vec2(log(r) * 1.4 - uTime * 0.35, a * uJ.x / 6.2831853);
  vec2 c = abs(fract(lp) - 0.5) * 2.0;
  vec2 z = c * 1.3;
  vec2 k = vec2(0.75 + 0.1 * sin(uTime * 0.09), 0.6 + 0.1 * cos(uTime * 0.07));
  float tr = 1e9;
  for (int i = 0; i < 6; i++) {
    z = abs(z) / max(dot(z, z), 1e-4) - k;
    tr = min(tr, abs(length(z) - 0.45));
  }
  float ring = floor(lp.x);
  vec3 col = pal(tr * 1.2 + ring * 0.11 + uShift) * exp(-tr * 9.0) * 0.9;
  col += vec3(1.0, 0.95, 0.85) * exp(-tr * 60.0) * 0.5;
  return col * smoothstep(0.0, 0.35, r);
}

// 4. 双曲の鏡：円の縁へ向かって無限に細かくなる敷き詰め（ポアンカレ円板）
vec3 k4Hyper(vec2 p) {
  vec2 z = p * 1.02;
  float rr = dot(z, z);
  float hd = log((1.0 + sqrt(rr)) / max(1.0 - sqrt(rr), 1e-4));
  if (rr >= 1.0) return vec3(0.0, 0.02, 0.04) + vec3(0.1, 0.3, 0.5) * exp(-(sqrt(rr) - 1.0) * 30.0);
  // 円板の中をゆっくり流す（双曲平面の平行移動）
  vec2 c = 0.35 * vec2(cos(uTime * 0.1), sin(uTime * 0.13));
  z = cdiv(z + c, vec2(1.0, 0.0) + cmul(vec2(c.x, -c.y), z));
  float P = uJ.x;
  float A = 3.14159265 / P;
  float B = 3.14159265 / 3.0;
  float den = sqrt(cos(B) * cos(B) - sin(A) * sin(A));
  float cd = cos(B) / den;
  float cr = sin(A) / den;
  vec2 n = vec2(-sin(A), cos(A));
  float flips = 0.0;
  for (int i = 0; i < 40; i++) {
    bool moved = false;
    if (z.y < 0.0) { z.y = -z.y; flips += 1.0; moved = true; }
    float t = dot(z, n);
    if (t > 0.0) { z -= 2.0 * t * n; flips += 1.0; moved = true; }
    vec2 w = z - vec2(cd, 0.0);
    float l2 = dot(w, w);
    if (l2 < cr * cr) { z = vec2(cd, 0.0) + w * (cr * cr / l2); flips += 1.0; moved = true; }
    if (!moved) break;
  }
  float e1 = z.y;
  float e2 = abs(dot(z, n));
  float e3 = length(z - vec2(cd, 0.0)) - cr;
  float e = min(e1, min(e2, e3));
  float par = mod(flips, 2.0);
  vec3 col = pal(par * 0.35 + hd * 0.12 + length(z) * 0.6 + uShift) * (0.45 + 0.55 * par);
  col = mix(vec3(1.0, 0.97, 0.85), col, smoothstep(0.0, 0.01 + 0.01 * (1.0 - rr), e));
  return col * (0.3 + 0.7 * (1.0 - rr));
}

// 5. アポロニウスのレース：円の中に円が無限に詰まる
vec3 k5Apollo(vec2 p) {
  vec2 z = kfold(p, uJ.x) * 3.2 + vec2(0.3 * sin(uTime * 0.07), 0.2 * cos(uTime * 0.05));
  float s = 1.15 + 0.12 * sin(uTime * 0.11);
  float scale = 1.0;
  float orb = 1e4;
  for (int i = 0; i < 8; i++) {
    z = -1.0 + 2.0 * fract(0.5 * z + 0.5);
    float r2 = max(dot(z, z), 1e-5);
    orb = min(orb, r2);
    float k = s / r2;
    z *= k;
    scale *= k;
  }
  float d = 0.25 * abs(z.y) / scale;
  vec3 col = pal(sqrt(orb) * 1.3 + uShift) * (0.35 + 0.65 * sqrt(orb));
  col = mix(vec3(0.85, 0.95, 1.0), col, smoothstep(0.0, 0.006, d));
  return col;
}

// 6. 流れるガラス：溶けたガラスのように色が流れる
vec3 k6Liquid(vec2 p) {
  vec2 q = kfold(p, uJ.x) * 2.2;
  float t = uTime * 0.12;
  vec2 a = vec2(fbm(q + vec2(0.0, t)), fbm(q + vec2(5.2, 1.3 - t)));
  vec2 b = vec2(fbm(q + 3.5 * a + vec2(1.7, 9.2) + t), fbm(q + 3.5 * a + vec2(8.3, 2.8) - t));
  float v = fbm(q + 3.0 * b);
  vec3 col = jewel(v * 1.8 + length(b) * 0.4 + uShift * 0.3);
  col *= 0.4 + 1.4 * v;
  col += vec3(0.95, 0.85, 0.45) * pow(max(0.0, v - 0.6), 2.0) * 5.0;
  return col;
}

// 7. 光の糸：鏡と鏡の間を、光る糸が波打ちながら行き交う
vec3 k7Threads(vec2 p) {
  vec2 q = kfold(p, uJ.x);
  float half_ = 3.14159265 / uJ.x;
  float rad = length(q);
  float u = atan(q.y, q.x) / half_;          // 鏡の扇形の中での位置（0〜1）
  float span = rad * half_;                  // 扇形のその場所での幅
  vec3 col = vec3(0.0, 0.0, 0.02);
  for (int i = 0; i < 7; i++) {
    float fi = float(i);
    float target = 0.5 + 0.45 * sin(rad * (5.0 + fi * 1.7) - uTime * (0.5 + 0.12 * fi) + fi * 1.9);
    float d = abs(u - target) * span;
    col += pal(fi * 0.13 + rad * 0.3 + uShift) * (0.006 / (d + 0.004));
  }
  return col * 0.5 * smoothstep(0.0, 0.15, rad);
}

// 8. ガラスの破片：色ガラスのかけらが重なって転がる
vec3 k8Shards(vec2 p) {
  vec2 q = kfold(p, uJ.x);
  vec3 col = vec3(1.0);
  float seam = 1.0;
  for (int l = 0; l < 2; l++) {
    float fl = float(l);
    vec2 z = rot2(q, uTime * (0.04 + 0.03 * fl) + fl * 1.3) * (3.0 + fl * 1.7) + vec2(uTime * 0.2 * (1.0 + fl), fl * 3.0);
    vec2 s = vec2(z.x - z.y * 0.57735, z.y * 1.1547);
    vec2 id = floor(s);
    vec2 f = fract(s);
    float up = step(1.0, f.x + f.y);
    vec2 h = hash2(id * 2.0 + up + fl * 31.0);
    float e = up > 0.5 ? min(1.0 - f.x, min(1.0 - f.y, f.x + f.y - 1.0)) : min(f.x, min(f.y, 1.0 - f.x - f.y));
    vec3 glass = h.x < 0.3 ? vec3(1.0) : pal(h.y + uShift + fl * 0.3) * 0.9 + 0.1;
    col *= glass;
    seam = min(seam, smoothstep(0.0, 0.05, e));
  }
  return col * (0.25 + 0.85 * seam) * 1.1;
}

// 9. 花びらの曼荼羅：幾重もの花びらが呼吸する
vec3 k9Mandala(vec2 p) {
  float r = length(p);
  float a = atan(p.y, p.x) + uTime * 0.05;
  vec3 col = vec3(0.01, 0.01, 0.03);
  for (int i = 0; i < 8; i++) {
    float fi = float(i);
    float petals = uJ.x * (1.0 + floor(fi * 0.5));
    float base = 0.1 + fi * 0.12 + 0.02 * sin(uTime * 0.4 + fi);
    float edge = base + 0.07 * pow(abs(cos(a * petals * 0.5 + fi * 0.7 + uTime * 0.1 * (mod(fi, 2.0) * 2.0 - 1.0))), 0.6);
    float inside = 1.0 - smoothstep(edge - 0.004, edge + 0.004, r);
    float band = inside * smoothstep(base - 0.13, base - 0.02, r);
    vec3 c = pal(fi * 0.09 + uShift + r * 0.3) * (0.5 + 0.5 * (r - base + 0.13) / 0.2);
    col = mix(col, c, band);
    col += pal(fi * 0.09 + uShift + 0.5) * 0.0015 / (abs(r - edge) + 0.0015);
  }
  return col;
}

vec3 kaleido(vec2 p) {
  vec3 c;
  if (uVar < 0.5) c = k0Lace(p);
  else if (uVar < 1.5) c = k1Gems(p);
  else if (uVar < 2.5) c = k2Stars(p);
  else if (uVar < 3.5) c = k3Tunnel(p);
  else if (uVar < 4.5) c = k4Hyper(p);
  else if (uVar < 5.5) c = k5Apollo(p);
  else if (uVar < 6.5) c = k6Liquid(p);
  else if (uVar < 7.5) c = k7Threads(p);
  else if (uVar < 8.5) c = k8Shards(p);
  else c = k9Mandala(p);
  return c * uJ.y;
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
