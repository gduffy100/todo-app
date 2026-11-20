import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/sync/cloud_backend.dart';
import '../data/sync/sync_engine.dart';
import '../domain/label_filter.dart';
import 'providers.dart';

/// The cloud connection. Null means the app is running local-only, which is
/// also the default in tests.
final cloudBackendProvider = Provider<CloudBackend?>((ref) => null);

final currentUserProvider = StreamProvider<CloudUser?>((ref) async* {
  final backend = ref.watch(cloudBackendProvider);
  yield backend?.currentUser;
  if (backend != null) yield* backend.userChanges;
});

/// Lists other people can also see, as of the last sync.
final sharedListIdsProvider = StreamProvider<Set<String>>(
  (ref) => ref.watch(databaseProvider).syncDao.watchSharedListIds(),
);

final myInvitesProvider = FutureProvider<List<ReceivedInvite>>((ref) async {
  final backend = ref.watch(cloudBackendProvider);
  final user = ref.watch(currentUserProvider).value;
  if (backend == null || user == null) return const [];
  return backend.myInvites();
});

enum SyncPhase { off, idle, syncing, failed, accountMismatch }

class SyncStatus {
  const SyncStatus(this.phase, {this.lastSynced});
  final SyncPhase phase;
  final DateTime? lastSynced;
}

/// Decides when to sync: on sign-in, after local edits, when the server hints
/// at a change, when the app returns to the foreground, and periodically in
/// case a hint was missed. Failures are expected while offline; changes stay
/// queued and go out on a later pass.
class SyncController extends Notifier<SyncStatus> {
  static const _localDebounce = Duration(seconds: 2);
  static const _remoteDebounce = Duration(seconds: 1);
  static const _period = Duration(minutes: 5);

  Timer? _debounce;
  Future<void>? _inFlight;
  bool _runAgain = false;
  StreamSubscription<void>? _remote;

  @override
  SyncStatus build() {
    final backend = ref.watch(cloudBackendProvider);
    if (backend == null) return const SyncStatus(SyncPhase.off);

    final subs = <StreamSubscription<Object?>>[
      backend.userChanges.listen((_) => _onUserChanged(backend)),
      ref.read(databaseProvider).syncDao.watchPendingCount().listen((n) {
        if (n > 0) _schedule(_localDebounce);
      }),
    ];
    final periodic = Timer.periodic(_period, (_) => syncNow());
    final lifecycle = AppLifecycleListener(onResume: syncNow);
    ref.onDispose(() {
      _debounce?.cancel();
      periodic.cancel();
      lifecycle.dispose();
      _remote?.cancel();
      for (final s in subs) {
        s.cancel();
      }
    });
    Future.microtask(() => _onUserChanged(backend));
    return SyncStatus(
      backend.currentUser == null ? SyncPhase.off : SyncPhase.idle,
    );
  }

  void _onUserChanged(CloudBackend backend) {
    _remote?.cancel();
    _remote = null;
    if (backend.currentUser == null) {
      state = const SyncStatus(SyncPhase.off);
      return;
    }
    _remote = backend.remoteChanges.listen((_) => _schedule(_remoteDebounce));
    syncNow();
  }

  void _schedule(Duration delay) {
    _debounce?.cancel();
    _debounce = Timer(delay, syncNow);
  }

  /// Runs a pass now, or once more after the one in progress, and completes
  /// when local changes made before this call have been sent. Never throws:
  /// the outcome is reported through [state].
  Future<void> syncNow() {
    final inFlight = _inFlight;
    if (inFlight != null) {
      _runAgain = true;
      return inFlight;
    }
    return _inFlight = _run().whenComplete(() => _inFlight = null);
  }

  Future<void> _run() async {
    final backend = ref.read(cloudBackendProvider);
    final user = backend?.currentUser;
    if (backend == null || user == null) return;
    final engine = SyncEngine(ref.read(databaseProvider), backend);
    try {
      do {
        _runAgain = false;
        state = SyncStatus(SyncPhase.syncing, lastSynced: state.lastSynced);
        await engine.sync(user.id);
        _dropStaleFilter();
        state = SyncStatus(SyncPhase.idle, lastSynced: DateTime.now());
      } while (_runAgain);
      ref.invalidate(myInvitesProvider);
    } on AccountMismatch {
      state = const SyncStatus(SyncPhase.accountMismatch);
    } on SyncInterrupted {
      state = const SyncStatus(SyncPhase.off);
    } catch (e, stack) {
      debugPrint('Sync failed: $e\n$stack');
      state = SyncStatus(SyncPhase.failed, lastSynced: state.lastSynced);
    }
  }

  /// The first sync gives default labels new ids. A filter still naming an old
  /// one would match nothing and look as if every task had gone.
  void _dropStaleFilter() {
    final filter = ref.read(labelFilterProvider);
    if (filter.labelIds.any((id) => id.startsWith('seed-'))) {
      ref.read(labelFilterProvider.notifier).set(const LabelFilter());
    }
  }
}

final syncControllerProvider = NotifierProvider<SyncController, SyncStatus>(
  SyncController.new,
);
