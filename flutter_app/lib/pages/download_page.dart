import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/api_service.dart';
import '../services/audio_service.dart';
import '../widgets/player_bar.dart';
import 'audio_list_page.dart';
import 'server_setup_page.dart';

class DownloadPage extends StatefulWidget {
  final String serverUrl;
  final String accessToken;

  const DownloadPage({super.key, required this.serverUrl, this.accessToken = ''});

  @override
  State<DownloadPage> createState() => _DownloadPageState();
}

class _DownloadPageState extends State<DownloadPage> {
  final _urlController = TextEditingController();
  late final ApiService _apiService;
  String _status = '';
  bool _downloading = false;
  double _progress = 0;
  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    _apiService = ApiService(widget.serverUrl, accessToken: widget.accessToken);
    _initAudio();
  }

  Future<void> _initAudio() async {
    final handler = await AudioManager.init();
    handler.setServerUrl(widget.serverUrl);
  }

  Future<void> _startDownload() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) return;

    setState(() {
      _downloading = true;
      _status = 'Checking cache...';
      _progress = 0;
    });

    try {
      final result = await _apiService.startDownload(url);

      if (result['cached'] == true) {
        setState(() {
          _status = 'Already downloaded!';
          _downloading = false;
          _progress = 1.0;
        });
        return;
      }

      final taskId = result['task_id']?.toString();
      if (taskId == null) {
        setState(() {
          _status = 'Error: No task ID received';
          _downloading = false;
        });
        return;
      }

      _pollProgress(taskId);
    } catch (e) {
      setState(() {
        _status = 'Error: $e';
        _downloading = false;
      });
    }
  }

  void _pollProgress(String taskId) {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 1), (timer) async {
      try {
        final progress = await _apiService.getProgress(taskId);
        final status = progress['status']?.toString() ?? '';
        final pct = (progress['progress'] as num?)?.toDouble() ?? 0;

        if (!mounted) {
          timer.cancel();
          return;
        }

        setState(() {
          _progress = pct / 100;
          switch (status) {
            case 'downloading':
              _status = 'Downloading... ${pct.toStringAsFixed(0)}%';
              break;
            case 'converting':
              _status = 'Converting...';
              break;
            case 'done':
            case 'completed':
              _status = 'Done!';
              _downloading = false;
              timer.cancel();
              _progress = 1.0;
              break;
            case 'error':
              _status = 'Error: ${progress['error'] ?? 'Unknown error'}';
              _downloading = false;
              timer.cancel();
              break;
            default:
              _status = status;
          }
        });
      } catch (e) {
        // Keep polling on transient errors
      }
    });
  }

  void _goToList() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => AudioListPage(serverUrl: widget.serverUrl, accessToken: widget.accessToken),
      ),
    );
  }

  Future<void> _changeServer() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('server_url');
    if (mounted) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const ServerSetupPage()),
      );
    }
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _urlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Download'),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.list),
            onPressed: _goToList,
            tooltip: 'Audio Library',
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: _changeServer,
            tooltip: 'Change Server',
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.download_rounded,
                    size: 64,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(height: 24),
                  TextField(
                    controller: _urlController,
                    decoration: InputDecoration(
                      labelText: 'YouTube URL',
                      hintText: 'https://youtube.com/watch?v=...',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      prefixIcon: const Icon(Icons.link),
                      suffixIcon: IconButton(
                        icon: const Icon(Icons.send),
                        onPressed: _downloading ? null : _startDownload,
                      ),
                    ),
                    keyboardType: TextInputType.url,
                    onSubmitted: (_) {
                      if (!_downloading) _startDownload();
                    },
                  ),
                  const SizedBox(height: 24),
                  if (_status.isNotEmpty) ...[
                    if (_downloading)
                      LinearProgressIndicator(
                        value: _progress > 0 ? _progress : null,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        if (_downloading)
                          const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        if (_downloading) const SizedBox(width: 12),
                        if (_status == 'Done!' ||
                            _status == 'Already downloaded!')
                          Icon(
                            Icons.check_circle,
                            color: Colors.green.shade400,
                            size: 20,
                          ),
                        if (_status == 'Done!' ||
                            _status == 'Already downloaded!')
                          const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            _status,
                            style:
                                Theme.of(context).textTheme.bodyLarge?.copyWith(
                                      color: _status.startsWith('Error')
                                          ? Theme.of(context).colorScheme.error
                                          : null,
                                    ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 32),
                  OutlinedButton.icon(
                    onPressed: _goToList,
                    icon: const Icon(Icons.library_music),
                    label: const Text('Browse Audio Library'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(double.infinity, 52),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const PlayerBar(),
        ],
      ),
    );
  }
}
