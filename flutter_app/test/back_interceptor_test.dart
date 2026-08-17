import 'package:flutter_test/flutter_test.dart';
import 'package:you_audio/services/back_interceptor.dart';

void main() {
  test('an unclaimed back press is not consumed', () {
    expect(BackInterceptor().handleBack(), isFalse);
  });

  test('the registered handler decides whether the press is consumed', () {
    final interceptor = BackInterceptor();
    var calls = 0;
    var consume = true;
    interceptor.register(() {
      calls++;
      return consume;
    });

    expect(interceptor.handleBack(), isTrue);
    consume = false;
    expect(interceptor.handleBack(), isFalse);
    expect(calls, 2);
  });

  test('unregister only clears its own handler', () {
    final interceptor = BackInterceptor();
    bool oldHandler() => false;
    bool newHandler() => true;

    interceptor.register(oldHandler);
    interceptor.register(newHandler);
    // The old view is disposed *after* its replacement registered — it must not
    // take the live handler down with it.
    interceptor.unregister(oldHandler);
    expect(interceptor.handleBack(), isTrue);

    interceptor.unregister(newHandler);
    expect(interceptor.handleBack(), isFalse);
  });
}
