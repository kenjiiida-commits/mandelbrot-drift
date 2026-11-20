import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import 'package:sensors_plus/sensors_plus.dart';

import 'drift.dart';
import 'recorder.dart';
import 'sound.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // ステータスバーとナビゲーションバーを隠して全画面にする
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'マンデルブロ・ドリフト',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: const DriftPage(),
    );
  }
}

class DriftPage extends StatefulWidget {
  const DriftPage({super.key});

  @override
  State<DriftPage> createState() => _DriftPageState();
}

class _DriftPageState extends State<DriftPage> with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  final Drift drift = Drift();
  final SoundEngine sound = SoundEngine();
  StreamSubscription<AccelerometerEvent>? accel;
  int lastScape = -1;
  ui.FragmentShader? shader;
  String? error;
  late final Ticker ticker;
  Duration last = Duration.zero;
  bool uiVisible = true;
  Timer? hideTimer;
  double lastPinch = 1;

  // 録画
  final RecordSettings recSettings = RecordSettings();
  bool recording = false;
  bool recCancel = false;
  double recProgress = 0;
  String recStage = '';

  static const speeds = [1.0, 2.0, 4.0, 0.5];
  int speedIdx = 0;

  @override
  void initState() {
    super.initState();
    ticker = createTicker((elapsed) {
      final dt = (elapsed - last).inMicroseconds / 1e6;
      last = elapsed;
      drift.tick(dt);
      // 模様が替わったら、合う環境音に切り替える
      if (drift.scape != lastScape) {
        lastScape = drift.scape;
        sound.setScape(lastScape);
      }
    });
    _load();
    showUi();
    sound.init();
    WidgetsBinding.instance.addObserver(this);
    // スマホの傾き（加速度センサー）を受け取る
    try {
      accel = accelerometerEventStream(samplingPeriod: SensorInterval.gameInterval).listen(
        (e) => drift.onAccel(e.x, e.y, e.z),
        onError: (_) {},
      );
    } catch (_) {}
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      sound.resumeFromBackground();
    } else if (state == AppLifecycleState.paused) {
      sound.pauseForBackground();
    }
  }

  Future<void> _load() async {
    try {
      final program = await ui.FragmentProgram.fromAsset('shaders/mandelbrot.frag');
      if (!mounted) return;
      setState(() => shader = program.fragmentShader());
      ticker.start();
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    accel?.cancel();
    sound.dispose();
    ticker.dispose();
    hideTimer?.cancel();
    shader?.dispose();
    drift.dispose();
    super.dispose();
  }

  void showUi() {
    hideTimer?.cancel();
    if (!uiVisible) setState(() => uiVisible = true);
    hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => uiVisible = false);
    });
  }

  void press(VoidCallback action) {
    setState(action);
    showUi();
  }

  /// 模様を選ぶメニュー
  void _openMenu() {
    hideTimer?.cancel();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xF0141418),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.8),
            child: ListView(
              shrinkWrap: true,
              children: [
                SwitchListTile(
                  title: const Text('おまかせで次々と切り替える'),
                  subtitle: const Text('約45秒ごとに次の模様へ'),
                  value: drift.autoCycle,
                  onChanged: (v) => setSheet(() => drift.autoCycle = v),
                ),
                const Divider(height: 1),
                for (var i = 0; i < patternList.length; i++) ...[
                  ListTile(
                    title: Text(i == 11
                        ? '万華鏡（${Drift.kNames.length}種類を順番に）'
                        : (i == 16
                            ? '宝石の城（${Drift.castleNames.length}種類を順番に）'
                            : (i == 22
                                ? '没入の旅（${Drift.journeyNames.length}種類を順番に）'
                                : (i == 23 ? '極彩色の渦（${Drift.psyNames.length}種類を順番に）' : patternList[i].name)))),
                    trailing: i == drift.pattern ? const Icon(Icons.check) : null,
                    onTap: () {
                      drift.requestPattern(i);
                      Navigator.pop(ctx);
                    },
                  ),
                  if (i == 11 || i == 16 || i == 22 || i == 23)
                    for (var v = 0; v < Drift.namesFor(i).length; v++)
                      ListTile(
                        dense: true,
                        contentPadding: const EdgeInsets.only(left: 40, right: 16),
                        title: Text('・${Drift.namesFor(i)[v]}'),
                        trailing: (drift.pattern == i && drift.variant == v)
                            ? const Icon(Icons.check, size: 18)
                            : null,
                        onTap: () {
                          drift.requestVariant(i, v);
                          Navigator.pop(ctx);
                        },
                      ),
                ],
              ],
            ),
          ),
        ),
      ),
    ).whenComplete(showUi);
  }

  @override
  Widget build(BuildContext context) {
    if (error != null) {
      return Scaffold(body: Center(child: Text('描画の準備に失敗しました\n$error')));
    }
    final sh = shader;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (sh != null)
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: showUi,
              onScaleStart: (_) => lastPinch = 1,
              onScaleUpdate: (d) {
                final h = MediaQuery.of(context).size.height;
                if (d.focalPointDelta != Offset.zero) drift.pan(d.focalPointDelta, h);
                if (d.pointerCount >= 2 && d.scale != lastPinch) {
                  drift.zoom(d.scale / lastPinch);
                  lastPinch = d.scale;
                }
                showUi();
              },
              child: CustomPaint(
                painter: FractalPainter(
                  shader: sh,
                  drift: drift,
                  dpr: MediaQuery.of(context).devicePixelRatio,
                ),
              ),
            ),
          IgnorePointer(
            ignoring: !uiVisible,
            child: AnimatedOpacity(
              opacity: uiVisible ? 1 : 0,
              duration: const Duration(milliseconds: 500),
              child: SafeArea(
                child: ListenableBuilder(listenable: drift, builder: (context, _) => _overlay()),
              ),
            ),
          ),
          if (recording) _recordingOverlay(),
        ],
      ),
    );
  }

  Widget _overlay() {
    const shadow = [Shadow(blurRadius: 4, color: Colors.black)];
    return Stack(
      children: [
        Positioned(
          left: 16,
          top: 12,
          right: 16,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(drift.placeLabel,
                  style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600, shadows: shadow)),
              Text(drift.detailLabel, style: const TextStyle(fontSize: 13, shadows: shadow)),
            ],
          ),
        ),
        Positioned(
          left: 12,
          right: 12,
          bottom: 16,
          child: Center(
            child: Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: const Color(0x99141418),
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Wrap(
                  alignment: WrapAlignment.center,
                  runSpacing: 6,
                  children: [
                    _btn(drift.autoCycle ? '模様（おまかせ）' : '模様', _openMenu, direct: true),
                    _btn('色', () => drift.nextColor()),
                    _btn('速さ ${_speedText(speeds[speedIdx])}×', () {
                      speedIdx = (speedIdx + 1) % speeds.length;
                      drift.speed = speeds[speedIdx];
                    }),
                    _btn(!drift.auto ? '自動再開' : (drift.playing ? '一時停止' : '再生'),
                        () => drift.playButton()),
                    if (drift.hasVariants)
                      _btn(drift.kHold ? 'ずっと見る：オン' : 'ずっと見る', () => drift.toggleHold()),
                    if (drift.usesTilt)
                      _btn(drift.tiltOn ? '見回す：オン' : '見回す：オフ', () => drift.toggleTilt()),
                    _btn(sound.enabled ? '音：オン' : '音：オフ', () => sound.toggle()),
                    _btn('● 録画', _openRecord, direct: true),
                  ],
                ),
            ),
          ),
        ),
      ],
    );
  }

  // ───────────── 録画 ─────────────

  void _openRecord() {
    hideTimer?.cancel();
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xF0141418),
      isScrollControlled: true,
      builder: (_) => RecordSheet(settings: recSettings, onStart: _record),
    ).whenComplete(showUi);
  }

  Widget _recordingOverlay() {
    return Container(
      color: const Color(0x99000000),
      alignment: Alignment.center,
      child: Container(
        width: 280,
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(color: const Color(0xF0141418), borderRadius: BorderRadius.circular(16)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.fiber_manual_record, color: Colors.redAccent),
            const SizedBox(height: 8),
            Text(recStage, style: const TextStyle(fontSize: 16)),
            const SizedBox(height: 12),
            LinearProgressIndicator(value: recProgress),
            const SizedBox(height: 8),
            Text('${(recProgress * 100).floor()}%'),
            const SizedBox(height: 12),
            TextButton(
              onPressed: recCancel ? null : () => setState(() => recCancel = true),
              child: Text(recCancel ? '取り消しています…' : '取り消す'),
            ),
          ],
        ),
      ),
    );
  }

  String _two(int v) => v.toString().padLeft(2, '0');

  /// 1コマずつ正確な時間で描き直し、Android 側で動画ファイルにする
  Future<void> _record() async {
    final sh = shader;
    if (sh == null || recording) return;
    final mq = MediaQuery.of(context);
    final screen = mq.size;
    final dpr = mq.devicePixelRatio;
    final s = recSettings;

    // 書き出す大きさ（縦横とも偶数にする）
    late final Size logical;
    int w, h;
    if (s.shorts) {
      logical = Size(screen.width, screen.width * 16 / 9);
      w = 1080;
      h = 1920;
    } else {
      final pw = screen.width * dpr, ph = screen.height * dpr;
      final longSide = math.max(pw, ph);
      final f = longSide > 1920 ? 1920 / longSide : 1.0;
      logical = screen;
      w = math.max(2, (pw * f / 2).round() * 2);
      h = math.max(2, (ph * f / 2).round() * 2);
    }
    try {
      (w, h) = await RecorderChannel.fitSize(w, h);
    } catch (_) {}
    if (!mounted) return;
    final kx = w / logical.width, ky = h / logical.height;
    final bitrate = (w * h * s.fps * 0.15).clamp(12e6, 40e6).round();
    final total = s.seconds * s.fps;

    hideTimer?.cancel();
    setState(() {
      recording = true;
      recCancel = false;
      recProgress = 0;
      recStage = '準備中…';
      uiVisible = false;
    });

    ticker.stop();
    final savedScale = drift.renderScale;
    final savedScreen = drift.screen;
    drift.recording = true;
    drift.renderScale = 1;
    drift.screen = logical;

    String? path;
    Object? failure;
    try {
      Uint8List? pcm;
      if (s.audio) {
        pcm = await compute(makeScapePcm, <Object>[drift.scape, s.seconds.toDouble()]);
      }
      await RecorderChannel.start(width: w, height: h, fps: s.fps, bitrate: bitrate, pcm: pcm);
      if (mounted) setState(() => recStage = '書き出し中');
      final painter = FractalPainter(shader: sh, drift: drift, dpr: kx);
      for (var i = 0; i < total && !recCancel; i++) {
        drift.tick(1 / s.fps);
        await drift.cpu[drift.pattern]?.settle();
        final pr = ui.PictureRecorder();
        final canvas = Canvas(pr);
        canvas.scale(kx, ky);
        painter.paint(canvas, logical);
        final pic = pr.endRecording();
        final img = await pic.toImage(w, h);
        pic.dispose();
        final bytes = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
        img.dispose();
        await RecorderChannel.frame(bytes!.buffer.asUint8List());
        if (mounted && (i % 3 == 0 || i == total - 1)) setState(() => recProgress = (i + 1) / total);
      }
      if (mounted) setState(() => recStage = recCancel ? '取り消しています…' : '保存しています…');
      final t = DateTime.now();
      final name = 'mandelbrot_drift_${t.year}${_two(t.month)}${_two(t.day)}_'
          '${_two(t.hour)}${_two(t.minute)}${_two(t.second)}${s.shorts ? '_short' : ''}.mp4';
      path = await RecorderChannel.finish(cancel: recCancel, name: name);
    } catch (e) {
      failure = e;
      try {
        await RecorderChannel.finish(cancel: true, name: 'cancel.mp4');
      } catch (_) {}
    } finally {
      drift.recording = false;
      drift.renderScale = savedScale;
      drift.screen = savedScreen;
      last = Duration.zero;
      if (mounted) {
        ticker.start();
        setState(() => recording = false);
      }
    }
    if (!mounted) return;
    if (failure != null) {
      _recordDone('録画できませんでした', '$failure', false);
    } else if (path != null) {
      _recordDone(
        '動画を保存しました',
        '$path\n\nギャラリー（フォト）アプリの「MandelbrotDrift」フォルダにあります。'
            '${s.shorts ? '\n\n「共有する」から YouTube を選ぶと、ショートとして投稿できます。' : ''}',
        true,
      );
    } else {
      showUi();
    }
  }

  void _recordDone(String title, String body, bool canShare) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          if (canShare)
            TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                RecorderChannel.share();
              },
              child: const Text('共有する'),
            ),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('閉じる')),
        ],
      ),
    ).whenComplete(showUi);
  }

  String _speedText(double s) => s == s.roundToDouble() ? s.toInt().toString() : s.toString();

  Widget _btn(String label, VoidCallback action, {bool direct = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: TextButton(
        style: TextButton.styleFrom(
          backgroundColor: const Color(0x1AFFFFFF),
          foregroundColor: Colors.white,
          shape: const StadiumBorder(),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        ),
        onPressed: direct ? action : () => press(action),
        child: Text(label, style: const TextStyle(fontSize: 14)),
      ),
    );
  }
}

// ───────────── 描く ─────────────

class FractalPainter extends CustomPainter {
  FractalPainter({required this.shader, required this.drift, required this.dpr})
      : super(repaint: drift);

  final ui.FragmentShader shader;
  final Drift drift;
  final double dpr;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    drift.screen = size;
    final pal = drift.palette;
    final cpu = drift.cpu[drift.pattern];
    if (cpu != null) {
      cpu.paint(canvas, size, pal, drift.shift, drift.ptime);
    } else {
      _paintShader(canvas, size, pal);
    }
    if (drift.fade > 0) {
      canvas.drawRect(
        Offset.zero & size,
        Paint()..color = Color.fromARGB((drift.fade * 255).round(), 0, 0, 0),
      );
    }
  }

  /// GPUで描く（画面より小さい画像に描いてから引き伸ばし、重い端末でも滑らかにする）
  void _paintShader(Canvas canvas, Size size, Palette pal) {
    final px = dpr * drift.renderScale;
    final w = math.max(1, (size.width * px).round());
    final h = math.max(1, (size.height * px).round());

    var i = 0;
    void f(double v) => shader.setFloat(i++, v);
    f(w.toDouble());
    f(h.toDouble());
    f(drift.cx);
    f(drift.cy);
    if (drift.hasVariants) {
      f(drift.kaleidoSegs); // 万華鏡では「鏡の数」と「明るさ」を渡す
      f(drift.kaleidoDim);
    } else {
      f(kJuliaR * math.cos(drift.jAngle));
      f(kJuliaR * math.sin(drift.jAngle));
    }
    f(drift.scale);
    f(drift.pattern >= 19 && drift.pattern <= 22 ? 0.0 : drift.rot); // 3Dの景色は画面を回さない
    f(drift.shift);
    f(drift.iterations);
    f(drift.shaderMode.toDouble());
    for (final v in [...pal.a, ...pal.b, ...pal.c, ...pal.d]) {
      f(v);
    }
    f(drift.ptime);
    f(drift.kaleidoVar.toDouble());
    f(drift.lookX);
    f(drift.lookY);
    for (final v in drift.psyUniforms) {
      f(v);
    }

    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawRect(
      Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      Paint()..shader = shader,
    );
    final picture = recorder.endRecording();
    final image = picture.toImageSync(w, h);
    picture.dispose();
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      Offset.zero & size,
      Paint()..filterQuality = FilterQuality.low,
    );
    image.dispose();
  }

  @override
  bool shouldRepaint(covariant FractalPainter old) => old.shader != shader || old.dpr != dpr;
}
