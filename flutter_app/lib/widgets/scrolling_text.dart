import 'package:flutter/material.dart';

/// A single-line text that the user can scroll horizontally when it overflows.
///
/// Video titles are often very long; instead of truncating with an ellipsis we
/// let the user drag the title sideways to read the rest. When the text fits,
/// it behaves like a normal [Text].
class ScrollingText extends StatelessWidget {
  final String text;
  final TextStyle? style;

  const ScrollingText(this.text, {super.key, this.style});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      // Keep the gesture from fighting the parent vertical list when the title
      // already fits; clamping avoids an overscroll glow on short titles.
      physics: const ClampingScrollPhysics(),
      child: Text(text, maxLines: 1, softWrap: false, style: style),
    );
  }
}
