import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app/app.dart';
import 'app/theme.dart';
import 'core/backend_config.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Draw under the status bar so backdrops reach the top edge instead of stopping at a dark strip.
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  try {
    await initializeBackend();
  } on Exception {
    return runApp(const _StartupUnavailable());
  } on StateError {
    return runApp(const _StartupUnavailable());
  }
  runApp(TaspaApp(client: Supabase.instance.client));
}

class _StartupUnavailable extends StatelessWidget {
  const _StartupUnavailable();

  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: taspaTheme(),
    home: const Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'Taspa could not start. Check the Supabase build settings.',
            ),
          ),
        ),
      ),
    ),
  );
}
