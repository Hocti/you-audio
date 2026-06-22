import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/api_service.dart';
import '../services/download_manager.dart';
import '../services/download_foreground_service.dart';
import '../services/share_handler.dart';
import '../widgets/player_bar.dart';
import 'link_tab.dart';
import 'channel_tab.dart';
import 'downloaded_tab.dart';
import 'play_tab.dart';
import 'settings_tab.dart';

class MainScaffold extends StatefulWidget {
  final String serverUrl;
  final String accessToken;

  const MainScaffold({
    super.key,
    required this.serverUrl,
    required this.accessToken,
  });

  @override
  State<MainScaffold> createState() => _MainScaffoldState();
}

class _MainScaffoldState extends State<MainScaffold> {
  int _currentIndex = 0;
  late ApiService _api;
  late String _serverUrl;
  late String _accessToken;

  // Carries a shared channel link/id to the Channel tab to open its detail view.
  final ValueNotifier<String?> _openChannelRequest = ValueNotifier<String?>(null);

  @override
  void initState() {
    super.initState();
    _serverUrl = widget.serverUrl;
    _accessToken = widget.accessToken;
    _api = ApiService(_serverUrl, accessToken: _accessToken);

    // Bridge OS share intents. A shared video downloads in the background; a
    // shared channel opens its detail page.
    ShareHandler.instance.init();
    ShareHandler.instance.onShare = _handleShare;

    // Ask for notification permission so the background-download foreground
    // service can post its ongoing notification (Android 13+).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      DownloadForegroundService.requestPermission();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final initial = await ShareHandler.instance.getInitial();
      debugPrint('[SHARE] getInitial() returned: ${initial ?? "(null)"}');
      if (initial != null) _handleShare(initial);
    });
  }

  @override
  void dispose() {
    ShareHandler.instance.onShare = null;
    _openChannelRequest.dispose();
    super.dispose();
  }

  void _handleShare(String text) {
    final url = firstUrl(text) ?? text.trim();
    final kind = classifyUrl(url);
    debugPrint('[SHARE] _handleShare text="$text" url="$url" kind=$kind');
    switch (kind) {
      case SharedLinkKind.video:
        // Fire-and-forget download, then drop to the background so the user
        // stays in the app they shared from.
        DownloadManager.instance.start(_api, url);
        ShareHandler.instance.moveToBackground();
        break;
      case SharedLinkKind.channel:
        if (mounted) setState(() => _currentIndex = 1);
        _openChannelRequest.value = url;
        break;
      case SharedLinkKind.unknown:
        if (mounted) setState(() => _currentIndex = 0);
        break;
    }
  }

  Future<void> _applyServerConfig(String url, String token) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('server_url', url);
    await prefs.setString('access_token', token);

    if (!mounted) return;
    setState(() {
      _serverUrl = url;
      _accessToken = token;
      _api = ApiService(_serverUrl, accessToken: _accessToken);
    });
  }

  void _goToPlay() => setState(() => _currentIndex = 3);

  @override
  Widget build(BuildContext context) {
    final tabs = <Widget>[
      LinkTab(api: _api),
      ChannelTab(
        key: ValueKey('channel|$_serverUrl|$_accessToken'),
        api: _api,
        onPlayTap: _goToPlay,
        openRequest: _openChannelRequest,
      ),
      DownloadedTab(onPlayTap: _goToPlay),
      const PlayTab(),
      SettingsTab(
        initialUrl: _serverUrl,
        initialToken: _accessToken,
        onSave: _applyServerConfig,
      ),
    ];

    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: tabs,
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const PlayerBar(),
            NavigationBar(
              selectedIndex: _currentIndex,
              onDestinationSelected: (i) => setState(() => _currentIndex = i),
              destinations: const [
                NavigationDestination(icon: Icon(Icons.link), label: 'Link'),
                NavigationDestination(icon: Icon(Icons.subscriptions), label: 'Channel'),
                NavigationDestination(icon: Icon(Icons.library_music), label: 'Downloaded'),
                NavigationDestination(icon: Icon(Icons.play_circle), label: 'Play'),
                NavigationDestination(icon: Icon(Icons.settings), label: 'Settings'),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
