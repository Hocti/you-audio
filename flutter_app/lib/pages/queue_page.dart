import 'package:flutter/material.dart';
import '../models/video.dart';
import '../services/audio_service.dart';
import '../services/local_library.dart';
import '../services/playback_progress.dart';
import '../widgets/video_actions.dart';
import '../widgets/video_thumbnail.dart';
import '../widgets/scrolling_text.dart';

/// "Up Next" queue: the tracks the user added via "Add to Queue". They can be
/// reordered (drag handle) or removed. The queue plays before the smart
/// auto-advance (see [AudioPlayerHandler.playNextUnplayed]).
class QueuePage extends StatelessWidget {
  const QueuePage({super.key});

  static Future<void> open(BuildContext context) {
    return Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const QueuePage()),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!AudioManager.isInitialized) {
      return Scaffold(
        appBar: AppBar(title: const Text('Up Next')),
        body: const Center(child: Text('Player not ready')),
      );
    }
    final handler = AudioManager.handler;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Up Next'),
        actions: [
          ValueListenableBuilder<List<Video>>(
            valueListenable: handler.upNext,
            builder: (_, q, __) => q.isEmpty
                ? const SizedBox.shrink()
                : IconButton(
                    icon: const Icon(Icons.clear_all),
                    tooltip: 'Clear queue',
                    onPressed: handler.clearQueue,
                  ),
          ),
        ],
      ),
      body: ValueListenableBuilder<List<Video>>(
        valueListenable: handler.upNext,
        builder: (context, q, _) {
          if (q.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.queue_music,
                      size: 64,
                      color: Theme.of(context).colorScheme.onSurfaceVariant),
                  const SizedBox(height: 16),
                  Text('Queue is empty',
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  Text(
                    'Long-press a track and choose "Add to Queue"',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                ],
              ),
            );
          }
          return ReorderableListView.builder(
            itemCount: q.length,
            onReorder: handler.reorderQueue,
            // Reorder via the handle only; long-press opens the copy menu.
            buildDefaultDragHandles: false,
            padding: const EdgeInsets.only(bottom: 8),
            itemBuilder: (context, index) {
              final v = q[index];
              return ListTile(
                // Per-instance key so identical videos queued twice stay distinct
                // and reordering animates correctly.
                key: ObjectKey(v),
                contentPadding: const EdgeInsets.only(left: 16),
                minLeadingWidth: VideoThumbnail.width,
                leading: VideoThumbnail(
                  filePath: LocalLibrary.thumbPath(v.youtubeId),
                  badge: v.duration > 0 ? v.durationFormatted : null,
                  progress: PlaybackProgress.fraction(v.youtubeId, v.duration),
                ),
                title: ScrollingText(v.title),
                subtitle: Text('${index + 1}  ·  ${v.channel}',
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                onLongPress: () => showModalBottomSheet(
                  context: context,
                  builder: (ctx) => SafeArea(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: copyIdMenuTiles(context, ctx,
                          youtubeId: v.youtubeId, channelId: v.channelId),
                    ),
                  ),
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.delete_outline),
                      tooltip: 'Remove',
                      onPressed: () => handler.removeFromQueue(index),
                    ),
                    ReorderableDragStartListener(
                      index: index,
                      child: const Padding(
                        padding: EdgeInsets.only(left: 4, right: 8),
                        child: Icon(Icons.drag_handle),
                      ),
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}
