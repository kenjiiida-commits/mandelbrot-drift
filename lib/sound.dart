// 環境音：その場で計算して作り、つなぎ目なくループさせて鳴らす
import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

/// 音の種類：0=静かな和音 1=風 2=洞窟 3=ワープ
const int scapePad = 0, scapeWind = 1, scapeCave = 2, scapeWarp = 3;

const int _sr = 22050; // 1秒あたりの音の数
const double _len = 24.0; // 24秒でひと回りする
const int _n = 529200; // _sr * _len

/// ループの長さでちょうど割り切れる周波数に丸める（つなぎ目で音が途切れないように）
double _q(double f) => (f * _len).roundToDouble() / _len;

class _Rng {
  _Rng(this._x);
  int _x;
  double next() {
    _x = (_x * 1103515245 + 12345) & 0x7fffffff;
    return _x / 0x7fffffff;
  }
}

void _normalize(Float64List x, double peak) {
  var m = 1e-9;
  for (final v in x) {
    if (v.abs() > m) m = v.abs();
  }
  for (var i = 0; i < x.length; i++) {
    x[i] = x[i] / m * peak;
  }
}

/// 雑音をなめらかにして（風のような音）、始めと終わりを重ねてつなぎ目をなくす
Float64List _noiseLoop(int seed, double Function(double t) cutoff) {
  const f = _sr; // 1秒分を重ねる
  const m = _n + f;
  final rnd = _Rng(seed);
  final y = Float64List(m);
  var s = 0.0;
  for (var i = 0; i < m; i++) {
    final a = 1 - math.exp(-2 * math.pi * math.max(20.0, cutoff(i / _sr)) / _sr); // 明るさがマイナスだと計算が発散するので下限を付ける
    s += a * (rnd.next() * 2 - 1 - s);
    y[i] = s;
  }
  final out = Float64List(_n);
  for (var i = 0; i < _n; i++) {
    out[i] = y[i];
  }
  for (var i = 0; i < f; i++) {
    final k = i / f;
    out[i] = y[_n + i] * math.sqrt(1 - k) + y[i] * math.sqrt(k);
  }
  return out;
}

double _sin(double f, double t) => math.sin(2 * math.pi * f * t);

Float64List _pad() {
  const notes = [110.0, 164.81, 220.0, 261.63, 329.63, 392.0];
  final x = Float64List(_n);
  for (var k = 0; k < notes.length; k++) {
    final f1 = _q(notes[k]), f2 = _q(notes[k] * 1.004);
    final m = 1 + k % 3;
    for (var i = 0; i < _n; i++) {
      final t = i / _sr;
      final env = 0.5 + 0.5 * math.sin(2 * math.pi * m * t / _len + k * 1.3);
      x[i] += (_sin(f1, t) + 0.6 * _sin(f2, t)) * env / (1 + k * 0.35);
    }
  }
  _normalize(x, 0.5);
  return x;
}

Float64List _wind() {
  final n = _noiseLoop(7, (t) => 420 + 220 * math.sin(2 * math.pi * 2 * t / _len) + 120 * math.sin(2 * math.pi * 5 * t / _len));
  _normalize(n, 1);
  final x = Float64List(_n);
  final a = _q(55), b = _q(82.4);
  for (var i = 0; i < _n; i++) {
    final t = i / _sr;
    final gust = 0.55 + 0.45 * math.sin(2 * math.pi * 3 * t / _len) * math.sin(2 * math.pi * t / _len + 0.7);
    x[i] = n[i] * gust + (0.25 * _sin(a, t) + 0.18 * _sin(b, t)) * 0.5;
  }
  _normalize(x, 0.6);
  return x;
}

Float64List _cave() {
  final x = Float64List(_n);
  final a = _q(55), b = _q(82.4), c = _q(110.3);
  for (var i = 0; i < _n; i++) {
    final t = i / _sr;
    x[i] = _sin(a, t) + 0.7 * _sin(b, t) * (0.6 + 0.4 * math.sin(2 * math.pi * 2 * t / _len)) + 0.3 * _sin(c, t);
  }
  _normalize(x, 0.35);
  final rumble = _noiseLoop(11, (t) => 120.0);
  _normalize(rumble, 0.12);
  for (var i = 0; i < _n; i++) {
    x[i] += rumble[i];
  }
  // 水滴の音と、洞窟の壁から返ってくる響き
  final rnd = _Rng(5);
  final dl = (_sr * 0.6).round();
  for (var k = 0; k < 18; k++) {
    final st = (rnd.next() * _n).floor();
    final f = 1300 + rnd.next() * 1300;
    final amp = (0.5 + 0.5 * rnd.next()) * 0.35;
    for (final echo in const [
      [0.0, 1.0],
      [0.13, 0.4],
      [0.27, 0.2],
      [0.41, 0.1]
    ]) {
      final off = st + (echo[0] * _sr).round();
      for (var j = 0; j < dl; j++) {
        final tt = j / _sr;
        x[(off + j) % _n] += math.sin(2 * math.pi * (f * tt - 300 * tt * tt)) * math.exp(-tt * 14) * amp * echo[1];
      }
    }
  }
  _normalize(x, 0.6);
  return x;
}

Float64List _warp() {
  final x = Float64List(_n);
  final hs = [for (var h = 1; h <= 8; h++) _q(55.0 * h)];
  final s1 = _q(880), s2 = _q(1320);
  for (var i = 0; i < _n; i++) {
    final t = i / _sr;
    final b = 0.5 + 0.5 * math.sin(2 * math.pi * 2 * t / _len);
    var v = 0.0;
    for (var h = 1; h <= 8; h++) {
      v += _sin(hs[h - 1], t) / h * math.exp(-h * (1.5 - b) * 0.6);
    }
    x[i] = v;
  }
  _normalize(x, 0.5);
  final whoosh = _noiseLoop(3, (t) => 900 + 700 * math.sin(2 * math.pi * 3 * t / _len));
  _normalize(whoosh, 0.25);
  for (var i = 0; i < _n; i++) {
    final t = i / _sr;
    final shimmer = (0.3 * _sin(s1, t) + 0.2 * _sin(s2, t)) * (0.5 + 0.5 * math.sin(2 * math.pi * 12 * t / _len));
    x[i] += whoosh[i] * (0.6 + 0.4 * math.sin(2 * math.pi * 3 * t / _len)) + shimmer * 0.15;
  }
  _normalize(x, 0.6);
  return x;
}

/// 音を作ってWAV形式のデータにする（別の処理の流れで計算するため、トップレベルの関数にしている）
Uint8List makeScapeWav(int kind) {
  final x = kind == scapeWind
      ? _wind()
      : kind == scapeCave
          ? _cave()
          : kind == scapeWarp
              ? _warp()
              : _pad();
  final d = ByteData(44 + x.length * 2);
  void tag(int o, String s) {
    for (var i = 0; i < 4; i++) {
      d.setUint8(o + i, s.codeUnitAt(i));
    }
  }

  tag(0, 'RIFF');
  d.setUint32(4, 36 + x.length * 2, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  d.setUint32(16, 16, Endian.little);
  d.setUint16(20, 1, Endian.little);
  d.setUint16(22, 1, Endian.little);
  d.setUint32(24, _sr, Endian.little);
  d.setUint32(28, _sr * 2, Endian.little);
  d.setUint16(32, 2, Endian.little);
  d.setUint16(34, 16, Endian.little);
  tag(36, 'data');
  d.setUint32(40, x.length * 2, Endian.little);
  for (var i = 0; i < x.length; i++) {
    var v = x[i];
    if (v > 1) v = 1;
    if (v < -1) v = -1;
    d.setInt16(44 + i * 2, (v * 32767).round(), Endian.little);
  }
  return d.buffer.asUint8List();
}

/// 模様に合わせて環境音を切り替えて鳴らす
class SoundEngine {
  final AudioPlayer _player = AudioPlayer();
  final Map<int, Uint8List> _cache = {};
  bool enabled = false;
  bool _paused = false;
  int _current = -1;
  int _want = scapePad;
  bool _busy = false;
  double _vol = 0;

  Future<void> init() async {
    await _player.setReleaseMode(ReleaseMode.loop);
  }

  void dispose() {
    _player.dispose();
  }

  void setScape(int kind) {
    _want = kind;
    _apply();
  }

  void toggle() {
    enabled = !enabled;
    _apply();
  }

  /// アプリが裏に回ったら止め、戻ったら続きを鳴らす
  void pauseForBackground() {
    _paused = true;
    if (_current >= 0) _player.pause();
  }

  void resumeFromBackground() {
    _paused = false;
    if (enabled && _current >= 0) _player.resume();
  }

  Future<void> _fadeTo(double v) async {
    final from = _vol;
    for (var i = 1; i <= 8; i++) {
      _vol = from + (v - from) * i / 8;
      await _player.setVolume(_vol);
      await Future<void>.delayed(const Duration(milliseconds: 60));
    }
  }

  Future<void> _apply() async {
    if (_busy) return;
    _busy = true;
    try {
      while (true) {
        if (!enabled || _paused) {
          if (_current >= 0) {
            await _fadeTo(0);
            await _player.stop();
            _current = -1;
          }
          break;
        }
        if (_want == _current) break;
        final k = _want;
        final bytes = _cache[k] ??= await compute(makeScapeWav, k);
        if (_current >= 0) await _fadeTo(0);
        _vol = 0;
        await _player.setVolume(0);
        await _player.play(BytesSource(bytes));
        _current = k;
        await _fadeTo(0.8);
      }
    } catch (e) {
      debugPrint('音を鳴らせませんでした: $e');
    } finally {
      _busy = false;
    }
  }
}
