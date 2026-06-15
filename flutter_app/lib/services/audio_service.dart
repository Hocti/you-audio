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

  AudioPlayer get player => _player;
  Video? get currentVideo => _currentVideo;

  AudioPlayerHandler() {
    _player.playbackEventStream.map(_transformEvent).pipe(playbackState);
    _player.processingStateStream.listen((state) {
      if (state == ProcessingState.completed) {
        _onTrackCompleted();
      }
    });

    // Save position periodically
    _player.positionStream.listen((position) {
      if (_currentVideo != null && position.inSeconds > 0) {
        _savePosition(_currentVideo!.id, position.inSeconds);
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
    final url = '$_serverUrl/api/audio/${video.id}';

    mediaItem.add(MediaItem(
      id: video.id,
      title: video.title,
      artist: video.channel,
      duration: Duration(seconds: video.duration),
      artUri: Uri.parse('$_serverUrl/api/thumbnail/${video.id}'),
    ));

    await _player.setUrl(url);

    // Restore saved position
    final savedPos = await _getSavedPosition(video.id);
    if (savedPos > 0 && savedPos < video.duration - 5) {
      await _player.seek(Duration(seconds: savedPos));
    }

    await _player.play();
  }

  Future<void> _onTrackCompleted() async {
    if (_currentVideo != null) {
      // Mark as completed by saving position = 0 (reset)
      await _savePosition(_currentVideo!.id, 0);
    }
    // Auto-play next unplayed track
    await playNextUnplayed();
  }

  Future<void> playNextUnplayed() async {
    if (_playlist.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();

    for (final video in _playlist) {
      if (video.id == _currentVideo?.id) continue;
      final pos = prefs.getInt('progress_${video.id}') ?? -1;
      // -1 means never played, pick this one
      if (pos == -1) {
        await playVideo(video);
        return;
      }
    }

    // If all have been started, pick first one that isn't current
    for (final video in _playlist) {
      if (video.id != _currentVideo?.id) {
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
        _currentVideo!.id,
        _player.position.inSeconds,
      );
    }
    await _player.pause();
  }

  @override
  Future<void> stop() async {
    if (_currentVideo != null) {
      await _savePosition(
        _currentVideo!.id,
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
