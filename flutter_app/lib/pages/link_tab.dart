import 'dart:async';
import 'package:flutter/material.dart';
import '../services/api_service.dart';

class LinkTab extends StatefulWidget {
  final ApiService api;
  const LinkTab({super.key, required this.api});

  @override
  State<LinkTab> createState() => _LinkTabState();
}

class _LinkTabState extends State<LinkTab> {
  final _urlController = TextEditingController();
  String _status = '';
  bool _downloading = false;
  double _progress = 0;
  Timer? _pollTimer;

  Future<void> _startDownload() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) return;

    setState(() {
      _downloading = true;
      _status = 'Checking cache...';
      _progress = 0;
    });

    try {
      final result = await widget.api.startDownload(url);

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
        final progress = await widget.api.getProgress(taskId);
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
      } catch (_) {
        // Keep polling on transient errors
      }
    });
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
      appBar: AppBar(title: const Text('Download'), centerTitle: true),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.download_rounded, size: 64,
                color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 24),
            TextField(
              controller: _urlController,
              decoration: InputDecoration(
                labelText: 'YouTube URL',
                hintText: 'https://youtube.com/watch?v=...',
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12)),
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
                      width: 16, height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  if (_downloading) const SizedBox(width: 12),
                  if (_status == 'Done!' || _status == 'Already downloaded!')
                    Icon(Icons.check_circle,
                        color: Colors.green.shade400, size: 20),
                  if (_status == 'Done!' || _status == 'Already downloaded!')
                    const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      _status,
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
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
          ],
        ),
      ),
    );
  }
}
