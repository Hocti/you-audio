import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/audio_service.dart';
import '../services/local_library.dart';
import '../models/subtitle_entry.dart';
import '../widgets/scrolling_text.dart';
import 'queue_page.dart';

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

  // Auto-scroll ("follow the line being spoken"). A key marks the currently
  // highlighted line so it can be revealed; `_autoScrolledIndex` keeps us to one
  // scroll per line change rather than one per position tick.
  static const String _autoScrollPrefKey = 'subtitle_autoscroll';

  /// Where the followed line lands in the viewport (0 = top, 1 = bottom).
  static const double _followAlignment = 0.35;

  final GlobalKey _currentLineKey = GlobalKey();
  final ScrollController _subtitleScroll = ScrollController();
  bool _autoScroll = true;
  int _autoScrolledIndex = -1;

  Future<void> _loadAutoScrollPref() async {
    final prefs = await SharedPreferences.getInstance();
    final enabled = prefs.getBool(_autoScrollPrefKey) ?? true;
    if (mounted && enabled != _autoScroll) {
      setState(() => _autoScroll = enabled);
    }
  }

  Future<void> _saveAutoScrollPref(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autoScrollPrefKey, enabled);
  }

  Duration get _playerPosition => AudioManager.isInitialized
      ? AudioManager.handler.player.position
      : Duration.zero;

  /// Follow the current line as playback moves, once per line change.
  void _maybeAutoScroll(int currentIdx) {
    if (!_autoScroll || currentIdx < 0 || currentIdx == _autoScrolledIndex) {
      return;
    }
    _autoScrolledIndex = currentIdx;
    _scrollToLine(currentIdx);
  }

  /// Bring line [index] into view.
  ///
  /// A line only carries [_currentLineKey] once it is built, and a line far
  /// outside the viewport isn't built at all — the old code gave up there, which
  /// is why auto-scroll went dead after a manual scroll or a seek. When the key
  /// has no context we jump to an estimated offset instead; that builds the real
  /// line, and the retry lands on it exactly.
  void _scrollToLine(int index, {int attempt = 0}) {
    if (attempt > 3) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_autoScroll) return;

      final ctx = _currentLineKey.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(
          ctx,
          alignment: _followAlignment,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
        return;
      }

      if (!_subtitleScroll.hasClients || _subtitles.isEmpty) return;
      final position = _subtitleScroll.position;
      final estimate = position.maxScrollExtent * (index / _subtitles.length);
      _subtitleScroll.jumpTo(
        estimate.clamp(position.minScrollExtent, position.maxScrollExtent),
      );
      _scrollToLine(index, attempt: attempt + 1);
    });
  }

  /// Turning it on jumps to wherever playback is *now*, so the user doesn't have
  /// to wait for the next line before the view catches up.
  void _toggleAutoScroll() {
    final enabled = !_autoScroll;
    setState(() {
      _autoScroll = enabled;
      _autoScrolledIndex = -1;
    });
    _saveAutoScrollPref(enabled);
    if (!enabled) return;
    final idx = _currentSubtitleIndex(_playerPosition);
    if (idx >= 0) {
      _autoScrolledIndex = idx;
      _scrollToLine(idx);
    }
  }

  /// A finger drag means the user has taken over: stop following until they
  /// re-arm the toggle. Programmatic scrolls carry no drag details, so
  /// auto-scroll never switches itself off.
  bool _onSubtitleScroll(ScrollNotification n) {
    final dragged = (n is ScrollStartNotification && n.dragDetails != null) ||
        (n is ScrollUpdateNotification && n.dragDetails != null);
    if (dragged && _autoScroll) {
      setState(() => _autoScroll = false);
      _saveAutoScrollPref(false);
    }
    return false; // keep the notification bubbling
  }

  @override
  void initState() {
    super.initState();
    _loadAutoScrollPref();
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
    _subtitleScroll.dispose();
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
          _autoScrolledIndex = -1; // re-scroll for the new track
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
            return ScrollingText(title);
          },
        ),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.queue_music),
            tooltip: 'Up Next',
            onPressed: () => QueuePage.open(context),
          ),
        ],
      ),
      body: StreamBuilder<Duration>(
        stream: player.positionStream,
        builder: (context, posSnap) {
          final position = posSnap.data ?? Duration.zero;
          final duration = player.duration ?? Duration.zero;
          final currentIdx = _currentSubtitleIndex(position);
          _maybeAutoScroll(currentIdx);

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

    return Stack(
      children: [
        NotificationListener<ScrollNotification>(
          onNotification: _onSubtitleScroll,
          child: ListView.builder(
            controller: _subtitleScroll,
            itemCount: _subtitles.length,
            // Room for the toggle button so it never covers the last line.
            padding: const EdgeInsets.only(bottom: 72),
            itemBuilder: (context, i) {
              final entry = _subtitles[i];
              final isCurrent = i == currentIdx;
              return ListTile(
                key: isCurrent ? _currentLineKey : null,
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
          ),
        ),
        Positioned(
          right: 12,
          bottom: 12,
          child: _buildAutoScrollToggle(context),
        ),
      ],
    );
  }

  /// Corner toggle for "follow the line being spoken". Filled = following.
  Widget _buildAutoScrollToggle(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: _autoScroll
          ? 'Auto-scroll on — tap to stop following'
          : 'Auto-scroll off — tap to jump to the current line',
      child: FloatingActionButton.small(
        heroTag: null, // not a route transition; avoids hero tag clashes
        onPressed: _toggleAutoScroll,
        backgroundColor:
            _autoScroll ? scheme.primary : scheme.surfaceContainerHighest,
        foregroundColor:
            _autoScroll ? scheme.onPrimary : scheme.onSurfaceVariant,
        child: Icon(_autoScroll
            ? Icons.center_focus_strong
            : Icons.center_focus_weak),
      ),
    );
  }
}
