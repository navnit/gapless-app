abstract interface class PlaybackPort {
  Stream<int> get positionUs;
  Stream<bool> get playing;
  Future<void> open(Uri source);
  Future<void> play();
  Future<void> pause();
  Future<void> seek(int sourceUs);
  Future<void> setRate(double rate);
  Future<void> dispose();
}
