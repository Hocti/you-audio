import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/video.dart';

class AudioPlayerHandler extends BaseAudioHandler with SeekHandler {
  final AudioPlayer _player = AudioPlayer();
  Video? _currentVideo;
  List<Video> _playlist = [];
  String _serverUrl = '';
  Video? _queuedNext;

  AudioPlayer get player => _player;
  Video? get currentVideo => _currentVideo;

  void queueNext(Video video) {
    _queuedNext = video;
  }

  AudioPlayerHandler() {
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
        if (dur > 0 && position.inSeconds / dur >= 0.95) {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setBool('completed_${_currentVideo!.youtubeId}', true);
        }
      }
    });
  }

  void setServerUrl(String url) {
    _serverUrl = url.endsWith('/') ? url.substring(0, url.length - 1) : url;
  }

  void setPlaylist(List<Video> videos) {
    _playlist = videos;
  }

  Future<void> playVideo(Video video) async {
    _currentVideo = video;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('opened_${video.youtubeId}', true);
    final url = '$_serverUrl/api/audio/${video.youtubeId}';

    mediaItem.add(MediaItem(
      id: video.youtubeId,
      title: video.title,
      artist: video.channel,
      duration: Duration(seconds: video.duration),
      artUri: Uri.parse('$_serverUrl/api/thumbnail/${video.youtubeId}'),
    ));

    await _player.setUrl(url);

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

  @override
  Future<void> skipToNext() async {
    // 15-second forward jump
    final newPos = _player.position + const Duration(seconds: 15);
    final dur = _player.duration ?? Duration.zero;
    if (newPos < dur) {
      await _player.seek(newPos);
    } else {
      await _player.seek(dur);
    }
  }

  @override
  Future<void> skipToPrevious() async {
    // 15-second backward jump
    final newPos = _player.position - const Duration(seconds: 15);
    if (newPos > Duration.zero) {
      await _player.seek(newPos);
    } else {
      await _player.seek(Duration.zero);
    }
  }

  PlaybackState _transformEvent(PlaybackEvent event) {
    return PlaybackState(
      controls: [
        MediaControl.skipToPrevious,
        if (_player.playing) MediaControl.pause else MediaControl.play,
        MediaControl.skipToNext,
      ],
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
      },
      androidCompactActionIndices: const [0, 1, 2],
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
        androidStopForegroundOnPause: false,
      ),
    );
    return _handler!;
  }

  static AudioPlayerHandler get handler => _handler!;
  static bool get isInitialized => _handler != null;
}
