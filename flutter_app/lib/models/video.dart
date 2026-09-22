class Video {
  final String youtubeId;   // used in all URL paths
  final String title;
  final String channel;
  final String? channelId;  // UC… id, when known (for "open channel")
  final int duration;       // seconds
  final bool hasSubtitle;

  const Video({
    required this.youtubeId,
    required this.title,
    required this.channel,
    required this.duration,
    this.channelId,
    this.hasSubtitle = false,
  });

  factory Video.fromJson(Map<String, dynamic> json) {
    return Video(
      youtubeId: json['youtube_id'] as String? ?? '',
      title: json['title'] as String? ?? 'Unknown',
      channel: json['channel_name'] as String? ?? 'Unknown',
      channelId: json['channel_id'] as String?,
      duration: json['duration'] as int? ?? 0,
      hasSubtitle: json['has_subtitle'] as bool? ?? false,
    );
  }

  String get durationFormatted => formatDurationSeconds(duration);
}

/// Human-readable duration like `3:45` or `1:02:03`.
String formatDurationSeconds(int seconds) {
  if (seconds < 0) seconds = 0;
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  final s = seconds % 60;
  if (h > 0) {
    return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }
  return '$m:${s.toString().padLeft(2, '0')}';
}
