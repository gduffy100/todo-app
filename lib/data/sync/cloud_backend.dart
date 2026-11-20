/// What the app needs from the cloud: sign-in, sharing and row transport.
/// Implemented by [SupabaseBackend]; tests use an in-memory fake, and a null
/// backend means the app is running local-only.
///
/// Every read that can return many rows takes a `limit` and a keyset position
/// and returns one page, ordered by that key. The server caps a response at
/// 1000 rows, so a caller that wants everything must keep paging.
abstract class CloudBackend {
  CloudUser? get currentUser;
  Stream<CloudUser?> get userChanges;

  /// Fires when something changed on the server, as a hint to sync.
  Stream<void> get remoteChanges;

  /// Emails a one-time sign-in code to [email].
  Future<void> sendCode(String email);
  Future<void> verifyCode(String email, String code);
  Future<void> signOut();

  /// Rows of [table] stamped at or after [since] (null = all), ordered by
  /// `server_updated_at` then `id`, starting after [after].
  Future<List<Map<String, dynamic>>> fetchChanged(
    String table, {
    DateTime? since,
    PagePosition? after,
    required int limit,
  });

  /// Rows of [table] whose [column] is one of [values], ordered by `id`,
  /// starting after [afterId].
  Future<List<Map<String, dynamic>>> fetchWhereIn(
    String table,
    String column,
    List<String> values, {
    String? afterId,
    required int limit,
  });

  /// Writes [rows], matching existing ones on [onConflict], and returns the
  /// ids it stored. A row missing from the result lost to a newer version
  /// already on the server. Throws [RowsRejected] if the server refuses them
  /// for good; anything else (such as being offline) is worth retrying.
  Future<Set<String>> upsert(
    String table,
    List<Map<String, dynamic>> rows, {
    required String onConflict,
  });

  /// Lists the user can currently reach, including deleted ones, ordered by
  /// id, starting after [afterId].
  Future<List<AccessibleList>> accessibleLists({
    String? afterId,
    required int limit,
  });

  /// Ids of live tasks currently in [listIds], ordered, after [afterId].
  Future<List<String>> taskIdsInLists(
    List<String> listIds, {
    String? afterId,
    required int limit,
  });

  Future<void> invite(String listId, String email);
  Future<void> cancelInvite(String inviteId);
  Future<List<SentInvite>> sentInvites(String listId);
  Future<List<ReceivedInvite>> myInvites();
  Future<void> acceptInvite(String inviteId);
  Future<void> declineInvite(String inviteId);
  Future<List<ListPerson>> people(String listId);
  Future<void> removeMember(String listId, String userId);
}

/// Where a page of [CloudBackend.fetchChanged] ended.
class PagePosition {
  const PagePosition(this.stamp, this.id);

  /// `server_updated_at` exactly as the server sent it.
  final String stamp;
  final String id;
}

class CloudUser {
  const CloudUser({required this.id, required this.email});
  final String id;
  final String email;
}

class AccessibleList {
  const AccessibleList({required this.id, required this.isShared});
  final String id;

  /// True if anyone other than this user can see the list.
  final bool isShared;
}

class SentInvite {
  const SentInvite({required this.id, required this.email});
  final String id;
  final String email;
}

class ReceivedInvite {
  const ReceivedInvite({
    required this.id,
    required this.listId,
    required this.listName,
    required this.invitedBy,
  });
  final String id;
  final String listId;
  final String listName;
  final String invitedBy;
}

class ListPerson {
  const ListPerson({
    required this.userId,
    required this.email,
    required this.isOwner,
  });
  final String userId;
  final String email;
  final bool isOwner;
}

/// The server permanently refused the rows, usually because access was lost.
class RowsRejected implements Exception {
  const RowsRejected(this.message);
  final String message;
  @override
  String toString() => 'RowsRejected: $message';
}

/// A problem to show the user as-is, such as a wrong sign-in code.
class CloudException implements Exception {
  const CloudException(this.message);
  final String message;
  @override
  String toString() => message;
}
