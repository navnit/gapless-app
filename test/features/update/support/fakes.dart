import 'package:gapless/features/update/domain/channel_detector_port.dart';
import 'package:gapless/features/update/domain/install_channel.dart';
import 'package:gapless/features/update/domain/release_info.dart';
import 'package:gapless/features/update/domain/update_checker_port.dart';
import 'package:gapless/features/update/domain/update_preferences_port.dart';

class FakeChecker implements UpdateCheckerPort {
  FakeChecker(this._result);
  final Object _result; // ReleaseInfo or UpdateCheckException
  int calls = 0;
  @override
  Future<ReleaseInfo> fetchLatest() async {
    calls++;
    final result = _result;
    if (result is ReleaseInfo) return result;
    throw result;
  }
}

class FakeDetector implements ChannelDetectorPort {
  FakeDetector(this.channel);
  final InstallChannel channel;
  @override
  Future<InstallChannel> detect() async => channel;
}

class MemoryPrefs implements UpdatePreferencesPort {
  MemoryPrefs([this.data = const UpdatePreferencesData()]);
  UpdatePreferencesData data;
  @override
  Future<UpdatePreferencesData> load() async => data;
  @override
  Future<void> save(UpdatePreferencesData next) async => data = next;
}
