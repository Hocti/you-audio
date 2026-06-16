import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/api_service.dart';
import '../services/download_manager.dart';

class LinkTab extends StatefulWidget {
  final ApiService api;
  const LinkTab({super.key, required this.api});

  @override
  State<LinkTab> createState() => _LinkTabState();
}

class _LinkTabState extends State<LinkTab> {
  String _status = '';
  String _url = '';

  Future<void> _pasteAndDownload() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final url = data?.text?.trim() ?? '';
    if (url.isEmpty) {
      setState(() => _status = 'Clipboard is empty');
      return;
    }
    if (!url.contains('youtu')) {
      setState(() {
        _url = url;
        _status = "That doesn't look like a YouTube URL";
      });
      return;
    }
    setState(() {
      _url = url;
      _status = 'Download started — track progress in the Downloaded tab.';
    });
    // Fire-and-forget: the backend converts, then the app pulls the file to the
    // device. Progress and any errors show up as rows in the Downloaded tab.
    DownloadManager.instance.start(widget.api, url);
  }

  @override
  Widget build(BuildContext context) {
    final isError = _status.startsWith('That') || _status == 'Clipboard is empty';
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
              onPressed: _pasteAndDownload,
              icon: const Icon(Icons.content_paste),
              label: const Text('Paste & Download'),
              style: FilledButton.styleFrom(
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
