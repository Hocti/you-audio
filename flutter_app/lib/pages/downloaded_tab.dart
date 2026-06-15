import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/video.dart';
import '../services/api_service.dart';
import '../services/audio_service.dart';

enum SortMode { downloadTime, channel, listenStatus }
enum FilterMode { all, unlistened, listened }

class DownloadedTab extends StatefulWidget {
  final ApiService api;
  final VoidCallback onPlayTap;

  const DownloadedTab({super.key, required this.api, required this.onPlayTap});

  @override
  State<DownloadedTab> createState() => _DownloadedTabState();
}

class _DownloadedTabState extends State<DownloadedTab> {
  List<Video> _videos = [];
  Map<String, int> _progressMap = {};
  // ignore: unused_field
  Map<String, bool> _openedMap = {};
  Map<String, bool> _completedMap = {};
  bool _loading = true;
  String? _error;
  SortMode _sortMode = SortMode.downloadTime;
  FilterMode _filterMode = FilterMode.all;

  @override
  void initState() {
    super.initState();
    _loadVideos();
  }

  Future<void> _loadVideos() async {
    setState(() { _loading = true; _error = null; });
    try {
      final videos = await widget.api.getVideos();
      final prefs = await SharedPreferences.getInstance();
      final progressMap = <String, int>{};
      final openedMap = <String, bool>{};
      final completedMap = <String, bool>{};
      for (final v in videos) {
        final pos = prefs.getInt('progress_${v.youtubeId}');
        if (pos != null) progressMap[v.youtubeId] = pos;
        openedMap[v.youtubeId] = prefs.getBool('opened_${v.youtubeId}') ?? false;
        completedMap[v.youtubeId] = prefs.getBool('completed_${v.youtubeId}') ?? false;
      }
      if (mounted) {
        setState(() {
          _videos = videos;
          _progressMap = progressMap;
          _openedMap = openedMap;
          _completedMap = completedMap;
          _loading = false;
        });
        if (AudioManager.isInitialized) {
          AudioManager.handler.setPlaylist(videos);
        }
      }
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _loading = false; });
    }
  }

  Future<void> _playVideo(Video video) async {
    final handler = AudioManager.handler;
    handler.setPlaylist(_videos);
    await handler.playVideo(video);
    widget.onPlayTap();
    if (mounted) setState(() {});
  }

  List<Video> get _displayVideos {
    var list = _videos.toList();

    switch (_filterMode) {
      case FilterMode.unlistened:
        list = list.where((v) => !(_completedMap[v.youtubeId] ?? false)).toList();
        break;
      case FilterMode.listened:
        list = list.where((v) => _completedMap[v.youtubeId] ?? false).toList();
        break;
      case FilterMode.all:
        break;
    }

    switch (_sortMode) {
      case SortMode.channel:
        list.sort((a, b) => a.channel.compareTo(b.channel));
        break;
      case SortMode.listenStatus:
        list.sort((a, b) {
          final ac = _completedMap[a.youtubeId] ?? false;
          final bc = _completedMap[b.youtubeId] ?? false;
          if (ac == bc) return 0;
          return ac ? 1 : -1; // unlistened first
        });
        break;
      case SortMode.downloadTime:
        break; // default order from backend
    }

    return list;
  }

  void _showContextMenu(BuildContext ctx, Video video) {
    showModalBottomSheet(
      context: ctx,
      builder: (_) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.queue_play_next),
            title: const Text('Play Next'),
            onTap: () {
              Navigator.pop(ctx);
              if (AudioManager.isInitialized) {
                AudioManager.handler.queueNext(video);
              }
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('"${video.title}" queued next')),
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline),
            title: const Text('Delete'),
            onTap: () {
              Navigator.pop(ctx);
              _deleteVideo(video);
            },
          ),
        ],
      ),
    );
  }

  Future<void> _deleteVideo(Video video) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete'),
        content: Text('Delete "${video.title}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      try {
        await widget.api.deleteVideo(video.youtubeId);
        await _loadVideos();
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Delete failed: $e')),
          );
        }
      }
    }
  }

  String _formatProgress(int seconds, int totalDuration) {
    if (seconds <= 0) return 'Not started';
    if (totalDuration > 0) {
      final pct = (seconds / totalDuration * 100).round();
      return '$pct% played';
    }
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return 'Played $m:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Downloaded'),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadVideos,
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: Column(
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Row(
              children: [
                FilterChip(
                  label: const Text('All'),
                  selected: _filterMode == FilterMode.all,
                  onSelected: (_) => setState(() => _filterMode = FilterMode.all),
                ),
                const SizedBox(width: 8),
                FilterChip(
                  label: const Text('Unlistened'),
                  selected: _filterMode == FilterMode.unlistened,
                  onSelected: (_) => setState(() => _filterMode = FilterMode.unlistened),
                ),
                const SizedBox(width: 8),
                FilterChip(
                  label: const Text('Listened'),
                  selected: _filterMode == FilterMode.listened,
                  onSelected: (_) => setState(() => _filterMode = FilterMode.listened),
                ),
                const SizedBox(width: 16),
                DropdownButton<SortMode>(
                  value: _sortMode,
                  items: const [
                    DropdownMenuItem(value: SortMode.downloadTime, child: Text('By date')),
                    DropdownMenuItem(value: SortMode.channel, child: Text('By channel')),
                    DropdownMenuItem(value: SortMode.listenStatus, child: Text('By status')),
                  ],
                  onChanged: (v) { if (v != null) setState(() => _sortMode = v); },
                  underline: const SizedBox.shrink(),
                ),
              ],
            ),
          ),
          Expanded(child: _buildContent()),
        ],
      ),
    );
  }

  Widget _buildContent() {
    if (_loading) return const Center(child: CircularProgressIndicator());

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.error_outline, size: 48,
                  color: Theme.of(context).colorScheme.error),
              const SizedBox(height: 16),
              Text('Failed to load videos',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Text(_error!, style: Theme.of(context).textTheme.bodySmall,
                  textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _loadVideos,
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    if (_videos.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.library_music_outlined, size: 64,
                color: Theme.of(context).colorScheme.onSurfaceVariant),
            const SizedBox(height: 16),
            Text('No audio files yet',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text('Download some YouTube videos first',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadVideos,
      child: ListView.builder(
        itemCount: _displayVideos.length,
        padding: const EdgeInsets.only(bottom: 8),
        itemBuilder: (context, index) {
          final video = _displayVideos[index];
          final progress = _progressMap[video.youtubeId];
          final isPlaying = AudioManager.isInitialized &&
              AudioManager.handler.currentVideo?.youtubeId == video.youtubeId;

          return ListTile(
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            leading: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: 80, height: 56,
                child: CachedNetworkImage(
                  imageUrl: widget.api.thumbnailUrl(video.youtubeId),
                  fit: BoxFit.cover,
                  placeholder: (_, __) => Container(
                    color: Theme.of(context).colorScheme.surfaceContainerHighest,
                    child: const Icon(Icons.music_note, size: 24),
                  ),
                  errorWidget: (_, __, ___) => Container(
                    color: Theme.of(context).colorScheme.surfaceContainerHighest,
                    child: const Icon(Icons.music_note, size: 24),
                  ),
                ),
              ),
            ),
            title: Text(video.title, maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: isPlaying ? Theme.of(context).colorScheme.primary : null,
                  fontWeight: isPlaying ? FontWeight.bold : null,
                )),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(video.channel, maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 2),
                Row(
                  children: [
                    Text(video.durationFormatted,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Theme.of(context).colorScheme.onSurfaceVariant)),
                    if (video.hasSubtitle) ...[
                      const SizedBox(width: 8),
                      Icon(Icons.closed_caption_outlined,
                          size: 14,
                          color: Theme.of(context).colorScheme.onSurfaceVariant),
                    ],
                    if (_completedMap[video.youtubeId] ?? false) ...[
                      const SizedBox(width: 8),
                      Icon(Icons.check_circle_outline,
                          size: 14,
                          color: Colors.green.shade400),
                    ],
                    if (progress != null) ...[
                      const SizedBox(width: 8),
                      Text(_formatProgress(progress, video.duration),
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: Theme.of(context).colorScheme.primary)),
                    ],
                  ],
                ),
              ],
            ),
            trailing: isPlaying
                ? Icon(Icons.equalizer,
                    color: Theme.of(context).colorScheme.primary)
                : const Icon(Icons.play_arrow),
            onTap: () => _playVideo(video),
            onLongPress: () => _showContextMenu(context, video),
          );
        },
      ),
    );
  }
}
