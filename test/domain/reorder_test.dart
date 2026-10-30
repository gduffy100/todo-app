import 'package:flutter_test/flutter_test.dart';
import 'package:todo_app/domain/reorder.dart';

void main() {
  const full = ['a', 'b', 'c', 'd', 'e'];

  test('unfiltered drag down', () {
    // move a (0) to after c: onReorderItem reports newIndex 2
    expect(
      fullIndexForVisibleDrop(
        fullIds: full,
        visibleIds: full,
        oldIndex: 0,
        newIndex: 2,
      ),
      2,
    );
  });

  test('unfiltered drag up', () {
    expect(
      fullIndexForVisibleDrop(
        fullIds: full,
        visibleIds: full,
        oldIndex: 4,
        newIndex: 0,
      ),
      0,
    );
  });

  test('filtered list maps to the anchor position in the full list', () {
    const visible = ['b', 'd', 'e'];
    // move e before d → full index of d (excluding e) = 3
    expect(
      fullIndexForVisibleDrop(
        fullIds: full,
        visibleIds: visible,
        oldIndex: 2,
        newIndex: 1,
      ),
      3,
    );
    // move b to the end → after e
    expect(
      fullIndexForVisibleDrop(
        fullIds: full,
        visibleIds: visible,
        oldIndex: 0,
        newIndex: 2,
      ),
      4,
    );
  });
}
