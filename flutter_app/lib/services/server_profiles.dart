import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// A saved backend configuration: server URL plus its access token.
class ServerProfile {
  final String url;
  final String token;

  const ServerProfile({required this.url, required this.token});

  /// Two profiles are the same setting when both halves match — the same server
  /// with a different token is a different profile (e.g. admin vs a plain user).
  bool matches(String otherUrl, String otherToken) =>
      url == otherUrl.trim() && token == otherToken.trim();

  Map<String, dynamic> toJson() => {'url': url, 'token': token};

  factory ServerProfile.fromJson(Map<String, dynamic> j) => ServerProfile(
        url: (j['url'] as String?) ?? '',
        token: (j['token'] as String?) ?? '',
      );
}

/// Saved server settings the user can switch between, in SharedPreferences.
///
/// Separate from the `server_url` / `access_token` keys, which stay the single
/// source of truth for the *active* configuration — this is only a shortlist to
/// pick from, so nothing here changes how the app connects.
class ServerProfiles {
  static const _key = 'server_profiles';

  /// Always returns a **growable** list — [add] and [remove] mutate it, and a
  /// `const []` here made saving the very first profile throw
  /// "Cannot add to an unmodifiable list".
  static Future<List<ServerProfile>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return <ServerProfile>[];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((j) => ServerProfile.fromJson(j as Map<String, dynamic>))
          .where((p) => p.url.isNotEmpty)
          .toList();
    } catch (_) {
      return <ServerProfile>[];
    }
  }

  static Future<void> _save(List<ServerProfile> items) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _key, jsonEncode(items.map((e) => e.toJson()).toList()));
  }

  /// True when this exact url+token pair is already saved.
  static Future<bool> contains(String url, String token) async {
    return (await load()).any((p) => p.matches(url, token));
  }

  /// Saves the pair, ignoring an exact duplicate. Returns the new list.
  static Future<List<ServerProfile>> add(String url, String token) async {
    final items = await load();
    if (items.any((p) => p.matches(url, token))) return items;
    items.add(ServerProfile(url: url.trim(), token: token.trim()));
    await _save(items);
    return items;
  }

  /// Removes the pair if present. Returns the new list.
  static Future<List<ServerProfile>> remove(String url, String token) async {
    final items = await load();
    items.removeWhere((p) => p.matches(url, token));
    await _save(items);
    return items;
  }
}
