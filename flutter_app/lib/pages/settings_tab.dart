import 'package:flutter/material.dart';

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

  @override
  void initState() {
    super.initState();
    _urlController = TextEditingController(text: widget.initialUrl);
    _tokenController = TextEditingController(text: widget.initialToken);
  }

  @override
  void dispose() {
    _urlController.dispose();
    _tokenController.dispose();
    super.dispose();
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
              'Change the URL or access token of your YouTube Audio backend.',
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
          ],
        ),
      ),
    );
  }
}
