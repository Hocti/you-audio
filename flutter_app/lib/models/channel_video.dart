/// A video returned by `GET /api/channel/{channel_id}/videos`.
///
/// Unlike [Video], the thumbnail is a direct YouTube CDN URL (not a backend
/// path), so it needs no access token to load.
class ChannelVideo {
  final String videoId;
  final String title;
  final String? publishedAt; // ISO-8601 string from YouTube
  final String? thumbnailUrl;
  final String channelName;

  const ChannelVideo({
    required this.videoId,
    required this.title,
    required this.channelName,
    this.publishedAt,
    this.thumbnailUrl,
  });

  factory ChannelVideo.fromJson(Map<String, dynamic> json) {
    return ChannelVideo(
      videoId: json['video_id'] as String? ?? '',
      title: json['title'] as String? ?? 'Unknown',
      channelName: json['channel_name'] as String? ?? 'Unknown',
      publishedAt: json['published_at'] as String?,
      thumbnailUrl: json['thumbnail_url'] as String?,
    );
  }
}
