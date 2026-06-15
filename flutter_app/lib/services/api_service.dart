import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/video.dart';

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
}
