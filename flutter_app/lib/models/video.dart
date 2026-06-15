class Video {
  final String youtubeId;   // used in all URL paths
  final String title;
  final String channel;
  final int duration;       // seconds
  final bool hasSubtitle;

  const Video({
    required this.youtubeId,
    required this.title,
    required this.channel,
    required this.duration,
    this.hasSubtitle = false,
  });

  factory Video.fromJson(Map<String, dynamic> json) {
    return Video(
      youtubeId: json['youtube_id'] as String? ?? '',
      title: json['title'] as String? ?? 'Unknown',
      channel: json['channel_name'] as String? ?? 'Unknown',
      duration: json['duration'] as int? ?? 0,
      hasSubtitle: json['has_subtitle'] as bool? ?? false,
    );
  }

  String get durationFormatted {
    final h = duration ~/ 3600;
    final m = (duration % 3600) ~/ 60;
    final s = duration % 60;
    if (h > 0) {
      return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '$m:${s.toString().padLeft(2, '0')}';
  }
}
