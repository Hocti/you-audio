import 'video.dart';

/// A video returned by `GET /api/channel/{channel_id}/videos`.
///
/// Unlike [Video], the thumbnail is a direct YouTube CDN URL (not a backend
/// path), so it needs no access token to load.
/// One page of `GET /api/channel/{id}/videos`. A null [nextPageToken] means
/// there are no more pages.
class ChannelPage {
  final List<ChannelVideo> videos;
  final String? nextPageToken;
  const ChannelPage(this.videos, this.nextPageToken);
}

class ChannelVideo {
  final String videoId;
  final String title;
  final String? publishedAt; // ISO-8601 string from YouTube
  final String? thumbnailUrl;
  final String channelName;
  /// Length in seconds. 0 means live / upcoming / premiere. Null if the
  /// backend is old and didn't send the field.
  final int? duration;
  /// YouTube `liveBroadcastContent`: `none`, `upcoming`, or `live`.
  final String liveBroadcast;
  /// In the channel's members-only playlist (server-side UUMO check).
  final bool membersOnly;

  const ChannelVideo({
    required this.videoId,
    required this.title,
    required this.channelName,
    this.publishedAt,
    this.thumbnailUrl,
    this.duration,
    this.liveBroadcast = 'none',
    this.membersOnly = false,
  });

  factory ChannelVideo.fromJson(Map<String, dynamic> json) {
    return ChannelVideo(
      videoId: json['video_id'] as String? ?? '',
      title: json['title'] as String? ?? 'Unknown',
      channelName: json['channel_name'] as String? ?? 'Unknown',
      publishedAt: json['published_at'] as String?,
      thumbnailUrl: json['thumbnail_url'] as String?,
      duration: _readDuration(json['duration']),
      liveBroadcast: json['live_broadcast'] as String? ?? 'none',
      membersOnly: json['members_only'] as bool? ?? false,
    );
  }

  static int? _readDuration(dynamic raw) {
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw);
    return null;
  }

  /// Live now, a scheduled premiere / unreleased upload, or members-only.
  /// These are collapsed out of the main channel list.
  bool get isCollapsed {
    if (liveBroadcast == 'live' || liveBroadcast == 'upcoming') return true;
    if (duration == 0) return true; // live / premiere with P0D
    if (_publishedInTheFuture) return true;
    if (membersOnly || looksMembersOnly) return true;
    return false;
  }

  bool get _publishedInTheFuture {
    if (publishedAt == null) return false;
    final dt = DateTime.tryParse(publishedAt!);
    if (dt == null) return false;
    return dt.isAfter(DateTime.now());
  }

  /// Title heuristic, a fallback for the server's [membersOnly] flag.
  bool get looksMembersOnly {
    final t = title.toLowerCase();
    return t.contains('會員獨家') ||
        t.contains('會員限定') ||
        t.contains('會員專屬') ||
        t.contains('[會員]') ||
        t.contains('members only') ||
        t.contains('members-only') ||
        t.contains('member-only');
  }

  String? get durationLabel {
    if (liveBroadcast == 'live') return 'LIVE';
    if (liveBroadcast == 'upcoming' || duration == 0) return 'SOON';
    if (duration != null && duration! > 0) {
      return formatDurationSeconds(duration!);
    }
    return null;
  }
}
