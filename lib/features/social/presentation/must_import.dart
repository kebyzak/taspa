import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../app/phosphor.dart';
import '../../../app/theme.dart';
import '../../catalog/presentation/discover_page.dart';
import '../../library/data/library_repository.dart';
import '../data/social_repository.dart';

/// Import a whole Must library (Want, watched movies, show progress, ratings, reviews) by public username.
class MustImportPage extends StatefulWidget {
  const MustImportPage({super.key});

  @override
  State<MustImportPage> createState() => _MustImportPageState();
}

class _MustImportPageState extends State<MustImportPage> {
  final _username = TextEditingController();
  SocialRow? _job;
  String? _error;
  bool _loading = true, _starting = false, _running = false;

  static const _messages = {
    'invalid_username': 'Enter your Must username, like @name.',
    'must_user_not_found': 'No Must profile with this username.',
    'must_profile_private':
        'This Must profile is private. Make it public in Must, then try again.',
    'must_library_empty': 'This Must profile has nothing to import.',
    'must_library_too_large': 'This library is too large to import.',
    'must_unavailable': 'Must is not answering right now. Try again later.',
  };

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _running = false;
    _username.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final job = await context.read<SocialRepository>().importStatus();
      if (!mounted) return;
      setState(() {
        _job = job;
        _loading = false;
      });
      if (job?['state'] == 'running') unawaited(_run());
    } on Exception {
      if (mounted)
        setState(() {
          _loading = false;
          _error = 'Could not load the import. Pull to retry.';
        });
    }
  }

  Future<void> _start() async {
    final name = _username.text.trim();
    if (name.isEmpty || _starting) return;
    setState(() {
      _starting = true;
      _error = null;
    });
    try {
      final job = await context.read<SocialRepository>().importMust(
        username: name,
      );
      if (!mounted) return;
      setState(() => _job = job);
      unawaited(_run());
    } on ImportFailure catch (failure) {
      if (mounted) {
        setState(
          () => _error =
              (_messages[failure.code] ??
                  'Could not start the import. Try again.') +
              (kDebugMode ? '\n[${failure.code}]' : ''),
        );
      }
    } on Exception catch (error) {
      if (mounted)
        setState(
          () => _error =
              'Could not start the import. Check your connection.${kDebugMode ? '\n[$error]' : ''}',
        );
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  /// Keeps stepping while this page is open; the server keeps progress, so leaving and coming back resumes.
  Future<void> _run() async {
    if (_running) return;
    _running = true;
    final social = context.read<SocialRepository>();
    final library = context.read<LibraryRepository>();
    var batches = 0;
    while (_running && mounted && _job?['state'] == 'running') {
      try {
        final job = await social.importMust();
        if (!mounted) break;
        setState(() {
          _job = job;
          _error = null;
        });
        // Let Library catch up every few steps instead of only at the end.
        if (++batches % 3 == 0 || job['state'] != 'running')
          library.notifyChanged();
      } on ImportFailure catch (failure) {
        if (failure.retryAfter == null) {
          if (mounted)
            setState(
              () => _error = _messages[failure.code] ?? 'Import paused. It will continue when you open this page again.',
            );
          break;
        }
        await Future<void>.delayed(
          Duration(seconds: failure.retryAfter!.clamp(5, 60)),
        );
      } on Exception {
        await Future<void>.delayed(const Duration(seconds: 10));
      }
    }
    _running = false;
    if (mounted && _job?['state'] == 'done') {
      // One "Imported N titles" line appears in Feed; Profile counts change too.
      social.notifyChanged();
    }
  }

  @override
  Widget build(BuildContext context) {
    final job = _job;
    final running = job?['state'] == 'running';
    final total = job?['total'] as int? ?? 0;
    final done = job?['done'] as int? ?? 0;
    final unmatched = (job?['unmatched'] as List? ?? const [])
        .cast<Map<String, dynamic>>();
    return Scaffold(
      appBar: AppBar(title: const Text('Import from Must')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _refresh,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                children: [
                  if (_error case final error?) ...[
                    InlineNotice(
                      error,
                      icon: PhosphorIconsRegular.warningCircle,
                    ),
                    const SizedBox(height: 12),
                  ],
                  if (running) ...[
                    Text(
                      'Importing @${job!['username']}',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 16),
                    LinearProgressIndicator(
                      value: total == 0 ? null : done / total,
                      color: coralColor,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '$done of $total titles',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Titles are matched one by one, so a big library takes a few minutes. '
                      'You can close the app: the import keeps going on our side and you get a notification when it is done. '
                      'With this page open it runs faster.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ] else ...[
                    if (job != null) ...[
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Row(
                            children: [
                              const Icon(
                                PhosphorIconsFill.checkCircle,
                                color: coralColor,
                                size: 32,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Imported ${job['imported']} of $total',
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleMedium,
                                    ),
                                    Text(
                                      'from @${job['username']}',
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall,
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 24),
                    ],
                    Text(
                      job == null ? 'Bring your Must library' : 'Import again',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Want, watched movies, show progress, ratings and reviews come over. '
                      'Titles you already have in Taspa stay as they are, so importing twice is safe.',
                      style: Theme.of(context).textTheme.bodyMedium
                          ?.copyWith(color: mutedColor),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _username,
                      enabled: !_starting,
                      autocorrect: false,
                      textInputAction: TextInputAction.go,
                      onSubmitted: (_) => _start(),
                      decoration: const InputDecoration(
                        labelText: 'Must username',
                        prefixText: '@',
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Your Must profile must be public while importing (Must → Settings → Privacy).',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: _starting ? null : _start,
                      child: _starting
                          ? const SizedBox.square(
                              dimension: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Import'),
                    ),
                  ],
                  if (unmatched.isNotEmpty) ...[
                    SectionHeader(
                      'Not found · ${unmatched.length}',
                      padding: const EdgeInsets.only(top: 32, bottom: 4),
                    ),
                    Text(
                      'Tap a title to find and add it yourself.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    for (final item in unmatched)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(
                          item['kind'] == 'show'
                              ? PhosphorIconsRegular.television
                              : PhosphorIconsRegular.filmStrip,
                        ),
                        title: Text(item['title'] as String? ?? ''),
                        subtitle: item['year'] == null
                            ? null
                            : Text('${item['year']}'),
                        trailing: const Icon(
                          PhosphorIconsRegular.magnifyingGlass,
                          size: 20,
                        ),
                        onTap: () => showSearchSheet(
                          context,
                          query: item['title'] as String?,
                        ),
                      ),
                  ],
                ],
              ),
            ),
    );
  }
}
