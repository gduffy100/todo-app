# CLAUDE.md

Guidance for Claude Code working in this repository.

## What this is
A local-first to-do app built with Flutter. It targets Android first (side-loaded, then the Play Store), plus desktop/mobile web; iOS comes later. Data lives in SQLite via Drift: native SQLite on mobile, SQLite-WASM in the browser.

**Stack:** Flutter (stable) · Dart · Drift · Riverpod · uuid · intl.

## Commands
Flutter SDK lives at `C:\dev\flutter` (on PATH as `flutter` / `dart`).

```bash
flutter pub get
dart run build_runner build   # regenerate Drift *.g.dart after schema/DAO changes
flutter analyze                                             # must be clean before commit
flutter test                                                # unit + widget tests
flutter test --coverage                                     # coverage → coverage/lcov.info
flutter test integration_test -d <deviceId>                 # e2e on emulator / USB phone
flutter run -d chrome                                       # web dev
flutter build apk --release                                 # side-load APK → build/app/outputs/flutter-apk/app-release.apk
flutter build appbundle --release                           # Play Store AAB
flutter build web --release --base-href /todo-app/          # GitHub Pages build
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

## Layout
```
lib/
  data/     Drift database (db.dart), tables, DAOs, connection (native vs web)
  domain/   pure Dart: ordering (fractional index), dependency graph, filters
  state/    Riverpod providers (stream from Drift)
  ui/       screens/, widgets/, layout breakpoints
test/              unit + widget tests (in-memory Drift NativeDatabase)
integration_test/  end-to-end flows
web/               sqlite3.wasm + drift_worker.js for Drift web
```

## Data rules (sync-ready — do not break)
- Every table has `id` (TEXT uuid v4 PK), `created_at`, `updated_at` and nullable `deleted_at`.
- **Never hard-delete user data.** Set `deleted_at`, and filter it out in queries.
- Every write bumps `updated_at`. That is all a future last-write-wins sync needs.
- Ordering uses a `sort_key` TEXT fractional index (see `domain/ordering.dart`). Reordering updates only the moved row. Never renumber siblings.
- Schema changes need a Drift `schemaVersion` bump plus a migration step, and a test for the migration.
- Predecessors form a DAG. Reject any edge that would create a cycle.

## Terminology
The UI calls them **lists** (Today, Tomorrow, Longer term, user lists); the code and DB call them groups (`task_groups`, `GroupsDao`, `groupId`). One or more lists can be shown at once (`selectedListIdsProvider`); several shown lists render as sections in a combined view. A list will be the unit of sharing.

## Responsive layouts
Layout is chosen by width (see `ui/layout/breakpoints.dart`), not by platform:
- **compact** (< 600dp): phone portrait. Labels shown as dots; editor in a bottom sheet; group bar at the bottom.
- **medium** (600–1024dp): richer tiles showing label names, due date and a notes preview.
- **expanded** (≥ 1024dp): tablet landscape / desktop. Two panes (list + detail); groups in a side rail.

## Workflow
- Branch per milestone/feature: `feat/...`, `fix/...`, `chore/...`. Open a PR with `gh pr create`; squash-merge once CI is green.
- Conventional Commits (`feat:`, `fix:`, `test:`, `chore:`, `ci:`, `docs:`).
- Before each commit, `flutter analyze` must be clean and `flutter test` must pass. Use `/ship`.
- New logic needs unit tests. New widgets need widget tests. Use the `test-engineer` subagent for substantial test work.
- Run the `code-reviewer` subagent on the diff before opening a PR.
- Releases: run `/release`. It tags `vX.Y.Z`, and CI builds the signed AAB/APK and deploys the web build to GitHub Pages.

## Secrets
The upload keystore and `android/key.properties` are never committed. CI gets them from these GitHub Secrets:
- `ANDROID_KEYSTORE_BASE64`
- `ANDROID_KEYSTORE_PASSWORD`
- `ANDROID_KEY_ALIAS`
- `ANDROID_KEY_PASSWORD`
