import 'package:flutter/material.dart';
import '../services/audio_service.dart';
import '../services/api_service.dart';
import '../widgets/player_bar.dart';
import 'link_tab.dart';
import 'channel_tab.dart';
import 'downloaded_tab.dart';
import 'play_tab.dart';

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
  late final ApiService _api;

  @override
  void initState() {
    super.initState();
    _api = ApiService(widget.serverUrl, accessToken: widget.accessToken);
    _initAudio();
  }

  Future<void> _initAudio() async {
    final handler = await AudioManager.init();
    handler.setServerUrl(widget.serverUrl);
  }

  void _goToPlay() => setState(() => _currentIndex = 3);

  @override
  Widget build(BuildContext context) {
    final tabs = <Widget>[
      LinkTab(api: _api),
      const ChannelTab(),
      DownloadedTab(api: _api, onPlayTap: _goToPlay),
      const PlayTab(),
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
              ],
            ),
          ],
        ),
      ),
    );
  }
}
