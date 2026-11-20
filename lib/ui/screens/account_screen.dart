import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../data/sync/cloud_backend.dart';
import '../../state/sync.dart';

/// Sign-in when signed out; sync status and invitations when signed in.
class AccountScreen extends ConsumerWidget {
  const AccountScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider).value;
    return Scaffold(
      appBar: AppBar(title: Text(user == null ? 'Sign in' : 'Account')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: user == null ? const _SignInForm() : _Account(user: user),
        ),
      ),
    );
  }
}

/// Signs in with a code sent by email: no password to keep, and no deep link
/// to configure on each platform.
class _SignInForm extends ConsumerStatefulWidget {
  const _SignInForm();

  @override
  ConsumerState<_SignInForm> createState() => _SignInFormState();
}

class _SignInFormState extends ConsumerState<_SignInForm> {
  final _email = TextEditingController();
  final _code = TextEditingController();
  bool _codeSent = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function(CloudBackend b) action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action(ref.read(cloudBackendProvider)!);
    } on CloudException catch (e) {
      _error = e.message;
    } catch (_) {
      _error = 'Could not reach the server. Are you online?';
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _sendCode() async {
    final email = _email.text.trim();
    if (!email.contains('@')) {
      setState(() => _error = 'Enter your email address');
      return;
    }
    await _run((b) async {
      await b.sendCode(email);
      _codeSent = true;
    });
  }

  Future<void> _verify() => _run((b) => b.verifyCode(_email.text, _code.text));

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          _codeSent
              ? 'Enter the code we sent to ${_email.text.trim()}.'
              : 'Sign in to use your lists on all your devices and share them '
                    'with other people. Everything on this device is kept and '
                    'uploaded to your account.',
        ),
        const SizedBox(height: 16),
        if (!_codeSent)
          TextField(
            controller: _email,
            autofocus: true,
            keyboardType: TextInputType.emailAddress,
            autofillHints: const [AutofillHints.email],
            decoration: const InputDecoration(labelText: 'Email'),
            onSubmitted: (_) => _sendCode(),
          )
        else
          TextField(
            controller: _code,
            autofocus: true,
            keyboardType: TextInputType.number,
            autofillHints: const [AutofillHints.oneTimeCode],
            decoration: const InputDecoration(labelText: 'Code'),
            onSubmitted: (_) => _verify(),
          ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _busy ? null : (_codeSent ? _verify : _sendCode),
          child: Text(_codeSent ? 'Sign in' : 'Email me a code'),
        ),
        if (_codeSent)
          TextButton(
            onPressed: _busy
                ? null
                : () => setState(() {
                    _codeSent = false;
                    _code.clear();
                    _error = null;
                  }),
            child: const Text('Use a different email'),
          ),
      ],
    );
  }
}

class _Account extends ConsumerWidget {
  const _Account({required this.user});
  final CloudUser user;

  String _statusText(SyncStatus status) => switch (status.phase) {
    SyncPhase.syncing => 'Syncing…',
    SyncPhase.failed =>
      'Could not sync. Your changes are saved and will be sent later.',
    SyncPhase.accountMismatch =>
      'This device holds data from a different account, so it is not syncing. '
          'Sign in with that account to continue.',
    _ =>
      status.lastSynced == null
          ? 'Not synced yet'
          : 'Last synced ${DateFormat.jm().format(status.lastSynced!)}',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(syncControllerProvider);
    final invites = ref.watch(myInvitesProvider).value ?? const [];
    final backend = ref.read(cloudBackendProvider)!;
    final sync = ref.read(syncControllerProvider.notifier);

    Future<void> respond(Future<void> Function() action) async {
      final messenger = ScaffoldMessenger.of(context);
      try {
        await action();
        ref.invalidate(myInvitesProvider);
        await sync.syncNow();
      } catch (_) {
        messenger.showSnackBar(
          const SnackBar(content: Text('That did not work. Are you online?')),
        );
      }
    }

    return ListView(
      children: [
        ListTile(
          leading: const Icon(Icons.account_circle),
          title: Text(user.email),
        ),
        ListTile(
          leading: Icon(
            status.phase == SyncPhase.idle ? Icons.cloud_done : Icons.cloud_off,
          ),
          title: Text(_statusText(status)),
          trailing: IconButton(
            tooltip: 'Sync now',
            icon: const Icon(Icons.sync),
            onPressed: status.phase == SyncPhase.syncing ? null : sync.syncNow,
          ),
        ),
        if (invites.isNotEmpty) ...[
          const Divider(),
          const ListTile(dense: true, title: Text('Invitations')),
          for (final i in invites)
            ListTile(
              title: Text(i.listName),
              subtitle: Text('From ${i.invitedBy}'),
              trailing: Wrap(
                children: [
                  TextButton(
                    onPressed: () => respond(() => backend.declineInvite(i.id)),
                    child: const Text('Decline'),
                  ),
                  FilledButton(
                    onPressed: () => respond(() => backend.acceptInvite(i.id)),
                    child: const Text('Join'),
                  ),
                ],
              ),
            ),
        ],
        const Divider(),
        ListTile(
          leading: const Icon(Icons.logout),
          title: const Text('Sign out'),
          subtitle: const Text('Your lists stay on this device'),
          onTap: backend.signOut,
        ),
      ],
    );
  }
}
