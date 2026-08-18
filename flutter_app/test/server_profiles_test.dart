import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:you_audio/services/server_profiles.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('starts empty', () async {
    expect(await ServerProfiles.load(), isEmpty);
    expect(await ServerProfiles.contains('http://a', 't'), isFalse);
  });

  test('add then contains, and load returns it', () async {
    await ServerProfiles.add('http://nas:8000', 'tok1');

    expect(await ServerProfiles.contains('http://nas:8000', 'tok1'), isTrue);
    final items = await ServerProfiles.load();
    expect(items, hasLength(1));
    expect(items.single.url, 'http://nas:8000');
    expect(items.single.token, 'tok1');
  });

  test('add trims whitespace and ignores an exact duplicate', () async {
    await ServerProfiles.add('  http://nas:8000  ', ' tok1 ');
    await ServerProfiles.add('http://nas:8000', 'tok1');

    final items = await ServerProfiles.load();
    expect(items, hasLength(1));
    expect(items.single.url, 'http://nas:8000');
  });

  test('same server with a different token is a separate profile', () async {
    await ServerProfiles.add('http://nas:8000', 'admin-token');
    await ServerProfiles.add('http://nas:8000', 'user-token');

    expect(await ServerProfiles.load(), hasLength(2));
    // Which matters: the two tokens grant different access.
    expect(await ServerProfiles.contains('http://nas:8000', 'admin-token'), isTrue);
    expect(await ServerProfiles.contains('http://nas:8000', 'other'), isFalse);
  });

  test('remove takes out only the matching pair', () async {
    await ServerProfiles.add('http://nas:8000', 'a');
    await ServerProfiles.add('http://local:8000', 'b');

    final left = await ServerProfiles.remove('http://nas:8000', 'a');
    expect(left, hasLength(1));
    expect(left.single.url, 'http://local:8000');
    expect(await ServerProfiles.contains('http://nas:8000', 'a'), isFalse);
  });

  test('an empty token is a valid profile', () async {
    await ServerProfiles.add('http://open:8000', '');
    expect(await ServerProfiles.contains('http://open:8000', ''), isTrue);
  });

  test('corrupt stored json is treated as empty, not thrown', () async {
    SharedPreferences.setMockInitialValues({'server_profiles': 'not json'});
    expect(await ServerProfiles.load(), isEmpty);
  });

  test('entries without a url are dropped on load', () async {
    SharedPreferences.setMockInitialValues({
      'server_profiles': '[{"url":"","token":"x"},{"url":"http://ok","token":"y"}]',
    });
    final items = await ServerProfiles.load();
    expect(items, hasLength(1));
    expect(items.single.url, 'http://ok');
  });
}
