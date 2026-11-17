// 動きの計算（どの模様を、どこを、どの色で描くか）
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'patterns.dart';

// ───────────── 模様の一覧 ─────────────

class PatternInfo {
  const PatternInfo(this.name, this.shaderMode, {this.gestures = false});
  final String name;
  final int shaderMode; // GPUで描く模様の番号（-1はスマホのCPUで描く模様）
  final bool gestures; // 指で動かせるか
}

const List<PatternInfo> patternList = [
  PatternInfo('マンデルブロ集合', 0, gestures: true),
  PatternInfo('ジュリア集合', 1, gestures: true),
  PatternInfo('ニュートン法フラクタル', 2, gestures: true),
  PatternInfo('黄金角の種の並び', -1),
  PatternInfo('反応拡散（チューリング模様）', -1),
  PatternInfo('ストレンジアトラクタ', -1),
  PatternInfo('マウラーのバラ', -1),
  PatternInfo('ボロノイ図（ステンドグラス）', 4),
  PatternInfo('ペンローズ・タイリング', -1),
  PatternInfo('L-system（植物の枝分かれ）', -1),
  PatternInfo('波の干渉', 3),
  PatternInfo('万華鏡', 5),
];

// ───────────── マンデルブロ集合の行き先（名所）と配色 ─────────────

class Target {
  const Target(this.name, this.x, this.y);
  final String name;
  final double x;
  final double y;
}

const List<Target> targets = [
  Target('タツノオトシゴの谷', -0.743643887, 0.131825904),
  Target('象の谷', 0.2549870375, -0.0005679791),
  Target('三重らせん', -0.7269, 0.1889),
  Target('ミシウレヴィチ点', 0.3602404434, -0.6413130611),
  Target('アンテナの小宇宙', -1.25066, 0.02012),
  Target('渦巻銀河', -0.77568377, 0.13646737),
  Target('北の尾根', -0.235125, 0.827215),
  Target('ミニブロ', -1.768778833, -0.001738996),
];

class Palette {
  const Palette(this.name, this.a, this.b, this.c, this.d);
  final String name;
  final List<double> a, b, c, d;
}

const List<Palette> palettes = [
  Palette('オーロラ', [.5, .5, .5], [.5, .5, .5], [1, 1, 1], [0, .10, .20]),
  Palette('黄金', [.5, .5, .5], [.5, .5, .5], [1, .7, .4], [0, .15, .20]),
  Palette('深海', [.5, .5, .5], [.5, .5, .5], [1, 1, 1], [.30, .20, .20]),
  Palette('夕焼け', [.8, .5, .4], [.2, .4, .2], [2, 1, 1], [0, .25, .25]),
  Palette('氷', [.5, .5, .5], [.5, .5, .5], [1, 1, .5], [.80, .90, .30]),
];

const double kWide = 1.6; // いちばん引いたときの大きさ
const double kDeep = 2.2e-4; // スマホのGPU（単精度）できれいに見える深さの限界
const double kJuliaR = 0.7885;

double smooth(double a, double b, double x) {
  final t = math.min(1.0, math.max(0.0, (x - a) / (b - a)));
  return t * t * (3 - 2 * t);
}

double lerp(double a, double b, double t) => a + (b - a) * t;

List<double> lerpList(List<double> a, List<double> b, double t) =>
    List.generate(3, (i) => lerp(a[i], b[i], t));

class Segment {
  Segment({
    required this.zoomIn,
    required this.cx0,
    required this.cy0,
    required this.s0,
    required this.cx1,
    required this.cy1,
    required this.s1,
  }) : dur = zoomIn ? 42 : 14;

  final bool zoomIn;
  final double dur;
  final double cx0, cy0, s0, cx1, cy1, s1;
  double t = 0;
}

// ───────────── 状態 ─────────────

class Drift extends ChangeNotifier {
  Drift() {
    _newSeg(true);
  }

  /// スマホのCPUで描く模様（番号は patternList と同じ）
  final Map<int, CpuPattern> cpu = {
    3: Phyllotaxis(),
    4: ReactionDiffusion(),
    5: Attractor(),
    6: MaurerRose(),
    8: Penrose(),
    9: LSystem(),
  };

  int pattern = 0;
  int _pending = -1;
  double fade = 0; // 切り替え時の暗転（0〜1）
  bool autoCycle = false; // おまかせで次々と切り替える
  double _cycleTime = 0;
  double ptime = 0; // この模様に切り替わってからの時間
  Size screen = Size.zero;

  double speed = 1;
  bool playing = true;
  bool auto = true;

  double cx = targets[0].x;
  double cy = targets[0].y;
  double logS = math.log(kWide);
  double rot = 0;
  double shift = 0;
  double jAngle = 0;

  int tIdx = 0;
  late Segment seg;

  int palIdx = 0;
  Palette palFrom = palettes[0];
  double palT = 1;

  // 端末の速さに合わせて描画の解像度を自動で上げ下げする
  double renderScale = 0.6;
  double _avgMs = 16.7;
  double _bestMs = 16.7;
  double _sinceResize = 0;

  double get scale => math.exp(logS);

  // 万華鏡：鏡で分ける数を30秒ごとに替え、替わる前後は暗くする
  static const List<int> _kSegs = [6, 8, 12, 10];
  double get kaleidoSegs => _kSegs[(ptime / 30).floor() % _kSegs.length].toDouble();
  double get kaleidoDim {
    final fr = ptime / 30 - (ptime / 30).floor();
    return math.min(1.0, math.min(fr * 6, (1 - fr) * 6));
  }
  PatternInfo get info => patternList[pattern];
  int get shaderMode => info.shaderMode;

  void _newSeg(bool zoomIn) {
    final t = targets[tIdx];
    seg = Segment(
      zoomIn: zoomIn,
      cx0: cx,
      cy0: cy,
      s0: logS,
      cx1: t.x,
      cy1: t.y,
      s1: math.log(zoomIn ? kDeep : kWide),
    );
  }

  void _stepTour(double dt) {
    seg.t += dt;
    final p = math.min(1.0, seg.t / seg.dur);
    logS = lerp(seg.s0, seg.s1, smooth(0, 1, p));
    // 引いているときは、十分に広がってから次の場所へ移動する
    final f = seg.zoomIn ? smooth(0, 0.25, p) : smooth(0.55, 1, p);
    cx = lerp(seg.cx0, seg.cx1, f);
    cy = lerp(seg.cy0, seg.cy1, f);
    if (p >= 1) {
      if (seg.zoomIn) {
        tIdx = (tIdx + 1) % targets.length;
        _newSeg(false);
      } else {
        _newSeg(true);
      }
    }
  }

  /// 模様を切り替える（いったん暗くしてから）
  void requestPattern(int i) {
    if (i == pattern && _pending < 0) return;
    _pending = i;
  }

  void _apply(int i) {
    pattern = i;
    ptime = 0;
    _cycleTime = 0;
    auto = true;
    cx = 0;
    cy = 0;
    logS = 0;
    if (i == 0) {
      cx = targets[tIdx].x;
      cy = targets[tIdx].y;
      logS = math.log(kWide);
      _newSeg(true);
    }
    cpu[i]?.reset();
  }

  void tick(double raw) {
    raw = math.min(0.1, math.max(0.0, raw));
    if (raw > 0) {
      _avgMs = _avgMs * 0.92 + raw * 1000 * 0.08;
      _bestMs = math.min(_bestMs, _avgMs);
    }
    _sinceResize += raw;
    if (_sinceResize > 1.2) {
      if (_avgMs > _bestMs * 1.5 && renderScale > 0.3) {
        renderScale = math.max(0.3, renderScale * 0.85);
        _sinceResize = 0;
      } else if (_avgMs < _bestMs * 1.1 && renderScale < 1.0) {
        renderScale = math.min(1.0, renderScale * 1.1);
        _sinceResize = 0;
      }
    }

    // 切り替え：0.6秒かけて暗くし、切り替えてから0.8秒かけて明るくする
    if (_pending >= 0) {
      fade = math.min(1.0, fade + raw / 0.6);
      if (fade >= 1) {
        _apply(_pending);
        _pending = -1;
      }
    } else if (fade > 0) {
      fade = math.max(0.0, fade - raw / 0.8);
    }

    final dt = playing ? raw * speed : 0.0;
    ptime += dt;
    rot += dt * 0.025;
    shift += dt * 0.035;

    if (autoCycle && _pending < 0) {
      _cycleTime += dt;
      if (_cycleTime > (pattern == 0 ? 56 : 45)) {
        requestPattern((pattern + 1) % patternList.length);
      }
    }

    switch (pattern) {
      case 0:
        if (auto) _stepTour(dt);
        break;
      case 1:
        jAngle += dt * 0.06;
        if (auto) {
          logS = math.log(1.45 + 0.12 * math.sin(jAngle * 1.7));
          cx = 0;
          cy = 0;
        }
        break;
      case 2:
        if (auto) {
          logS = math.log(1.35 + 0.2 * math.sin(ptime * 0.08));
          cx = 0;
          cy = 0;
        }
        break;
      default:
        cx = 0;
        cy = 0;
        logS = 0;
        cpu[pattern]?.update(dt, ptime, palette, shift, screen);
    }
    palT = math.min(1.0, palT + raw / 1.8);
    notifyListeners();
  }

  /// いまの配色（切り替え中は前の配色と混ぜる）
  Palette get palette {
    final p = palettes[palIdx];
    final k = smooth(0, 1, palT);
    return Palette(
      p.name,
      lerpList(palFrom.a, p.a, k),
      lerpList(palFrom.b, p.b, k),
      lerpList(palFrom.c, p.c, k),
      lerpList(palFrom.d, p.d, k),
    );
  }

  double get iterations {
    if (shaderMode != 0) return 320;
    final v = 140 + 62 * (math.log(kWide / scale) / math.ln2);
    return math.min(1100.0, math.max(140.0, v)).roundToDouble();
  }

  // ── ボタンとタッチ操作 ──
  void nextColor() {
    palFrom = palette;
    palIdx = (palIdx + 1) % palettes.length;
    palT = 0;
  }

  void playButton() {
    if (!auto) {
      auto = true;
      playing = true;
      if (pattern == 0) _newSeg(false);
    } else {
      playing = !playing;
    }
  }

  void pan(Offset delta, double screenHeight) {
    if (!info.gestures) return;
    auto = false;
    final s = scale * 2 / screenHeight;
    final x = delta.dx * s, y = -delta.dy * s;
    final c = math.cos(rot), n = math.sin(rot);
    cx -= c * x - n * y;
    cy -= n * x + c * y;
  }

  void zoom(double factor) {
    if (!info.gestures) return;
    auto = false;
    logS = math.min(math.log(3.0), math.max(math.log(kDeep * 0.6), logS - math.log(factor)));
  }

  String get placeLabel {
    if (pattern == 0) {
      if (!auto) return '自由探索';
      return seg.zoomIn ? targets[tIdx].name : '→ ${targets[tIdx].name}';
    }
    return info.name;
  }

  String get detailLabel {
    switch (pattern) {
      case 0:
        final z = kWide / scale;
        return '倍率 ×${z < 10 ? z.toStringAsFixed(1) : _comma(z.round())}';
      case 1:
        final re = kJuliaR * math.cos(jAngle), im = kJuliaR * math.sin(jAngle);
        return 'c = ${re.toStringAsFixed(3)} ${im >= 0 ? '+' : '−'} ${im.abs().toStringAsFixed(3)}i';
      case 2:
        return 'z³ = 1 の3つの解のどれにたどり着くかで色分け';
      case 7:
        return '動く40個の種に、いちばん近い場所で塗り分ける';
      case 10:
        return '3つの波源の波が強め合い、打ち消し合う';
      case 11:
        return '${kaleidoSegs.toInt()}方向に鏡で折り返した模様';
      default:
        return cpu[pattern]?.detail(ptime) ?? '';
    }
  }

  static String _comma(int v) => v.toString().replaceAllMapped(
      RegExp(r'(\d)(?=(\d{3})+$)'), (m) => '${m[1]},');
}
