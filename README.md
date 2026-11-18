# Taspa

## Run locally

Copy `.env.example` to `.env` in the project root and fill in the Supabase URL and publishable key. Keep server credentials in Supabase Edge Function secrets.

In Android Studio, open the project root and select the `main.dart` Flutter run configuration. Its **Additional run args** should contain `--dart-define-from-file=.env`. If you use a different configuration, add that same argument.

To launch from a terminal, run this from the project root:

```powershell
flutter run --dart-define-from-file=.env
```

The argument supplies compile-time settings. Stop the previous debug session before starting again with the updated configuration.
