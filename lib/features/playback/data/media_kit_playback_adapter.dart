import 'package:gapless/features/playback/domain/playback_port.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

typedef MediaKitPlaybackBackendFactory =
    MediaKitPlaybackBackend Function(
      PlayerConfiguration playerConfiguration,
      VideoControllerConfiguration videoConfiguration,
    );

abstract interface class MediaKitPlaybackBackend {
  Stream<Duration> get positions;
  Stream<bool> get playing;
  VideoController? get videoController;

  Future<void> open(Uri source, {required bool play});
  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);
  Future<void> setRate(double rate);
  Future<void> dispose();
}

final class MediaKitPlaybackAdapter implements PlaybackPort {
  MediaKitPlaybackAdapter({
    MediaKitPlaybackBackendFactory backendFactory = _createBackend,
  }) : _backend = backendFactory(
         const PlayerConfiguration(osc: false, protocolWhitelist: ['file']),
         const VideoControllerConfiguration(
           hwdec: 'auto-safe',
           enableHardwareAcceleration: true,
         ),
       );

  final MediaKitPlaybackBackend _backend;
  bool _opened = false;
  bool _disposed = false;
  Future<void>? _disposeFuture;

  VideoController get videoController =>
      _backend.videoController ??
      (throw StateError('The injected backend has no video controller'));

  @override
  Stream<int> get positionUs =>
      _backend.positions.map((position) => position.inMicroseconds);

  @override
  Stream<bool> get playing => _backend.playing;

  @override
  Future<void> open(Uri source) async {
    _ensureActive();
    if (!_isAbsoluteLocalFile(source)) {
      throw ArgumentError.value(
        source,
        'source',
        'Must be an absolute file URI',
      );
    }
    await _backend.open(source, play: false);
    _ensureActive();
    _opened = true;
  }

  @override
  Future<void> play() async {
    _ensureOpened();
    await _backend.play();
  }

  @override
  Future<void> pause() async {
    _ensureOpened();
    await _backend.pause();
  }

  @override
  Future<void> seek(int sourceUs) async {
    _ensureOpened();
    if (sourceUs < 0) {
      throw ArgumentError.value(sourceUs, 'sourceUs');
    }
    await _backend.seek(Duration(microseconds: sourceUs));
  }

  @override
  Future<void> setRate(double rate) async {
    _ensureOpened();
    if (!rate.isFinite || rate <= 0) {
      throw ArgumentError.value(rate, 'rate');
    }
    await _backend.setRate(rate);
  }

  @override
  Future<void> dispose() {
    final existing = _disposeFuture;
    if (existing != null) return existing;
    _disposed = true;
    final future = _backend.dispose();
    _disposeFuture = future;
    return future;
  }

  void _ensureActive() {
    if (_disposed) {
      throw StateError('MediaKitPlaybackAdapter is disposed');
    }
  }

  void _ensureOpened() {
    _ensureActive();
    if (!_opened) {
      throw StateError('No media source is open');
    }
  }
}

bool _isAbsoluteLocalFile(Uri source) =>
    source.scheme == 'file' &&
    source.host.isEmpty &&
    source.path.startsWith('/') &&
    !source.hasQuery &&
    !source.hasFragment;

MediaKitPlaybackBackend _createBackend(
  PlayerConfiguration playerConfiguration,
  VideoControllerConfiguration videoConfiguration,
) =>
    _ProductionMediaKitPlaybackBackend(playerConfiguration, videoConfiguration);

final class _ProductionMediaKitPlaybackBackend
    implements MediaKitPlaybackBackend {
  _ProductionMediaKitPlaybackBackend(
    PlayerConfiguration playerConfiguration,
    VideoControllerConfiguration videoConfiguration,
  ) : _player = Player(configuration: playerConfiguration) {
    _videoController = VideoController(
      _player,
      configuration: videoConfiguration,
    );
  }

  final Player _player;
  late final VideoController _videoController;

  @override
  Stream<Duration> get positions => _player.stream.position;

  @override
  Stream<bool> get playing => _player.stream.playing;

  @override
  VideoController get videoController => _videoController;

  @override
  Future<void> open(Uri source, {required bool play}) =>
      _player.open(Media(source.toString()), play: play);

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> setRate(double rate) => _player.setRate(rate);

  @override
  Future<void> dispose() => _player.dispose();
}
