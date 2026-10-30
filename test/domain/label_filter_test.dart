import 'package:flutter_test/flutter_test.dart';
import 'package:todo_app/domain/label_filter.dart';

void main() {
  test('empty filter matches everything', () {
    const f = LabelFilter();
    expect(f.isActive, isFalse);
    expect(f.matches([]), isTrue);
    expect(f.matches(['x']), isTrue);
  });

  test('any matches tasks with at least one label', () {
    final f = const LabelFilter().toggle('a').toggle('b');
    expect(f.matches(['a']), isTrue);
    expect(f.matches(['c']), isFalse);
    expect(f.matches([]), isFalse);
  });

  test('all requires every selected label', () {
    final f = const LabelFilter()
        .toggle('a')
        .toggle('b')
        .withMatch(LabelMatch.all);
    expect(f.matches(['a', 'b', 'c']), isTrue);
    expect(f.matches(['a']), isFalse);
  });

  test('toggle removes an already-selected label', () {
    final f = const LabelFilter().toggle('a').toggle('a');
    expect(f.isActive, isFalse);
  });
}
