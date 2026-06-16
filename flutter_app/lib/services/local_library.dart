import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/local_video.dart';

/// Owns the on-device library: audio/thumbnail/subtitle files plus a
/// `library.json` index. Everything here is local — no backend access — so the
/// Downloaded tab works fully offline.
///
/// Layout under the app documents directory:
/// ```
/// library/
///   audio/{id}.mp3
///   thumbs/{id}.jpg
///   subs/{id}.vtt
///   library.json
/// ```
class LocalLibrary {
  static Directory? _baseDir;
  static List<LocalVideo> _index = [];
  static Future<void>? _initFuture;

  /// Initializes once; safe to call repeatedly.
  static Future<void> ensureInitialized() {
    return _initFuture ??= _init();
  }

  static Future<void> _init() async {
    final docs = await getApplicationDocumentsDirectory();
    final base = Directory('${docs.path}/library');
    await Directory('${base.path}/audio').create(recursive: true);
    await Directory('${base.path}/thumbs').create(recursive: true);
    await Directory('${base.path}/subs').create(recursive: true);
    _baseDir = base;
    await _loadIndex();
  }

  static String _base() {
    final dir = _baseDir;
    if (dir == null) {
      throw StateError('LocalLibrary.ensureInitialized() not awaited');
    }
    return dir.path;
  }

  static String audioPath(String id) => '${_base()}/audio/$id.mp3';
  static String thumbPath(String id) => '${_base()}/thumbs/$id.jpg';
  static String subPath(String id) => '${_base()}/subs/$id.vtt';
  static String get _indexPath => '${_base()}/library.json';

  static List<LocalVideo> all() => List.unmodifiable(_index);

  static bool contains(String id) =>
      _index.any((v) => v.youtubeId == id);

  static LocalVideo? get(String id) {
    for (final v in _index) {
      if (v.youtubeId == id) return v;
    }
    return null;
  }

  static Future<void> _loadIndex() async {
    final file = File(_indexPath);
    if (!await file.exists()) {
      _index = [];
      return;
    }
    try {
      final raw = await file.readAsString();
      final list = jsonDecode(raw) as List<dynamic>;
      _index = list
          .map((j) => LocalVideo.fromJson(j as Map<String, dynamic>))
          .toList();
    } catch (_) {
      _index = [];
    }
  }

  static Future<void> _saveIndex() async {
    final file = File(_indexPath);
    await file.writeAsString(
        jsonEncode(_index.map((e) => e.toJson()).toList()));
  }

  /// Adds (or replaces) an index entry. The actual files must already be
  /// written via [audioPath]/[thumbPath]/[subPath].
  static Future<void> addEntry(LocalVideo video) async {
    _index.removeWhere((v) => v.youtubeId == video.youtubeId);
    _index.insert(0, video); // newest first
    await _saveIndex();
  }

  /// Removes the index entry and deletes the files from disk.
  static Future<void> remove(String id) async {
    _index.removeWhere((v) => v.youtubeId == id);
    await _saveIndex();
    for (final path in [audioPath(id), thumbPath(id), subPath(id)]) {
      final f = File(path);
      if (await f.exists()) {
        await f.delete();
      }
    }
  }
}
