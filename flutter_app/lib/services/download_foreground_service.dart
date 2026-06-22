import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// Keeps the app process alive while downloads run in the background.
///
/// Downloads execute in the main Flutter isolate (see [DownloadManager]). When
/// the app is backgrounded the OS may kill that isolate mid-download; running an
/// Android foreground service (with an ongoing notification) keeps the process
/// alive until the download finishes. The service holds no logic of its own —
/// it's purely a lifetime anchor.
class DownloadForegroundService {
  static bool _inited = false;

  static const String _title = 'Downloading audio';

  static void _ensureInit() {
    if (_inited) return;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'download_foreground_service',
        channelName: 'Background downloads',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: false,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
    _inited = true;
  }

  /// Request the Android 13+ notification permission so the ongoing
  /// notification (and thus the foreground service) can be shown.
  static Future<void> requestPermission() async {
    final status = await FlutterForegroundTask.checkNotificationPermission();
    if (status != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }
  }

  static Future<void> start(String text) async {
    _ensureInit();
    if (await FlutterForegroundTask.isRunningService) {
      await update(text);
      return;
    }
    await FlutterForegroundTask.startService(
      serviceId: 0xD0,
      notificationTitle: _title,
      notificationText: text,
    );
  }

  static Future<void> update(String text) async {
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.updateService(
        notificationTitle: _title,
        notificationText: text,
      );
    }
  }

  static Future<void> stop() async {
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.stopService();
    }
  }
}
