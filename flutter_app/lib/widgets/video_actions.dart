import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

/// Shared actions for a video, used by the Downloaded and Channel-detail
/// context menus: copy link, open in the YouTube app, and a metadata detail
/// sheet.

String youtubeWatchUrl(String youtubeId) =>
    'https://www.youtube.com/watch?v=$youtubeId';

Future<void> copyYoutubeLink(BuildContext context, String youtubeId) async {
  await Clipboard.setData(ClipboardData(text: youtubeWatchUrl(youtubeId)));
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Link copied')),
    );
  }
}

Future<void> openInYouTube(BuildContext context, String youtubeId) async {
  final uri = Uri.parse(youtubeWatchUrl(youtubeId));
  bool ok = false;
  try {
    ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {
    ok = false;
  }
  if (!ok && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("Couldn't open YouTube")),
    );
  }
}

/// A scrollable modal showing a video's metadata. The only way out is the
/// Close button (or a drag-dismiss).
void showVideoDetailSheet(
  BuildContext context, {
  required String title,
  required List<(String, String)> rows,
}) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) {
      return DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.5,
        minChildSize: 0.3,
        maxChildSize: 0.9,
        builder: (ctx, scrollController) {
          return Column(
            children: [
              Expanded(
                child: ListView(
                  controller: scrollController,
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                  children: [
                    Text(title, style: Theme.of(ctx).textTheme.titleMedium),
                    const Divider(height: 24),
                    for (final (label, value) in rows)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              label,
                              style: Theme.of(ctx).textTheme.labelSmall?.copyWith(
                                    color: Theme.of(ctx)
                                        .colorScheme
                                        .onSurfaceVariant,
                                  ),
                            ),
                            const SizedBox(height: 2),
                            SelectableText(value),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: () => Navigator.pop(ctx),
                    icon: const Icon(Icons.close),
                    label: const Text('Close'),
                  ),
                ),
              ),
            ],
          );
        },
      );
    },
  );
}
