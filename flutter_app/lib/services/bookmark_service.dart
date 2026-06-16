import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// A bookmarked YouTube channel (id + display name).
class ChannelBookmark {
  final String id;
  final String name;
  const ChannelBookmark({required this.id, required this.name});

  Map<String, dynamic> toJson() => {'id': id, 'name': name};

  factory ChannelBookmark.fromJson(Map<String, dynamic> j) => ChannelBookmark(
        id: j['id'] as String,
        name: (j['name'] as String?) ?? (j['id'] as String),
      );
}

/// Stores bookmarked channels in SharedPreferences as a JSON list.
class BookmarkService {
  static const _key = 'bookmarked_channels';

  static Future<List<ChannelBookmark>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((j) => ChannelBookmark.fromJson(j as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> _save(List<ChannelBookmark> items) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _key, jsonEncode(items.map((e) => e.toJson()).toList()));
  }

  static Future<bool> isBookmarked(String id) async {
    return (await load()).any((e) => e.id == id);
  }

  /// Adds the bookmark, or updates its name if the id already exists.
  static Future<void> add(ChannelBookmark bm) async {
    final items = await load();
    final idx = items.indexWhere((e) => e.id == bm.id);
    if (idx >= 0) {
      items[idx] = bm;
    } else {
      items.add(bm);
    }
    await _save(items);
  }

  static Future<void> remove(String id) async {
    final items = await load();
    items.removeWhere((e) => e.id == id);
    await _save(items);
  }
}

/// Extracts a `UC…` channel id from a bare id or any URL containing
/// `/channel/UC…`. Returns null if none is found.
String? extractChannelId(String input) {
  final match = RegExp(r'UC[\w-]{22}').firstMatch(input.trim());
  return match?.group(0);
}
