import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:you_audio/services/bookmark_service.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('new bookmarks are inserted at the top', () async {
    await BookmarkService.add(
        const ChannelBookmark(id: 'UC_old', name: 'Old'));
    await BookmarkService.add(
        const ChannelBookmark(id: 'UC_new', name: 'New'));

    final items = await BookmarkService.load();
    expect(items.map((e) => e.id).toList(), ['UC_new', 'UC_old']);
  });

  test('updating an existing bookmark keeps its position', () async {
    await BookmarkService.add(
        const ChannelBookmark(id: 'UC_a', name: 'A'));
    await BookmarkService.add(
        const ChannelBookmark(id: 'UC_b', name: 'B'));
    await BookmarkService.add(
        const ChannelBookmark(id: 'UC_a', name: 'A renamed'));

    final items = await BookmarkService.load();
    expect(items.map((e) => e.id).toList(), ['UC_b', 'UC_a']);
    expect(items.last.name, 'A renamed');
  });

  test('saveOrder persists a dragged list', () async {
    await BookmarkService.add(
        const ChannelBookmark(id: 'UC_a', name: 'A'));
    await BookmarkService.add(
        const ChannelBookmark(id: 'UC_b', name: 'B'));
    await BookmarkService.add(
        const ChannelBookmark(id: 'UC_c', name: 'C'));
    // Newest-first: C, B, A. Drag C to the bottom.
    await BookmarkService.saveOrder(const [
      ChannelBookmark(id: 'UC_b', name: 'B'),
      ChannelBookmark(id: 'UC_a', name: 'A'),
      ChannelBookmark(id: 'UC_c', name: 'C'),
    ]);

    final items = await BookmarkService.load();
    expect(items.map((e) => e.id).toList(), ['UC_b', 'UC_a', 'UC_c']);
  });
}
