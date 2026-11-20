import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import 'cloud_backend.dart';

/// Connection details, supplied at build time with `--dart-define`. The
/// publishable key is safe to ship: row-level security protects the data.
class SupabaseConfig {
  static const url = String.fromEnvironment('SUPABASE_URL');
  static const publishableKey = String.fromEnvironment(
    'SUPABASE_PUBLISHABLE_KEY',
  );
  static bool get isConfigured => url.isNotEmpty && publishableKey.isNotEmpty;
}

class SupabaseBackend implements CloudBackend {
  SupabaseBackend(this._client);

  final SupabaseClient _client;

  static const _hintedTables = [
    'task_groups',
    'tasks',
    'labels',
    'task_labels',
    'task_dependencies',
  ];

  CloudUser? _toUser(User? u) =>
      u == null ? null : CloudUser(id: u.id, email: u.email ?? '');

  @override
  CloudUser? get currentUser => _toUser(_client.auth.currentUser);

  @override
  Stream<CloudUser?> get userChanges =>
      _client.auth.onAuthStateChange.map((e) => _toUser(e.session?.user));

  @override
  Stream<void> get remoteChanges {
    late RealtimeChannel channel;
    final controller = StreamController<void>(
      onCancel: () => _client.removeChannel(channel),
    );
    channel = _client.channel('listo-changes');
    for (final table in _hintedTables) {
      channel.onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: table,
        callback: (_) => controller.add(null),
      );
    }
    channel.subscribe();
    return controller.stream;
  }

  @override
  Future<void> sendCode(String email) => _friendly(
    () => _client.auth.signInWithOtp(email: email.trim().toLowerCase()),
  );

  @override
  Future<void> verifyCode(String email, String code) => _friendly(
    () => _client.auth.verifyOTP(
      email: email.trim().toLowerCase(),
      token: code.trim(),
      type: OtpType.email,
    ),
  );

  @override
  Future<void> signOut() => _client.auth.signOut();

  @override
  Future<List<Map<String, dynamic>>> fetchChanged(
    String table, {
    DateTime? since,
    PagePosition? after,
    required int limit,
  }) async {
    var query = _client.from(table).select();
    if (since != null) {
      query = query.gte('server_updated_at', since.toUtc().toIso8601String());
    }
    if (after != null) {
      // Quoted: the stamp contains characters PostgREST reserves.
      query = query.or(
        'server_updated_at.gt."${after.stamp}",'
        'and(server_updated_at.eq."${after.stamp}",id.gt."${after.id}")',
      );
    }
    return query.order('server_updated_at').order('id').limit(limit);
  }

  @override
  Future<List<Map<String, dynamic>>> fetchWhereIn(
    String table,
    String column,
    List<String> values, {
    String? afterId,
    required int limit,
  }) async {
    var query = _client.from(table).select().inFilter(column, values);
    if (afterId != null) query = query.gt('id', afterId);
    return query.order('id').limit(limit);
  }

  @override
  Future<Set<String>> upsert(
    String table,
    List<Map<String, dynamic>> rows, {
    required String onConflict,
  }) async {
    try {
      final stored = await _client
          .from(table)
          .upsert(rows, onConflict: onConflict)
          .select('id');
      return {for (final r in stored) r['id'] as String};
    } on PostgrestException catch (e) {
      // Only a policy refusal or a row the schema will never accept is final.
      // A missing privilege (42501 without "row-level security") means the
      // session is gone, and dropping the rows then would lose them.
      final code = e.code ?? '';
      final refused =
          code == '42501' && e.message.contains('row-level security');
      if (refused || code.startsWith('23') || code.startsWith('22')) {
        throw RowsRejected(e.message);
      }
      rethrow;
    }
  }

  @override
  Future<List<AccessibleList>> accessibleLists({
    String? afterId,
    required int limit,
  }) async {
    var query = _client.rpc<List<dynamic>>('my_lists');
    if (afterId != null) query = query.gt('id', afterId);
    final List<dynamic> rows = await query.order('id').limit(limit);
    return [
      for (final r in rows.cast<Map<String, dynamic>>())
        AccessibleList(id: r['id'] as String, isShared: r['is_shared'] as bool),
    ];
  }

  @override
  Future<List<String>> taskIdsInLists(
    List<String> listIds, {
    String? afterId,
    required int limit,
  }) async {
    var query = _client
        .from('tasks')
        .select('id')
        .inFilter('group_id', listIds)
        .isFilter('deleted_at', null);
    if (afterId != null) query = query.gt('id', afterId);
    final rows = await query.order('id').limit(limit);
    return [for (final r in rows) r['id'] as String];
  }

  @override
  Future<void> invite(String listId, String email) => _friendly(
    () => _client.rpc<void>(
      'invite_to_list',
      params: {'p_list_id': listId, 'p_email': email},
    ),
  );

  @override
  Future<void> cancelInvite(String inviteId) =>
      _client.rpc<void>('cancel_invite', params: {'p_invite_id': inviteId});

  @override
  Future<List<SentInvite>> sentInvites(String listId) async {
    final rows = await _client
        .from('list_invites')
        .select('id, email')
        .eq('list_id', listId);
    return [
      for (final r in rows)
        SentInvite(id: r['id'] as String, email: r['email'] as String),
    ];
  }

  @override
  Future<List<ReceivedInvite>> myInvites() async {
    final List<dynamic> rows = await _client.rpc('my_invites');
    return [
      for (final r in rows.cast<Map<String, dynamic>>())
        ReceivedInvite(
          id: r['id'] as String,
          listId: r['list_id'] as String,
          listName: r['list_name'] as String,
          invitedBy: r['invited_by_email'] as String,
        ),
    ];
  }

  @override
  Future<void> acceptInvite(String inviteId) => _friendly(
    () => _client.rpc<void>('accept_invite', params: {'p_invite_id': inviteId}),
  );

  @override
  Future<void> declineInvite(String inviteId) =>
      _client.rpc<void>('decline_invite', params: {'p_invite_id': inviteId});

  @override
  Future<List<ListPerson>> people(String listId) async {
    final List<dynamic> rows = await _client.rpc(
      'list_people',
      params: {'p_list_id': listId},
    );
    return [
      for (final r in rows.cast<Map<String, dynamic>>())
        ListPerson(
          userId: r['user_id'] as String,
          email: r['email'] as String,
          isOwner: r['is_owner'] as bool,
        ),
    ];
  }

  @override
  Future<void> removeMember(String listId, String userId) => _client.rpc<void>(
    'remove_member',
    params: {'p_list_id': listId, 'p_user_id': userId},
  );

  /// Turns server errors worth showing into [CloudException].
  Future<void> _friendly(Future<Object?> Function() action) async {
    try {
      await action();
    } on AuthException catch (e) {
      throw CloudException(e.message);
    } on PostgrestException catch (e) {
      throw CloudException(e.message);
    }
  }
}
