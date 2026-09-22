import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/video.dart';
import 'local_library.dart';

class AudioPlayerHandler extends BaseAudioHandler with SeekHandler {
  final AudioPlayer _player = AudioPlayer();
  Video? _currentVideo;
  List<Video> _playlist = [];
  // User-managed "play next" queue (FIFO). Takes priority over the smart
  // auto-advance; exposed via [queue] so the Queue page can rebuild.
  final List<Video> _queue = [];
  // Named `upNext` to avoid clashing with BaseAudioHandler.queue (MediaItems).
  final ValueNotifier<List<Video>> upNext = ValueNotifier(const []);
  bool _markedCompleted = false;
  double _speed = 1.0; // remembered playback speed, applied to every track
  int _lastPosSaveMs = 0; // throttles position writes to ~once per 2s

  /// How much of a *streamed* track has been cached to disk, 0.0–1.0. Null when
  /// nothing is streaming (a local-file track, or the cache already completed).
  final ValueNotifier<double?> streamCacheProgress = ValueNotifier(null);
  StreamSubscription<double>? _streamProgressSub;

  static const List<double> speedSteps = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.25, 2.5];
  static const _speedKey = 'playback_speed';
  static const _lastPlayedKey = 'last_played_youtube_id';

  AudioPlayer get player => _player;
  Video? get currentVideo => _currentVideo;

  double get currentSpeed => _speed;

  @override
  Future<void> setSpeed(double speed) async {
    _speed = speed.clamp(0.5, 2.5);
    await _player.setSpeed(_speed);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_speedKey, _speed);
  }

  Future<void> _loadSpeed() async {
    final prefs = await SharedPreferences.getInstance();
    _speed = (prefs.getDouble(_speedKey) ?? 1.0).clamp(0.5, 2.5);
    await _player.setSpeed(_speed);
  }

  void _publishQueue() => upNext.value = List.unmodifiable(_queue);

  /// Append a track to the play-next queue.
  void addToQueue(Video video) {
    _queue.add(video);
    _publishQueue();
  }

  /// Back-compat alias for the "Play Next" menu action.
  void queueNext(Video video) => addToQueue(video);

  void removeFromQueue(int index) {
    if (index < 0 || index >= _queue.length) return;
    _queue.removeAt(index);
    _publishQueue();
  }

  void reorderQueue(int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= _queue.length) return;
    // ReorderableListView reports newIndex as the insertion slot *before*
    // removal, so adjust when moving an item further down the list.
    if (newIndex > oldIndex) newIndex -= 1;
    final item = _queue.removeAt(oldIndex);
    _queue.insert(newIndex.clamp(0, _queue.length), item);
    _publishQueue();
  }

  void clearQueue() {
    _queue.clear();
    _publishQueue();
  }

  AudioPlayerHandler() {
    _loadSpeed();
    _player.playbackEventStream.map(_transformEvent).pipe(playbackState);
    _player.processingStateStream.listen((state) {
      if (state == ProcessingState.completed) {
        _onTrackCompleted();
      }
    });

    // Save position periodically. positionStream fires sub-second, so throttle
    // the SharedPreferences write to ~once every 2s (pause/stop still flush the
    // exact final position immediately).
    _player.positionStream.listen((position) async {
      if (_currentVideo != null && position.inSeconds > 0) {
        final now = DateTime.now().millisecondsSinceEpoch;
        if (now - _lastPosSaveMs >= 2000) {
          _lastPosSaveMs = now;
          _savePosition(_currentVideo!.youtubeId, position.inSeconds);
        }
        final dur = _currentVideo!.duration;
        if (dur > 0 && !_markedCompleted && position.inSeconds / dur >= 0.95) {
          _markedCompleted = true;
          final prefs = await SharedPreferences.getInstance();
          await prefs.setBool('completed_${_currentVideo!.youtubeId}', true);
          // Treat a near-end listen as a full play for the high-water mark.
          final maxKey = 'max_progress_${_currentVideo!.youtubeId}';
          final prevMax = prefs.getInt(maxKey) ?? 0;
          if (dur > prevMax) await prefs.setInt(maxKey, dur);
        }
      }
    });
  }

  void setPlaylist(List<Video> videos) {
    _playlist = videos;
  }

  Future<void> playVideo(Video video) async {
    // A local-file track carries no streaming state; drop any listener left
    // over from a previous playStream so the progress notifier doesn't linger.
    await _streamProgressSub?.cancel();
    _streamProgressSub = null;
    streamCacheProgress.value = null;

    _currentVideo = video;
    _markedCompleted = false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('opened_${video.youtubeId}', true);
    await prefs.setString(_lastPlayedKey, video.youtubeId);

    final audioFile = LocalLibrary.audioPath(video.youtubeId);
    final thumbFile = LocalLibrary.thumbPath(video.youtubeId);

    mediaItem.add(MediaItem(
      id: video.youtubeId,
      title: video.title,
      artist: video.channel,
      duration: Duration(seconds: video.duration),
      artUri: File(thumbFile).existsSync() ? Uri.file(thumbFile) : null,
    ));

    await _player.setFilePath(audioFile);
    await _player.setSpeed(_speed); // keep the user's chosen speed across tracks

    // Restore saved position
    final savedPos = await _getSavedPosition(video.youtubeId);
    if (savedPos > 0 && savedPos < video.duration - 5) {
      await _player.seek(Duration(seconds: savedPos));
    }

    await _player.play();
  }

  /// Play a track straight from the backend while it caches to the device.
  ///
  /// Additive — [playVideo] (local file) is untouched and still handles anything
  /// already in the library. `LockCachingAudioSource` writes to
  /// `LocalLibrary.audioPath`, so the cache file *is* the library file: once
  /// [streamCacheProgress] reaches 1.0 the track is an ordinary offline entry
  /// and [onCached] fires so the caller can add it to `LocalLibrary`.
  ///
  /// [url] must be range-capable (`ApiService.streamUrl`, not `audioUrl`) —
  /// just_audio issues a byte-range request whenever the listener seeks past the
  /// part it has cached.
  Future<void> playStream(
    Video video, {
    required String url,
    required Map<String, String> headers,
    VoidCallback? onCached,
  }) async {
    _currentVideo = video;
    _markedCompleted = false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('opened_${video.youtubeId}', true);
    await prefs.setString(_lastPlayedKey, video.youtubeId);

    final thumbFile = LocalLibrary.thumbPath(video.youtubeId);
    mediaItem.add(MediaItem(
      id: video.youtubeId,
      title: video.title,
      artist: video.channel,
      duration: Duration(seconds: video.duration),
      artUri: File(thumbFile).existsSync() ? Uri.file(thumbFile) : null,
    ));

    // Deliberately using an experimental API: it is the only thing in just_audio
    // that plays and caches in one pass, and hand-rolling the equivalent means
    // running our own local HTTP proxy with byte-range bookkeeping. Contained to
    // this one method — if it ever disappears, only streaming breaks and the
    // download path keeps working.
    // ignore: experimental_member_use
    final source = LockCachingAudioSource(
      Uri.parse(url),
      headers: headers,
      cacheFile: File(LocalLibrary.audioPath(video.youtubeId)),
    );

    await _streamProgressSub?.cancel();
    streamCacheProgress.value = 0.0;
    _streamProgressSub = source.downloadProgressStream.listen((progress) {
      streamCacheProgress.value = progress;
      if (progress >= 1.0) {
        streamCacheProgress.value = null; // done: nothing left to show
        onCached?.call();
      }
    });

    await _player.setAudioSource(source);
    await _player.setSpeed(_speed);

    final savedPos = await _getSavedPosition(video.youtubeId);
    if (savedPos > 0 && savedPos < video.duration - 5) {
      await _player.seek(Duration(seconds: savedPos));
    }

    await _player.play();
  }

  /// Reload the last-played track at its saved position, **paused**, so the app
  /// opens showing what was playing and where, ready to resume on tap. Does not
  /// start playback. Safe to call at startup; a no-op if nothing was played or
  /// the file is gone.
  Future<void> restoreLastSession() async {
    if (_currentVideo != null) return; // something already loaded
    final prefs = await SharedPreferences.getInstance();
    final id = prefs.getString(_lastPlayedKey);
    if (id == null || id.isEmpty) return;

    await LocalLibrary.ensureInitialized();
    final lv = LocalLibrary.get(id);
    if (lv == null) return;
    final audioFile = LocalLibrary.audioPath(id);
    if (!File(audioFile).existsSync()) return;

    final video = lv.toVideo();
    _currentVideo = video;
    _markedCompleted = false;

    final thumbFile = LocalLibrary.thumbPath(id);
    mediaItem.add(MediaItem(
      id: video.youtubeId,
      title: video.title,
      artist: video.channel,
      duration: Duration(seconds: video.duration),
      artUri: File(thumbFile).existsSync() ? Uri.file(thumbFile) : null,
    ));

    try {
      await _player.setFilePath(audioFile);
      await _player.setSpeed(_speed);
      final savedPos = await _getSavedPosition(id);
      if (savedPos > 0 && savedPos < video.duration - 5) {
        await _player.seek(Duration(seconds: savedPos));
      }
    } catch (_) {
      // Couldn't load the file; leave the metadata showing without audio.
    }
    // Intentionally not calling play() — the user resumes manually.
  }

  Future<void> _onTrackCompleted() async {
    if (_currentVideo != null) {
      final id = _currentVideo!.youtubeId;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('completed_$id', true);
      final dur = _currentVideo!.duration;
      final prevMax = prefs.getInt('max_progress_$id') ?? 0;
      if (dur > prevMax) {
        await prefs.setInt('max_progress_$id', dur);
      }
      // Resume from the start next time, but keep the high-water mark.
      await _savePosition(id, 0);
    }
    // Auto-play next unplayed track
    await playNextUnplayed();
  }

  Future<void> playNextUnplayed() async {
    // The user-managed queue takes priority over smart auto-advance.
    if (_queue.isNotEmpty) {
      final next = _queue.removeAt(0);
      _publishQueue();
      await playVideo(next);
      return;
    }
    if (_playlist.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();

    // First pass: find unstarted (never played) and not completed
    for (final video in _playlist) {
      if (video.youtubeId == _currentVideo?.youtubeId) continue;
      final pos = prefs.getInt('progress_${video.youtubeId}') ?? -1;
      final completed = prefs.getBool('completed_${video.youtubeId}') ?? false;
      if (pos == -1 && !completed) {
        await playVideo(video);
        return;
      }
    }

    // Second pass: in-progress but not completed
    for (final video in _playlist) {
      if (video.youtubeId == _currentVideo?.youtubeId) continue;
      final completed = prefs.getBool('completed_${video.youtubeId}') ?? false;
      if (!completed) {
        await playVideo(video);
        return;
      }
    }

    // All done — pick first non-current
    for (final video in _playlist) {
      if (video.youtubeId != _currentVideo?.youtubeId) {
        await playVideo(video);
        return;
      }
    }
  }

  Future<void> _savePosition(String videoId, int seconds) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('progress_$videoId', seconds);
    // High-water mark: how far the user has ever reached, even if they later
    // seek back or replay from the start. Never lowered.
    final maxKey = 'max_progress_$videoId';
    final prevMax = prefs.getInt(maxKey) ?? 0;
    if (seconds > prevMax) {
      await prefs.setInt(maxKey, seconds);
    }
  }

  Future<int> _getSavedPosition(String videoId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt('progress_$videoId') ?? 0;
  }

  @override
  Future<void> play() async {
    debugPrint('[NOTIF] play() called');
    // If the service was revived by a media button while nothing is loaded
    // (e.g. the app was killed), reload the last-played track first so the
    // hardware/Bluetooth/notification play button still starts playback.
    if (_currentVideo == null) {
      await restoreLastSession();
    }
    await _player.play();
  }

  @override
  Future<void> pause() async {
    debugPrint('[NOTIF] pause() called');
    if (_currentVideo != null) {
      await _savePosition(
        _currentVideo!.youtubeId,
        _player.position.inSeconds,
      );
    }
    await _player.pause();
  }

  @override
  Future<void> stop() async {
    if (_currentVideo != null) {
      await _savePosition(
        _currentVideo!.youtubeId,
        _player.position.inSeconds,
      );
    }
    await _player.stop();
    await super.stop();
  }

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  int _currentIndex() =>
      _playlist.indexWhere((v) => v.youtubeId == _currentVideo?.youtubeId);

  /// Next track in the playlist (audio change), not a 30s seek.
  @override
  Future<void> skipToNext() async {
    debugPrint('[NOTIF] skipToNext() called, playlist=${_playlist.length}');
    if (_playlist.isEmpty) return;
    final i = _currentIndex();
    if (i >= 0 && i + 1 < _playlist.length) {
      await playVideo(_playlist[i + 1]);
    }
  }

  /// Previous track. If we're more than 3s into the current track, restart it
  /// first (standard player behaviour) before stepping to the previous track.
  @override
  Future<void> skipToPrevious() async {
    debugPrint('[NOTIF] skipToPrevious() called');
    if (_player.position > const Duration(seconds: 3)) {
      await _player.seek(Duration.zero);
      return;
    }
    if (_playlist.isEmpty) return;
    final i = _currentIndex();
    if (i > 0) {
      await playVideo(_playlist[i - 1]);
    } else {
      await _player.seek(Duration.zero);
    }
  }

  /// 30-second forward seek (the ±30s buttons / notification fast-forward).
  @override
  Future<void> fastForward() async {
    debugPrint('[NOTIF] fastForward() called');
    final newPos = _player.position + const Duration(seconds: 30);
    final dur = _player.duration ?? Duration.zero;
    await _player.seek(newPos < dur ? newPos : dur);
  }

  /// 30-second backward seek.
  @override
  Future<void> rewind() async {
    debugPrint('[NOTIF] rewind() called');
    final newPos = _player.position - const Duration(seconds: 30);
    await _player.seek(newPos > Duration.zero ? newPos : Duration.zero);
  }

  PlaybackState _transformEvent(PlaybackEvent event) {
    return PlaybackState(
      controls: [
        MediaControl.skipToPrevious,
        MediaControl.rewind,
        if (_player.playing) MediaControl.pause else MediaControl.play,
        MediaControl.fastForward,
        MediaControl.skipToNext,
      ],
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
      },
      androidCompactActionIndices: const [0, 2, 4],
      processingState: const {
        ProcessingState.idle: AudioProcessingState.idle,
        ProcessingState.loading: AudioProcessingState.loading,
        ProcessingState.buffering: AudioProcessingState.buffering,
        ProcessingState.ready: AudioProcessingState.ready,
        ProcessingState.completed: AudioProcessingState.completed,
      }[_player.processingState]!,
      playing: _player.playing,
      updatePosition: _player.position,
      bufferedPosition: _player.bufferedPosition,
      speed: _player.speed,
      queueIndex: event.currentIndex,
    );
  }
}

class AudioManager {
  static AudioPlayerHandler? _handler;

  static Future<AudioPlayerHandler> init() async {
    _handler ??= await AudioService.init(
      builder: () => AudioPlayerHandler(),
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'net.teashop.you_audio.audio',
        androidNotificationChannelName: 'You Audio',
        androidNotificationOngoing: true,
        androidStopForegroundOnPause: true,
      ),
    );
    return _handler!;
  }

  static AudioPlayerHandler get handler => _handler!;
  static bool get isInitialized => _handler != null;
}
