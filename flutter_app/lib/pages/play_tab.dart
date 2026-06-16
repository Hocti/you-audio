import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import '../services/audio_service.dart';
import '../services/local_library.dart';
import '../models/subtitle_entry.dart';

class PlayTab extends StatefulWidget {
  const PlayTab({super.key});

  @override
  State<PlayTab> createState() => _PlayTabState();
}

class _PlayTabState extends State<PlayTab> {
  List<SubtitleEntry> _subtitles = [];
  bool _loadingSubtitles = false;
  String? _lastLoadedYoutubeId;
  double _currentSpeed = 1.0;
  StreamSubscription<dynamic>? _mediaItemSub;

  @override
  void initState() {
    super.initState();
    _tryLoadSubtitles();
    if (AudioManager.isInitialized) {
      _currentSpeed = AudioManager.handler.player.speed;
    }
    // Listen for track changes
    if (AudioManager.isInitialized) {
      _mediaItemSub = AudioManager.handler.mediaItem.listen((_) {
        if (mounted) _tryLoadSubtitles();
      });
    }
  }

  @override
  void dispose() {
    _mediaItemSub?.cancel();
    super.dispose();
  }

  Future<void> _tryLoadSubtitles() async {
    if (!AudioManager.isInitialized) return;
    final video = AudioManager.handler.currentVideo;
    if (video == null || !video.hasSubtitle) {
      if (mounted) setState(() => _subtitles = []);
      return;
    }
    if (video.youtubeId == _lastLoadedYoutubeId) return;

    setState(() => _loadingSubtitles = true);
    try {
      await LocalLibrary.ensureInitialized();
      final file = File(LocalLibrary.subPath(video.youtubeId));
      if (!await file.exists()) {
        if (mounted) {
          setState(() { _subtitles = []; _loadingSubtitles = false; });
        }
        return;
      }
      final vtt = await file.readAsString();
      final entries = parseVtt(vtt);
      if (mounted) {
        setState(() {
          _subtitles = entries;
          _lastLoadedYoutubeId = video.youtubeId;
          _loadingSubtitles = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() { _subtitles = []; _loadingSubtitles = false; });
    }
  }

  int _currentSubtitleIndex(Duration position) {
    for (int i = 0; i < _subtitles.length; i++) {
      if (position >= _subtitles[i].start && position < _subtitles[i].end) {
        return i;
      }
    }
    return -1;
  }

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    if (h > 0) {
      return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    if (!AudioManager.isInitialized ||
        AudioManager.handler.currentVideo == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Now Playing')),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.play_circle_outline, size: 64,
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
              const SizedBox(height: 16),
              Text('No audio playing',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Text('Tap a track in the Downloaded tab',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant)),
            ],
          ),
        ),
      );
    }

    final handler = AudioManager.handler;
    final player = handler.player;

    return Scaffold(
      appBar: AppBar(
        title: StreamBuilder(
          stream: handler.mediaItem,
          builder: (_, snap) {
            final title = snap.data?.title ?? 'Now Playing';
            return Text(title, overflow: TextOverflow.ellipsis);
          },
        ),
        centerTitle: true,
      ),
      body: StreamBuilder<Duration>(
        stream: player.positionStream,
        builder: (context, posSnap) {
          final position = posSnap.data ?? Duration.zero;
          final duration = player.duration ?? Duration.zero;
          final currentIdx = _currentSubtitleIndex(position);

          return Column(
            children: [
              // Speed control
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text('Speed:', style: Theme.of(context).textTheme.bodyMedium),
                    const SizedBox(width: 8),
                    DropdownButton<double>(
                      value: AudioPlayerHandler.speedSteps.reduce((a, b) =>
                          (a - _currentSpeed).abs() < (b - _currentSpeed).abs() ? a : b),
                      items: AudioPlayerHandler.speedSteps
                          .map((s) => DropdownMenuItem(value: s, child: Text('${s}x')))
                          .toList(),
                      onChanged: (v) {
                        if (v != null) {
                          AudioManager.handler.setSpeed(v);
                          setState(() => _currentSpeed = v);
                        }
                      },
                      underline: const SizedBox.shrink(),
                    ),
                  ],
                ),
              ),
              // Seek bar
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Slider(
                  value: duration.inMilliseconds > 0
                      ? (position.inMilliseconds /
                              duration.inMilliseconds)
                          .clamp(0.0, 1.0)
                      : 0.0,
                  onChanged: (v) {
                    handler.seek(Duration(
                        milliseconds:
                            (v * duration.inMilliseconds).round()));
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(_fmt(position),
                        style: Theme.of(context).textTheme.bodySmall),
                    Text(_fmt(duration),
                        style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ),
              const Divider(height: 16),
              // Subtitle list or empty state
              Expanded(child: _buildSubtitleList(context, currentIdx)),
            ],
          );
        },
      ),
    );
  }

  Widget _buildSubtitleList(BuildContext context, int currentIdx) {
    if (_loadingSubtitles) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_subtitles.isEmpty) {
      final hasSubtitle =
          AudioManager.isInitialized &&
          (AudioManager.handler.currentVideo?.hasSubtitle ?? false);
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              hasSubtitle
                  ? Icons.hourglass_empty
                  : Icons.closed_caption_disabled_outlined,
              size: 48,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Text(
              hasSubtitle ? 'Loading subtitles...' : 'No subtitles available',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      itemCount: _subtitles.length,
      itemBuilder: (context, i) {
        final entry = _subtitles[i];
        final isCurrent = i == currentIdx;
        return ListTile(
          dense: true,
          selected: isCurrent,
          selectedTileColor:
              Theme.of(context).colorScheme.primaryContainer,
          title: Text(
            entry.text,
            style: TextStyle(
              fontWeight:
                  isCurrent ? FontWeight.bold : FontWeight.normal,
              color: isCurrent
                  ? Theme.of(context)
                      .colorScheme
                      .onPrimaryContainer
                  : null,
            ),
          ),
          onTap: () => AudioManager.handler.seek(entry.start),
        );
      },
    );
  }
}
