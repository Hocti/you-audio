import 'dart:async';
import 'dart:io';
import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/video.dart';
import 'local_library.dart';

class AudioPlayerHandler extends BaseAudioHandler with SeekHandler {
  final AudioPlayer _player = AudioPlayer();
  Video? _currentVideo;
  List<Video> _playlist = [];
  Video? _queuedNext;
  bool _markedCompleted = false;
  double _speed = 1.0; // remembered playback speed, applied to every track

  static const List<double> speedSteps = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.25, 2.5];
  static const _speedKey = 'playback_speed';

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

  void queueNext(Video video) {
    _queuedNext = video;
  }

  AudioPlayerHandler() {
    _loadSpeed();
    _player.playbackEventStream.map(_transformEvent).pipe(playbackState);
    _player.processingStateStream.listen((state) {
      if (state == ProcessingState.completed) {
        _onTrackCompleted();
      }
    });

    // Save position periodically
    _player.positionStream.listen((position) async {
      if (_currentVideo != null && position.inSeconds > 0) {
        _savePosition(_currentVideo!.youtubeId, position.inSeconds);
        final dur = _currentVideo!.duration;
        if (dur > 0 && !_markedCompleted && position.inSeconds / dur >= 0.95) {
          _markedCompleted = true;
          final prefs = await SharedPreferences.getInstance();
          await prefs.setBool('completed_${_currentVideo!.youtubeId}', true);
        }
      }
    });
  }

  void setPlaylist(List<Video> videos) {
    _playlist = videos;
  }

  Future<void> playVideo(Video video) async {
    _currentVideo = video;
    _markedCompleted = false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('opened_${video.youtubeId}', true);

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

  Future<void> _onTrackCompleted() async {
    if (_currentVideo != null) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('completed_${_currentVideo!.youtubeId}', true);
      await _savePosition(_currentVideo!.youtubeId, 0);
    }
    // Auto-play next unplayed track
    await playNextUnplayed();
  }

  Future<void> playNextUnplayed() async {
    if (_queuedNext != null) {
      final next = _queuedNext!;
      _queuedNext = null;
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
  }

  Future<int> _getSavedPosition(String videoId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt('progress_$videoId') ?? 0;
  }

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() async {
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
    final newPos = _player.position + const Duration(seconds: 30);
    final dur = _player.duration ?? Duration.zero;
    await _player.seek(newPos < dur ? newPos : dur);
  }

  /// 30-second backward seek.
  @override
  Future<void> rewind() async {
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
        androidNotificationChannelId: 'com.example.flutter_app.audio',
        androidNotificationChannelName: 'YouTube Audio',
        androidNotificationOngoing: true,
        androidStopForegroundOnPause: true,
      ),
    );
    return _handler!;
  }

  static AudioPlayerHandler get handler => _handler!;
  static bool get isInitialized => _handler != null;
}
