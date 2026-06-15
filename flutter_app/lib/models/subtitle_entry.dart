class SubtitleEntry {
  final Duration start;
  final Duration end;
  final String text;

  const SubtitleEntry({
    required this.start,
    required this.end,
    required this.text,
  });
}

List<SubtitleEntry> parseVtt(String vttContent) {
  final entries = <SubtitleEntry>[];
  final lines = vttContent.split('\n');
  int i = 0;

  // Skip WEBVTT header and any header blocks
  while (i < lines.length && !lines[i].contains('-->')) {
    i++;
  }

  while (i < lines.length) {
    final line = lines[i].trim();
    if (line.contains('-->')) {
      final arrow = line.indexOf('-->');
      final startStr = line.substring(0, arrow).trim();
      // End time may have positioning info after space (e.g., "00:00:05.000 align:start")
      final endPart = line.substring(arrow + 3).trim();
      final endStr = endPart.split(' ').first;

      final start = _parseTime(startStr);
      final end = _parseTime(endStr);
      i++;

      final textLines = <String>[];
      while (i < lines.length && lines[i].trim().isNotEmpty) {
        // Remove VTT tags: <c>, <00:00:00.000>, <b>, etc.
        final cleaned = lines[i].trim().replaceAll(RegExp(r'<[^>]+>'), '');
        if (cleaned.isNotEmpty) textLines.add(cleaned);
        i++;
      }

      if (textLines.isNotEmpty && start != end) {
        entries.add(SubtitleEntry(
          start: start,
          end: end,
          text: textLines.join(' '),
        ));
      }
    }
    i++;
  }
  return entries;
}

Duration _parseTime(String s) {
  // Supports HH:MM:SS.mmm or MM:SS.mmm
  final parts = s.trim().split(':');
  try {
    if (parts.length == 3) {
      final h = int.parse(parts[0]);
      final m = int.parse(parts[1]);
      final secParts = parts[2].split('.');
      final sec = int.parse(secParts[0]);
      final ms = secParts.length > 1
          ? int.parse(secParts[1].padRight(3, '0').substring(0, 3))
          : 0;
      return Duration(hours: h, minutes: m, seconds: sec, milliseconds: ms);
    } else if (parts.length == 2) {
      final m = int.parse(parts[0]);
      final secParts = parts[1].split('.');
      final sec = int.parse(secParts[0]);
      final ms = secParts.length > 1
          ? int.parse(secParts[1].padRight(3, '0').substring(0, 3))
          : 0;
      return Duration(minutes: m, seconds: sec, milliseconds: ms);
    }
  } catch (_) {}
  return Duration.zero;
}
