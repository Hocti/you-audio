import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import '../services/audio_service.dart';

class PlayerBar extends StatelessWidget {
  const PlayerBar({super.key});

  @override
  Widget build(BuildContext context) {
    if (!AudioManager.isInitialized) return const SizedBox.shrink();

    final handler = AudioManager.handler;
    final player = handler.player;

    return StreamBuilder<PlayerState>(
      stream: player.playerStateStream,
      builder: (context, snapshot) {
        final currentVideo = handler.currentVideo;
        if (currentVideo == null) return const SizedBox.shrink();

        final playerState = snapshot.data;
        final playing = playerState?.playing ?? false;

        return Container(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHigh,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.3),
                blurRadius: 8,
                offset: const Offset(0, -2),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
                // Progress bar
                StreamBuilder<Duration>(
                  stream: player.positionStream,
                  builder: (context, posSnap) {
                    final position = posSnap.data ?? Duration.zero;
                    final duration = player.duration ?? Duration.zero;
                    final progress = duration.inMilliseconds > 0
                        ? position.inMilliseconds / duration.inMilliseconds
                        : 0.0;

                    return Column(
                      children: [
                        SliderTheme(
                          data: SliderThemeData(
                            trackHeight: 3,
                            thumbShape: const RoundSliderThumbShape(
                              enabledThumbRadius: 6,
                            ),
                            overlayShape: const RoundSliderOverlayShape(
                              overlayRadius: 14,
                            ),
                            activeTrackColor:
                                Theme.of(context).colorScheme.primary,
                            inactiveTrackColor:
                                Theme.of(context).colorScheme.surfaceContainerHighest,
                            thumbColor:
                                Theme.of(context).colorScheme.primary,
                          ),
                          child: Slider(
                            value: progress.clamp(0.0, 1.0),
                            onChanged: (value) {
                              final newPosition = Duration(
                                milliseconds:
                                    (value * duration.inMilliseconds).round(),
                              );
                              player.seek(newPosition);
                            },
                          ),
                        ),
                        Padding(
                          padding:
                              const EdgeInsets.symmetric(horizontal: 16),
                          child: Row(
                            mainAxisAlignment:
                                MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                _formatDuration(position),
                                style: Theme.of(context)
                                    .textTheme
                                    .bodySmall
                                    ?.copyWith(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurfaceVariant,
                                    ),
                              ),
                              Text(
                                _formatDuration(duration),
                                style: Theme.of(context)
                                    .textTheme
                                    .bodySmall
                                    ?.copyWith(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurfaceVariant,
                                    ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    );
                  },
                ),
                // Controls row
                Padding(
                  padding:
                      const EdgeInsets.only(left: 12, right: 12, bottom: 8),
                  child: Row(
                    children: [
                      // Title (scrolling)
                      Expanded(
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Text(
                            currentVideo.title,
                            style: Theme.of(context)
                                .textTheme
                                .bodyMedium
                                ?.copyWith(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurface,
                                ),
                            maxLines: 1,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      // -30s
                      IconButton(
                        icon: const Icon(Icons.replay_30),
                        iconSize: 28,
                        onPressed: () => handler.skipToPrevious(),
                        tooltip: 'Back 30s',
                      ),
                      // Play/Pause
                      IconButton(
                        icon: Icon(
                          playing
                              ? Icons.pause_circle_filled
                              : Icons.play_circle_filled,
                        ),
                        iconSize: 40,
                        color: Theme.of(context).colorScheme.primary,
                        onPressed: () {
                          if (playing) {
                            handler.pause();
                          } else {
                            handler.play();
                          }
                        },
                      ),
                      // +30s
                      IconButton(
                        icon: const Icon(Icons.forward_30),
                        iconSize: 28,
                        onPressed: () => handler.skipToNext(),
                        tooltip: 'Forward 30s',
                      ),
                      // Next track
                      IconButton(
                        icon: const Icon(Icons.skip_next),
                        iconSize: 28,
                        onPressed: () => handler.playNextUnplayed(),
                        tooltip: 'Next track',
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  String _formatDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    if (h > 0) {
      return '${h}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '${m}:${s.toString().padLeft(2, '0')}';
  }
}
