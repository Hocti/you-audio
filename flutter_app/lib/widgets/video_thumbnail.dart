import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

/// The one thumbnail used by every video list (Channel, Downloaded, Up Next):
/// image, a length badge in the bottom-left corner, and a red listen-progress
/// bar along the bottom edge.
class VideoThumbnail extends StatelessWidget {
  static const double width = 80;
  static const double height = 56;

  /// Local file (preferred when it exists) and/or a network URL fallback.
  final String? filePath;
  final String? networkUrl;

  /// Text for the bottom-left badge (e.g. `12:34`, `LIVE`, `SOON`); null hides it.
  final String? badge;
  final Color? badgeColor;

  /// 0..1 fraction played; null or 0 hides the bar.
  final double? progress;

  /// Icon shown when there's no image (or while it loads / fails).
  final IconData placeholderIcon;
  final Color? placeholderColor;

  const VideoThumbnail({
    super.key,
    this.filePath,
    this.networkUrl,
    this.badge,
    this.badgeColor,
    this.progress,
    this.placeholderIcon = Icons.music_note,
    this.placeholderColor,
  });

  @override
  Widget build(BuildContext context) {
    final placeholder = ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Center(
        child: Icon(placeholderIcon, size: 24, color: placeholderColor),
      ),
    );

    Widget image = placeholder;
    final file = filePath == null ? null : File(filePath!);
    if (file != null && file.existsSync()) {
      image = Image.file(file, fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => placeholder);
    } else if (networkUrl != null) {
      image = CachedNetworkImage(
        imageUrl: networkUrl!,
        fit: BoxFit.cover,
        placeholder: (_, __) => placeholder,
        errorWidget: (_, __, ___) => placeholder,
      );
    }

    final p = progress;
    final showBar = p != null && p > 0;
    const barHeight = 3.0;

    return SizedBox(
      width: width,
      height: height,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Stack(
          children: [
            Positioned.fill(child: image),
            if (badge != null)
              Positioned(
                left: 4,
                bottom: showBar ? barHeight + 3 : 4,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  decoration: BoxDecoration(
                    color: badgeColor ?? Colors.black87,
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: Text(
                    badge!,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      height: 1.15,
                      letterSpacing: 0.2,
                    ),
                  ),
                ),
              ),
            if (showBar)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: barHeight,
                child: ColoredBox(
                  color: Colors.white24,
                  child: FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: p.clamp(0.0, 1.0),
                    child: const ColoredBox(color: Colors.red),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
