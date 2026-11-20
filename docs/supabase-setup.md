# Connecting Listo to Supabase

Sign-in, sync and shared lists need a Supabase project. Without one the app still builds and runs, local-only, with no sign-in option.

## 1. Create the project

Create a project at [supabase.com](https://supabase.com/dashboard). From **Project Settings → API**, note the **project URL** and the **publishable key** (older projects call it the anon key).

Never put the secret or `service_role` key in the app. It bypasses all access rules.

## 2. Create the database schema

Either paste [the migration](../supabase/migrations/20261101000000_lists_sync_and_sharing.sql) into the dashboard's **SQL Editor** and run it, or use the CLI:

```bash
npx supabase login
npx supabase init            # first time only
npx supabase link --project-ref <project-ref>
npx supabase db push
```

Later changes come as new files in `supabase/migrations/`. Apply each one the same way (paste it into the SQL Editor, or run `npx supabase db push`).

## Keep "Confirm email" on

In **Authentication → Sign In / Providers → Email**, leave **Confirm email** enabled. Invitations are matched by email address. With confirmation off, anyone could register someone else's address with a password and accept that person's invitations.

## 3. Make sign-in emails contain a code

The app signs in with a typed code, but the default email only has a link.

In **Authentication → Email Templates → Magic Link**, include the code in the body:

```html
<h2>Your Listo sign-in code</h2>
<p>{{ .Token }}</p>
```

## 4. Set up email delivery

The built-in email service is only for trying things out and allows very few messages per hour. Before inviting real users, add your own provider under **Authentication → SMTP Settings**.

## 5. Run the app against it

Run this as a single line. It works in PowerShell, Command Prompt and bash:

```bash
flutter run -d chrome --dart-define=SUPABASE_URL=https://<project-ref>.supabase.co --dart-define=SUPABASE_PUBLISHABLE_KEY=<publishable-key>
```

If the values don't arrive, the app falls back to local-only without an error. You can tell it's connected when **Sign in** appears in the main menu.

Release builds read the same two values from the GitHub Secrets `SUPABASE_URL` and `SUPABASE_PUBLISHABLE_KEY`. If they are not set, CI still succeeds and produces a local-only build.

## 6. Check it works

Use two accounts, on two devices or browser profiles:

1. Sign in on the first and create a list with a task in it.
2. Open the list's menu, choose **Share list**, and invite the second account's email.
3. Sign in on the second. Open **Account** in the main menu and join the list.
4. Edit a task on each side and confirm that the change appears on the other.
5. Remove the second account from the list and confirm that the list disappears there.

No invitation email is sent. Invitations appear in the app when that person signs in with the invited address.

## Testing the access rules

The rules are tested on real Postgres, with no Docker or Supabase account needed:

```bash
cd supabase/tests
npm ci
npm test
```
