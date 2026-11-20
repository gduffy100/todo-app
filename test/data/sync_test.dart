import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:todo_app/data/backup.dart';
import 'package:todo_app/data/db.dart';
import 'package:todo_app/data/sync/cloud_backend.dart';
import 'package:todo_app/data/sync/sync_engine.dart';

import '../ui/harness.dart';
import 'fake_cloud.dart';

const alice = CloudUser(
  id: '00000000-0000-4000-8000-00000000000a',
  email: 'alice@example.com',
);
const bob = CloudUser(
  id: '00000000-0000-4000-8000-00000000000b',
  email: 'bob@example.com',
);

/// One install of the app, signed in to the shared fake server.
class Device {
  Device(this.server, this.user)
    : backend = FakeBackend(server, user),
      db = memoryDb() {
    addTearDown(db.close);
  }
  final FakeServer server;
  final CloudUser user;
  final FakeBackend backend;
  final AppDatabase db;

  /// Pages at the server's cap, as the app does against Supabase.
  Future<void> sync() =>
      SyncEngine(db, backend, pageSize: server.maxRows).sync(user.id);

  Future<List<String>> titles() async =>
      [for (final v in await db.tasksDao.loadViews()) v.task.title]..sort();

  Future<String> list(String name) async =>
      (await db.groupsDao.getGroups()).firstWhere((g) => g.name == name).id;

  Future<List<String>> listNames() async => [
    for (final g in await db.groupsDao.getGroups()) g.name,
  ];

  Future<String> addTask(String title, String listName) async =>
      db.tasksDao.createTask(title: title, groupId: await list(listName));
}

void main() {
  late FakeServer server;
  setUp(() => server = FakeServer());

  /// [owner] shares [listName] with [member], then both sync.
  Future<void> share(Device owner, Device member, String listName) async {
    await owner.sync();
    await owner.backend.invite(await owner.list(listName), member.user.email);
    final invite = (await member.backend.myInvites()).single;
    await member.backend.acceptInvite(invite.id);
    await member.sync();
    await owner.sync();
  }

  group('one user, several devices', () {
    test('first sign-in uploads what is already on the device', () async {
      final phone = Device(server, alice);
      await phone.addTask('Buy milk', 'Today');
      await phone.sync();

      final laptop = Device(server, alice);
      await laptop.sync();
      expect(await laptop.titles(), ['Buy milk']);
    });

    test('default lists and labels merge rather than duplicate', () async {
      final phone = Device(server, alice);
      final laptop = Device(server, alice);
      await phone.sync();
      await laptop.sync();
      await phone.sync();
      expect(await phone.listNames(), await laptop.listNames());
      expect((await phone.listNames()).where((n) => n == 'Today').length, 1);
      final labels = await laptop.db.labelsDao.getLabels();
      expect(labels.map((l) => l.name).toSet().length, labels.length);
    });

    test('edits and deletes reach the other device', () async {
      final phone = Device(server, alice);
      final laptop = Device(server, alice);
      final id = await phone.addTask('Draft', 'Today');
      await phone.sync();
      await laptop.sync();

      await laptop.db.tasksDao.updateTask(id, title: 'Final');
      await laptop.sync();
      await phone.sync();
      expect(await phone.titles(), ['Final']);

      await phone.db.tasksDao.deleteTask(id);
      await phone.sync();
      await laptop.sync();
      expect(await laptop.titles(), isEmpty);
    });

    test('clearing a value reaches the other device', () async {
      final phone = Device(server, alice);
      final laptop = Device(server, alice);
      final id = await phone.addTask('Task', 'Today');
      await phone.db.tasksDao.updateTask(
        id,
        dueDate: Value(DateTime.utc(2030)),
      );
      await phone.db.tasksDao.setCompleted(id, true);
      await phone.sync();
      await laptop.sync();
      final before = (await laptop.db.tasksDao.loadViews()).single.task;
      expect(before.dueDate, isNotNull);
      expect(before.completedAt, isNotNull);

      await phone.db.tasksDao.updateTask(id, dueDate: const Value(null));
      await phone.db.tasksDao.setCompleted(id, false);
      await phone.sync();
      await laptop.sync();
      final after = (await laptop.db.tasksDao.loadViews()).single.task;
      expect(after.dueDate, isNull);
      expect(after.completedAt, isNull);
    });

    test('the newer of two offline edits wins on both devices', () async {
      final phone = Device(server, alice);
      final laptop = Device(server, alice);
      final id = await phone.addTask('Start', 'Today');
      await phone.sync();
      await laptop.sync();

      await phone.db.tasksDao.updateTask(id, title: 'Older');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await laptop.db.tasksDao.updateTask(id, title: 'Newer');

      // The newer edit arrives first, so the older one must lose on arrival.
      await laptop.sync();
      await phone.sync();
      await laptop.sync();
      expect(await phone.titles(), ['Newer']);
      expect(await laptop.titles(), ['Newer']);
    });

    test('the same label added on two devices settles on one link', () async {
      final phone = Device(server, alice);
      final laptop = Device(server, alice);
      final id = await phone.addTask('Task', 'Today');
      await phone.sync();
      await laptop.sync();
      final label = (await phone.db.labelsDao.getLabels()).first.id;

      await phone.db.tasksDao.setLabels(id, {label});
      await laptop.db.tasksDao.setLabels(id, {label});
      await phone.sync();
      await laptop.sync();
      await phone.sync();

      final onPhone = await phone.db.select(phone.db.taskLabels).get();
      final onLaptop = await laptop.db.select(laptop.db.taskLabels).get();
      expect(onPhone.single.id, onLaptop.single.id);
      expect(server.tables['task_labels']!.length, 1);
    });
  });

  group('outbox', () {
    test('a clean sync leaves nothing queued, and nothing echoes', () async {
      final phone = Device(server, alice);
      final laptop = Device(server, alice);
      await phone.addTask('Task', 'Today');
      await phone.sync();
      await laptop.sync();
      expect(await phone.db.syncDao.pendingCount(), 0);
      expect(await laptop.db.syncDao.pendingCount(), 0);
    });

    test('changes made offline wait and then go out', () async {
      final phone = Device(server, alice);
      await phone.sync();
      await phone.addTask('Offline', 'Today');
      server.offline = true;
      await expectLater(phone.sync(), throwsStateError);
      expect(await phone.db.syncDao.pendingCount(), greaterThan(0));

      server.offline = false;
      await phone.sync();
      expect(await phone.db.syncDao.pendingCount(), 0);
      expect(server.tables['tasks']!.values.single['title'], 'Offline');
    });

    test('a backup import with old dates is still uploaded', () async {
      final other = memoryDb();
      addTearDown(other.close);
      await other.tasksDao.createTask(
        title: 'From backup',
        groupId: (await other.groupsDao.getGroups()).first.id,
      );
      final backup = await Backup(other).exportJson();

      final phone = Device(server, alice);
      await phone.sync();
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await phone.addTask('Newer task', 'Today');
      await phone.sync();
      await Backup(phone.db).importJson(backup);
      await phone.sync();

      final laptop = Device(server, alice);
      await laptop.sync();
      expect(await laptop.titles(), ['From backup', 'Newer task']);
      // The backup's seed ids must not create a second Today.
      expect((await laptop.listNames()).where((n) => n == 'Today').length, 1);
    });

    test('one refused row does not hold up the others', () async {
      final phone = Device(server, alice);
      await phone.sync();
      final bad = await phone.addTask('Refused', 'Today');
      await phone.addTask('Fine', 'Today');
      server.refused.add(bad);
      await phone.sync();
      expect(server.tables['tasks']!.values.map((t) => t['title']), ['Fine']);
      expect(await phone.db.syncDao.pendingCount(), 0);
    });
  });

  group('accounts', () {
    test("two users' default lists do not collide", () async {
      final a = Device(server, alice);
      final b = Device(server, bob);
      await a.sync();
      await b.sync();
      expect(await a.list('Today'), isNot(await b.list('Today')));
      await a.addTask('Private to Alice', 'Today');
      await a.sync();
      await b.sync();
      expect(await b.titles(), isEmpty);
    });

    test('a device will not mix data into a second account', () async {
      final a = Device(server, alice);
      await a.addTask('Mine', 'Today');
      await a.sync();
      a.backend.signInAs(bob);
      await expectLater(
        SyncEngine(a.db, a.backend).sync(bob.id),
        throwsA(isA<AccountMismatch>()),
      );
      expect(
        server.tables['tasks']!.values.where((t) => t['title'] == 'Mine'),
        hasLength(1),
      );
    });
  });

  group('sharing', () {
    late Device a;
    late Device b;
    setUp(() async {
      a = Device(server, alice);
      b = Device(server, bob);
      await a.db.groupsDao.createGroup('Trip');
      await b.sync();
    });

    test('joining brings the rows older than the member cursor', () async {
      await a.addTask('Book flights', 'Trip');
      await a.addTask('Private', 'Today');
      await share(a, b, 'Trip');
      expect(await b.titles(), ['Book flights']);
      expect(await b.listNames(), contains('Trip'));
    });

    test('changes flow both ways', () async {
      final id = await a.addTask('Book flights', 'Trip');
      await share(a, b, 'Trip');

      await b.db.tasksDao.updateTask(id, title: 'Flights booked');
      await b.addTask('Pack', 'Trip');
      await b.sync();
      await a.sync();
      expect(await a.titles(), ['Flights booked', 'Pack']);
    });

    test('the list is reported as shared to both people', () async {
      await share(a, b, 'Trip');
      final listId = await a.list('Trip');
      expect(await a.db.syncDao.getIdSet('shared_list_ids'), {listId});
      expect(await b.db.syncDao.getIdSet('shared_list_ids'), {listId});
    });

    test('a label already in use comes along with its task', () async {
      final id = await a.addTask('Book flights', 'Trip');
      await share(a, b, 'Trip');
      // Read after the first sync, which gives default labels their real ids.
      final label = (await a.db.labelsDao.getLabels()).first;
      await a.db.tasksDao.setLabels(id, {label.id});
      await a.sync();
      await b.sync();
      final view = (await b.db.tasksDao.loadViews()).single;
      expect(view.labels.single.name, label.name);
    });

    test('a removed member loses the list, and nobody else does', () async {
      await a.addTask('Book flights', 'Trip');
      await share(a, b, 'Trip');
      final listId = await a.list('Trip');

      await a.backend.removeMember(listId, bob.id);
      await b.sync();
      expect(await b.titles(), isEmpty);
      expect(await b.listNames(), isNot(contains('Trip')));
      expect(await b.db.syncDao.pendingCount(), 0);

      await a.sync();
      expect(await a.titles(), ['Book flights']);
      expect(server.tables['tasks']!.values.single['deleted_at'], isNull);
    });

    test('rejoining restores the list', () async {
      await a.addTask('Book flights', 'Trip');
      await share(a, b, 'Trip');
      final listId = await a.list('Trip');
      await a.backend.removeMember(listId, bob.id);
      await b.sync();
      await a.addTask('Added while away', 'Trip');
      await a.sync();

      await a.backend.invite(listId, bob.email);
      await b.backend.acceptInvite((await b.backend.myInvites()).single.id);
      await b.sync();
      expect(await b.titles(), ['Added while away', 'Book flights']);
      expect(await b.listNames(), contains('Trip'));
    });

    test('an edit made after losing access is dropped, not stuck', () async {
      final id = await a.addTask('Book flights', 'Trip');
      await share(a, b, 'Trip');
      await a.backend.removeMember(await a.list('Trip'), bob.id);

      await b.db.tasksDao.updateTask(id, title: 'Too late');
      await b.sync();
      expect(await b.db.syncDao.pendingCount(), 0);
      expect(server.tables['tasks']![id]!['title'], 'Book flights');
    });

    test('a task moved to a private list disappears for others', () async {
      final id = await a.addTask('Secret plan', 'Trip');
      await share(a, b, 'Trip');
      expect(await b.titles(), ['Secret plan']);

      await a.db.tasksDao.moveToGroup(id, await a.list('Today'));
      await a.sync();
      await b.sync();
      expect(await b.titles(), isEmpty);
      expect(await a.titles(), ['Secret plan']);
    });

    test('a task moved between visible lists is not evicted', () async {
      await a.db.groupsDao.createGroup('Work');
      final id = await a.addTask('Task', 'Trip');
      await share(a, b, 'Trip');
      await share(a, b, 'Work');
      await a.db.tasksDao.moveToGroup(id, await a.list('Work'));
      await a.sync();
      await b.sync();
      expect(await b.titles(), ['Task']);
    });

    test(
      'deleting a shared list does not pull tasks into a member list',
      () async {
        await a.addTask('Book flights', 'Trip');
        await share(a, b, 'Trip');

        await a.db.groupsDao.deleteGroup(await a.list('Trip'));
        await a.sync();
        await b.sync();
        await a.sync();

        expect(await b.titles(), isEmpty);
        expect(await b.listNames(), isNot(contains('Trip')));
        // The owner keeps the tasks in their own default list.
        expect(await a.titles(), ['Book flights']);
        final task = server.tables['tasks']!.values.single;
        expect(task['group_id'], await a.list('Today'));
      },
    );

    test('a list others can see is never the repair target', () async {
      final trip = await a.list('Trip');
      await share(a, b, 'Trip');
      await b.db.groupsDao.reorderGroup(trip, 0);
      expect((await b.db.groupsDao.getGroups()).first.id, trip);

      await b.db.groupsDao.createGroup('Mine');
      final mine = await b.addTask('My task', 'Mine');
      await b.db.groupsDao.deleteGroup(await b.list('Mine'));
      await b.sync();

      final row = (await b.db.tasksDao.loadViews()).firstWhere(
        (v) => v.task.id == mine,
      );
      expect(row.task.groupId, await b.list('Today'));
    });
  });

  group('review fixes', () {
    test('signing out before a sync keeps unsent edits', () async {
      final phone = Device(server, alice);
      await phone.sync();
      await phone.addTask('Unsent', 'Today');
      phone.backend.signInAs(null);
      await expectLater(phone.sync(), throwsA(anything));
      expect(await phone.db.syncDao.pendingCount(), greaterThan(0));

      phone.backend.signInAs(alice);
      await phone.sync();
      expect(server.tables['tasks']!.values.map((t) => t['title']), ['Unsent']);
    });

    test('signing out during a push leaves the outbox alone', () async {
      final phone = Device(server, alice);
      await phone.sync();
      await phone.addTask('Mid-push', 'Today');
      server.beforeUpsert = (_) async {
        server.beforeUpsert = null;
        phone.backend.signInAs(null);
      };
      await expectLater(phone.sync(), throwsA(isA<SyncInterrupted>()));
      expect(await phone.db.syncDao.pendingCount(), greaterThan(0));
    });

    test(
      'a child queued after its parent table was sent still uploads',
      () async {
        final phone = Device(server, alice);
        await phone.addTask('Existing', 'Today');
        String? lateTask;
        // Runs while the first sync is sending labels, after lists were sent.
        server.beforeUpsert = (table) async {
          if (table != 'labels') return;
          server.beforeUpsert = null;
          final list = await phone.db.groupsDao.createGroup('Late list');
          lateTask = await phone.db.tasksDao.createTask(
            title: 'Late task',
            groupId: list,
          );
        };
        await phone.sync();
        expect(server.tables['tasks']!.containsKey(lateTask), isTrue);
        expect(await phone.db.syncDao.pendingCount(), 0);
      },
    );

    test('more rows than one response holds are all fetched', () async {
      server.maxRows = 2;
      final a = Device(server, alice);
      final b = Device(server, bob);
      await a.db.groupsDao.createGroup('Trip');
      for (var i = 0; i < 5; i++) {
        await a.addTask('Task $i', 'Trip');
      }
      await b.sync();
      await share(a, b, 'Trip');
      expect(await b.titles(), hasLength(5));

      // Checking for moved tasks must not evict the ones past the first page.
      await b.sync();
      await a.sync();
      expect(await b.titles(), hasLength(5));
      expect(await a.titles(), hasLength(5));
    });

    test('a row changing mid-pull does not push another out of it', () async {
      server.maxRows = 2;
      final phone = Device(server, alice);
      for (var i = 0; i < 5; i++) {
        await phone.addTask('Task $i', 'Today');
      }
      await phone.sync();

      var bumped = false;
      server.afterFetchPage = (table) {
        if (table != 'tasks' || bumped) return;
        bumped = true;
        final oldest = server.tables['tasks']!.values.reduce(
          (a, b) =>
              (a['server_updated_at'] as String).compareTo(
                    b['server_updated_at'] as String,
                  ) <=
                  0
              ? a
              : b,
        );
        oldest['server_updated_at'] = server.stamp();
      };
      final laptop = Device(server, alice);
      await laptop.sync();
      expect(await laptop.titles(), hasLength(5));
    });

    test('a write that loses on the server shows the winner', () async {
      final phone = Device(server, alice);
      final laptop = Device(server, alice);
      final id = await phone.addTask('Start', 'Today');
      await phone.sync();
      await laptop.sync();

      // The phone's clock runs fast, so its edit beats a later real one.
      await (phone.db.update(
        phone.db.tasks,
      )..where((t) => t.id.equals(id))).write(
        TasksCompanion(
          title: const Value('From phone'),
          updatedAt: Value(nowUtc().add(const Duration(minutes: 3))),
        ),
      );
      await phone.sync();
      await laptop.sync();
      // Move the laptop's cursor well past the phone's edit.
      for (var i = 0; i < 3; i++) {
        await laptop.addTask('Filler $i', 'Today');
        await laptop.sync();
      }

      await laptop.db.tasksDao.updateTask(id, title: 'From laptop');
      await laptop.sync();
      final titles = await laptop.titles();
      expect(titles, contains('From phone'));
      expect(titles, isNot(contains('From laptop')));
    });

    test('joining a list brings dependencies that point into it', () async {
      final a = Device(server, alice);
      final b = Device(server, bob);
      await a.db.groupsDao.createGroup('Work');
      await a.db.groupsDao.createGroup('Trip');
      final pack = await a.addTask('Pack', 'Work');
      final flights = await a.addTask('Book flights', 'Trip');
      await b.sync();
      await share(a, b, 'Work');

      // Hidden from Bob for now: its predecessor is in a list he cannot see.
      await a.db.tasksDao.addPredecessor(pack, flights);
      // A later visible edge moves Bob's cursor past the hidden one.
      final unpack = await a.addTask('Unpack', 'Work');
      await a.db.tasksDao.addPredecessor(unpack, pack);
      await a.sync();
      await b.sync();

      await share(a, b, 'Trip');
      final edges = await (b.db.select(
        b.db.taskDependencies,
      )..where((d) => d.deletedAt.isNull())).get();
      expect(
        {for (final e in edges) (e.taskId, e.predecessorId)},
        {(pack, flights), (unpack, pack)},
      );
    });

    test('importing an old backup re-sends only what it changed', () async {
      final a = Device(server, alice);
      final b = Device(server, bob);
      await a.db.groupsDao.createGroup('Trip');
      final shared = await a.addTask('Book flights', 'Trip');
      await b.sync();
      await share(a, b, 'Trip');

      final fresh = memoryDb();
      addTearDown(fresh.close);
      final backup = await Backup(fresh).exportJson();
      server.upserted.clear();
      await Backup(b.db).importJson(backup);
      await b.sync();
      expect(server.upserted, isNot(contains(shared)));
      expect(server.upserted, isNot(contains(await a.list('Trip'))));
    });

    test(
      'a member reordering lists does not move them for the owner',
      () async {
        final a = Device(server, alice);
        final b = Device(server, bob);
        await a.db.groupsDao.createGroup('Trip');
        await b.sync();
        await share(a, b, 'Trip');
        final before = [for (final g in await a.db.groupsDao.getGroups()) g.id];

        await b.db.groupsDao.reorderGroup(await b.list('Trip'), 0);
        await b.sync();
        await a.sync();
        expect([
          for (final g in await a.db.groupsDao.getGroups()) g.id,
        ], before);
      },
    );
  });

  group('migration', () {
    test('v1 data survives the upgrade and can then sync', () async {
      final db = AppDatabase(
        DatabaseConnection(
          NativeDatabase.memory(
            setup: (raw) {
              raw.execute('''
                CREATE TABLE task_groups (
                  id TEXT NOT NULL PRIMARY KEY, created_at TEXT NOT NULL,
                  updated_at TEXT NOT NULL, deleted_at TEXT NULL,
                  name TEXT NOT NULL, sort_key TEXT NOT NULL,
                  is_system INTEGER NOT NULL DEFAULT 0);
                CREATE TABLE tasks (
                  id TEXT NOT NULL PRIMARY KEY, created_at TEXT NOT NULL,
                  updated_at TEXT NOT NULL, deleted_at TEXT NULL,
                  title TEXT NOT NULL, notes TEXT NOT NULL DEFAULT '',
                  group_id TEXT NOT NULL REFERENCES task_groups (id),
                  sort_key TEXT NOT NULL, due_date TEXT NULL,
                  completed_at TEXT NULL);
                CREATE TABLE labels (
                  id TEXT NOT NULL PRIMARY KEY, created_at TEXT NOT NULL,
                  updated_at TEXT NOT NULL, deleted_at TEXT NULL,
                  name TEXT NOT NULL, color INTEGER NOT NULL);
                CREATE TABLE task_labels (
                  id TEXT NOT NULL PRIMARY KEY, created_at TEXT NOT NULL,
                  updated_at TEXT NOT NULL, deleted_at TEXT NULL,
                  task_id TEXT NOT NULL REFERENCES tasks (id),
                  label_id TEXT NOT NULL REFERENCES labels (id),
                  UNIQUE (task_id, label_id));
                CREATE TABLE task_dependencies (
                  id TEXT NOT NULL PRIMARY KEY, created_at TEXT NOT NULL,
                  updated_at TEXT NOT NULL, deleted_at TEXT NULL,
                  task_id TEXT NOT NULL REFERENCES tasks (id),
                  predecessor_id TEXT NOT NULL REFERENCES tasks (id),
                  UNIQUE (task_id, predecessor_id));
                INSERT INTO task_groups VALUES ('seed-group-today',
                  '2000-01-01T00:00:00.000Z', '2000-01-01T00:00:00.000Z', NULL,
                  'Today', 'V', 1);
                INSERT INTO tasks VALUES ('t1', '2026-01-01T00:00:00.000Z',
                  '2026-01-01T00:00:00.000Z', NULL, 'Old task', '',
                  'seed-group-today', 'V', NULL, NULL);
                PRAGMA user_version = 1;
              ''');
            },
          ),
          closeStreamsSynchronously: true,
        ),
      );
      addTearDown(db.close);

      final views = await db.tasksDao.loadViews();
      expect(views.single.task.title, 'Old task');
      expect((await db.groupsDao.getGroups()).single.ownerId, isNull);

      // Triggers exist: edits are queued from now on.
      expect(await db.syncDao.pendingCount(), 0);
      await db.tasksDao.updateTask('t1', title: 'Edited');
      expect(await db.syncDao.pendingCount(), 1);

      // And the old rows upload on first sign-in, under adopted ids.
      await SyncEngine(db, FakeBackend(server, alice)).sync(alice.id);
      final task = server.tables['tasks']!['t1']!;
      expect(task['title'], 'Edited');
      expect(task['group_id'], isNot('seed-group-today'));
      expect(
        server.tables['task_groups']!.containsKey(task['group_id']),
        isTrue,
      );
    });
  });
}
