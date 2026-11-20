import 'dart:async';

import 'package:todo_app/data/sync/cloud_backend.dart';

/// An in-memory server enforcing the same rules as the Supabase migrations:
/// who can reach what, last-write-wins, server-assigned stamps, and a cap on
/// rows per response. The real rules are tested against Postgres in
/// `supabase/tests`.
class FakeServer {
  final tables = <String, Map<String, Map<String, dynamic>>>{
    'task_groups': {},
    'labels': {},
    'tasks': {},
    'task_labels': {},
    'task_dependencies': {},
  };
  final members = <String, Set<String>>{};
  final invites = <String, ({String listId, String email})>{};
  final emails = <String, String>{};
  final hints = StreamController<void>.broadcast();
  var _tick = 0;

  /// Rows per response, like PostgREST's `max_rows`.
  int maxRows = 1000;

  /// Fails every request as if offline.
  bool offline = false;

  /// Row ids refused as if access had been lost.
  final refused = <String>{};

  /// Ids written by each upsert, in order.
  final upserted = <String>[];

  /// Runs before an upsert to [table] is applied, to change things mid-push.
  Future<void> Function(String table)? beforeUpsert;

  /// Runs after each page of a pull, to change things mid-pull.
  void Function(String table)? afterFetchPage;

  String stamp() =>
      DateTime.utc(2026)
          .add(Duration(seconds: 3600 * 24 * 30 + ++_tick * 120))
          .toIso8601String();

  bool canReachList(String user, String listId) =>
      tables['task_groups']![listId]?['owner_id'] == user ||
      (members[listId]?.contains(user) ?? false);

  bool canReachTask(String user, String taskId) {
    final task = tables['tasks']![taskId];
    return task != null && canReachList(user, task['group_id'] as String);
  }

  bool canReachLabel(String user, String labelId) =>
      tables['labels']![labelId]?['owner_id'] == user ||
      tables['task_labels']!.values.any(
        (l) =>
            l['label_id'] == labelId &&
            canReachTask(user, l['task_id'] as String),
      );

  bool visible(String user, String table, Map<String, dynamic> r) =>
      switch (table) {
        'task_groups' => canReachList(user, r['id'] as String),
        'tasks' => canReachList(user, r['group_id'] as String),
        'labels' => canReachLabel(user, r['id'] as String),
        'task_labels' => canReachTask(user, r['task_id'] as String),
        _ =>
          canReachTask(user, r['task_id'] as String) &&
              canReachTask(user, r['predecessor_id'] as String),
      };

  /// True if the row is refused; mirrors the RLS checks on write.
  bool denied(String user, String table, Map<String, dynamic> r) =>
      switch (table) {
        'tasks' => !canReachList(user, r['group_id'] as String),
        'task_labels' =>
          !canReachTask(user, r['task_id'] as String) ||
              !canReachLabel(user, r['label_id'] as String),
        'task_dependencies' =>
          !canReachTask(user, r['task_id'] as String) ||
              !canReachTask(user, r['predecessor_id'] as String),
        _ => false,
      };
}

class FakeBackend implements CloudBackend {
  FakeBackend(this.server, CloudUser this.user) {
    server.emails[user!.id] = user!.email;
  }

  final FakeServer server;
  CloudUser? user;
  final _users = StreamController<CloudUser?>.broadcast();

  void signInAs(CloudUser? u) {
    user = u;
    _users.add(u);
  }

  @override
  CloudUser? get currentUser => user;
  @override
  Stream<CloudUser?> get userChanges => _users.stream;
  @override
  Stream<void> get remoteChanges => server.hints.stream;

  String? sentCodeTo;

  @override
  Future<void> sendCode(String email) async => sentCodeTo = email;

  @override
  Future<void> verifyCode(String email, String code) async {
    if (code != '123456') throw const CloudException('Wrong code');
    signInAs(
      const CloudUser(
        id: '00000000-0000-4000-8000-0000000000aa',
        email: 'me@example.com',
      ),
    );
  }

  @override
  Future<void> signOut() async => signInAs(null);

  /// The signed-in user. Signed out, requests run as `anon`, which has no
  /// privileges at all: a retryable error, not a refusal.
  String get _me {
    if (server.offline) throw StateError('offline');
    final u = user;
    if (u == null) throw StateError('permission denied for table');
    return u.id;
  }

  int _cap(int limit) => limit < server.maxRows ? limit : server.maxRows;

  List<T> _page<T>(List<T> sorted, bool Function(T) isAfter, int limit) => [
    ...sorted.where(isAfter).take(_cap(limit)),
  ];

  @override
  Future<List<Map<String, dynamic>>> fetchChanged(
    String table, {
    DateTime? since,
    PagePosition? after,
    required int limit,
  }) async {
    final me = _me;
    String key(Map<String, dynamic> r) =>
        '${r['server_updated_at']}|${r['id']}';
    final rows =
        server.tables[table]!.values
            .where((r) => server.visible(me, table, r))
            .where(
              (r) =>
                  since == null ||
                  !DateTime.parse(r['server_updated_at'] as String)
                      .isBefore(since),
            )
            .toList()
          ..sort((a, b) => key(a).compareTo(key(b)));
    final page = _page(
      rows,
      (r) =>
          after == null || key(r).compareTo('${after.stamp}|${after.id}') > 0,
      limit,
    );
    server.afterFetchPage?.call(table);
    return [for (final r in page) Map<String, dynamic>.of(r)];
  }

  @override
  Future<List<Map<String, dynamic>>> fetchWhereIn(
    String table,
    String column,
    List<String> values, {
    String? afterId,
    required int limit,
  }) async {
    final me = _me;
    final rows = [
      for (final r in server.tables[table]!.values)
        if (values.contains(r[column]) && server.visible(me, table, r)) r,
    ]..sort((a, b) => (a['id'] as String).compareTo(b['id'] as String));
    return [
      for (final r in _page(
        rows,
        (r) => afterId == null || (r['id'] as String).compareTo(afterId) > 0,
        limit,
      ))
        Map<String, dynamic>.of(r),
    ];
  }

  @override
  Future<Set<String>> upsert(
    String table,
    List<Map<String, dynamic>> rows, {
    required String onConflict,
  }) async {
    final me = _me;
    await server.beforeUpsert?.call(table);
    for (final r in rows) {
      if (server.refused.contains(r['id']) || server.denied(me, table, r)) {
        throw RowsRejected('refused ${r['id']}');
      }
    }
    final keys = onConflict.split(',');
    final store = server.tables[table]!;
    final stored = <String>{};
    for (final r in rows) {
      final existing = store.values
          .where((e) => keys.every((k) => e[k] == r[k]))
          .firstOrNull;
      if (existing != null) {
        if (!server.visible(me, table, existing)) {
          throw RowsRejected('no access to ${r['id']}');
        }
        final older = DateTime.parse(r['updated_at'] as String)
            .isBefore(DateTime.parse(existing['updated_at'] as String));
        if (older) continue;
        store.remove(existing['id']);
      }
      final row = {...r, 'server_updated_at': server.stamp()};
      if (table == 'task_groups' || table == 'labels') {
        final owner = existing?['owner_id'] ?? me;
        row['owner_id'] = owner;
        // As in guard_owned_row: only the owner deletes, or moves a list.
        if (owner != me) {
          row['deleted_at'] = existing?['deleted_at'];
          if (table == 'task_groups') row['sort_key'] = existing?['sort_key'];
        }
      }
      store[row['id'] as String] = row;
      stored.add(row['id'] as String);
      server.upserted.add(row['id'] as String);
    }
    return stored;
  }

  @override
  Future<List<AccessibleList>> accessibleLists({
    String? afterId,
    required int limit,
  }) async {
    final me = _me;
    final lists = [
      for (final g in server.tables['task_groups']!.values)
        if (server.canReachList(me, g['id'] as String))
          AccessibleList(
            id: g['id'] as String,
            isShared:
                g['owner_id'] != me ||
                (server.members[g['id']]?.isNotEmpty ?? false),
          ),
    ]..sort((a, b) => a.id.compareTo(b.id));
    return _page(
      lists,
      (l) => afterId == null || l.id.compareTo(afterId) > 0,
      limit,
    );
  }

  @override
  Future<List<String>> taskIdsInLists(
    List<String> listIds, {
    String? afterId,
    required int limit,
  }) async {
    _me;
    final ids = [
      for (final t in server.tables['tasks']!.values)
        if (listIds.contains(t['group_id']) && t['deleted_at'] == null)
          t['id'] as String,
    ]..sort();
    return _page(
      ids,
      (id) => afterId == null || id.compareTo(afterId) > 0,
      limit,
    );
  }

  @override
  Future<void> invite(String listId, String email) async {
    server.invites['inv-${server.invites.length}-$listId'] = (
      listId: listId,
      email: email.toLowerCase(),
    );
  }

  @override
  Future<void> cancelInvite(String inviteId) async =>
      server.invites.remove(inviteId);

  @override
  Future<List<SentInvite>> sentInvites(String listId) async => [
    for (final e in server.invites.entries)
      if (e.value.listId == listId) SentInvite(id: e.key, email: e.value.email),
  ];

  @override
  Future<List<ReceivedInvite>> myInvites() async => [
    for (final e in server.invites.entries)
      if (e.value.email == currentUser!.email)
        ReceivedInvite(
          id: e.key,
          listId: e.value.listId,
          listName:
              server.tables['task_groups']![e.value.listId]!['name'] as String,
          invitedBy: 'owner@example.com',
        ),
  ];

  @override
  Future<void> acceptInvite(String inviteId) async {
    final invite = server.invites.remove(inviteId)!;
    (server.members[invite.listId] ??= {}).add(_me);
  }

  @override
  Future<void> declineInvite(String inviteId) async =>
      server.invites.remove(inviteId);

  @override
  Future<List<ListPerson>> people(String listId) async => [
    ListPerson(
      userId: server.tables['task_groups']![listId]!['owner_id'] as String,
      email:
          server.emails[server.tables['task_groups']![listId]!['owner_id']] ??
          'owner@example.com',
      isOwner: true,
    ),
    for (final m in server.members[listId] ?? const <String>{})
      ListPerson(
        userId: m,
        email: server.emails[m] ?? 'member@example.com',
        isOwner: false,
      ),
  ];

  @override
  Future<void> removeMember(String listId, String userId) async {
    server.members[listId]?.remove(userId);
  }
}
