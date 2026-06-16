import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/channel_video.dart';
import '../services/api_service.dart';
import '../services/audio_service.dart';
import '../services/bookmark_service.dart';
import '../services/download_manager.dart';
import '../services/local_library.dart';

/// Tab 2 — browse a YouTube channel's latest videos.
///
/// Two views:
///  - Paste view: a "Paste Channel ID" button plus a list of bookmarked channels.
///  - Detail view: the channel's latest videos, with back + bookmark toggle.
///    Tapping a video downloads it (or plays it if already on the device).
class ChannelTab extends StatefulWidget {
  final ApiService api;
  final VoidCallback onPlayTap;
  const ChannelTab({super.key, required this.api, required this.onPlayTap});

  @override
  State<ChannelTab> createState() => _ChannelTabState();
}

class _ChannelTabState extends State<ChannelTab> {
  String? _channelId; // null => paste view, set => detail view
  String? _channelName; // known name when entering from a bookmark
  String _pasteError = '';
  bool _resolving = false;
  List<ChannelBookmark> _bookmarks = [];

  @override
  void initState() {
    super.initState();
    _loadBookmarks();
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
      api: widget.api,
      channelId: _channelId!,
      initialName: _channelName,
      onBack: _back,
      onPlayTap: widget.onPlayTap,
    );
  }

  Widget _buildPasteView(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Channel'), centerTitle: true),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 8),
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
            Row(
              children: [
                Text('Bookmarked channels',
                    style: Theme.of(context).textTheme.titleSmall),
              ],
            ),
            const Divider(),
            Expanded(child: _buildBookmarkList(context)),
          ],
        ),
      ),
    );
  }

  Widget _buildBookmarkList(BuildContext context) {
    if (_bookmarks.isEmpty) {
      return Center(
        child: Text(
          'No bookmarks yet.\nOpen a channel and tap the star to save it.',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
          textAlign: TextAlign.center,
        ),
      );
    }
    return ListView.builder(
      itemCount: _bookmarks.length,
      itemBuilder: (context, index) {
        final bm = _bookmarks[index];
        return ListTile(
          leading: const Icon(Icons.star, color: Colors.amber),
          title: Text(bm.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(bm.id,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _enterDetail(bm.id, name: bm.name),
        );
      },
    );
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

  const _ChannelDetailView({
    required this.api,
    required this.channelId,
    required this.initialName,
    required this.onBack,
    required this.onPlayTap,
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

  @override
  void initState() {
    super.initState();
    _channelName = widget.initialName;
    _loadBookmarkState();
    _load();
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
        title: Text(_displayName, overflow: TextOverflow.ellipsis),
        actions: [
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

    // Rebuild as downloads progress/complete so row state/icons stay current.
    return ValueListenableBuilder<List<DownloadJob>>(
      valueListenable: DownloadManager.instance.jobs,
      builder: (context, jobs, _) => ListView.builder(
        itemCount: _videos.length,
        padding: const EdgeInsets.only(bottom: 8),
        itemBuilder: (context, index) =>
            _buildVideoTile(_videos[index], jobs),
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
      title: Text(video.title, maxLines: 2, overflow: TextOverflow.ellipsis),
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
    );
  }
}
