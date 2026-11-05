import 'package:shared_preferences/shared_preferences.dart';

/// Synchronous read access to the per-video listen progress that
/// `AudioPlayerHandler` writes to SharedPreferences (`progress_<id>`,
/// `max_progress_<id>`, `completed_<id>`), so list rows can draw a progress
/// bar while building.
///
/// SharedPreferences keeps an in-memory copy that its setters update, so once
/// [init] has run these reads always reflect the latest writes.
class PlaybackProgress {
  PlaybackProgress._();

  static SharedPreferences? _prefs;

  static Future<void> init() async {
    _prefs ??= await SharedPreferences.getInstance();
  }

  static bool isCompleted(String youtubeId) =>
      _prefs?.getBool('completed_$youtubeId') ?? false;

  /// Furthest point reached in seconds (not the resume point); the full
  /// [duration] once completed. 0 = never played.
  static int furthestSeconds(String youtubeId, int duration) {
    final p = _prefs;
    if (p == null) return 0;
    final current = p.getInt('progress_$youtubeId') ?? 0;
    final maxP = p.getInt('max_progress_$youtubeId') ?? 0;
    var shown = maxP > current ? maxP : current;
    if (isCompleted(youtubeId) && duration > shown) shown = duration;
    return shown;
  }

  /// 0..1 fraction played, or null when never played / duration unknown.
  static double? fraction(String youtubeId, int? duration) {
    if (isCompleted(youtubeId)) return 1.0;
    if (duration == null || duration <= 0) return null;
    final s = furthestSeconds(youtubeId, duration);
    if (s <= 0) return null;
    return (s / duration).clamp(0.0, 1.0);
  }
}
