import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/api_service.dart';
import '../services/download_manager.dart';
import '../services/stream_manager.dart';

class LinkTab extends StatefulWidget {
  final ApiService api;

  /// Jumps to the Play tab — used after a stream starts playing.
  final VoidCallback? onPlayTap;

  const LinkTab({super.key, required this.api, this.onPlayTap});

  @override
  State<LinkTab> createState() => _LinkTabState();
}

class _LinkTabState extends State<LinkTab> {
  String _status = '';
  String _url = '';
  bool _streaming = false;

  /// Reads the clipboard and validates it as a YouTube link. Returns null (and
  /// sets the status text) when there is nothing usable.
  Future<String?> _clipboardYoutubeUrl() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final url = data?.text?.trim() ?? '';
    if (url.isEmpty) {
      setState(() => _status = 'Clipboard is empty');
      return null;
    }
    if (!url.contains('youtu')) {
      setState(() {
        _url = url;
        _status = "That doesn't look like a YouTube URL";
      });
      return null;
    }
    return url;
  }

  Future<void> _pasteAndDownload() async {
    final url = await _clipboardYoutubeUrl();
    if (url == null) return;
    setState(() {
      _url = url;
      _status = 'Download started — track progress in the Downloaded tab.';
    });
    // Fire-and-forget: the backend converts, then the app pulls the file to the
    // device. Progress and any errors show up as rows in the Downloaded tab.
    DownloadManager.instance.start(widget.api, url);
  }

  /// Same backend work, but playback starts as soon as the audio is ready there
  /// instead of after the whole file has reached the device. The file still ends
  /// up in the library, so this is a shortcut to listening, not a different
  /// result.
  Future<void> _pasteAndStream() async {
    final url = await _clipboardYoutubeUrl();
    if (url == null) return;
    setState(() {
      _url = url;
      _streaming = true;
      _status = 'Preparing stream…';
    });

    await StreamManager.instance.start(
      widget.api,
      url,
      onPlaying: () => widget.onPlayTap?.call(),
    );

    if (!mounted) return;
    final job = StreamManager.instance.job.value;
    setState(() {
      _streaming = false;
      if (job?.stage == StreamStage.error) {
        _status = 'Stream failed: ${job?.error ?? 'unknown error'}';
      } else {
        _status = 'Streaming — it keeps caching to the device while it plays.';
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final isError = _status.startsWith('That') ||
        _status == 'Clipboard is empty' ||
        _status.startsWith('Stream failed');
    return Scaffold(
      appBar: AppBar(title: const Text('Download'), centerTitle: true),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.download_rounded, size: 64,
                color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 16),
            Text(
              'Copy a YouTube link, then tap Paste & Download',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _streaming ? null : _pasteAndDownload,
              icon: const Icon(Icons.content_paste),
              label: const Text('Paste & Download'),
              style: FilledButton.styleFrom(
                minimumSize: const Size(double.infinity, 52),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _streaming ? null : _pasteAndStream,
              icon: _streaming
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.play_circle_outline),
              label: Text(_streaming ? 'Preparing…' : 'Paste & Stream'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(double.infinity, 52),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
            const SizedBox(height: 24),
            if (_url.isNotEmpty)
              Text(
                _url,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            if (_status.isNotEmpty) ...[
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (!isError) ...[
                    Icon(Icons.check_circle, color: Colors.green.shade400, size: 20),
                    const SizedBox(width: 8),
                  ],
                  Flexible(
                    child: Text(
                      _status,
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                            color: isError
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
