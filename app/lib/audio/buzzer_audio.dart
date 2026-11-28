import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/services.dart';

import '../state/circuit_exports.dart';

/// Optional low-overhead synthesized audio feedback for energized Buzzers (disabled by default).
// shortcut: native OS players + SystemSound fallback used because offline pub cache lacks audioplayers; replace with audioplayers on connected build.
class BuzzerAudio {
  bool enabled = false;
  DateTime _lastBeep = DateTime.fromMillisecondsSinceEpoch(0);
  String? _cachedWavPath;
  double _cachedFreq = -1;
  bool _playing = false;
  String? _linuxPlayer;
  bool _linuxPlayerChecked = false;
  Directory? _tempDir;
  bool _disposed = false;

  void dispose() {
    _disposed = true;
    try {
      _tempDir?.deleteSync(recursive: true);
      _tempDir = null;
      _cachedWavPath = null;
    } catch (_) {}
  }

  Future<void> triggerIfActive(double freqHz) async {
    if (!enabled) return;
    final now = DateTime.now();
    if (now.difference(_lastBeep).inMilliseconds < 320) return;
    _lastBeep = now;

    final clampedFreq = freqHz.clamp(120.0, 4000.0);
    try {
      if (!Platform.isLinux && !Platform.isMacOS && !Platform.isWindows) {
        await SystemSound.play(SystemSoundType.alert);
        return;
      }
      if (_playing) return;
      final path = await _ensureWavAsync(clampedFreq);
      if (_disposed || !enabled || _playing) return;
      if (Platform.isLinux) {
        final player = await _findLinuxPlayer();
        if (_disposed || !enabled || _playing) return;
        if (player != null) {
          final args = player == 'aplay' ? ['-q', path] : [path];
          _unawaitedProcess(player, args);
        }
      } else if (Platform.isMacOS) {
        _unawaitedProcess('afplay', [path]);
      } else if (Platform.isWindows) {
        final safePath = path.replaceAll("'", "''");
        _unawaitedProcess('powershell', [
          '-NoProfile',
          '-Command',
          "(New-Object Media.SoundPlayer '$safePath').PlaySync()",
        ]);
      }
    } catch (_) {
      // Audio playback must never fail or block simulation ticks.
    }
  }

  Future<String?> _findLinuxPlayer() async {
    if (_linuxPlayerChecked) return _linuxPlayer;
    for (final bin in const ['pw-play', 'paplay', 'aplay']) {
      try {
        final res = await Process.run('which', [bin]);
        if (res.exitCode == 0) {
          _linuxPlayer = bin;
          break;
        }
      } catch (_) {}
    }
    _linuxPlayerChecked = true;
    return _linuxPlayer;
  }

  void _unawaitedProcess(String exe, List<String> args) {
    if (_playing) return;
    _playing = true;
    Process.start(exe, args).then((proc) {
      proc.stdout.drain<void>();
      proc.stderr.drain<void>();
      proc.exitCode.whenComplete(() => _playing = false);
    }).catchError((_) {
      _playing = false;
    });
  }

  Future<String> _ensureWavAsync(double freqHz) async {
    if (_cachedWavPath != null && (_cachedFreq - freqHz).abs() < 5.0) {
      return _cachedWavPath!;
    }
    const sampleRate = 22050;
    const numSamples = (sampleRate * 140) ~/ 1000;
    final samples = List<double>.generate(numSamples, (i) {
      final env = math.sin(math.pi * i / numSamples);
      return math.sin(2 * math.pi * freqHz * i / sampleRate) * env * 0.3;
    });

    final dir = _tempDir ??= await Directory.systemTemp.createTemp('benchosc_buzzer_');
    if (_disposed) {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
      _tempDir = null;
      throw StateError('disposed');
    }
    final file = File('${dir.path}/buzzer.wav');
    await file.writeAsBytes(encodeWav16Pcm(samples, sampleRate: sampleRate), flush: true);
    _cachedWavPath = file.path;
    _cachedFreq = freqHz;
    return file.path;
  }
}
