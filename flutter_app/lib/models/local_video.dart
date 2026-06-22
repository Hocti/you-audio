import 'video.dart';

/// A track that has been downloaded to the device and is in the local library.
///
/// Mirrors [Video]'s playable fields plus a download timestamp. Stored as an
/// entry in `library.json`; actual file paths are resolved by `LocalLibrary`.
class LocalVideo {
  final String youtubeId;
  final String title;
  final String channel;
  final String? channelId; // UC… id, when known (for "open channel")
  final int duration; // seconds
  final bool hasSubtitle;
  final DateTime downloadedAt;

  const LocalVideo({
    required this.youtubeId,
    required this.title,
    required this.channel,
    required this.duration,
    required this.hasSubtitle,
    required this.downloadedAt,
    this.channelId,
  });

  Map<String, dynamic> toJson() => {
        'youtube_id': youtubeId,
        'title': title,
        'channel': channel,
        'channel_id': channelId,
        'duration': duration,
        'has_subtitle': hasSubtitle,
        'downloaded_at': downloadedAt.toIso8601String(),
      };

  factory LocalVideo.fromJson(Map<String, dynamic> j) => LocalVideo(
        youtubeId: j['youtube_id'] as String? ?? '',
        title: j['title'] as String? ?? 'Unknown',
        channel: j['channel'] as String? ?? 'Unknown',
        channelId: j['channel_id'] as String?,
        duration: (j['duration'] as num?)?.toInt() ?? 0,
        hasSubtitle: j['has_subtitle'] as bool? ?? false,
        downloadedAt:
            DateTime.tryParse(j['downloaded_at'] as String? ?? '') ??
                DateTime.fromMillisecondsSinceEpoch(0),
      );

  /// The playback model used by the audio handler.
  Video toVideo() => Video(
        youtubeId: youtubeId,
        title: title,
        channel: channel,
        channelId: channelId,
        duration: duration,
        hasSubtitle: hasSubtitle,
      );
}
