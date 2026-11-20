import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:todo_app/data/db.dart';
import 'package:todo_app/data/sync/cloud_backend.dart';
import 'package:todo_app/main.dart';
import 'package:todo_app/state/providers.dart';
import 'package:todo_app/state/sync.dart';
import 'package:todo_app/ui/screens/account_screen.dart';
import 'package:todo_app/ui/screens/share_list_screen.dart';

import '../data/fake_cloud.dart';
import 'harness.dart';

const me = CloudUser(
  id: '00000000-0000-4000-8000-0000000000aa',
  email: 'me@example.com',
);

Future<AppDatabase> pumpScreen(
  WidgetTester tester,
  Widget screen,
  FakeBackend backend,
) async {
  tester.view.physicalSize = compactSize;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final db = memoryDb();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        cloudBackendProvider.overrideWithValue(backend),
      ],
      child: MaterialApp(home: screen),
    ),
  );
  await settle(tester);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    await db.close();
  });
  return db;
}

void main() {
  testWidgets('local-only builds offer no sign-in', (tester) async {
    await pumpApp(tester, compactSize);
    await tester.tap(find.byTooltip('Menu'));
    await settle(tester);
    expect(find.text('Sign in'), findsNothing);
    expect(find.text('Export data'), findsOneWidget);
  });

  testWidgets('the menu offers sign-in when the cloud is available', (
    tester,
  ) async {
    tester.view.physicalSize = compactSize;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final db = memoryDb();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          cloudBackendProvider.overrideWithValue(
            FakeBackend(FakeServer(), me)..user = null,
          ),
        ],
        child: const TodoApp(),
      ),
    );
    await settle(tester);
    await tester.tap(find.byTooltip('Menu'));
    await settle(tester);
    expect(find.text('Sign in'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await db.close();
  });

  testWidgets('signs in with an emailed code', (tester) async {
    final backend = FakeBackend(FakeServer(), me)..user = null;
    await pumpScreen(tester, const AccountScreen(), backend);

    await tester.tap(find.text('Email me a code'));
    await settle(tester);
    expect(find.text('Enter your email address'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'me@example.com');
    await tester.tap(find.text('Email me a code'));
    await settle(tester);
    expect(backend.sentCodeTo, 'me@example.com');

    await tester.enterText(find.byType(TextField), '000000');
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await settle(tester);
    expect(find.text('Wrong code'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '123456');
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await settle(tester);
    expect(find.text('me@example.com'), findsOneWidget);
    expect(find.text('Sign out'), findsOneWidget);
  });

  testWidgets('shows an invitation and joins the list', (tester) async {
    final server = FakeServer();
    server.tables['task_groups']!['L1'] = {
      'id': 'L1',
      'owner_id': 'someone-else',
      'name': 'Trip',
      'sort_key': 'a',
      'is_system': false,
      'created_at': '2026-01-01T00:00:00Z',
      'updated_at': '2026-01-01T00:00:00Z',
      'deleted_at': null,
      'server_updated_at': '2026-01-01T00:00:00Z',
    };
    final backend = FakeBackend(server, me);
    await backend.invite('L1', me.email);
    final db = await pumpScreen(tester, const AccountScreen(), backend);

    expect(find.text('Trip'), findsOneWidget);
    await tester.tap(find.text('Join'));
    await settle(tester);

    expect(find.text('Trip'), findsNothing);
    expect(server.members['L1'], {me.id});
    final lists = await db.groupsDao.getGroups();
    expect(lists.map((g) => g.name), contains('Trip'));
  });

  group('sharing screen', () {
    Future<TaskGroup> ownedList(FakeServer server) async {
      final setup = memoryDb();
      addTearDown(setup.close);
      final id = await setup.groupsDao.createGroup('Trip');
      final list = (await setup.groupsDao.getGroups()).firstWhere(
        (g) => g.id == id,
      );
      server.tables['task_groups']![id] = {
        'id': id,
        'owner_id': me.id,
        'name': 'Trip',
        'sort_key': list.sortKey,
        'is_system': false,
        'created_at': '2026-01-01T00:00:00Z',
        'updated_at': '2026-01-01T00:00:00Z',
        'deleted_at': null,
        'server_updated_at': '2026-01-01T00:00:00Z',
      };
      return list;
    }

    testWidgets('the owner can invite, cancel and remove', (tester) async {
      final server = FakeServer();
      final list = await tester.runAsync(() => ownedList(server));
      server.members[list!.id] = {'friend'};
      server.emails['friend'] = 'friend@example.com';
      final backend = FakeBackend(server, me);
      await pumpScreen(
        tester,
        ShareListScreen(list: list, isOwner: true),
        backend,
      );

      expect(find.text('Owner'), findsOneWidget);
      expect(find.text('friend@example.com'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'New@Example.com');
      await tester.tap(find.widgetWithText(FilledButton, 'Invite'));
      await settle(tester);
      expect(find.text('new@example.com'), findsOneWidget);
      expect(find.text('Invited'), findsOneWidget);

      await tester.tap(find.byTooltip('Cancel invitation to new@example.com'));
      await settle(tester);
      expect(find.text('new@example.com'), findsNothing);

      await tester.tap(find.byTooltip('Remove friend@example.com'));
      await settle(tester);
      expect(find.text('friend@example.com'), findsNothing);
      expect(server.members[list.id], isEmpty);
    });

    testWidgets('a member sees people but cannot manage them', (tester) async {
      final server = FakeServer();
      final list = await tester.runAsync(() => ownedList(server));
      server.members[list!.id] = {'friend'};
      server.emails['friend'] = 'friend@example.com';
      await pumpScreen(
        tester,
        ShareListScreen(list: list, isOwner: false),
        FakeBackend(server, me),
      );
      expect(find.text('friend@example.com'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Invite'), findsNothing);
      expect(find.byIcon(Icons.person_remove), findsNothing);
    });
  });
}
