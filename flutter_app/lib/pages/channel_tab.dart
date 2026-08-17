import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/channel_video.dart';
import '../services/api_service.dart';
import '../services/audio_service.dart';
import '../services/back_interceptor.dart';
import '../services/bookmark_service.dart';
import '../services/download_manager.dart';
import '../services/local_library.dart';
import '../widgets/scrolling_text.dart';
import '../widgets/video_actions.dart';

/// Tab 2 — browse a YouTube channel's latest videos.
///
/// Two views:
///  - Paste view: a "Paste Channel ID" button plus a list of bookmarked channels.
///  - Detail view: the channel's latest videos, with back + bookmark toggle.
///    Tapping a video downloads it (or plays it if already on the device).
class ChannelTab extends StatefulWidget {
  final ApiService api;
  final VoidCallback onPlayTap;

  /// Set by the host (e.g. a shared channel link) to open a channel's detail
  /// view from outside this tab. The value is a channel id or any channel URL;
  /// it is resolved like a pasted channel. Consumed (reset to null) once handled.
  final ValueNotifier<String?>? openRequest;

  /// Host-owned hook for the Android back gesture: this tab consumes it while a
  /// channel detail view (or its search field) is open.
  final BackInterceptor? backInterceptor;

  const ChannelTab({
    super.key,
    required this.api,
    required this.onPlayTap,
    this.openRequest,
    this.backInterceptor,
  });

  @override
  State<ChannelTab> createState() => _ChannelTabState();
}

class _ChannelTabState extends State<ChannelTab> {
  String? _channelId; // null => paste view, set => detail view
  String? _channelName; // known name when entering from a bookmark
  String _pasteError = '';
  bool _resolving = false;
  List<ChannelBookmark> _bookmarks = [];

  /// Back-press hook the detail view registers itself with, so it can close its
  /// search field before we leave the detail view entirely.
  final BackInterceptor _detailBack = BackInterceptor();

  @override
  void initState() {
    super.initState();
    _loadBookmarks();
    widget.backInterceptor?.register(_handleBack);
    widget.openRequest?.addListener(_onOpenRequest);
    // Handle a request that was set before this tab was built.
    if (widget.openRequest?.value != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _onOpenRequest());
    }
  }

  @override
  void dispose() {
    widget.backInterceptor?.unregister(_handleBack);
    widget.openRequest?.removeListener(_onOpenRequest);
    super.dispose();
  }

  /// Android back inside this tab: close the detail view's search, else return
  /// from the detail view to the channel list. False = nothing to go back to,
  /// so the host decides (switch tabs / leave the app).
  bool _handleBack() {
    if (_detailBack.handleBack()) return true;
    if (_channelId != null) {
      _back();
      return true;
    }
    return false;
  }

  void _onOpenRequest() {
    final raw = widget.openRequest?.value;
    if (raw == null || !mounted) return;
    widget.openRequest!.value = null; // consume (re-fires listener with null)
    _openFromInput(raw);
  }

  Future<void> _loadBookmarks() async {
    final items = await BookmarkService.load();
    if (mounted) setState(() => _bookmarks = items);
  }

  Future<void> _pasteChannelId() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final raw = data?.text?.trim() ?? '';
    if (raw.isEmpty) {
      setState(() => _pasteError = 'Clipboard is empty');
      return;
    }
    await _openFromInput(raw);
  }

  /// Opens the detail view for a channel id or URL, resolving via the backend
  /// when it isn't a bare/embedded UC… id. Shared by the paste button and
  /// external [ChannelTab.openRequest] requests.
  Future<void> _openFromInput(String raw) async {
    raw = raw.trim();
    if (raw.isEmpty) return;
    // Fast path: a bare/embedded UC… id needs no backend call.
    final localId = extractChannelId(raw);
    if (localId != null) {
      _enterDetail(localId);
      return;
    }
    // Otherwise ask the backend to resolve a URL / @handle / username.
    setState(() {
      _pasteError = '';
      _resolving = true;
    });
    try {
      final res = await widget.api.resolveChannel(raw);
      if (!mounted) return;
      setState(() => _resolving = false);
      _enterDetail(res.id, name: res.name);
    } catch (e) {
      if (!mounted) return;
      final msg = e.toString().contains('404')
          ? "Couldn't find that channel."
          : 'Could not resolve channel (check server / token).';
      setState(() {
        _resolving = false;
        _pasteError = msg;
      });
    }
  }

  void _enterDetail(String id, {String? name}) {
    setState(() {
      _pasteError = '';
      _channelId = id;
      _channelName = name;
    });
  }

  void _back() {
    setState(() {
      _channelId = null;
      _channelName = null;
    });
    _loadBookmarks(); // reflect any bookmark changes made in the detail view
  }

  @override
  Widget build(BuildContext context) {
    if (_channelId == null) {
      return _buildPasteView(context);
    }
    return _ChannelDetailView(
      key: ValueKey(_channelId),
      api: widget.api,
      channelId: _channelId!,
      initialName: _channelName,
      onBack: _back,
      onPlayTap: widget.onPlayTap,
      backInterceptor: _detailBack,
    );
  }

  Widget _buildPasteView(BuildContext context) {
    // One scroll view: the paste header scrolls away with the bookmark list, so
    // on small screens the header doesn't permanently occupy the top half.
    return Scaffold(
      appBar: AppBar(title: const Text('Channel'), centerTitle: true),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
        children: [
          Icon(Icons.subscriptions_outlined, size: 56,
              color: Theme.of(context).colorScheme.primary),
          const SizedBox(height: 12),
          Text(
            'Paste a channel ID, a /channel/ URL, or an @handle URL',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _resolving ? null : _pasteChannelId,
            icon: _resolving
                ? const SizedBox(
                    width: 18, height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.content_paste),
            label: Text(_resolving ? 'Resolving…' : 'Paste Channel'),
            style: FilledButton.styleFrom(
              minimumSize: const Size(double.infinity, 52),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
          if (_pasteError.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              _pasteError,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.error,
                  ),
              textAlign: TextAlign.center,
            ),
          ],
          const SizedBox(height: 24),
          Text('Bookmarked channels',
              style: Theme.of(context).textTheme.titleSmall),
          const Divider(),
          ..._buildBookmarkItems(context),
        ],
      ),
    );
  }

  /// Bookmark rows (or an empty-state message) for the scrollable paste view.
  List<Widget> _buildBookmarkItems(BuildContext context) {
    if (_bookmarks.isEmpty) {
      return [
        Padding(
          padding: const EdgeInsets.only(top: 32),
          child: Text(
            'No bookmarks yet.\nOpen a channel and tap the star to save it.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
            textAlign: TextAlign.center,
          ),
        ),
      ];
    }
    return _bookmarks.map((bm) {
      return ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.star, color: Colors.amber),
        title: Text(bm.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(bm.id,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => _enterDetail(bm.id, name: bm.name),
      );
    }).toList();
  }
}

/// Per-row state for a channel video.
enum _RowState { playing, downloaded, downloading, error, none }

class _ChannelDetailView extends StatefulWidget {
  final ApiService api;
  final String channelId;
  final String? initialName;
  final VoidCallback onBack;
  final VoidCallback onPlayTap;
  final BackInterceptor backInterceptor;

  const _ChannelDetailView({
    super.key,
    required this.api,
    required this.channelId,
    required this.initialName,
    required this.onBack,
    required this.onPlayTap,
    required this.backInterceptor,
  });

  @override
  State<_ChannelDetailView> createState() => _ChannelDetailViewState();
}

class _ChannelDetailViewState extends State<_ChannelDetailView> {
  List<ChannelVideo> _videos = [];
  bool _loading = true;
  String? _error;
  bool _bookmarked = false;
  String? _channelName; // resolved from results

  // Title search within the channel's videos.
  bool _searching = false;
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _channelName = widget.initialName;
    widget.backInterceptor.register(_handleBack);
    _loadBookmarkState();
    _load();
  }

  @override
  void dispose() {
    widget.backInterceptor.unregister(_handleBack);
    _searchController.dispose();
    super.dispose();
  }

  /// Back closes an open search field. Leaving the channel is the parent's job.
  bool _handleBack() {
    if (_searching) {
      _toggleSearch();
      return true;
    }
    return false;
  }

  void _toggleSearch() {
    setState(() {
      if (_searching) {
        _searching = false;
        _searchQuery = '';
        _searchController.clear();
      } else {
        _searching = true;
      }
    });
  }

  List<ChannelVideo> get _displayVideos {
    final q = _searchQuery.trim().toLowerCase();
    if (q.isEmpty) return _videos;
    return _videos.where((v) => v.title.toLowerCase().contains(q)).toList();
  }

  Future<void> _loadBookmarkState() async {
    final b = await BookmarkService.isBookmarked(widget.channelId);
    if (mounted) setState(() => _bookmarked = b);
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      await LocalLibrary.ensureInitialized();
      final videos = await widget.api.getChannelVideos(widget.channelId);
      if (mounted) {
        setState(() {
          _videos = videos;
          _channelName ??= videos.isNotEmpty ? videos.first.channelName : null;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _loading = false; });
    }
  }

  String get _displayName =>
      _channelName ?? widget.initialName ?? widget.channelId;

  Future<void> _toggleBookmark() async {
    if (_bookmarked) {
      await BookmarkService.remove(widget.channelId);
    } else {
      await BookmarkService.add(
          ChannelBookmark(id: widget.channelId, name: _displayName));
    }
    if (mounted) setState(() => _bookmarked = !_bookmarked);
  }

  DownloadJob? _jobFor(String videoId, List<DownloadJob> jobs) {
    for (final j in jobs) {
      if (j.youtubeId == videoId) return j;
    }
    return null;
  }

  _RowState _stateFor(String videoId, List<DownloadJob> jobs) {
    if (AudioManager.isInitialized &&
        AudioManager.handler.currentVideo?.youtubeId == videoId) {
      return _RowState.playing;
    }
    if (LocalLibrary.contains(videoId)) return _RowState.downloaded;
    final job = _jobFor(videoId, jobs);
    if (job != null) {
      return job.stage == DownloadStage.error
          ? _RowState.error
          : _RowState.downloading;
    }
    return _RowState.none;
  }

  Future<void> _onTapVideo(ChannelVideo video, _RowState state) async {
    switch (state) {
      case _RowState.playing:
        widget.onPlayTap();
        break;
      case _RowState.downloaded:
        await _play(video.videoId);
        break;
      case _RowState.none:
      case _RowState.error:
        DownloadManager.instance
            .start(widget.api, 'https://www.youtube.com/watch?v=${video.videoId}');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Downloading "${video.title}"…')),
          );
          setState(() {});
        }
        break;
      case _RowState.downloading:
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Already downloading…')),
          );
        }
        break;
    }
  }

  Future<void> _play(String videoId) async {
    final lv = LocalLibrary.get(videoId);
    if (lv == null || !AudioManager.isInitialized) return;
    final handler = AudioManager.handler;
    handler.setPlaylist(LocalLibrary.all().map((e) => e.toVideo()).toList());
    try {
      await handler.playVideo(lv.toVideo());
      widget.onPlayTap();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Playback failed: $e')),
        );
      }
    }
  }

  String _friendlyError(String raw) {
    if (raw.contains('401') || raw.contains('403')) {
      return 'Authentication failed — check your access token in Settings.';
    }
    if (raw.contains('404')) return 'Channel not found. Check the channel ID.';
    if (raw.contains('500')) {
      return 'Server is missing a YouTube API key (YOUTUBE_API_KEY).';
    }
    if (raw.contains('502')) {
      return 'YouTube API error — quota may be exhausted or the key is invalid.';
    }
    if (raw.contains('SocketException') ||
        raw.contains('Connection') ||
        raw.contains('Failed host lookup') ||
        raw.contains('timed out')) {
      return "Can't reach the server at ${widget.api.serverUrl}.";
    }
    return 'Something went wrong loading this channel.';
  }

  Widget _trailingFor(_RowState state, DownloadJob? job) {
    switch (state) {
      case _RowState.playing:
        return Icon(Icons.equalizer,
            color: Theme.of(context).colorScheme.primary);
      case _RowState.downloaded:
        return Icon(Icons.download_done, color: Colors.green.shade400);
      case _RowState.downloading:
        return const SizedBox(
          width: 22, height: 22,
          child: CircularProgressIndicator(strokeWidth: 2),
        );
      case _RowState.error:
        return Icon(Icons.error_outline,
            color: Theme.of(context).colorScheme.error);
      case _RowState.none:
        return Icon(Icons.download_outlined,
            color: Theme.of(context).colorScheme.onSurfaceVariant);
    }
  }

  String _formatDate(String? iso) {
    if (iso == null) return '';
    final dt = DateTime.tryParse(iso);
    if (dt == null) return '';
    final local = dt.toLocal();
    return '${local.year}-${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: widget.onBack,
          tooltip: 'Back',
        ),
        title: _searching
            ? TextField(
                controller: _searchController,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: 'Filter by title…',
                  border: InputBorder.none,
                ),
                onChanged: (v) => setState(() => _searchQuery = v),
              )
            : Text(_displayName, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            icon: Icon(_searching ? Icons.close : Icons.search),
            tooltip: _searching ? 'Close search' : 'Search',
            onPressed: _toggleSearch,
          ),
          if (!_searching)
            IconButton(
              icon: Icon(_bookmarked ? Icons.star : Icons.star_border,
                  color: _bookmarked ? Colors.amber : null),
              onPressed: _toggleBookmark,
              tooltip: _bookmarked ? 'Remove bookmark' : 'Bookmark channel',
            ),
        ],
      ),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.error_outline, size: 48,
                  color: Theme.of(context).colorScheme.error),
              const SizedBox(height: 16),
              Text('Failed to load channel',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Text(_friendlyError(_error!),
                  style: Theme.of(context).textTheme.bodyMedium,
                  textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _load,
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    if (_videos.isEmpty) {
      return const Center(child: Text('No videos found for this channel'));
    }

    final videos = _displayVideos;
    if (videos.isEmpty) {
      return const Center(child: Text('No videos match your search'));
    }

    // Rebuild as downloads progress/complete so row state/icons stay current.
    return ValueListenableBuilder<List<DownloadJob>>(
      valueListenable: DownloadManager.instance.jobs,
      builder: (context, jobs, _) => ListView.builder(
        itemCount: videos.length,
        padding: const EdgeInsets.only(bottom: 8),
        itemBuilder: (context, index) =>
            _buildVideoTile(videos[index], jobs),
      ),
    );
  }

  Widget _buildVideoTile(ChannelVideo video, List<DownloadJob> jobs) {
    final state = _stateFor(video.videoId, jobs);
    final job = _jobFor(video.videoId, jobs);
    return ListTile(
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(
          width: 80, height: 56,
          child: video.thumbnailUrl == null
              ? Container(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  child: const Icon(Icons.music_note, size: 24),
                )
              : CachedNetworkImage(
                  imageUrl: video.thumbnailUrl!,
                  fit: BoxFit.cover,
                  placeholder: (_, __) => Container(
                    color: Theme.of(context).colorScheme.surfaceContainerHighest,
                    child: const Icon(Icons.music_note, size: 24),
                  ),
                  errorWidget: (_, __, ___) => Container(
                    color: Theme.of(context).colorScheme.surfaceContainerHighest,
                    child: const Icon(Icons.music_note, size: 24),
                  ),
                ),
        ),
      ),
      title: ScrollingText(video.title),
      subtitle: Text(
        state == _RowState.error && job != null
            ? 'Download failed — tap to retry'
            : _formatDate(video.publishedAt),
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: state == _RowState.error
                  ? Theme.of(context).colorScheme.error
                  : Theme.of(context).colorScheme.onSurfaceVariant,
            ),
      ),
      trailing: _trailingFor(state, job),
      onTap: () => _onTapVideo(video, state),
      onLongPress: () => _showContextMenu(video, state),
    );
  }

  void _showContextMenu(ChannelVideo video, _RowState state) {
    final alreadyHere = state == _RowState.downloaded ||
        state == _RowState.downloading ||
        state == _RowState.playing;
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!alreadyHere)
              ListTile(
                leading: const Icon(Icons.download_outlined),
                title: const Text('Download audio'),
                onTap: () {
                  Navigator.pop(ctx);
                  _onTapVideo(video, _RowState.none);
                },
              ),
            ListTile(
              leading: const Icon(Icons.content_copy),
              title: const Text('Copy YouTube link'),
              onTap: () {
                Navigator.pop(ctx);
                copyYoutubeLink(context, video.videoId);
              },
            ),
            ListTile(
              leading: const Icon(Icons.open_in_new),
              title: const Text('Open in YouTube'),
              onTap: () {
                Navigator.pop(ctx);
                openInYouTube(context, video.videoId);
              },
            ),
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('Detail'),
              onTap: () {
                Navigator.pop(ctx);
                _showDetail(video);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showDetail(ChannelVideo video) {
    showVideoDetailSheet(
      context,
      title: video.title,
      rows: [
        ('Channel', video.channelName),
        ('Video ID', video.videoId),
        if (video.publishedAt != null)
          ('Published', _formatDate(video.publishedAt)),
      ],
    );
  }
}
