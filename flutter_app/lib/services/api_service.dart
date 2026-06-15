import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/video.dart';

class ApiService {
  final String serverUrl;

  ApiService(this.serverUrl);

  String get _baseUrl => serverUrl.endsWith('/') ? serverUrl.substring(0, serverUrl.length - 1) : serverUrl;

  Future<Map<String, dynamic>> startDownload(String youtubeUrl) async {
    final response = await http.post(
      Uri.parse('$_baseUrl/api/download'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'url': youtubeUrl}),
    );
    if (response.statusCode == 200) {
      return jsonDecode(response.body);
    }
    throw Exception('Download request failed: ${response.statusCode}');
  }

  Future<Map<String, dynamic>> getProgress(String taskId) async {
    final response = await http.get(
      Uri.parse('$_baseUrl/api/progress/$taskId'),
    );
    if (response.statusCode == 200) {
      return jsonDecode(response.body);
    }
    throw Exception('Progress request failed: ${response.statusCode}');
  }

  Future<List<Video>> getVideos() async {
    final response = await http.get(
      Uri.parse('$_baseUrl/api/videos'),
    );
    if (response.statusCode == 200) {
      final List<dynamic> data = jsonDecode(response.body);
      return data.map((json) => Video.fromJson(json)).toList();
    }
    throw Exception('Failed to fetch videos: ${response.statusCode}');
  }

  String getAudioUrl(String videoId) {
    return '$_baseUrl/api/audio/$videoId';
  }

  String getThumbnailUrl(String videoId) {
    return '$_baseUrl/api/thumbnail/$videoId';
  }
}
