// 録画：いま流れている模様を、1コマずつ描き直して高画質の動画ファイルにする
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 録画の設定
class RecordSettings {
  bool shorts = false; // true=YouTubeショート（縦1080×1920）、false=そのままの画面
  int seconds = 30;
  int fps = 30;
  bool audio = true;
}

/// Android 側（Kotlin の VideoRecorder）とのやりとり
class RecorderChannel {
  static const _ch = MethodChannel('mandelbrot_drift/recorder');

  static Future<void> start({
    required int width,
    required int height,
    required int fps,
    required int bitrate,
    Uint8List? pcm,
  }) =>
      _ch.invokeMethod('start', {
        'width': width,
        'height': height,
        'fps': fps,
        'bitrate': bitrate,
        'pcm': pcm,
        'sampleRate': 44100,
      });

  /// この機種で書き出せる大きさを聞く
  static Future<(int, int)> fitSize(int w, int h) async {
    final r = await _ch.invokeListMethod<int>('fitSize', {'width': w, 'height': h});
    if (r == null || r.length < 2) return (w, h);
    return (r[0], r[1]);
  }

  static Future<void> frame(Uint8List rgba) => _ch.invokeMethod('frame', rgba);

  static Future<String?> finish({required bool cancel, required String name}) =>
      _ch.invokeMethod<String>('finish', {'cancel': cancel, 'name': name});

  static Future<bool> share() async => (await _ch.invokeMethod<bool>('share')) ?? false;
}

/// 録画の設定を選ぶ画面（下から出てくるシート）
class RecordSheet extends StatefulWidget {
  const RecordSheet({super.key, required this.settings, required this.onStart});
  final RecordSettings settings;
  final VoidCallback onStart;

  @override
  State<RecordSheet> createState() => _RecordSheetState();
}

class _RecordSheetState extends State<RecordSheet> {
  Widget _choices<T>(String label, List<(String, T)> items, T value, void Function(T) onSel) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 13, color: Colors.white70)),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              for (final it in items)
                ChoiceChip(
                  label: Text(it.$1),
                  selected: it.$2 == value,
                  onSelected: (_) => setState(() => onSel(it.$2)),
                ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.settings;
    return SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 16, 20, 4),
              child: Text('録画して動画ファイルにする', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
            ),
            _choices<bool>('形式', [('そのままの画面', false), ('YouTubeショート（縦1080×1920）', true)], s.shorts, (v) => s.shorts = v),
            _choices<int>('長さ', [('15秒', 15), ('30秒', 30), ('60秒', 60)], s.seconds, (v) => s.seconds = v),
            _choices<int>('なめらかさ', [('30コマ/秒', 30), ('60コマ/秒（書き出しに時間がかかる）', 60)], s.fps, (v) => s.fps = v),
            SwitchListTile(
              title: const Text('環境音を入れる'),
              value: s.audio,
              onChanged: (v) => setState(() => s.audio = v),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                '1コマずつ描き直して書き出すので、スマホが重くてもカクつかない高画質になります。'
                'そのぶん、動画の長さより時間がかかります。ボタンなどの表示は映りません。',
                style: TextStyle(fontSize: 12, color: Colors.white60),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
              child: FilledButton.icon(
                icon: const Icon(Icons.fiber_manual_record, color: Colors.redAccent),
                label: const Text('録画を始める'),
                onPressed: () {
                  Navigator.pop(context);
                  widget.onStart();
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
