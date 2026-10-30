---
name: ship
description: Analyze, test, commit, push the current branch and open (or update) a PR. Use when a unit of work is finished.
---

1. If on `main`, create a branch named after the work (`feat/...`, `fix/...`, `chore/...`) before committing.
2. If any Drift table or DAO changed, run `dart run build_runner build`.
3. Run `dart format lib test integration_test` and `flutter analyze`. Fix every issue.
4. Run `flutter test`. If anything fails, stop and fix it, or report it. Never commit with failing tests.
5. Run the `code-reviewer` subagent on the diff. Address high-severity findings.
6. Stage the relevant files and commit with a Conventional Commit message. Never stage `android/key.properties` or `*.jks`.
7. `git push -u origin HEAD`.
8. If no PR exists for the branch, run `gh pr create --fill`, with a body summarising changes and the test results. Otherwise report the existing PR URL.
9. Run `gh pr checks --watch`. Report the outcome. If the user has asked for auto-merge, run `gh pr merge --squash --delete-branch` once checks pass.
