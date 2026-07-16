import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:gapless/features/playback/data/media_kit_playback_adapter.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

void main() {
  late _RecordingBackend backend;
  late PlayerConfiguration playerConfiguration;
  late VideoControllerConfiguration videoConfiguration;
  late MediaKitPlaybackAdapter adapter;

  setUp(() {
    backend = _RecordingBackend();
    adapter = MediaKitPlaybackAdapter(
      backendFactory: (playerConfig, videoConfig) {
        playerConfiguration = playerConfig;
        videoConfiguration = videoConfig;
        return backend;
      },
    );
  });

  tearDown(() async {
    await adapter.dispose();
    await backend.closeStreams();
  });

  test('uses file-only playback with safe hardware video configuration', () {
    expect(playerConfiguration.osc, isFalse);
    expect(playerConfiguration.protocolWhitelist, ['file']);
    expect(videoConfiguration.hwdec, 'auto-safe');
    expect(videoConfiguration.enableHardwareAcceleration, isTrue);
    expect(backend.videoController, isNull);
  });

  test('opens an absolute local file without autoplay', () async {
    final source = Uri.file('/videos/interview.mp4');

    await adapter.open(source);

    expect(backend.opens, [(source: source, play: false)]);
  });

  test('maps positions and seeks using exact integer microseconds', () async {
    await adapter.open(Uri.file('/videos/interview.mp4'));
    final positions = <int>[];
    final subscription = adapter.positionUs.listen(positions.add);

    backend.emitPosition(const Duration(microseconds: 9007199254740991));
    await adapter.seek(9007199254740991);
    await _pump();

    expect(positions, [9007199254740991]);
    expect(backend.seeks, [const Duration(microseconds: 9007199254740991)]);
    await subscription.cancel();
  });

  test('forwards playing state and playback commands', () async {
    await adapter.open(Uri.file('/videos/interview.mp4'));
    final playing = <bool>[];
    final subscription = adapter.playing.listen(playing.add);

    backend.emitPlaying(true);
    await adapter.play();
    await adapter.pause();
    await adapter.setRate(2.5);
    await _pump();

    expect(playing, [true]);
    expect(backend.playCount, 1);
    expect(backend.pauseCount, 1);
    expect(backend.rates, [2.5]);
    await subscription.cancel();
  });

  test(
    'rejects unsafe sources and invalid commands before backend calls',
    () async {
      for (final source in [
        Uri.parse('https://example.com/video.mp4'),
        Uri.file('relative.mp4'),
        Uri.parse('file://server/share/video.mp4'),
        Uri.parse('file:///video.mp4?token=secret'),
        Uri.parse('file:///video.mp4#fragment'),
      ]) {
        await expectLater(
          adapter.open(source),
          throwsArgumentError,
          reason: '$source must be rejected',
        );
      }
      await expectLater(adapter.play(), throwsStateError);
      await expectLater(adapter.pause(), throwsStateError);
      await expectLater(adapter.seek(0), throwsStateError);
      await expectLater(adapter.setRate(1), throwsStateError);
      expect(backend.opens, isEmpty);

      await adapter.open(Uri.file('/videos/interview.mp4'));
      await expectLater(adapter.seek(-1), throwsArgumentError);
      for (final rate in [0.0, -1.0, double.nan, double.infinity]) {
        await expectLater(adapter.setRate(rate), throwsArgumentError);
      }
      expect(backend.seeks, isEmpty);
      expect(backend.rates, isEmpty);
    },
  );

  test('disposes the owned backend once and rejects later commands', () async {
    await adapter.open(Uri.file('/videos/interview.mp4'));

    await adapter.dispose();
    await adapter.dispose();

    expect(backend.disposeCount, 1);
    await expectLater(
      adapter.open(Uri.file('/videos/other.mp4')),
      throwsStateError,
    );
    await expectLater(adapter.play(), throwsStateError);
    await expectLater(adapter.pause(), throwsStateError);
    await expectLater(adapter.seek(0), throwsStateError);
    await expectLater(adapter.setRate(1), throwsStateError);
  });
}

final class _RecordingBackend implements MediaKitPlaybackBackend {
  final _positions = StreamController<Duration>.broadcast(sync: true);
  final _playing = StreamController<bool>.broadcast(sync: true);

  final List<({Uri source, bool play})> opens = [];
  final List<Duration> seeks = [];
  final List<double> rates = [];
  int playCount = 0;
  int pauseCount = 0;
  int disposeCount = 0;

  @override
  Stream<Duration> get positions => _positions.stream;

  @override
  Stream<bool> get playing => _playing.stream;

  @override
  VideoController? get videoController => null;

  @override
  Future<void> open(Uri source, {required bool play}) async {
    opens.add((source: source, play: play));
  }

  @override
  Future<void> play() async => playCount += 1;

  @override
  Future<void> pause() async => pauseCount += 1;

  @override
  Future<void> seek(Duration position) async => seeks.add(position);

  @override
  Future<void> setRate(double rate) async => rates.add(rate);

  @override
  Future<void> dispose() async => disposeCount += 1;

  void emitPosition(Duration position) => _positions.add(position);

  void emitPlaying(bool value) => _playing.add(value);

  Future<void> closeStreams() async {
    await _positions.close();
    await _playing.close();
  }
}

Future<void> _pump() => Future<void>.delayed(Duration.zero);
