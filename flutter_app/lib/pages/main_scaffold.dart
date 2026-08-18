import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/api_service.dart';
import '../services/back_interceptor.dart';
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

  // Tabs the user came from, most recent last — the Android back button walks
  // this instead of quitting the app (tabs live in an IndexedStack, so there are
  // no routes for the Navigator to pop).
  final List<int> _tabHistory = [];

  // How many tab hops back are remembered before the oldest is forgotten.
  static const int _maxTabHistory = 10;

  // Lets the Channel tab claim a back press while its detail view is open.
  final BackInterceptor _channelBack = BackInterceptor();

  static const int _channelTabIndex = 1;

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

  /// Switches tabs, remembering where we came from so back can return there.
  void _setTab(int index) {
    if (index == _currentIndex) return;
    setState(() {
      _tabHistory.add(_currentIndex);
      if (_tabHistory.length > _maxTabHistory) _tabHistory.removeAt(0);
      _currentIndex = index;
    });
  }

  /// Android back / predictive-back gesture. Gives the current tab's nested
  /// views (Channel detail, its search field) first refusal, then walks the tab
  /// history, and only leaves the app once there's nothing left to go back to.
  void _handleBack() {
    if (_currentIndex == _channelTabIndex && _channelBack.handleBack()) return;
    if (_tabHistory.isNotEmpty) {
      setState(() => _currentIndex = _tabHistory.removeLast());
      return;
    }
    SystemNavigator.pop();
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
        if (mounted) _setTab(_channelTabIndex);
        _openChannelRequest.value = url;
        break;
      case SharedLinkKind.unknown:
        if (mounted) _setTab(0);
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

  void _goToPlay() => _setTab(3);

  /// Switch to the Channel tab and open the given channel (id or name). Used by
  /// the Downloaded tab's "Open channel" action; reuses the shared channel-open
  /// request consumed by ChannelTab.
  void _openChannel(String idOrName) {
    _setTab(_channelTabIndex);
    _openChannelRequest.value = idOrName;
  }

  @override
  Widget build(BuildContext context) {
    final tabs = <Widget>[
      LinkTab(api: _api, onPlayTap: _goToPlay),
      ChannelTab(
        key: ValueKey('channel|$_serverUrl|$_accessToken'),
        api: _api,
        onPlayTap: _goToPlay,
        openRequest: _openChannelRequest,
        backInterceptor: _channelBack,
      ),
      DownloadedTab(
        api: _api,
        onPlayTap: _goToPlay,
        onOpenChannel: _openChannel,
      ),
      const PlayTab(),
      SettingsTab(
        initialUrl: _serverUrl,
        initialToken: _accessToken,
        onSave: _applyServerConfig,
      ),
    ];

    // canPop is false so every back press reaches _handleBack; it calls
    // SystemNavigator.pop() itself once there is nothing left to go back to.
    // Pushed routes (Queue page, bottom sheets) sit above this one and still pop
    // normally — PopScope only fires when this route is the top one.
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handleBack();
      },
      child: _buildScaffold(tabs),
    );
  }

  Widget _buildScaffold(List<Widget> tabs) {
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
              onDestinationSelected: _setTab,
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
