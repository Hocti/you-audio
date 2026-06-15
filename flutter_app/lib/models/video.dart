class Video {
  final String id;
  final String title;
  final String channel;
  final int duration; // seconds
  final String? thumbnailUrl;

  Video({
    required this.id,
    required this.title,
    required this.channel,
    required this.duration,
    this.thumbnailUrl,
  });

  factory Video.fromJson(Map<String, dynamic> json) {
    return Video(
      id: json['id'] ?? json['video_id'] ?? '',
      title: json['title'] ?? 'Unknown',
      channel: json['channel'] ?? json['uploader'] ?? 'Unknown',
      duration: json['duration'] ?? 0,
      thumbnailUrl: json['thumbnail'],
    );
  }

  String get durationFormatted {
    final h = duration ~/ 3600;
    final m = (duration % 3600) ~/ 60;
    final s = duration % 60;
    if (h > 0) {
      return '${h}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '${m}:${s.toString().padLeft(2, '0')}';
  }
}
