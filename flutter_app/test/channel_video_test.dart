import 'package:flutter_test/flutter_test.dart';
import 'package:you_audio/models/channel_video.dart';
import 'package:you_audio/models/video.dart';
import 'package:you_audio/services/download_manager.dart';

ChannelVideo _v({
  String id = 'abcdefghijk',
  String title = 'A normal video',
  int? duration = 125,
  String live = 'none',
  String? publishedAt,
}) {
  return ChannelVideo(
    videoId: id,
    title: title,
    channelName: 'Test',
    duration: duration,
    liveBroadcast: live,
    publishedAt: publishedAt,
  );
}

void main() {
  test('normal videos stay in the main list', () {
    expect(_v().isCollapsed, isFalse);
    expect(_v().durationLabel, '2:05');
  });

  test('live and upcoming videos are collapsed', () {
    expect(_v(live: 'live', duration: 0).isCollapsed, isTrue);
    expect(_v(live: 'live', duration: 0).durationLabel, 'LIVE');
    expect(_v(live: 'upcoming', duration: 0).isCollapsed, isTrue);
    expect(_v(live: 'upcoming', duration: 0).durationLabel, 'SOON');
  });

  test('zero duration is treated as unreleased / live', () {
    expect(_v(duration: 0).isCollapsed, isTrue);
    expect(_v(duration: 0).durationLabel, 'SOON');
  });

  test('future publishedAt is collapsed as unreleased', () {
    final future = DateTime.now().add(const Duration(days: 2)).toIso8601String();
    expect(_v(publishedAt: future).isCollapsed, isTrue);
  });

  test('members-only titles are collapsed', () {
    expect(_v(title: '會員獨家：本週直播').isCollapsed, isTrue);
    expect(_v(title: 'Members only Q&A').isCollapsed, isTrue);
    expect(_v(title: '[會員] 幕後花絮').isCollapsed, isTrue);
  });

  test('old backend with no duration still shows a playable row', () {
    expect(_v(duration: null).isCollapsed, isFalse);
    expect(_v(duration: null).durationLabel, isNull);
  });

  test('formatDurationSeconds pads minutes and hours', () {
    expect(formatDurationSeconds(5), '0:05');
    expect(formatDurationSeconds(125), '2:05');
    expect(formatDurationSeconds(3661), '1:01:01');
  });

  test('extractYoutubeVideoId handles common URL shapes', () {
    expect(extractYoutubeVideoId('https://youtu.be/dQw4w9WgXcQ'),
        'dQw4w9WgXcQ');
    expect(
        extractYoutubeVideoId(
            'https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=12s'),
        'dQw4w9WgXcQ');
    expect(
        extractYoutubeVideoId('https://www.youtube.com/shorts/dQw4w9WgXcQ'),
        'dQw4w9WgXcQ');
    expect(extractYoutubeVideoId('not a url'), isNull);
  });
}
