import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/local_video.dart';
import '../models/video.dart';
import 'api_service.dart';
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

    try {
      final resp = await api.startDownload(url);
      final respVideo = resp['video'] as Map<String, dynamic>?;
      final youtubeId = respVideo?['youtube_id'] as String? ?? '';
      job.youtubeId = youtubeId;
      final respTitle = respVideo?['title'] as String?;
      if (respTitle != null) job.title = respTitle;
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

      job.stage = DownloadStage.saving;
      job.percent = 0;
      _publish();
      await _saveLocal(api, youtubeId, respVideo, job);

      _remove(job);
    } catch (e) {
      job.stage = DownloadStage.error;
      job.error = e.toString();
      _publish();
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
      duration: duration,
      hasSubtitle: hasSubtitle,
      downloadedAt: DateTime.now(),
    ));
  }
}
