import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import 'drift.dart';

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

class _DriftPageState extends State<DriftPage> with SingleTickerProviderStateMixin {
  final Drift drift = Drift();
  ui.FragmentShader? shader;
  String? error;
  late final Ticker ticker;
  Duration last = Duration.zero;
  bool uiVisible = true;
  Timer? hideTimer;
  double lastPinch = 1;

  static const speeds = [1.0, 2.0, 4.0, 0.5];
  int speedIdx = 0;

  @override
  void initState() {
    super.initState();
    ticker = createTicker((elapsed) {
      final dt = (elapsed - last).inMicroseconds / 1e6;
      last = elapsed;
      drift.tick(dt);
    });
    _load();
    showUi();
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
                for (var i = 0; i < patternList.length; i++)
                  ListTile(
                    title: Text(patternList[i].name),
                    trailing: i == drift.pattern ? const Icon(Icons.check) : null,
                    onTap: () {
                      drift.requestPattern(i);
                      Navigator.pop(ctx);
                    },
                  ),
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
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: const Color(0x99141418),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _btn(drift.autoCycle ? '模様（おまかせ）' : '模様', _openMenu, direct: true),
                    _btn('色', () => drift.nextColor()),
                    _btn('速さ ${_speedText(speeds[speedIdx])}×', () {
                      speedIdx = (speedIdx + 1) % speeds.length;
                      drift.speed = speeds[speedIdx];
                    }),
                    _btn(!drift.auto ? '自動再開' : (drift.playing ? '一時停止' : '再生'),
                        () => drift.playButton()),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
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
    if (drift.pattern == 11) {
      f(drift.kaleidoSegs); // 万華鏡では「鏡の数」と「明るさ」を渡す
      f(drift.kaleidoDim);
    } else {
      f(kJuliaR * math.cos(drift.jAngle));
      f(kJuliaR * math.sin(drift.jAngle));
    }
    f(drift.scale);
    f(drift.rot);
    f(drift.shift);
    f(drift.iterations);
    f(drift.shaderMode.toDouble());
    for (final v in [...pal.a, ...pal.b, ...pal.c, ...pal.d]) {
      f(v);
    }
    f(drift.ptime);

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
