import 'package:flutter/services.dart';

/// What a shared YouTube link points at.
enum SharedLinkKind { video, channel, unknown }

/// Extracts the first http(s) URL from shared text. YouTube's share sometimes
/// prepends a title (e.g. "Some title https://youtu.be/abc"), so we can't assume
/// the whole string is the URL.
String? firstUrl(String text) {
  final m = RegExp(r'https?://[^\s]+').firstMatch(text);
  return m?.group(0);
}

/// Classifies a YouTube URL as a video, a channel, or neither. Video is checked
/// first because some video URLs also contain channel-ish path segments.
SharedLinkKind classifyUrl(String url) {
  final u = url.toLowerCase();
  if (u.contains('watch?v=') ||
      u.contains('youtu.be/') ||
      u.contains('/shorts/') ||
      u.contains('/live/') ||
      RegExp(r'[?&]v=').hasMatch(u)) {
    return SharedLinkKind.video;
  }
  if (u.contains('/channel/') ||
      u.contains('/@') ||
      u.contains('/c/') ||
      u.contains('/user/')) {
    return SharedLinkKind.channel;
  }
  return SharedLinkKind.unknown;
}

typedef ShareCallback = void Function(String sharedText);

/// Bridges the native share intent (ACTION_SEND text/plain) into Dart.
///
/// The Android side (`MainActivity.kt`) stashes the text shared at cold start and
/// hands it over on [getInitial]; for shares that arrive while the app is already
/// running it pushes `onShare`. [moveToBackground] drops the activity to the
/// background so a shared video can download without the user leaving their app.
class ShareHandler {
  ShareHandler._();
  static final ShareHandler instance = ShareHandler._();
  static const _channel = MethodChannel('app/share');

  /// Invoked when a share arrives while the app is already running.
  ShareCallback? onShare;

  void init() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onShare') {
        final text = call.arguments as String?;
        if (text != null && text.isNotEmpty) onShare?.call(text);
      }
      return null;
    });
  }

  /// The text shared at cold start, if any. Consumed (returns null) after the
  /// first call so a rebuild doesn't re-process it.
  Future<String?> getInitial() async {
    try {
      return await _channel.invokeMethod<String>('getInitialShare');
    } catch (_) {
      return null;
    }
  }

  Future<void> moveToBackground() async {
    try {
      await _channel.invokeMethod('moveToBackground');
    } catch (_) {}
  }
}
