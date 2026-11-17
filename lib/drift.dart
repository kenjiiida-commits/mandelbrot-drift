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
  PatternInfo('水の底でゆらめく光', 6),
  PatternInfo('星雲の中を飛ぶ', 7),
  PatternInfo('雪の結晶が育つ', 8),
  PatternInfo('シャボン玉', 9),
  PatternInfo('宝石の城（立体フラクタル）', 10),
  PatternInfo('4次元の立体', -1),
  PatternInfo('光の群れ', -1),
  PatternInfo('光る洞窟を飛ぶ', 11),
  PatternInfo('夕暮れの大地を飛ぶ', 12),
  PatternInfo('ワープ航行', 13),
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
    17: Poly4(),
    18: Flock(),
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

  // 万華鏡 18種類：30秒ごとに次の種類へ。替わる前後は暗くする（「ずっと見る」の間は替えない）
  static const List<String> kNames = [
    '宝石のレース',
    'エメラルドとサファイア',
    '星屑',
    '無限トンネル',
    '無限トンネル：らせん',
    '無限トンネル：宝石の回廊',
    '無限トンネル：光の輪',
    '無限トンネル：二つの渦',
    '双曲の鏡',
    'アポロニウスのレース',
    '流れるガラス',
    '流れるガラス：夕焼け',
    '流れるガラス：オーロラ',
    '流れるガラス：大理石',
    '流れるガラス：オパール',
    '光の糸',
    'ガラスの破片',
    '花びらの曼荼羅',
  ];
  static const List<String> _kDescs = [
    '折り返しと反転を繰り返して生まれるレース',
    '緑と青の宝石を金の枠に散りばめる',
    '青と緑のきらめきが流れていく',
    'どこまでも奥へ続く鏡のトンネル',
    '渦を巻きながら奥へ吸い込まれる',
    '緑と青の宝石が奥へと連なる',
    'ネオンのような光の線が奥へ続く',
    '一方の渦から湧き出て、もう一方へ吸い込まれる',
    '縁へ向かって無限に細かくなる敷き詰め',
    '円の中に円が無限に詰まったレース',
    '溶けたガラスのように宝石の色が流れる',
    '紫からバラ色、金色へと流れる',
    '緑と紫の光のカーテンが揺れる',
    '白い石の中を青と金の筋が流れる',
    '虹色の光がきらめきながら流れる',
    '光る糸が鏡の間を行き交う',
    '色ガラスのかけらが重なって転がる',
    '幾重もの花びらが呼吸する',
  ];
  static const List<int> _kSegs = [8, 6, 8, 8, 6, 8, 10, 6, 7, 6, 6, 8, 6, 6, 8, 12, 6, 8];
  // 宝石の城 6種類（万華鏡と同じく、30秒ごとに切り替え・ずっと見る・メニューから選べる）
  static const List<String> castleNames = [
    '宝石の城（基本）',
    'キリモミ飛行',
    '色の波',
    'ネオンの街',
    '黄金の城',
    '水晶の城',
  ];
  static const List<String> _castleDescs = [
    'メンガーのスポンジが並ぶ街を飛び抜ける',
    'くるくると回転しながら、らせんを描いて突き進む',
    '立方体の色が、波のように次々と移り変わる',
    '暗い街の立方体の縁が、ネオンのように光る',
    '金色に輝く立方体が光を照り返す',
    '透き通った立方体が何枚も重なって見える',
  ];

  /// 種類を持つ模様（万華鏡と宝石の城）の、種類の名前の一覧
  static List<String> namesFor(int pat) => pat == 16 ? castleNames : kNames;
  bool get hasVariants => pattern == 11 || pattern == 16;

  final Map<int, int> _vStart = {11: 0, 16: 0};
  int _vNext = -1;
  double _kTime = 0; // 種類を切り替えるための時計（「ずっと見る」の間は止まる）
  bool kHold = false; // 同じ種類をずっと見る
  int get variant =>
      hasVariants ? ((_vStart[pattern] ?? 0) + (_kTime / 30).floor()) % namesFor(pattern).length : 0;
  int get kaleidoVar => variant;
  double get kaleidoSegs => pattern == 11 ? _kSegs[variant].toDouble() : 6.0;
  double get kaleidoDim {
    final fadeIn = math.min(1.0, ptime / 5);
    if (kHold) return fadeIn;
    final fr = _kTime / 30 - (_kTime / 30).floor();
    return math.min(fadeIn, math.min(1.0, math.min(fr * 6, (1 - fr) * 6) + (_kTime < 5 ? 1.0 : 0.0)));
  }

  void toggleHold() => kHold = !kHold;

  /// メニューで選んだ種類の万華鏡から始める
  void requestKaleido(int v) => requestVariant(11, v);

  /// メニューで選んだ種類から始める（万華鏡＝11、宝石の城＝16）
  void requestVariant(int pat, int v) {
    _vNext = v;
    _pending = pat;
  }

  // ── スマホの傾きで見回す（3Dの景色と宝石の城） ──
  bool tiltOn = true;
  double lookX = 0, lookY = 0; // 実際に見ている向き（なめらかに追いかける）
  double _roll = 0, _pitch = 0; // いまのスマホの傾き
  double _baseRoll = 0, _basePitch = 0; // 基準にする傾き（ゆっくり今の持ち方に合わせる）
  bool _hasTilt = false;
  bool get usesTilt => pattern == 16 || pattern >= 19;

  /// 加速度センサーの値（重力の向き）からスマホの傾きを求める
  void onAccel(double ax, double ay, double az) {
    _roll = math.atan2(ax, ay); // ハンドルのように左右に傾ける
    _pitch = math.atan2(az, ay); // 上端を手前・奥に倒す
    if (!_hasTilt) {
      _baseRoll = _roll;
      _basePitch = _pitch;
      _hasTilt = true;
    }
  }

  void toggleTilt() => tiltOn = !tiltOn;

  /// 模様に合う環境音（0=静かな和音 1=風 2=洞窟 3=ワープ）
  int get scape => pattern == 19 ? 2 : (pattern == 20 ? 1 : (pattern == 21 ? 3 : 0));

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
    if (i == 11 || i == 16) {
      _kTime = 0;
      if (_vNext >= 0) {
        _vStart[i] = _vNext;
        _vNext = -1;
      }
    }
    if (i == 16 || i >= 19) {
      _baseRoll = _roll;
      _basePitch = _pitch;
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

    if (hasVariants && !kHold) _kTime += dt;
    // 傾きの基準をゆっくり今の持ち方に近づけ、見回す向きをなめらかに追いかける
    if (_hasTilt) {
      final k = math.min(1.0, raw * 0.08);
      _baseRoll += (_roll - _baseRoll) * k;
      _basePitch += (_pitch - _basePitch) * k;
    }
    final on = tiltOn && usesTilt && _hasTilt;
    final tx = on ? math.max(-0.9, math.min(0.9, (_roll - _baseRoll) * 1.2)) : 0.0;
    final ty = on ? math.max(-0.7, math.min(0.7, (_pitch - _basePitch) * 1.0)) : 0.0;
    final f = math.min(1.0, raw * 6);
    lookX += (tx - lookX) * f;
    lookY += (ty - lookY) * f;
    if (autoCycle && _pending < 0 && !(hasVariants && kHold)) {
      _cycleTime += dt;
      if (_cycleTime > (pattern == 0 ? 56 : (pattern == 11 ? 150 : (pattern == 16 ? 120 : 45)))) {
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
    if (pattern == 11) return '万華鏡：${kNames[variant]}';
    if (pattern == 16) return variant == 0 ? '宝石の城' : '宝石の城：${castleNames[variant]}';
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
      case 12:
        return '水面で曲がった光が、底に揺れる網目を描く';
      case 13:
        return '色とりどりのガスと星の中を、奥へ奥へと進む';
      case 14:
        return '6方向に枝を伸ばして育つ（約24秒ごとに新しい結晶）';
      case 15:
        return '薄い膜に光が干渉して、虹色が流れる';
      case 19:
        return '曲がりくねった洞窟を、体を傾けながら進む${tiltOn ? '（スマホを傾けると見回せる）' : ''}';
      case 20:
        return '夕日に向かって、山と湖の上を低空で飛ぶ${tiltOn ? '（スマホを傾けると見回せる）' : ''}';
      case 21:
        return '星が光の筋になって、中心から外へ流れ去る${tiltOn ? '（スマホを傾けると見回せる）' : ''}';
      case 16:
        return '${_castleDescs[variant]}（${variant + 1}/${castleNames.length}）${kHold ? '・ずっと表示中' : ''}';
      case 11:
        return '${_kDescs[kaleidoVar]}（${kaleidoVar + 1}/${kNames.length}）${kHold ? '・ずっと表示中' : ''}';
      default:
        return cpu[pattern]?.detail(ptime) ?? '';
    }
  }

  static String _comma(int v) => v.toString().replaceAllMapped(
      RegExp(r'(\d)(?=(\d{3})+$)'), (m) => '${m[1]},');
}
