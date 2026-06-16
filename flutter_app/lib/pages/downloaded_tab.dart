import 'dart:io';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/local_video.dart';
import '../services/audio_service.dart';
import '../services/local_library.dart';
import '../services/download_manager.dart';

enum SortMode { downloadTime, channel, listenStatus }
enum FilterMode { all, unlistened, listened }

class DownloadedTab extends StatefulWidget {
  final VoidCallback onPlayTap;

  const DownloadedTab({super.key, required this.onPlayTap});

  @override
  State<DownloadedTab> createState() => _DownloadedTabState();
}

class _DownloadedTabState extends State<DownloadedTab> {
  List<LocalVideo> _videos = [];
  Map<String, int> _progressMap = {};
  Map<String, bool> _completedMap = {};
  bool _loading = true;
  SortMode _sortMode = SortMode.downloadTime;
  FilterMode _filterMode = FilterMode.all;

  @override
  void initState() {
    super.initState();
    DownloadManager.instance.jobs.addListener(_onJobsChanged);
    _load();
  }

  @override
  void dispose() {
    DownloadManager.instance.jobs.removeListener(_onJobsChanged);
    super.dispose();
  }

  // A job finishing adds it to the library and removes itself, so reload.
  void _onJobsChanged() => _load(showSpinner: false);

  Future<void> _load({bool showSpinner = true}) async {
    if (showSpinner && mounted) setState(() => _loading = true);
    await LocalLibrary.ensureInitialized();
    final videos = LocalLibrary.all();
    final prefs = await SharedPreferences.getInstance();
    final progressMap = <String, int>{};
    final completedMap = <String, bool>{};
    for (final v in videos) {
      final pos = prefs.getInt('progress_${v.youtubeId}');
      if (pos != null) progressMap[v.youtubeId] = pos;
      completedMap[v.youtubeId] =
          prefs.getBool('completed_${v.youtubeId}') ?? false;
    }
    if (mounted) {
      setState(() {
        _videos = videos;
        _progressMap = progressMap;
        _completedMap = completedMap;
        _loading = false;
      });
      if (AudioManager.isInitialized) {
        AudioManager.handler.setPlaylist(videos.map((e) => e.toVideo()).toList());
      }
    }
  }

  Future<void> _playVideo(LocalVideo video) async {
    final path = LocalLibrary.audioPath(video.youtubeId);
    final exists = File(path).existsSync();
    if (!AudioManager.isInitialized) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Audio engine not ready yet — try again in a moment')),
        );
      }
      return;
    }
    if (!exists) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Audio file missing on device')),
        );
      }
      return;
    }
    final handler = AudioManager.handler;
    handler.setPlaylist(_videos.map((e) => e.toVideo()).toList());
    try {
      await handler.playVideo(video.toVideo());
      widget.onPlayTap();
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Playback failed: $e')),
        );
      }
    }
  }

  List<LocalVideo> get _displayVideos {
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
        break; // already newest-first from the library
    }

    return list;
  }

  void _showContextMenu(BuildContext ctx, LocalVideo video) {
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
                AudioManager.handler.queueNext(video.toVideo());
              }
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('"${video.title}" queued next')),
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline),
            title: const Text('Delete from device'),
            onTap: () {
              Navigator.pop(ctx);
              _deleteVideo(video);
            },
          ),
        ],
      ),
    );
  }

  Future<void> _deleteVideo(LocalVideo video) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete'),
        content: Text('Delete "${video.title}" from this device?'),
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
    if (confirmed == true) {
      await LocalLibrary.remove(video.youtubeId);
      await _load(showSpinner: false);
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

  String _stageLabel(DownloadJob j) {
    switch (j.stage) {
      case DownloadStage.checking:
        return 'Checking…';
      case DownloadStage.downloading:
        return 'Downloading ${(j.percent * 100).round()}%';
      case DownloadStage.converting:
        return 'Converting…';
      case DownloadStage.saving:
        return 'Saving to device…';
      case DownloadStage.done:
        return 'Done';
      case DownloadStage.error:
        return 'Failed: ${j.error ?? 'unknown error'}';
    }
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
            onPressed: () => _load(),
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
          Expanded(
            child: ValueListenableBuilder<List<DownloadJob>>(
              valueListenable: DownloadManager.instance.jobs,
              builder: (context, jobs, _) => _buildContent(jobs),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContent(List<DownloadJob> jobs) {
    if (_loading && _videos.isEmpty && jobs.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    final displayVideos = _displayVideos;

    if (jobs.isEmpty && displayVideos.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              _videos.isEmpty
                  ? Icons.library_music_outlined
                  : Icons.filter_list_off,
              size: 64,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 16),
            Text(
              _videos.isEmpty ? 'No audio on this device yet' : 'No results for this filter',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (_videos.isEmpty) ...[
              const SizedBox(height: 8),
              Text(
                'Download a YouTube link from the Download tab',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            ],
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: () => _load(showSpinner: false),
      child: ListView(
        padding: const EdgeInsets.only(bottom: 8),
        children: [
          ...jobs.map(_buildJobTile),
          ...displayVideos.map(_buildVideoTile),
        ],
      ),
    );
  }

  Widget _buildJobTile(DownloadJob job) {
    final isError = job.stage == DownloadStage.error;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: SizedBox(
        width: 80, height: 56,
        child: Container(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(isError ? Icons.error_outline : Icons.downloading,
              color: isError
                  ? Theme.of(context).colorScheme.error
                  : Colors.amber),
        ),
      ),
      title: Text(job.title, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text(_stageLabel(job),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: isError ? Theme.of(context).colorScheme.error : null,
              )),
      trailing: isError
          ? IconButton(
              icon: const Icon(Icons.close),
              tooltip: 'Dismiss',
              onPressed: () => DownloadManager.instance.dismiss(job.id),
            )
          : const SizedBox(
              width: 20, height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
    );
  }

  Widget _buildVideoTile(LocalVideo video) {
    final progress = _progressMap[video.youtubeId];
    final isPlaying = AudioManager.isInitialized &&
        AudioManager.handler.currentVideo?.youtubeId == video.youtubeId;
    final thumb = File(LocalLibrary.thumbPath(video.youtubeId));

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(
          width: 80, height: 56,
          child: thumb.existsSync()
              ? Image.file(thumb, fit: BoxFit.cover)
              : Container(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  child: const Icon(Icons.music_note, size: 24),
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
              Text(video.toVideo().durationFormatted,
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
                    size: 14, color: Colors.green.shade400),
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
          ? Icon(Icons.equalizer, color: Theme.of(context).colorScheme.primary)
          : const Icon(Icons.play_arrow),
      onTap: () => _playVideo(video),
      onLongPress: () => _showContextMenu(context, video),
    );
  }
}
