import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:todo_app/domain/ordering.dart';

void main() {
  group('keyBetween', () {
    test('first key in an empty list', () {
      expect(keyBetween(null, null), isNotEmpty);
    });

    test('appending keeps ascending order', () {
      final keys = initialKeys(200);
      final sorted = [...keys]..sort();
      expect(keys, sorted);
      expect(keys.toSet().length, keys.length);
    });

    test('prepending repeatedly stays before the head', () {
      var head = keyBetween(null, null);
      for (var i = 0; i < 200; i++) {
        final next = keyBetween(null, head);
        expect(next.compareTo(head), lessThan(0), reason: '$next < $head');
        expect(next.endsWith('0'), isFalse);
        head = next;
      }
    });

    test('inserting between neighbours repeatedly', () {
      var lo = keyBetween(null, null);
      final hi = keyBetween(lo, null);
      for (var i = 0; i < 200; i++) {
        final mid = keyBetween(lo, hi);
        expect(lo.compareTo(mid), lessThan(0));
        expect(mid.compareTo(hi), lessThan(0));
        lo = mid;
      }
    });

    test('random inserts keep a total order', () {
      final rnd = Random(42);
      final keys = <String>[keyBetween(null, null)];
      for (var i = 0; i < 500; i++) {
        final at = rnd.nextInt(keys.length + 1);
        final k = keyBetween(
          at == 0 ? null : keys[at - 1],
          at == keys.length ? null : keys[at],
        );
        keys.insert(at, k);
      }
      expect(keys, [...keys]..sort());
      expect(keys.toSet().length, keys.length);
    });

    test('rejects out-of-order bounds', () {
      expect(() => keyBetween('b', 'a'), throwsArgumentError);
      expect(() => keyBetween('a', 'a'), throwsArgumentError);
    });
  });
}
