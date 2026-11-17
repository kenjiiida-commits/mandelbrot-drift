// スマホのCPUで計算して描く模様（黄金角・反応拡散・アトラクタ・バラ・ペンローズ・L-system）
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'drift.dart';

double _c01(double x) => x < 0 ? 0.0 : (x > 1 ? 1.0 : x);

/// コサインパレットの色を 0xAARRGGBB の整数で返す
int palArgb(Palette p, double t, [double bright = 1.0]) {
  int ch(int i) =>
      (_c01((p.a[i] + p.b[i] * math.cos(6.2831853 * (p.c[i] * t + p.d[i]))) * bright) * 255).round();
  return 0xFF000000 | (ch(0) << 16) | (ch(1) << 8) | ch(2);
}

Color palColor(Palette p, double t, [double bright = 1.0, double alpha = 1.0]) =>
    Color(palArgb(p, t, bright)).withAlpha((_c01(alpha) * 255).round());

/// 0〜1 の値を色に変える早見表（256段階 × RGB）
Uint8List buildLut(Palette p, double shift, double range) {
  final lut = Uint8List(256 * 3);
  for (var i = 0; i < 256; i++) {
    final c = palArgb(p, i / 255 * range + shift);
    lut[i * 3] = (c >> 16) & 0xFF;
    lut[i * 3 + 1] = (c >> 8) & 0xFF;
    lut[i * 3 + 2] = c & 0xFF;
  }
  return lut;
}

const Color kBg = Color(0xFF050508);

abstract class CpuPattern {
  /// 模様に切り替わったときに呼ばれる
  void reset() {}

  /// 毎フレームの計算（t はこの模様に切り替わってからの時間）
  void update(double dt, double t, Palette pal, double shift, Size size) {}

  void paint(Canvas canvas, Size size, Palette pal, double shift, double t);

  String detail(double t) => '';
}

// ───────────── 黄金角の種の並び ─────────────

class Phyllotaxis extends CpuPattern {
  double _angle(double t) => 137.50776 + math.sin(t * 0.15) * 1.2;

  @override
  void paint(Canvas canvas, Size size, Palette pal, double shift, double t) {
    canvas.drawRect(Offset.zero & size, Paint()..color = kBg);
    const n = 1400;
    final ang = _angle(t) * math.pi / 180;
    final cx = size.width / 2, cy = size.height / 2;
    final reach = math.sqrt(cx * cx + cy * cy) * 0.98;
    final c = reach / math.sqrt(n);
    final rot = t * 0.05;
    final paint = Paint();
    for (var i = 1; i < n; i++) {
      final r = c * math.sqrt(i);
      final a = i * ang + rot;
      paint.color = palColor(pal, i / n * 0.8 + shift);
      canvas.drawCircle(Offset(cx + r * math.cos(a), cy + r * math.sin(a)), c * (0.22 + 0.22 * i / n), paint);
    }
  }

  @override
  String detail(double t) => '1つごとに ${_angle(t).toStringAsFixed(2)}° 回す（黄金角は 137.51°）';
}

// ───────────── 画素で描く模様の共通部分 ─────────────

abstract class PixelPattern extends CpuPattern {
  ui.Image? _image;
  bool _decoding = false;
  int pw = 0, ph = 0;
  Uint8List? pixels;

  /// 計算した画素を画像に変換する（変換中は次のフレームを待つ）
  void submit() {
    final px = pixels;
    if (_decoding || px == null) return;
    _decoding = true;
    ui.decodeImageFromPixels(Uint8List.fromList(px), pw, ph, ui.PixelFormat.rgba8888, (img) {
      _image?.dispose();
      _image = img;
      _decoding = false;
    });
  }

  bool needsInit(Size size, int height) {
    if (size.isEmpty) return false;
    final want = math.max(60, (height * size.width / size.height).round());
    return pw == 0 || (pw - want).abs() > 2;
  }

  @override
  void paint(Canvas canvas, Size size, Palette pal, double shift, double t) {
    canvas.drawRect(Offset.zero & size, Paint()..color = kBg);
    final img = _image;
    if (img == null) return;
    canvas.drawImageRect(
      img,
      Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
      Offset.zero & size,
      Paint()..filterQuality = FilterQuality.medium,
    );
  }
}

// ───────────── 反応拡散（Gray-Scott モデル） ─────────────

class ReactionDiffusion extends PixelPattern {
  Float32List _a = Float32List(0), _b = Float32List(0), _na = Float32List(0), _nb = Float32List(0);
  final _rnd = math.Random();
  double _dropTimer = 0;
  double _f = 0.0367, _k = 0.0649;

  @override
  void reset() {
    pw = 0;
  }

  void _init(Size size) {
    ph = 220;
    pw = math.max(60, (ph * size.width / size.height).round());
    final n = pw * ph;
    _a = Float32List(n)..fillRange(0, n, 1.0);
    _b = Float32List(n);
    _na = Float32List(n);
    _nb = Float32List(n);
    pixels = Uint8List(n * 4);
    for (var i = 0; i < 18; i++) {
      _drop();
    }
  }

  /// ところどころに物質Bを落として、模様の種にする
  void _drop() {
    final cx = _rnd.nextInt(pw), cy = _rnd.nextInt(ph);
    for (var y = -3; y <= 3; y++) {
      for (var x = -3; x <= 3; x++) {
        final i = ((cy + y + ph) % ph) * pw + (cx + x + pw) % pw;
        _b[i] = 1.0;
        _a[i] = 0.5;
      }
    }
  }

  void _step() {
    final w = pw, h = ph;
    final a = _a, b = _b, na = _na, nb = _nb;
    final f = _f, k = _k;
    for (var y = 0; y < h; y++) {
      final ym = ((y - 1 + h) % h) * w, y0 = y * w, yp = ((y + 1) % h) * w;
      for (var x = 0; x < w; x++) {
        final xm = (x - 1 + w) % w, xp = (x + 1) % w;
        final i = y0 + x;
        final av = a[i], bv = b[i];
        final la = 0.2 * (a[y0 + xm] + a[y0 + xp] + a[ym + x] + a[yp + x]) +
            0.05 * (a[ym + xm] + a[ym + xp] + a[yp + xm] + a[yp + xp]) -
            av;
        final lb = 0.2 * (b[y0 + xm] + b[y0 + xp] + b[ym + x] + b[yp + x]) +
            0.05 * (b[ym + xm] + b[ym + xp] + b[yp + xm] + b[yp + xp]) -
            bv;
        final abb = av * bv * bv;
        na[i] = av + la - abb + f * (1 - av);
        nb[i] = bv + 0.5 * lb + abb - (k + f) * bv;
      }
    }
    _a = na;
    _na = a;
    _b = nb;
    _nb = b;
  }

  @override
  void update(double dt, double t, Palette pal, double shift, Size size) {
    if (needsInit(size, 220)) _init(size);
    if (pw == 0) return;
    // 「水玉が分裂する」設定と「サンゴ状」の設定の間をゆっくり行き来する
    final m = 0.5 + 0.5 * math.sin(t * 0.03);
    _f = 0.0367 + (0.0545 - 0.0367) * m;
    _k = 0.0649 + (0.0620 - 0.0649) * m;
    final steps = math.min(24, (dt * 60 * 6).round());
    for (var s = 0; s < steps; s++) {
      _step();
    }
    _dropTimer += dt;
    if (_dropTimer > 4) {
      _dropTimer = 0;
      _drop();
    }
    final lut = buildLut(pal, shift, 0.75);
    final px = pixels!;
    final n = pw * ph;
    for (var i = 0; i < n; i++) {
      var v = _b[i] * 2.8;
      if (v < 0) v = 0;
      if (v > 1) v = 1;
      final li = (v * 255).toInt() * 3;
      final q = i * 4;
      px[q] = (8 + lut[li] * v * 0.96).toInt();
      px[q + 1] = (8 + lut[li + 1] * v * 0.96).toInt();
      px[q + 2] = (12 + lut[li + 2] * v * 0.95).toInt();
      px[q + 3] = 255;
    }
    submit();
  }

  @override
  String detail(double t) => '2つの物質が広がりながら反応する';
}

// ───────────── ストレンジアトラクタ（Clifford） ─────────────

class Attractor extends PixelPattern {
  Float32List _dens = Float32List(0);
  double _x = 0.1, _y = 0.1;
  double _pa = 0, _pb = 0, _pc = 0, _pd = 0;

  @override
  void reset() {
    pw = 0;
  }

  void _init(Size size) {
    ph = 640;
    pw = math.max(60, (ph * size.width / size.height).round());
    _dens = Float32List(pw * ph);
    pixels = Uint8List(pw * ph * 4);
  }

  @override
  void update(double dt, double t, Palette pal, double shift, Size size) {
    if (needsInit(size, 640)) _init(size);
    if (pw == 0) return;
    _pa = -1.4 + 0.25 * math.sin(t * 0.07);
    _pb = 1.6 + 0.2 * math.cos(t * 0.05);
    _pc = 1.0 + 0.2 * math.sin(t * 0.09);
    _pd = 0.7 + 0.15 * math.cos(t * 0.06);

    final d = _dens;
    if (dt > 0) {
      final decay = math.exp(-dt * 1.5);
      for (var i = 0; i < d.length; i++) {
        d[i] *= decay;
      }
    }
    // 縦長の画面では、横に広い形を90°回して大きく見せる
    final limX = 1 + _pc.abs(), limY = 1 + _pd.abs();
    final swap = ph > pw;
    final sc = swap
        ? math.min(pw / (2 * limY), ph / (2 * limX)) * 1.1
        : math.min(pw / (2 * limX), ph / (2 * limY)) * 1.1;
    final cx = pw / 2, cy = ph / 2;
    final n = math.min(80000, (dt * 60 * 40000).round());
    var x = _x, y = _y;
    for (var i = 0; i < n; i++) {
      final nx = math.sin(_pa * y) + _pc * math.cos(_pa * x);
      final ny = math.sin(_pb * x) + _pd * math.cos(_pb * y);
      x = nx;
      y = ny;
      final ix = (swap ? cx + y * sc : cx + x * sc).toInt();
      final iy = (swap ? cy + x * sc : cy + y * sc).toInt();
      if (ix >= 0 && ix < pw && iy >= 0 && iy < ph) d[iy * pw + ix] += 1;
    }
    _x = x;
    _y = y;

    final lut = buildLut(pal, shift + 0.4, 0.8);
    final px = pixels!;
    for (var i = 0; i < d.length; i++) {
      final dv = d[i];
      final v = dv / (dv + 10);
      final li = (v * 255).toInt() * 3;
      final q = i * 4;
      px[q] = (5 + lut[li] * v * 0.97).toInt();
      px[q + 1] = (5 + lut[li + 1] * v * 0.97).toInt();
      px[q + 2] = (8 + lut[li + 2] * v * 0.96).toInt();
      px[q + 3] = 255;
    }
    submit();
  }

  @override
  String detail(double t) =>
      'a=${_pa.toStringAsFixed(2)} b=${_pb.toStringAsFixed(2)} c=${_pc.toStringAsFixed(2)} d=${_pd.toStringAsFixed(2)}';
}

// ───────────── マウラーのバラ ─────────────

class MaurerRose extends CpuPattern {
  int _n(double t) => 2 + (t / 24).floor() % 6;
  double _d(double t) => 29 + 8 * math.sin(t * 0.04) + ((t / 24).floor() % 4) * 10;

  @override
  void paint(Canvas canvas, Size size, Palette pal, double shift, double t) {
    canvas.drawRect(Offset.zero & size, Paint()..color = kBg);
    final fr = t / 24 - (t / 24).floor();
    final alpha = math.min(1.0, math.min(fr * 5, (1 - fr) * 5));
    final n = _n(t);
    final dd = _d(t);
    final cx = size.width / 2, cy = size.height / 2;
    final r0 = math.min(size.width, size.height) * 0.46;
    final rot = t * 0.05;

    final lines = Path();
    for (var k = 0; k <= 360; k++) {
      final th = k * dd * math.pi / 180;
      final r = r0 * math.sin(n * th);
      final x = cx + r * math.cos(th + rot), y = cy + r * math.sin(th + rot);
      if (k == 0) {
        lines.moveTo(x, y);
      } else {
        lines.lineTo(x, y);
      }
    }
    canvas.drawPath(
      lines,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0
        ..color = palColor(pal, t * 0.03 + shift, 1, 0.75 * alpha),
    );

    final rose = Path();
    for (var k = 0; k <= 720; k++) {
      final th = k * math.pi / 360;
      final r = r0 * math.sin(n * th);
      final x = cx + r * math.cos(th + rot), y = cy + r * math.sin(th + rot);
      if (k == 0) {
        rose.moveTo(x, y);
      } else {
        rose.lineTo(x, y);
      }
    }
    canvas.drawPath(
      rose,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2
        ..color = palColor(pal, t * 0.03 + shift + 0.45, 1, 0.95 * alpha),
    );
  }

  @override
  String detail(double t) => '花びら n = ${_n(t)}、飛ばす角度 d = ${_d(t).toStringAsFixed(1)}°';
}

// ───────────── ペンローズ・タイリング ─────────────

class Penrose extends CpuPattern {
  Float32List? _pos;
  Float32List? _edges;
  Float32List? _dist;
  Uint8List? _type;
  Int32List? _colors;

  void _build() {
    const phi = 1.6180339887;
    // [種類, Aのx, Aのy, Bのx, Bのy, Cのx, Cのy]
    var tris = <List<double>>[];
    for (var i = 0; i < 10; i++) {
      var bx = math.cos((2 * i - 1) * math.pi / 10), by = math.sin((2 * i - 1) * math.pi / 10);
      var cx = math.cos((2 * i + 1) * math.pi / 10), cy = math.sin((2 * i + 1) * math.pi / 10);
      if (i % 2 == 0) {
        final tx = bx, ty = by;
        bx = cx;
        by = cy;
        cx = tx;
        cy = ty;
      }
      tris.add([0, 0, 0, bx, by, cx, cy]);
    }
    // 黄金比で三角形を分割していくと、繰り返さない敷き詰めができる
    for (var level = 0; level < 8; level++) {
      final next = <List<double>>[];
      for (final t in tris) {
        final ax = t[1], ay = t[2], bx = t[3], by = t[4], cx = t[5], cy = t[6];
        if (t[0] == 0) {
          final px = ax + (bx - ax) / phi, py = ay + (by - ay) / phi;
          next.add([0, cx, cy, px, py, bx, by]);
          next.add([1, px, py, cx, cy, ax, ay]);
        } else {
          final qx = bx + (ax - bx) / phi, qy = by + (ay - by) / phi;
          final rx = bx + (cx - bx) / phi, ry = by + (cy - by) / phi;
          next.add([1, rx, ry, cx, cy, ax, ay]);
          next.add([1, qx, qy, rx, ry, bx, by]);
          next.add([0, rx, ry, qx, qy, ax, ay]);
        }
      }
      tris = next;
    }
    final n = tris.length;
    final pos = Float32List(n * 6);
    final edges = Float32List(n * 8);
    final dist = Float32List(n);
    final type = Uint8List(n);
    for (var i = 0; i < n; i++) {
      final t = tris[i];
      for (var j = 0; j < 6; j++) {
        pos[i * 6 + j] = t[j + 1];
      }
      // ひし形の辺は C→A と A→B（B–C は2つの三角形の境目なので描かない）
      edges[i * 8] = t[5];
      edges[i * 8 + 1] = t[6];
      edges[i * 8 + 2] = t[1];
      edges[i * 8 + 3] = t[2];
      edges[i * 8 + 4] = t[1];
      edges[i * 8 + 5] = t[2];
      edges[i * 8 + 6] = t[3];
      edges[i * 8 + 7] = t[4];
      final gx = (t[1] + t[3] + t[5]) / 3, gy = (t[2] + t[4] + t[6]) / 3;
      dist[i] = math.sqrt(gx * gx + gy * gy);
      type[i] = t[0] == 0 ? 0 : 1;
    }
    _pos = pos;
    _edges = edges;
    _dist = dist;
    _type = type;
    _colors = Int32List(n * 3);
  }

  @override
  void paint(Canvas canvas, Size size, Palette pal, double shift, double t) {
    canvas.drawRect(Offset.zero & size, Paint()..color = kBg);
    if (_pos == null) _build();
    final type = _type!, dist = _dist!, cols = _colors!;
    final n = type.length;
    for (var i = 0; i < n; i++) {
      final base = type[i] == 0 ? 0.0 : 0.38;
      final c = palArgb(pal, base + 0.22 * math.sin(dist[i] * 14 - t * 0.5) + shift, 0.92);
      cols[i * 3] = c;
      cols[i * 3 + 1] = c;
      cols[i * 3 + 2] = c;
    }
    final r = 0.36 + 0.12 * math.sin(t * 0.05);
    final half = math.sqrt(size.width * size.width + size.height * size.height) / 2;
    final s = half / r;
    canvas.save();
    canvas.translate(size.width / 2, size.height / 2);
    canvas.rotate(t * 0.02);
    canvas.scale(s);
    final v = ui.Vertices.raw(ui.VertexMode.triangles, _pos!, colors: cols);
    canvas.drawVertices(v, BlendMode.dst, Paint());
    v.dispose();
    canvas.drawRawPoints(
      ui.PointMode.lines,
      _edges!,
      Paint()
        ..color = const Color(0xE6050508)
        ..strokeWidth = 1.6 / s,
    );
    canvas.restore();
  }

  @override
  String detail(double t) => '2種類のひし形だけで、同じ並びを繰り返さずに敷き詰める';
}

// ───────────── L-system（植物の枝分かれ） ─────────────

class LDef {
  const LDef(this.name, this.axiom, this.rules, this.angle, this.iter, {this.sway = false, this.width = 1.2});
  final String name;
  final String axiom;
  final Map<String, String> rules;
  final double angle;
  final int iter;
  final bool sway;
  final double width;
}

const List<LDef> lDefs = [
  LDef('シダのような草', 'X', {'X': 'F+[[X]-X]-F[-X]+X', 'F': 'FF'}, 25, 6, sway: true, width: 1.0),
  LDef('枝分かれする樹', 'F', {'F': 'FF+[+F-F-F]-[-F+F+F]'}, 22.5, 4, sway: true, width: 1.3),
  LDef('ドラゴン曲線', 'FX', {'X': 'X+YF+', 'Y': '-FX-Y'}, 90, 12, width: 1.6),
  LDef('コッホ雪片', 'F--F--F', {'F': 'F+F--F+F'}, 60, 4, width: 1.6),
];

class LSystem extends CpuPattern {
  int _cur = -1;
  String _code = '';
  Float32List _seg = Float32List(0);
  Float32List _depth = Float32List(0);
  double _maxDepth = 1;
  double _minX = 0, _minY = 0, _maxX = 1, _maxY = 1;
  static const _cycle = 18.0;

  int _index(double t) => (t / _cycle).floor() % lDefs.length;

  void _load(int idx) {
    _cur = idx;
    final d = lDefs[idx];
    var s = d.axiom;
    for (var i = 0; i < d.iter; i++) {
      final sb = StringBuffer();
      for (var j = 0; j < s.length; j++) {
        final ch = s[j];
        sb.write(d.rules[ch] ?? ch);
      }
      s = sb.toString();
    }
    _code = s;
    var count = 0;
    for (var j = 0; j < s.length; j++) {
      if (s.codeUnitAt(j) == 70) count++; // 'F'
    }
    _seg = Float32List(count * 4);
    _depth = Float32List(count);
    _interpret(d.angle, 0, true);
    _maxDepth = 1;
    _minX = double.infinity;
    _minY = double.infinity;
    _maxX = -double.infinity;
    _maxY = -double.infinity;
    for (var k = 0; k < count; k++) {
      if (_depth[k] > _maxDepth) _maxDepth = _depth[k];
      for (var e = 0; e < 2; e++) {
        final x = _seg[k * 4 + e * 2], y = _seg[k * 4 + e * 2 + 1];
        if (x < _minX) _minX = x;
        if (x > _maxX) _maxX = x;
        if (y < _minY) _minY = y;
        if (y > _maxY) _maxY = y;
      }
    }
  }

  /// 文字列を「亀」の動きとして読み、線分を作る（F=進む、+−=曲がる、[ ]=枝の分岐）
  void _interpret(double angleDeg, double sway, bool writeDepth) {
    final ang = angleDeg * math.pi / 180;
    var x = 0.0, y = 0.0, dir = -math.pi / 2, depth = 0.0;
    final stack = <double>[];
    var k = 0;
    final code = _code;
    for (var i = 0; i < code.length; i++) {
      final c = code.codeUnitAt(i);
      if (c == 70) {
        final nx = x + math.cos(dir), ny = y + math.sin(dir);
        _seg[k * 4] = x;
        _seg[k * 4 + 1] = y;
        _seg[k * 4 + 2] = nx;
        _seg[k * 4 + 3] = ny;
        if (writeDepth) _depth[k] = depth;
        k++;
        depth += 1;
        x = nx;
        y = ny;
      } else if (c == 43) {
        dir += ang; // '+'
      } else if (c == 45) {
        dir -= ang; // '-'
      } else if (c == 91) {
        stack
          ..add(x)
          ..add(y)
          ..add(dir)
          ..add(depth); // '['
        dir += sway; // 風で枝がしなる
      } else if (c == 93 && stack.length >= 4) {
        depth = stack.removeLast(); // ']'
        dir = stack.removeLast();
        y = stack.removeLast();
        x = stack.removeLast();
      }
    }
  }

  @override
  void reset() {
    _cur = -1;
  }

  @override
  void paint(Canvas canvas, Size size, Palette pal, double shift, double t) {
    canvas.drawRect(Offset.zero & size, Paint()..color = kBg);
    final idx = _index(t);
    if (idx != _cur) _load(idx);
    final d = lDefs[idx];
    final fr = t / _cycle - (t / _cycle).floor();
    final alpha = math.min(1.0, math.min(fr * 8, (1 - fr) * 8));
    final grow = smooth(0, 0.6, fr);
    if (d.sway) _interpret(d.angle, 0.05 * math.sin(t * 0.9), false);

    final bw = math.max(1e-6, _maxX - _minX), bh = math.max(1e-6, _maxY - _minY);
    final s = d.sway
        ? math.min(size.width / bw, size.height / bh) * 0.9
        : math.min(size.width, size.height) / math.max(bw, bh) * 0.88;

    const buckets = 40;
    final lists = List.generate(buckets, (_) => <double>[]);
    final limit = grow * _maxDepth;
    final count = _depth.length;
    for (var k = 0; k < count; k++) {
      final dep = _depth[k];
      if (dep > limit) continue;
      final bi = math.min(buckets - 1, (dep / _maxDepth * buckets).floor());
      lists[bi]
        ..add(_seg[k * 4])
        ..add(_seg[k * 4 + 1])
        ..add(_seg[k * 4 + 2])
        ..add(_seg[k * 4 + 3]);
    }

    canvas.save();
    canvas.translate(size.width / 2, size.height / 2);
    if (!d.sway) canvas.rotate(t * 0.03);
    canvas.scale(s);
    canvas.translate(-(_minX + _maxX) / 2, -(_minY + _maxY) / 2);
    for (var b = 0; b < buckets; b++) {
      if (lists[b].isEmpty) continue;
      canvas.drawRawPoints(
        ui.PointMode.lines,
        Float32List.fromList(lists[b]),
        Paint()
          ..color = palColor(pal, b / buckets * 0.7 + shift, 1, alpha)
          ..strokeWidth = d.width / s
          ..strokeCap = StrokeCap.round,
      );
    }
    canvas.restore();
  }

  @override
  String detail(double t) => lDefs[_index(t)].name;
}
