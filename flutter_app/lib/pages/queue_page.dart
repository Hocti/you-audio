import 'package:flutter/material.dart';
import '../models/video.dart';
import '../services/audio_service.dart';
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
            padding: const EdgeInsets.only(bottom: 8),
            itemBuilder: (context, index) {
              final v = q[index];
              return ListTile(
                // Per-instance key so identical videos queued twice stay distinct
                // and reordering animates correctly.
                key: ObjectKey(v),
                leading: CircleAvatar(
                  radius: 14,
                  child: Text('${index + 1}',
                      style: const TextStyle(fontSize: 12)),
                ),
                title: ScrollingText(v.title),
                subtitle: Text(v.channel,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
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
