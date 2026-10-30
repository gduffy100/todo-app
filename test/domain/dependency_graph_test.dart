import 'package:flutter_test/flutter_test.dart';
import 'package:todo_app/domain/dependency_graph.dart';

void main() {
  test('self dependency is a cycle', () {
    expect(wouldCreateCycle({}, 'a', 'a'), isTrue);
  });

  test('direct back-edge is a cycle', () {
    // b depends on a; making a depend on b closes the loop.
    expect(
      wouldCreateCycle(
        {
          'b': {'a'},
        },
        'a',
        'b',
      ),
      isTrue,
    );
  });

  test('transitive back-edge is a cycle', () {
    final g = {
      'c': {'b'},
      'b': {'a'},
    };
    expect(wouldCreateCycle(g, 'a', 'c'), isTrue);
  });

  test('diamond without loop is fine', () {
    final g = {
      'd': {'b', 'c'},
      'b': {'a'},
      'c': {'a'},
    };
    expect(wouldCreateCycle(g, 'e', 'd'), isFalse);
    expect(wouldCreateCycle(g, 'd', 'a'), isFalse);
  });
}
