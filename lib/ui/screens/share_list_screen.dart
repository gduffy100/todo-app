import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db.dart';
import '../../data/sync/cloud_backend.dart';
import '../../state/sync.dart';

/// Who has a list. The owner can also invite people and remove them.
class ShareListScreen extends ConsumerStatefulWidget {
  const ShareListScreen({super.key, required this.list, required this.isOwner});

  final TaskGroup list;
  final bool isOwner;

  @override
  ConsumerState<ShareListScreen> createState() => _ShareListScreenState();
}

class _ShareListScreenState extends ConsumerState<ShareListScreen> {
  final _email = TextEditingController();
  List<ListPerson> _people = const [];
  List<SentInvite> _invites = const [];
  bool _loading = true;
  String? _error;

  CloudBackend get _backend => ref.read(cloudBackendProvider)!;

  @override
  void initState() {
    super.initState();
    // Loading syncs, which updates providers: not allowed during a build.
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  Future<void> _load() => _guard(() async {
    // A new list has to reach the server before it can be shared.
    await ref.read(syncControllerProvider.notifier).syncNow();
    final people = await _backend.people(widget.list.id);
    final invites = widget.isOwner
        ? await _backend.sentInvites(widget.list.id)
        : const <SentInvite>[];
    _people = people;
    _invites = invites;
  });

  Future<void> _guard(Future<void> Function() action) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await action();
    } on CloudException catch (e) {
      _error = e.message;
    } catch (_) {
      _error = 'Could not reach the server. Are you online?';
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _invite() async {
    final email = _email.text.trim();
    if (!email.contains('@')) {
      setState(() => _error = 'Enter an email address');
      return;
    }
    await _guard(() async {
      await ref.read(syncControllerProvider.notifier).syncNow();
      await _backend.invite(widget.list.id, email);
      _email.clear();
      _invites = await _backend.sentInvites(widget.list.id);
    });
  }

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(currentUserProvider).value;
    return Scaffold(
      appBar: AppBar(title: Text(widget.list.name)),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: ListView(
            children: [
              if (_loading) const LinearProgressIndicator(),
              if (widget.isOwner)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextField(
                        controller: _email,
                        keyboardType: TextInputType.emailAddress,
                        decoration: const InputDecoration(
                          labelText: 'Invite by email',
                          helperText:
                              'They will see the invitation when they sign '
                              'in to Listo with this address. No email is '
                              'sent, so let them know.',
                          helperMaxLines: 3,
                        ),
                        onSubmitted: (_) => _invite(),
                      ),
                      const SizedBox(height: 12),
                      FilledButton(
                        onPressed: _loading ? null : _invite,
                        child: const Text('Invite'),
                      ),
                    ],
                  ),
                ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              for (final p in _people)
                ListTile(
                  leading: const Icon(Icons.person),
                  title: Text(p.email),
                  subtitle: p.isOwner ? const Text('Owner') : null,
                  trailing: widget.isOwner && !p.isOwner && p.userId != me?.id
                      ? IconButton(
                          tooltip: 'Remove ${p.email}',
                          icon: const Icon(Icons.person_remove),
                          onPressed: () => _guard(() async {
                            await _backend.removeMember(
                              widget.list.id,
                              p.userId,
                            );
                            _people = await _backend.people(widget.list.id);
                          }),
                        )
                      : null,
                ),
              for (final i in _invites)
                ListTile(
                  leading: const Icon(Icons.mail_outline),
                  title: Text(i.email),
                  subtitle: const Text('Invited'),
                  trailing: IconButton(
                    tooltip: 'Cancel invitation to ${i.email}',
                    icon: const Icon(Icons.close),
                    onPressed: () => _guard(() async {
                      await _backend.cancelInvite(i.id);
                      _invites = await _backend.sentInvites(widget.list.id);
                    }),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
