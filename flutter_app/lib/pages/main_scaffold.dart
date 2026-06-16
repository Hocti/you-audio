import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/api_service.dart';
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

  @override
  void initState() {
    super.initState();
    _serverUrl = widget.serverUrl;
    _accessToken = widget.accessToken;
    _api = ApiService(_serverUrl, accessToken: _accessToken);
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
