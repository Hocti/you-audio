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

  /// The server sent videos without `duration` / `members_only`: it predates
  /// those fields, so lengths can't be shown and members-only videos can only
  /// be caught by the title heuristic. Fixed by redeploying the backend.
  final bool serverOutdated;
  const ChannelPage(this.videos, this.nextPageToken,
      {this.serverOutdated = false});
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

  /// Lower-cased title fragments that mark a members-only upload (zh / ja / en).
  static const _membersTitleMarkers = [
    '會員獨家', '會員限定', '會員專屬', '會員專用', '[會員]', '【會員】', '會限',
    '会员限定', '会员专属',
    'メン限', 'メンげん', 'メンゲン', 'メンバー限定', 'メンバーシップ限定',
    'メンバー様限定', 'メンシ限定',
    'members only', 'members-only', 'member-only', 'member only',
    'membership only',
  ];

  /// Title heuristic, a fallback for the server's [membersOnly] flag.
  bool get looksMembersOnly {
    final t = title.toLowerCase();
    return _membersTitleMarkers.any(t.contains);
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
