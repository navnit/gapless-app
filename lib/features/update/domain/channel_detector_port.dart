import 'package:gapless/features/update/domain/install_channel.dart';

abstract interface class ChannelDetectorPort {
  Future<InstallChannel> detect();
}
