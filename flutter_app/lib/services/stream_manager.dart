import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/local_video.dart';
import '../models/video.dart';
import 'api_service.dart';
import 'audio_service.dart';
import 'local_library.dart';

/// Where a stream request has got to.
enum StreamStage { preparing, converting, playing, error }

/// Immutable snapshot of an in-flight "stream this video" request.
///
/// Immutable on purpose: [StreamManager.job] is a `ValueNotifier`, which only
/// notifies when the value it holds is a *different* object, so every change
/// publishes a fresh snapshot via [copyWith].
@immutable
class StreamJob {
  final String youtubeId;
  final String title;
  final StreamStage stage;

  /// Backend conversion progress, 0..1. Device caching progress is separate and
  /// lives on `AudioPlayerHandler.streamCacheProgress` once playback starts.
  final double percent;
  final String? error;

  const StreamJob({
    this.youtubeId = '',
    this.title = 'Preparing…',
    this.stage = StreamStage.preparing,
    this.percent = 0,
    this.error,
  });

  StreamJob copyWith({
    String? youtubeId,
    String? title,
    StreamStage? stage,
    double? percent,
    String? error,
  }) {
    return StreamJob(
      youtubeId: youtubeId ?? this.youtubeId,
      title: title ?? this.title,
      stage: stage ?? this.stage,
      percent: percent ?? this.percent,
      error: error ?? this.error,
    );
  }
}

/// Starts playback as soon as the backend has the audio, instead of waiting for
/// the whole file to reach the device.
///
/// Sibling of `DownloadManager`, not a replacement: that one pulls the complete
/// mp3 and only then plays a local file, and stays the default. Here the player
/// streams from `/api/stream` while just_audio caches the bytes into the very
/// same library path — so when it finishes, the track is an ordinary offline
/// entry. Same files, same Downloaded tab row, reached in a different order.
///
/// What still has to happen first is the *backend* work (yt-dlp + ffmpeg): this
/// removes the device transfer from the wait, not the conversion.
class StreamManager {
  StreamManager._();
  static final StreamManager instance = StreamManager._();

  /// The current request, or null when idle. Pages watch this for status text.
  final ValueNotifier<StreamJob?> job = ValueNotifier(null);

  void _set(StreamJob next) => job.value = next;

  /// Prepare [url] on the backend and play it. [onPlaying] fires once audio has
  /// actually started, so the caller can switch to the Play tab.
  Future<void> start(
    ApiService api,
    String url, {
    VoidCallback? onPlaying,
  }) async {
    var current = const StreamJob();
    _set(current);

    try {
      await LocalLibrary.ensureInitialized();
      if (!AudioManager.isInitialized) {
        throw Exception('Audio engine is not ready yet');
      }

      // 1. Metadata first, so there is a title and duration to build the
      //    MediaItem from before any audio exists.
      final meta = await api.getMetadata(url);
      final youtubeId = meta['youtube_id'] as String? ?? '';
      if (youtubeId.isEmpty) throw Exception('Server returned no video id');
      final metaTitle = (meta['title'] as String?)?.trim();
      current = current.copyWith(
        youtubeId: youtubeId,
        title: (metaTitle == null || metaTitle.isEmpty) ? youtubeId : metaTitle,
      );
      _set(current);

      // 2. Already on the device? Streaming would be pointless — play the file.
      if (LocalLibrary.contains(youtubeId) ||
          File(LocalLibrary.audioPath(youtubeId)).existsSync()) {
        await _playLocal(youtubeId, meta);
        _set(current.copyWith(stage: StreamStage.playing, percent: 1));
        onPlaying?.call();
        return;
      }

      // 3. Make the backend produce the mp3 — /api/stream only serves a
      //    finished `done` row.
      final resp = await api.startDownload(url);
      if (resp['cached'] != true) {
        final taskId = resp['task_id']?.toString();
        if (taskId == null) throw Exception('Server returned no task id');
        current = current.copyWith(stage: StreamStage.converting);
        _set(current);
        current = await _awaitBackend(api, taskId, current);
      }

      // 4. Thumbnail and subtitle are small; pull them so the Play tab has art
      //    and lyrics from the first second. Best-effort.
      final serverMeta = await api.getVideoMeta(youtubeId);
      final hasSubtitle = serverMeta?.hasSubtitle ?? false;
      await _pullExtras(api, youtubeId, hasSubtitle);

      final video = Video(
        youtubeId: youtubeId,
        title: serverMeta?.title ?? current.title,
        channel: serverMeta?.channel ??
            (meta['channel_name'] as String?) ??
            'Unknown',
        channelId: serverMeta?.channelId ?? (meta['channel_id'] as String?),
        duration: serverMeta?.duration ?? (meta['duration'] as int?) ?? 0,
        hasSubtitle: hasSubtitle,
      );

      // 5. Play now, cache as it goes. The library entry is only added once the
      //    cache completes, so a half-cached track never looks downloaded.
      await AudioManager.handler.playStream(
        video,
        url: api.streamUrl(youtubeId),
        headers: api.authHeaders,
        onCached: () => LocalLibrary.addEntry(LocalVideo(
          youtubeId: youtubeId,
          title: video.title,
          channel: video.channel,
          channelId: video.channelId,
          duration: video.duration,
          hasSubtitle: video.hasSubtitle,
          downloadedAt: DateTime.now(),
        )),
      );

      _set(current.copyWith(stage: StreamStage.playing, percent: 1));
      onPlaying?.call();
    } catch (e) {
      _set(current.copyWith(stage: StreamStage.error, error: e.toString()));
    }
  }

  /// Clear the status once the caller has shown it.
  void clear() => job.value = null;

  Future<void> _playLocal(String youtubeId, Map<String, dynamic> meta) async {
    final local = LocalLibrary.get(youtubeId);
    final video = local?.toVideo() ??
        Video(
          youtubeId: youtubeId,
          title: (meta['title'] as String?) ?? youtubeId,
          channel: (meta['channel_name'] as String?) ?? 'Unknown',
          channelId: meta['channel_id'] as String?,
          duration: (meta['duration'] as int?) ?? 0,
          hasSubtitle: File(LocalLibrary.subPath(youtubeId)).existsSync(),
        );
    await AudioManager.handler.playVideo(video);
  }

  Future<StreamJob> _awaitBackend(
      ApiService api, String taskId, StreamJob start) async {
    var current = start;
    while (true) {
      await Future.delayed(const Duration(seconds: 1));
      Map<String, dynamic> p;
      try {
        p = await api.getProgress(taskId);
      } catch (_) {
        continue; // transient network error; keep polling
      }
      current = current.copyWith(
        percent: ((p['progress_percent'] as num?)?.toDouble() ?? 0) / 100,
      );
      final status = p['status']?.toString() ?? '';
      if (status == 'error') {
        throw Exception(p['error']?.toString() ?? 'Backend download failed');
      }
      _set(current);
      if (status == 'done' || status == 'completed') return current;
    }
  }

  Future<void> _pullExtras(
      ApiService api, String youtubeId, bool hasSubtitle) async {
    try {
      final bytes = await api.downloadThumbnailBytes(youtubeId);
      await File(LocalLibrary.thumbPath(youtubeId)).writeAsBytes(bytes);
    } catch (_) {}
    if (hasSubtitle) {
      try {
        final vtt = await api.getSubtitleText(youtubeId);
        await File(LocalLibrary.subPath(youtubeId)).writeAsString(vtt);
      } catch (_) {}
    }
  }
}
