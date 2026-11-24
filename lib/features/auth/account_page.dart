import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../app/theme.dart';
import '../../core/backend_config.dart';
import '../../core/offline_store.dart';
import '../notifications/notifications.dart';
import 'auth_cubit.dart';

enum _Form { signIn, signUp, forgot }

class AccountPage extends StatefulWidget {
  const AccountPage({super.key, this.returnTo});

  final String? returnTo;

  @override
  State<AccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends State<AccountPage> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _handle = TextEditingController();
  _Form _form = _Form.signIn;
  bool _saving = false;
  String? _message;

  @override
  void dispose() {
    for (final controller in [_email, _password, _handle]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    final account = context.read<AccountCubit>();
    final auth = Supabase.instance.client.auth;
    final email = _email.text.trim();
    final phase = account.state.phase;
    final guest = phase == AccountPhase.guest;
    final missing = switch (phase) {
      AccountPhase.needsHandle when _handle.text.trim().isEmpty =>
        'Enter a handle.',
      AccountPhase.recovery when _password.text.isEmpty =>
        'Enter a new password.',
      _ when guest && email.isEmpty =>
        _form == _Form.signIn
            ? 'Enter your email or handle.'
            : 'Enter your email.',
      _ when guest && _form != _Form.signIn && !email.contains('@') =>
        'Enter a valid email.',
      _
          when guest &&
              (_form == _Form.signIn || _form == _Form.signUp) &&
              _password.text.isEmpty =>
        'Enter your password.',
      _ => null,
    };
    if (missing != null) {
      setState(() => _message = missing);
      return;
    }
    setState(() {
      _saving = true;
      _message = null;
    });
    try {
      switch (account.state.phase) {
        case AccountPhase.needsHandle:
          await account.claim(_handle.text.trim());
        case AccountPhase.recovery:
          await account.changePassword(_password.text);
        case AccountPhase.unavailable:
          await account.refresh();
        case AccountPhase.guest:
          switch (_form) {
            case _Form.signIn when email.indexOf('@') > 0:
              await auth.signInWithPassword(
                email: email,
                password: _password.text,
              );
            case _Form.signIn:
              final response = await Supabase.instance.client.functions.invoke(
                'sign-in',
                body: {
                  'handle': email.replaceFirst('@', ''),
                  'password': _password.text,
                },
              );
              await auth.setSession(
                (response.data as Map)['refresh_token'] as String,
              );
            case _Form.signUp:
              await auth.signUp(
                email: email,
                password: _password.text,
                emailRedirectTo: authCallback,
              );
              if (mounted) {
                setState(() {
                  _form = _Form.signIn;
                  _message = 'Check your email and open the confirmation link, then sign in.';
                });
              }
            case _Form.forgot:
              await auth.resetPasswordForEmail(email, redirectTo: authCallback);
              if (mounted) {
                setState(() {
                  _form = _Form.signIn;
                  _message = 'If the address is registered, a reset message will arrive shortly.';
                });
              }
          }
        case AccountPhase.loading:
        case AccountPhase.ready:
          break;
      }
    } on AuthException catch (error) {
      if (mounted) {
        setState(() {
          _message = switch (error.code) {
            'email_not_confirmed' => 'Verify your email before signing in.',
            'invalid_credentials' => 'Wrong email or password.',
            'user_already_exists' ||
            'email_exists' => 'An account with this email already exists.',
            'weak_password' =>
              'Choose a stronger password (at least 6 characters).',
            'email_address_invalid' => 'Enter a valid email.',
            'over_request_rate_limit' || 'over_email_send_rate_limit' =>
              'Too many attempts. Wait a minute and try again.',
            _ =>
              'Something went wrong. Try again.'
                  '${kDebugMode ? '\n[${error.statusCode}] ${error.code}: ${error.message}' : ''}',
          };
        });
      }
    } on FunctionException catch (error) {
      if (mounted) {
        setState(() {
          _message = switch ((error.details as Map?)?['code']) {
            'invalid_credentials' => 'Wrong handle or password.',
            'email_not_confirmed' => 'Verify your email before signing in.',
            'over_request_rate_limit' =>
              'Too many attempts. Wait a minute and try again.',
            _ => 'Something went wrong. Try again.',
          };
        });
      }
    } on PostgrestException catch (error) {
      if (mounted) {
        setState(() {
          _message = switch (error.code) {
            '23505' => 'That handle is taken.',
            '22023' => 'Use 3–24 lowercase letters, numbers, or underscores.',
            _ => 'Profile setup is unavailable. Try again.',
          };
        });
      }
    } on Exception {
      if (mounted) setState(() => _message = 'Could not connect. Try again.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _switchForm(_Form form) => setState(() {
    _form = form;
    _message = null;
  });

  Future<void> _deleteAccount() async {
    String password = '';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Permanently delete your account?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Your library, reviews and profile will be removed.'),
            TextField(
              onChanged: (value) => password = value,
              obscureText: true,
              enableSuggestions: false,
              autocorrect: false,
              decoration: const InputDecoration(labelText: 'Current password'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              if (password.isNotEmpty) Navigator.pop(dialog, true);
            },
            child: const Text('Delete account'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final client = Supabase.instance.client;
    final push = context.read<AndroidPush>();
    final store = context.read<OfflineStore>();
    final id = client.auth.currentUser?.id;
    setState(() {
      _saving = true;
      _message = null;
    });
    try {
      await client.functions.invoke(
        'delete-account',
        body: {'confirm': true, 'password': password},
      );
      await push.beforeSignOut().catchError((Object _) {});
      await client.auth.signOut(scope: SignOutScope.local);
      if (id != null) await store.forgetEdits(id).catchError((Object _) {});
      if (mounted) context.go('/discover');
    } on FunctionException catch (error) {
      if (mounted) {
        setState(
          () => _message = error.status == 403
              ? 'Check your current password and try again.'
              : 'Could not confirm account deletion. Try again.',
        );
      }
    } on Exception {
      if (mounted) {
        setState(
          () => _message = 'Could not confirm account deletion. Try again.',
        );
      }
    } finally {
      password = '';
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _signOut(String owner) async {
    final store = context.read<OfflineStore>();
    final push = context.read<AndroidPush>();
    setState(() {
      _saving = true;
      _message = null;
    });
    try {
      if (await store.hasEdits(owner)) {
        if (!mounted) return;
        final keep = await showDialog<bool>(
          context: context,
          builder: (dialog) => AlertDialog(
            title: const Text('Keep unsynced changes?'),
            content: const Text(
              'You can restore saved drafts and pending changes when you sign in to this account again.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialog),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(dialog, false),
                child: const Text('Discard'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(dialog, true),
                child: const Text('Keep on this device'),
              ),
            ],
          ),
        );
        if (keep == null) return;
        if (!keep) await store.forgetEdits(owner);
      }
      await push.beforeSignOut().catchError((Object _) {});
      await Supabase.instance.client.auth.signOut(scope: SignOutScope.local);
    } on Exception {
      if (mounted) setState(() => _message = 'Could not sign out. Try again.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final account = context.watch<AccountCubit>().state;
    final phase = account.phase;
    final label = switch (phase) {
      AccountPhase.needsHandle => 'Choose a handle',
      AccountPhase.recovery => 'New password',
      AccountPhase.unavailable => 'Try again',
      _ => switch (_form) {
        _Form.signIn => 'Sign in',
        _Form.signUp => 'Create account',
        _Form.forgot => 'Send reset email',
      },
    };
    return BlocListener<AccountCubit, Account>(
      listenWhen: (previous, current) =>
          previous.phase != AccountPhase.ready &&
          current.phase == AccountPhase.ready,
      listener: (context, state) {
        final route = widget.returnTo;
        if (context.canPop()) {
          context.pop();
        } else {
          context.go(
            route != null &&
                    (route.startsWith('/titles/') || route == '/library')
                ? route
                : '/profile',
          );
        }
      },
      child: ListView(
        padding: const EdgeInsets.fromLTRB(24, 32, 24, 32),
        children: [
          if (phase == AccountPhase.guest) ...[
            Center(
              child: SvgPicture.asset(
                'assets/brand/wordmark_ivory.svg',
                width: 120,
                semanticsLabel: 'Taspa',
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Your film and TV diary',
              textAlign: TextAlign.center,
              style: TextStyle(color: mutedColor),
            ),
            const SizedBox(height: 40),
          ],
          Text(
            phase == AccountPhase.ready ? 'Account' : label,
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 24),
          if (phase == AccountPhase.loading) const Skeleton(rows: 3),
          if (phase == AccountPhase.ready) ...[
            Text('@${account.handle}'),
            const SizedBox(height: 24),
            OutlinedButton(
              onPressed: _saving ? null : () => _signOut(account.userId!),
              child: const Text('Sign out'),
            ),
            TextButton(
              onPressed: _saving ? null : _deleteAccount,
              child: const Text('Delete account'),
            ),
          ],
          if (phase == AccountPhase.guest)
            TextField(
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              autocorrect: false,
              autofillHints: [
                _form == _Form.signIn
                    ? AutofillHints.username
                    : AutofillHints.email,
              ],
              decoration: InputDecoration(
                labelText: _form == _Form.signIn ? 'Email or handle' : 'Email',
              ),
            ),
          if (phase == AccountPhase.needsHandle)
            TextField(
              controller: _handle,
              decoration: const InputDecoration(labelText: 'Handle'),
              autocorrect: false,
            ),
          if (phase == AccountPhase.recovery ||
              (phase == AccountPhase.guest &&
                  (_form == _Form.signUp || _form == _Form.signIn))) ...[
            const SizedBox(height: 12),
            TextField(
              controller: _password,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Password'),
            ),
          ],
          if (_message case final message?) ...[
            const SizedBox(height: 12),
            Semantics(liveRegion: true, child: Text(message)),
          ],
          if (phase != AccountPhase.ready && phase != AccountPhase.loading) ...[
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _saving ? null : _submit,
              child: Text(_saving ? 'Working…' : label),
            ),
          ],
          if (phase == AccountPhase.guest)
            Wrap(
              alignment: WrapAlignment.center,
              children: [
                if (_form != _Form.signIn)
                  TextButton(
                    onPressed: () => _switchForm(_Form.signIn),
                    child: const Text('Sign in'),
                  ),
                if (_form != _Form.signUp)
                  TextButton(
                    onPressed: () => _switchForm(_Form.signUp),
                    child: const Text('Create account'),
                  ),
                if (_form == _Form.signIn)
                  TextButton(
                    onPressed: () => _switchForm(_Form.forgot),
                    child: const Text('Forgot password'),
                  ),
              ],
            ),
          const SizedBox(height: 24),
          TextButton(
            onPressed: () => context.push('/help'),
            style: TextButton.styleFrom(foregroundColor: mutedColor),
            child: const Text('About Taspa and help'),
          ),
        ],
      ),
    );
  }
}
