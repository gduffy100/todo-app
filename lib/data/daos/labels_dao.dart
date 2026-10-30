import 'package:drift/drift.dart';

import '../db.dart';

part 'labels_dao.g.dart';

@DriftAccessor(tables: [Labels, TaskLabels])
class LabelsDao extends DatabaseAccessor<AppDatabase> with _$LabelsDaoMixin {
  LabelsDao(super.db);

  SimpleSelectStatement<$LabelsTable, Label> _live() => select(labels)
    ..where((l) => l.deletedAt.isNull())
    ..orderBy([(l) => OrderingTerm.asc(l.name.collate(Collate.noCase))]);

  Stream<List<Label>> watchLabels() => _live().watch();
  Future<List<Label>> getLabels() => _live().get();

  Future<String> createLabel(String name, int color) async {
    final row = await into(
      labels,
    ).insertReturning(LabelsCompanion.insert(name: name.trim(), color: color));
    return row.id;
  }

  Future<void> updateLabel(String id, {String? name, int? color}) =>
      (update(labels)..where((l) => l.id.equals(id))).write(
        LabelsCompanion(
          name: name == null ? const Value.absent() : Value(name.trim()),
          color: Value.absentIfNull(color),
          updatedAt: Value(nowUtc()),
        ),
      );

  /// Soft-deletes the label and its task links.
  Future<void> deleteLabel(String id) => transaction(() async {
    final now = nowUtc();
    await (update(labels)..where((l) => l.id.equals(id))).write(
      LabelsCompanion(deletedAt: Value(now), updatedAt: Value(now)),
    );
    await (update(
      taskLabels,
    )..where((tl) => tl.labelId.equals(id) & tl.deletedAt.isNull())).write(
      TaskLabelsCompanion(deletedAt: Value(now), updatedAt: Value(now)),
    );
  });
}
