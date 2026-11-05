import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

/// Shared actions for a video, used by the Downloaded and Channel-detail
/// context menus: copy link, open in the YouTube app, and a metadata detail
/// sheet.

String youtubeWatchUrl(String youtubeId) =>
    'https://www.youtube.com/watch?v=$youtubeId';

String youtubeChannelUrl(String channelId) =>
    'https://www.youtube.com/channel/$channelId';

Future<void> copyYoutubeLink(BuildContext context, String youtubeId) async {
  await Clipboard.setData(ClipboardData(text: youtubeWatchUrl(youtubeId)));
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Link copied')),
    );
  }
}

Future<void> copyVideoId(BuildContext context, String youtubeId) async {
  await Clipboard.setData(ClipboardData(text: youtubeId));
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Video ID copied: $youtubeId')),
    );
  }
}

/// "Copy video ID" + "Copy channel ID" rows for a video's long-press menu.
/// [sheetContext] is the bottom sheet's context (popped before copying);
/// [context] is the page's, used for the SnackBar. The channel row is left
/// out when the id isn't known.
List<Widget> copyIdMenuTiles(
  BuildContext context,
  BuildContext sheetContext, {
  required String youtubeId,
  String? channelId,
}) {
  return [
    ListTile(
      leading: const Icon(Icons.tag),
      title: const Text('Copy video ID'),
      subtitle: Text(youtubeId),
      onTap: () {
        Navigator.pop(sheetContext);
        copyVideoId(context, youtubeId);
      },
    ),
    if (channelId != null && channelId.isNotEmpty)
      ListTile(
        leading: const Icon(Icons.account_box_outlined),
        title: const Text('Copy channel ID'),
        subtitle: Text(channelId, maxLines: 1, overflow: TextOverflow.ellipsis),
        onTap: () {
          Navigator.pop(sheetContext);
          copyChannelId(context, channelId);
        },
      ),
  ];
}

/// Copies the bare `UC…` id — that is what the app's own channel input takes,
/// so it is more useful here than the full URL.
Future<void> copyChannelId(BuildContext context, String channelId) async {
  await Clipboard.setData(ClipboardData(text: channelId));
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Channel ID copied: $channelId')),
    );
  }
}

Future<void> openChannelInYouTube(
    BuildContext context, String channelId) async {
  await _launchExternal(context, youtubeChannelUrl(channelId), 'YouTube');
}

Future<void> openInYouTube(BuildContext context, String youtubeId) async {
  await _launchExternal(context, youtubeWatchUrl(youtubeId), 'YouTube');
}

Future<void> _launchExternal(
    BuildContext context, String url, String what) async {
  bool ok = false;
  try {
    ok = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  } catch (_) {
    ok = false;
  }
  if (!ok && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text("Couldn't open $what")),
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
