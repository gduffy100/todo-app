---
name: release
description: Cut a versioned release. Bump the version, tag, push; CI builds the signed AAB/APK and deploys web. Argument: patch | minor | major (default patch).
---

Delegate to the `release-engineer` subagent with this instruction: "Cut a <patch|minor|major> release."

The release engineer must:
1. Check that it's on `main`, the tree is clean and CI is green.
2. Bump the pubspec version.
3. Commit, tag, and push the commit and tag.
4. Watch the `release` workflow.
5. Report the Release and Pages URLs.
