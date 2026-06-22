import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/local_video.dart';
import '../models/video.dart';
import 'api_service.dart';
import 'download_foreground_service.dart';
import 'local_library.dart';

enum DownloadStage { checking, downloading, converting, saving, done, error }

/// One active download: backend convert + pull-to-device.
class DownloadJob {
  final int id;
  String youtubeId;
  String title;
  DownloadStage stage;
  double percent; // 0..1
  String? error;

  DownloadJob({
    required this.id,
    this.youtubeId = '',
    this.title = 'Downloading…',
    this.stage = DownloadStage.checking,
    this.percent = 0,
    this.error,
  });
}

/// Orchestrates downloads: asks the backend to fetch/convert a YouTube URL,
/// then copies the resulting mp3 + thumbnail + subtitle to the device's local
/// library. The Downloaded tab watches [jobs] to show in-progress rows; once a
/// job finishes it's added to [LocalLibrary] and removed from the list.
class DownloadManager {
  DownloadManager._();
  static final DownloadManager instance = DownloadManager._();

  /// Active/failed jobs, newest first. Replaced wholesale on each change so
  /// `ValueListenableBuilder` rebuilds.
  final ValueNotifier<List<DownloadJob>> jobs = ValueNotifier(const []);
  final List<DownloadJob> _list = [];
  int _nextId = 1;

  void _publish() => jobs.value = List.unmodifiable(_list);

  /// Jobs still doing work (errors are terminal and don't keep the service up).
  int get _activeCount =>
      _list.where((j) => j.stage != DownloadStage.error).length;

  /// Start (or refresh) the foreground service so downloads survive backgrounding.
  Future<void> _startService() async {
    final n = _activeCount;
    if (n > 0) {
      await DownloadForegroundService.start('$n download(s) in progress');
    }
  }

  /// Stop the service when no downloads remain, else refresh its notification.
  Future<void> _stopServiceIfIdle() async {
    final n = _activeCount;
    if (n == 0) {
      await DownloadForegroundService.stop();
    } else {
      await DownloadForegroundService.update('$n download(s) in progress');
    }
  }

  void _remove(DownloadJob job) {
    _list.remove(job);
    _publish();
  }

  /// Dismiss a failed job from the list.
  void dismiss(int jobId) {
    _list.removeWhere((j) => j.id == jobId);
    _publish();
  }

  Future<void> start(ApiService api, String url) async {
    await LocalLibrary.ensureInitialized();
    final job = DownloadJob(id: _nextId++);
    _list.insert(0, job);
    _publish();
    await _startService();

    try {
      // 1. Metadata + thumbnail first, so the in-progress row shows the real
      //    title and art before the (slow) audio download even starts.
      Map<String, dynamic>? meta = await _fetchMetadata(api, url, job);

      // 2. Ask the backend to fetch/convert the audio.
      final resp = await api.startDownload(url);
      final respVideo = resp['video'] as Map<String, dynamic>?;
      final youtubeId = (meta?['youtube_id'] as String?) ??
          (respVideo?['youtube_id'] as String?) ??
          '';
      job.youtubeId = youtubeId;
      final title = (meta?['title'] as String?) ?? (respVideo?['title'] as String?);
      if (title != null) job.title = title;
      _publish();

      if (youtubeId.isEmpty) {
        throw Exception('Server returned no video id');
      }
      if (LocalLibrary.contains(youtubeId)) {
        _remove(job); // already on device
        return;
      }

      final cached = resp['cached'] == true;
      if (!cached) {
        final taskId = resp['task_id']?.toString();
        if (taskId == null) throw Exception('Server returned no task id');
        await _pollUntilDone(api, taskId, job);
      }

      // 3. Pull the finished audio (+ thumbnail/subtitle) to the device.
      job.stage = DownloadStage.saving;
      job.percent = 0;
      _publish();
      await _saveLocal(api, youtubeId, meta ?? respVideo, job);

      _remove(job);
    } catch (e) {
      job.stage = DownloadStage.error;
      job.error = e.toString();
      _publish();
    } finally {
      await _stopServiceIfIdle();
    }
  }

  /// Fetch metadata up front and pull the thumbnail to the device so the
  /// in-progress row can show a title + art. Best-effort: an older backend
  /// without `/api/metadata` just falls through to the normal flow.
  Future<Map<String, dynamic>?> _fetchMetadata(
      ApiService api, String url, DownloadJob job) async {
    try {
      final meta = await api.getMetadata(url);
      final youtubeId = meta['youtube_id'] as String? ?? '';
      if (youtubeId.isNotEmpty) job.youtubeId = youtubeId;
      final title = meta['title'] as String?;
      if (title != null && title.isNotEmpty) job.title = title;
      _publish();

      // Pull the thumbnail early (best-effort) for the in-progress row.
      if (youtubeId.isNotEmpty &&
          (meta['has_thumbnail'] as bool? ?? false) &&
          !LocalLibrary.contains(youtubeId)) {
        try {
          final tb = await api.downloadThumbnailBytes(youtubeId);
          await File(LocalLibrary.thumbPath(youtubeId)).writeAsBytes(tb);
          _publish();
        } catch (_) {}
      }
      return meta;
    } catch (_) {
      return null; // metadata unavailable — proceed with the normal flow
    }
  }

  Future<void> _pollUntilDone(
      ApiService api, String taskId, DownloadJob job) async {
    while (true) {
      await Future.delayed(const Duration(seconds: 1));
      Map<String, dynamic> p;
      try {
        p = await api.getProgress(taskId);
      } catch (_) {
        continue; // transient network error; keep polling
      }
      final status = p['status']?.toString() ?? '';
      job.percent = ((p['progress_percent'] as num?)?.toDouble() ?? 0) / 100;
      switch (status) {
        case 'converting':
          job.stage = DownloadStage.converting;
          break;
        case 'done':
        case 'completed':
          _publish();
          return;
        case 'error':
          throw Exception(p['error']?.toString() ?? 'Download error');
        default:
          job.stage = DownloadStage.downloading;
      }
      _publish();
    }
  }

  Future<void> _saveLocal(ApiService api, String youtubeId,
      Map<String, dynamic>? respVideo, DownloadJob job) async {
    final Video? meta = await api.getVideoMeta(youtubeId);
    final title =
        meta?.title ?? (respVideo?['title'] as String?) ?? job.title;
    final channel =
        meta?.channel ?? (respVideo?['channel_name'] as String?) ?? 'Unknown';
    final channelId =
        meta?.channelId ?? (respVideo?['channel_id'] as String?);
    final duration =
        meta?.duration ?? (respVideo?['duration'] as int?) ?? 0;
    final hasSubtitle =
        meta?.hasSubtitle ?? (respVideo?['has_subtitle'] as bool? ?? false);

    // Audio is required.
    final audioBytes = await api.downloadAudioBytes(youtubeId);
    await File(LocalLibrary.audioPath(youtubeId)).writeAsBytes(audioBytes);

    // Thumbnail + subtitle are best-effort.
    try {
      final tb = await api.downloadThumbnailBytes(youtubeId);
      await File(LocalLibrary.thumbPath(youtubeId)).writeAsBytes(tb);
    } catch (_) {}
    if (hasSubtitle) {
      try {
        final vtt = await api.getSubtitleText(youtubeId);
        await File(LocalLibrary.subPath(youtubeId)).writeAsString(vtt);
      } catch (_) {}
    }

    await LocalLibrary.addEntry(LocalVideo(
      youtubeId: youtubeId,
      title: title,
      channel: channel,
      channelId: channelId,
      duration: duration,
      hasSubtitle: hasSubtitle,
      downloadedAt: DateTime.now(),
    ));
  }
}
