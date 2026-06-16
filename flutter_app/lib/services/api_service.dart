import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/video.dart';
import '../models/channel_video.dart';

class ApiService {
  final String serverUrl;
  final String accessToken;

  ApiService(this.serverUrl, {this.accessToken = ''});

  String get _base => serverUrl.endsWith('/')
      ? serverUrl.substring(0, serverUrl.length - 1)
      : serverUrl;

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        if (accessToken.isNotEmpty) 'X-Access-Token': accessToken,
      };

  /// Auth-only headers for non-JSON requests (e.g. image loading).
  Map<String, String> get authHeaders =>
      accessToken.isEmpty ? const {} : {'X-Access-Token': accessToken};

  Future<Map<String, dynamic>> startDownload(String youtubeUrl) async {
    final resp = await http.post(
      Uri.parse('$_base/api/download'),
      headers: _headers,
      body: jsonEncode({'url': youtubeUrl}),
    );
    if (resp.statusCode == 200) return jsonDecode(resp.body) as Map<String, dynamic>;
    throw Exception('Download failed: ${resp.statusCode}');
  }

  Future<Map<String, dynamic>> getProgress(String taskId) async {
    final resp = await http.get(
      Uri.parse('$_base/api/progress/$taskId'),
      headers: _headers,
    );
    if (resp.statusCode == 200) return jsonDecode(resp.body) as Map<String, dynamic>;
    throw Exception('Progress failed: ${resp.statusCode}');
  }

  Future<List<Video>> getVideos() async {
    final resp = await http.get(
      Uri.parse('$_base/api/videos'),
      headers: _headers,
    );
    if (resp.statusCode == 200) {
      final body = jsonDecode(resp.body) as Map<String, dynamic>;
      final list = (body['videos'] as List<dynamic>?) ?? const <dynamic>[];
      return list.map((j) => Video.fromJson(j as Map<String, dynamic>)).toList();
    }
    throw Exception('getVideos failed: ${resp.statusCode}');
  }

  /// Map of `youtube_id` → backend status (`done`, `downloading`, …) for every
  /// video the backend knows about. Used to flag channel videos as already
  /// downloaded or in progress.
  Future<Map<String, String>> getVideoStatuses() async {
    final resp = await http.get(
      Uri.parse('$_base/api/videos'),
      headers: _headers,
    );
    if (resp.statusCode == 200) {
      final body = jsonDecode(resp.body) as Map<String, dynamic>;
      final list = (body['videos'] as List<dynamic>?) ?? const <dynamic>[];
      final map = <String, String>{};
      for (final j in list) {
        final m = j as Map<String, dynamic>;
        final id = m['youtube_id'] as String?;
        final status = m['status'] as String?;
        if (id != null && status != null) map[id] = status;
      }
      return map;
    }
    throw Exception('getVideoStatuses failed: ${resp.statusCode}');
  }

  /// Resolves a channel id from a bare id, a channel URL, or an `@handle`.
  /// Returns `(id, name)`; throws on failure (404 = not found).
  Future<({String id, String? name})> resolveChannel(String input) async {
    final uri = Uri.parse('$_base/api/channel/resolve')
        .replace(queryParameters: {'q': input});
    final resp = await http.get(uri, headers: _headers);
    if (resp.statusCode == 200) {
      final j = jsonDecode(resp.body) as Map<String, dynamic>;
      return (id: j['channel_id'] as String, name: j['channel_name'] as String?);
    }
    throw Exception('resolve failed: ${resp.statusCode}');
  }

  Future<List<ChannelVideo>> getChannelVideos(String channelId) async {
    final resp = await http.get(
      Uri.parse('$_base/api/channel/$channelId/videos'),
      headers: _headers,
    );
    if (resp.statusCode == 200) {
      final body = jsonDecode(resp.body) as Map<String, dynamic>;
      final list = (body['videos'] as List<dynamic>?) ?? const <dynamic>[];
      return list
          .map((j) => ChannelVideo.fromJson(j as Map<String, dynamic>))
          .toList();
    }
    throw Exception('getChannelVideos failed: ${resp.statusCode}');
  }

  Future<void> deleteVideo(String youtubeId) async {
    final resp = await http.delete(
      Uri.parse('$_base/api/videos/$youtubeId'),
      headers: _headers,
    );
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw Exception('Delete failed: ${resp.statusCode}');
    }
  }

  Future<String> getSubtitleText(String youtubeId) async {
    final resp = await http.get(
      Uri.parse('$_base/api/subtitles/$youtubeId'),
      headers: _headers,
    );
    if (resp.statusCode == 200) return resp.body;
    throw Exception('No subtitles: ${resp.statusCode}');
  }

  String audioUrl(String youtubeId) => '$_base/api/audio/$youtubeId';
  String thumbnailUrl(String youtubeId) => '$_base/api/thumbnail/$youtubeId';

  /// Full metadata for a single downloaded video, or null if not found.
  Future<Video?> getVideoMeta(String youtubeId) async {
    final videos = await getVideos();
    for (final v in videos) {
      if (v.youtubeId == youtubeId) return v;
    }
    return null;
  }

  Future<List<int>> downloadAudioBytes(String youtubeId) =>
      _getBytes('$_base/api/audio/$youtubeId');

  Future<List<int>> downloadThumbnailBytes(String youtubeId) =>
      _getBytes('$_base/api/thumbnail/$youtubeId');

  Future<List<int>> _getBytes(String url) async {
    final resp = await http.get(Uri.parse(url), headers: authHeaders);
    if (resp.statusCode == 200) return resp.bodyBytes;
    throw Exception('Download failed: ${resp.statusCode}');
  }
}
