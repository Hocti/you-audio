import 'package:flutter/material.dart';
import '../services/api_service.dart';
import '../services/server_profiles.dart';

/// Settings tab: lets the user change the backend server URL and access token
/// after the initial setup. Values are pre-filled with the current config and
/// applied via [onSave].
class SettingsTab extends StatefulWidget {
  final String initialUrl;
  final String initialToken;

  /// Called when the user saves. Receives the trimmed URL and token.
  final void Function(String url, String token) onSave;

  const SettingsTab({
    super.key,
    required this.initialUrl,
    required this.initialToken,
    required this.onSave,
  });

  @override
  State<SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends State<SettingsTab> {
  late final TextEditingController _urlController;
  late final TextEditingController _tokenController;

  bool _testing = false;
  // Result of the last connection test: shown below the Test button.
  ({bool ok, String message})? _testResult;

  // Saved settings the user can switch between. `_currentIsSaved` decides
  // whether the small button offers Save or Delete.
  List<ServerProfile> _profiles = const [];
  bool _currentIsSaved = false;

  @override
  void initState() {
    super.initState();
    _urlController = TextEditingController(text: widget.initialUrl);
    _tokenController = TextEditingController(text: widget.initialToken);
    // Editing either field can change whether it matches a saved profile.
    _urlController.addListener(_refreshSavedState);
    _tokenController.addListener(_refreshSavedState);
    _loadProfiles();
  }

  @override
  void dispose() {
    _urlController.removeListener(_refreshSavedState);
    _tokenController.removeListener(_refreshSavedState);
    _urlController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  Future<void> _loadProfiles() async {
    final items = await ServerProfiles.load();
    if (!mounted) return;
    setState(() {
      _profiles = items;
      _currentIsSaved = _matchesSaved(items);
    });
  }

  bool _matchesSaved(List<ServerProfile> items) {
    final url = _urlController.text.trim();
    final token = _tokenController.text.trim();
    return items.any((p) => p.matches(url, token));
  }

  void _refreshSavedState() {
    final saved = _matchesSaved(_profiles);
    if (saved != _currentIsSaved && mounted) {
      setState(() => _currentIsSaved = saved);
    }
  }

  /// Save the two fields as a profile, or remove it if it is already saved.
  Future<void> _toggleSaveProfile() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) {
      _snack('Enter a server URL first');
      return;
    }
    final token = _tokenController.text.trim();
    final items = _currentIsSaved
        ? await ServerProfiles.remove(url, token)
        : await ServerProfiles.add(url, token);
    if (!mounted) return;
    final removed = _currentIsSaved;
    setState(() {
      _profiles = items;
      _currentIsSaved = _matchesSaved(items);
    });
    _snack(removed ? 'Setting deleted' : 'Setting saved');
  }

  /// Pick one of the saved settings and make it the active one.
  Future<void> _switchProfile() async {
    final items = await ServerProfiles.load();
    if (!mounted) return;
    setState(() => _profiles = items);

    if (items.isEmpty) {
      _snack('No saved settings yet — tap Save first');
      return;
    }

    final activeUrl = _urlController.text.trim();
    final activeToken = _tokenController.text.trim();

    final chosen = await showModalBottomSheet<ServerProfile>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Text('Saved settings',
                  style: Theme.of(ctx).textTheme.titleSmall),
            ),
            for (final p in items)
              ListTile(
                leading: Icon(p.matches(activeUrl, activeToken)
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked),
                title: Text(p.url, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(
                  p.token.isEmpty ? 'No token' : 'Token ••••${_tail(p.token)}',
                  style: Theme.of(ctx).textTheme.bodySmall,
                ),
                onTap: () => Navigator.pop(ctx, p),
              ),
          ],
        ),
      ),
    );
    if (chosen == null || !mounted) return;

    _urlController.text = chosen.url;
    _tokenController.text = chosen.token;
    _refreshSavedState();
    // "Switch" means switch — apply it, the same way Save & Reconnect does.
    widget.onSave(chosen.url, chosen.token);
    FocusScope.of(context).unfocus();
    _snack('Switched to ${chosen.url}');
  }

  /// Last few characters of a token, so a profile is recognisable without
  /// showing the secret.
  static String _tail(String token) =>
      token.length <= 4 ? token : token.substring(token.length - 4);

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  /// Probes /api/health with the *currently entered* URL/token (not the saved
  /// config) so the user can verify before saving.
  Future<void> _test() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) {
      setState(() => _testResult = (ok: false, message: 'Enter a server URL first'));
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _testing = true;
      _testResult = null;
    });

    final api = ApiService(url, accessToken: _tokenController.text.trim());
    final res = await api.checkHealth();
    if (!mounted) return;

    final ({bool ok, String message}) outcome;
    if (!res.reachable) {
      outcome = (
        ok: false,
        message: 'Server unreachable'
            '${res.statusCode != null ? ' (HTTP ${res.statusCode})' : ''}.',
      );
    } else if (res.tokenRequired && !res.tokenValid) {
      outcome = (ok: false, message: 'Server OK, but the access token is wrong.');
    } else if (res.tokenRequired) {
      outcome = (ok: true, message: 'Server OK and access token is valid.');
    } else {
      outcome = (ok: true, message: 'Server OK (no access token required).');
    }
    setState(() {
      _testing = false;
      _testResult = outcome;
    });
  }

  void _save() {
    final url = _urlController.text.trim();
    if (url.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a server URL')),
      );
      return;
    }
    final token = _tokenController.text.trim();
    widget.onSave(url, token);
    FocusScope.of(context).unfocus();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Server settings saved')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings'), centerTitle: true),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: ListView(
          children: [
            const SizedBox(height: 8),
            Text(
              'Backend Server',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              'Change the URL or access token of your You Audio backend.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 24),
            TextField(
              controller: _urlController,
              decoration: InputDecoration(
                labelText: 'Server URL',
                hintText: 'http://192.168.1.100:8000',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                prefixIcon: const Icon(Icons.link),
              ),
              keyboardType: TextInputType.url,
              onSubmitted: (_) => _save(),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _tokenController,
              decoration: InputDecoration(
                labelText: 'Access Token (optional)',
                hintText: 'Leave empty if no auth is set',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                prefixIcon: const Icon(Icons.lock_outline),
              ),
              obscureText: true,
              onSubmitted: (_) => _save(),
            ),
            const SizedBox(height: 24),
            OutlinedButton.icon(
              onPressed: _testing ? null : _test,
              icon: _testing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.wifi_tethering),
              label: Text(_testing ? 'Testing…' : 'Test'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(double.infinity, 52),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
            if (_testResult != null) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  Icon(
                    _testResult!.ok ? Icons.check_circle : Icons.error,
                    color: _testResult!.ok
                        ? Colors.green.shade400
                        : Theme.of(context).colorScheme.error,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _testResult!.message,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: _testResult!.ok
                                ? Colors.green.shade400
                                : Theme.of(context).colorScheme.error,
                          ),
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _save,
              icon: const Icon(Icons.check),
              label: const Text('Save & Reconnect'),
              style: FilledButton.styleFrom(
                minimumSize: const Size(double.infinity, 52),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
            const SizedBox(height: 8),
            // Saved settings: keep several servers/tokens and jump between them.
            // Save & Reconnect above still applies whatever is in the fields.
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _toggleSaveProfile,
                    icon: Icon(
                      _currentIsSaved
                          ? Icons.bookmark_remove_outlined
                          : Icons.bookmark_add_outlined,
                      size: 18,
                    ),
                    label: Text(_currentIsSaved ? 'Delete' : 'Save'),
                    style: _smallButtonStyle(context),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _switchProfile,
                    icon: const Icon(Icons.swap_horiz, size: 18),
                    label: Text(_profiles.isEmpty
                        ? 'Switch'
                        : 'Switch (${_profiles.length})'),
                    style: _smallButtonStyle(context),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  ButtonStyle _smallButtonStyle(BuildContext context) => OutlinedButton.styleFrom(
        minimumSize: const Size(0, 38),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        textStyle: Theme.of(context).textTheme.labelMedium,
        visualDensity: VisualDensity.compact,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      );
}
