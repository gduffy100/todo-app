// Runs the real migration on real Postgres (PGlite) and exercises it as the
// `authenticated` role, with a stub of the parts of Supabase it relies on.
import assert from 'node:assert/strict';
import { readdirSync, readFileSync } from 'node:fs';
import { beforeEach, test } from 'node:test';
import { PGlite } from '@electric-sql/pglite';

const migrationsDir = new URL('../migrations/', import.meta.url);

const supabaseStub = `
  create role anon nologin;
  create role authenticated nologin;
  grant usage on schema public to anon, authenticated;
  -- Mirrors Supabase: new objects are fully granted unless revoked.
  alter default privileges in schema public
    grant all on tables to anon, authenticated;
  alter default privileges in schema public
    grant all on functions to anon, authenticated;
  create schema auth;
  grant usage on schema auth to anon, authenticated;
  create table auth.users (
    id uuid primary key,
    email text,
    email_confirmed_at timestamptz
  );
  create function auth.uid() returns uuid language sql stable as $$
    select nullif(current_setting('test.uid', true), '')::uuid
  $$;
  create publication supabase_realtime;
`;

const ALICE = '00000000-0000-4000-8000-00000000000a';
const BOB = '00000000-0000-4000-8000-00000000000b';
const MALLORY = '00000000-0000-4000-8000-00000000000c';
const UNVERIFIED = '00000000-0000-4000-8000-00000000000d';
const T = '2026-01-01T00:00:00Z';

let db;

/** Runs [sql] as [uid] in the `authenticated` role; returns the rows. */
async function as(uid, sql, params = []) {
  await db.exec(`set test.uid = '${uid}'; set role authenticated;`);
  try {
    return (await db.query(sql, params)).rows;
  } finally {
    await db.exec(`reset role; set test.uid = '';`);
  }
}

async function denied(promise, code = '42501') {
  await assert.rejects(promise, (e) => {
    assert.equal(e.code, code, e.message);
    return true;
  });
}

const addList = (uid, id, { name = id, system = false, at = T } = {}) =>
  as(
    uid,
    `insert into task_groups (id, name, sort_key, is_system, created_at, updated_at)
     values ($1, $2, 'a', $3, $4, $4)`,
    [id, name, system, at],
  );

const addTask = (uid, id, listId, { title = id, at = T } = {}) =>
  as(
    uid,
    `insert into tasks (id, group_id, title, sort_key, created_at, updated_at)
     values ($1, $2, $3, 'a', $4, $4)`,
    [id, listId, title, at],
  );

const addLabel = (uid, id) =>
  as(
    uid,
    `insert into labels (id, name, color, created_at, updated_at)
     values ($1, $1, 1, $2, $2)`,
    [id, T],
  );

async function share(listId, ownerUid, memberUid, email) {
  await as(ownerUid, 'select invite_to_list($1, $2)', [listId, email]);
  const [invite] = await as(memberUid, 'select * from my_invites()');
  await as(memberUid, 'select accept_invite($1)', [invite.id]);
}

const ids = (rows) => rows.map((r) => r.id).sort();

beforeEach(async () => {
  db = new PGlite();
  await db.exec(supabaseStub);
  for (const f of readdirSync(migrationsDir).sort()) {
    await db.exec(readFileSync(new URL(f, migrationsDir), 'utf8'));
  }
  await db.query(
    `insert into auth.users (id, email, email_confirmed_at) values
       ($1, 'alice@example.com', now()), ($2, 'bob@example.com', now()),
       ($3, 'mallory@example.com', now()), ($4, 'bob2@example.com', null)`,
    [ALICE, BOB, MALLORY, UNVERIFIED],
  );
});

test('users see only their own lists and tasks', async () => {
  await addList(ALICE, 'a1');
  await addTask(ALICE, 't1', 'a1');
  assert.deepEqual(await as(MALLORY, 'select * from task_groups'), []);
  assert.deepEqual(await as(MALLORY, 'select * from tasks'), []);
  assert.deepEqual(ids(await as(ALICE, 'select id from tasks')), ['t1']);
});

test('owner_id cannot be forged on insert or changed on update', async () => {
  await as(
    MALLORY,
    `insert into task_groups (id, owner_id, name, sort_key, created_at, updated_at)
     values ('m1', $1, 'x', 'a', $2, $2)`,
    [ALICE, T],
  );
  assert.deepEqual(await as(ALICE, 'select * from task_groups'), []);
  await as(MALLORY, `update task_groups set owner_id = $1 where id = 'm1'`, [ALICE]);
  const [row] = await as(MALLORY, `select owner_id from task_groups where id = 'm1'`);
  assert.equal(row.owner_id, MALLORY);
});

test('an upsert cannot take over a row with an existing id', async () => {
  await addList(ALICE, 'a1');
  await addTask(ALICE, 't1', 'a1');
  await denied(
    as(
      MALLORY,
      `insert into task_groups (id, name, sort_key, created_at, updated_at)
       values ('a1', 'stolen', 'a', $1, '2030-01-01')
       on conflict (id) do update set name = excluded.name`,
      [T],
    ),
  );
  await addList(MALLORY, 'm1');
  await denied(
    as(
      MALLORY,
      `insert into tasks (id, group_id, title, sort_key, created_at, updated_at)
       values ('t1', 'm1', 'stolen', 'a', $1, '2030-01-01')
       on conflict (id) do update set title = excluded.title, group_id = excluded.group_id`,
      [T],
    ),
  );
  const [t] = await as(ALICE, `select title, group_id from tasks where id = 't1'`);
  assert.deepEqual(t, { title: 't1', group_id: 'a1' });
});

test('tasks cannot be added to a list you cannot reach', async () => {
  await addList(ALICE, 'a1');
  await denied(addTask(MALLORY, 't1', 'a1'));
});

test('hard deletes and truncate are refused', async () => {
  await addList(ALICE, 'a1');
  await addTask(ALICE, 't1', 'a1');
  await denied(as(ALICE, 'delete from tasks'));
  await denied(as(ALICE, 'truncate tasks cascade'));
  await denied(as(MALLORY, 'truncate task_groups cascade'));
  assert.equal((await as(ALICE, 'select id from tasks')).length, 1);
});

test('anon can read nothing', async () => {
  await db.exec('set role anon;');
  try {
    await denied(db.query('select * from tasks'));
    await denied(db.query('select * from my_invites()'));
  } finally {
    await db.exec('reset role;');
  }
});

test('an older write loses, a newer or equal one wins', async () => {
  await addList(ALICE, 'a1', { at: '2026-06-01T00:00:00Z' });
  const upsert = (name, at) =>
    as(
      ALICE,
      `insert into task_groups (id, name, sort_key, created_at, updated_at)
       values ('a1', $1, 'a', $2, $2)
       on conflict (id) do update set name = excluded.name, updated_at = excluded.updated_at`,
      [name, at],
    );
  const name = async () =>
    (await as(ALICE, `select name from task_groups where id = 'a1'`))[0].name;
  await upsert('stale', '2026-01-01T00:00:00Z');
  assert.equal(await name(), 'a1');
  await upsert('tie', '2026-06-01T00:00:00Z');
  assert.equal(await name(), 'tie');
  await upsert('new', '2026-07-01T00:00:00Z');
  assert.equal(await name(), 'new');
});

test('a far-future client clock is clamped', async () => {
  await addList(ALICE, 'a1', { at: '2999-01-01T00:00:00Z' });
  const [r] = await as(ALICE, `select updated_at from task_groups where id = 'a1'`);
  assert.ok(r.updated_at.getFullYear() < 2999);
});

test('accepting an invite grants access to the list and its tasks', async () => {
  await addList(ALICE, 'a1', { name: 'Trip' });
  await addTask(ALICE, 't1', 'a1');
  await as(ALICE, 'select invite_to_list($1, $2)', ['a1', ' BOB@Example.com ']);
  assert.deepEqual(await as(BOB, 'select * from tasks'), []);
  const [invite] = await as(BOB, 'select * from my_invites()');
  assert.equal(invite.list_name, 'Trip');
  assert.equal(invite.invited_by_email, 'alice@example.com');
  await as(BOB, 'select accept_invite($1)', [invite.id]);
  assert.deepEqual(ids(await as(BOB, 'select id from tasks')), ['t1']);
  await addTask(BOB, 't2', 'a1');
  assert.deepEqual(ids(await as(ALICE, 'select id from tasks')), ['t1', 't2']);
  assert.deepEqual(await as(BOB, 'select * from my_invites()'), []);
});

test('an invite cannot be claimed by anyone else', async () => {
  await addList(ALICE, 'a1');
  await as(ALICE, 'select invite_to_list($1, $2)', ['a1', 'bob@example.com']);
  const [invite] = await as(BOB, 'select * from my_invites()');
  assert.deepEqual(await as(MALLORY, 'select * from my_invites()'), []);
  await denied(as(MALLORY, 'select accept_invite($1)', [invite.id]), 'P0002');
  assert.deepEqual(await as(MALLORY, 'select * from task_groups'), []);
});

test('an unverified email cannot claim an invite', async () => {
  await addList(ALICE, 'a1');
  await as(ALICE, 'select invite_to_list($1, $2)', ['a1', 'bob2@example.com']);
  assert.deepEqual(await as(UNVERIFIED, 'select * from my_invites()'), []);
  const [{ id }] = (await db.query('select id from list_invites')).rows;
  await denied(as(UNVERIFIED, 'select accept_invite($1)', [id]), 'P0002');
});

test('only the owner can invite, and system lists cannot be shared', async () => {
  await addList(ALICE, 'a1');
  await addList(ALICE, 'today', { system: true });
  await denied(as(MALLORY, 'select invite_to_list($1, $2)', ['a1', 'mallory@example.com']));
  await share('a1', ALICE, BOB, 'bob@example.com');
  await denied(as(BOB, 'select invite_to_list($1, $2)', ['a1', 'mallory@example.com']));
  await denied(as(ALICE, 'select invite_to_list($1, $2)', ['today', 'bob@example.com']), '22023');
  await denied(as(ALICE, 'select invite_to_list($1, $2)', ['a1', 'not-an-email']), '22023');
});

test('invites and membership cannot be read or forged directly', async () => {
  await addList(ALICE, 'a1');
  await as(ALICE, 'select invite_to_list($1, $2)', ['a1', 'bob@example.com']);
  assert.deepEqual(await as(MALLORY, 'select * from list_invites'), []);
  await denied(
    as(MALLORY, `insert into list_members (list_id, user_id) values ('a1', $1)`, [MALLORY]),
  );
  await denied(
    as(
      MALLORY,
      `insert into list_invites (list_id, email, invited_by)
       values ('a1', 'mallory@example.com', $1)`,
      [MALLORY],
    ),
  );
});

test('a member can edit but cannot delete a list', async () => {
  await addList(ALICE, 'a1');
  await share('a1', ALICE, BOB, 'bob@example.com');
  await as(BOB, `update task_groups set name = 'renamed', deleted_at = now() where id = 'a1'`);
  const [g] = await as(ALICE, `select name, deleted_at from task_groups where id = 'a1'`);
  assert.equal(g.name, 'renamed');
  assert.equal(g.deleted_at, null);
  await as(ALICE, `update task_groups set deleted_at = now() where id = 'a1'`);
  const [d] = await as(ALICE, `select deleted_at from task_groups where id = 'a1'`);
  assert.notEqual(d.deleted_at, null);
});

test('is_system cannot be flipped to dodge sharing rules', async () => {
  await addList(ALICE, 'today', { system: true });
  await as(ALICE, `update task_groups set is_system = false where id = 'today'`);
  const [g] = await as(ALICE, `select is_system from task_groups where id = 'today'`);
  assert.equal(g.is_system, true);
});

test('removing and leaving revoke access', async () => {
  await addList(ALICE, 'a1');
  await addTask(ALICE, 't1', 'a1');
  await share('a1', ALICE, BOB, 'bob@example.com');
  await share('a1', ALICE, MALLORY, 'mallory@example.com');
  await denied(as(MALLORY, 'select remove_member($1, $2)', ['a1', BOB]));
  await as(MALLORY, 'select remove_member($1, $2)', ['a1', MALLORY]);
  assert.deepEqual(await as(MALLORY, 'select * from tasks'), []);
  await as(ALICE, 'select remove_member($1, $2)', ['a1', BOB]);
  assert.deepEqual(await as(BOB, 'select * from tasks'), []);
  await denied(addTask(BOB, 't2', 'a1'));
});

test('list_people shows members to members only', async () => {
  await addList(ALICE, 'a1');
  await share('a1', ALICE, BOB, 'bob@example.com');
  const people = await as(BOB, 'select email, is_owner from list_people($1)', ['a1']);
  assert.deepEqual(
    people.sort((a, b) => a.email.localeCompare(b.email)),
    [
      { email: 'alice@example.com', is_owner: true },
      { email: 'bob@example.com', is_owner: false },
    ],
  );
  assert.deepEqual(await as(MALLORY, 'select * from list_people($1)', ['a1']), []);
});

test('labels are private until attached to a reachable task', async () => {
  await addList(ALICE, 'a1');
  await addTask(ALICE, 't1', 'a1');
  await addLabel(ALICE, 'l1');
  await addLabel(ALICE, 'secret');
  await share('a1', ALICE, BOB, 'bob@example.com');
  assert.deepEqual(await as(BOB, 'select * from labels'), []);
  await as(
    ALICE,
    `insert into task_labels (id, task_id, label_id, created_at, updated_at)
     values ('tl1', 't1', 'l1', $1, $1)`,
    [T],
  );
  assert.deepEqual(ids(await as(BOB, 'select id from labels')), ['l1']);
  assert.equal((await as(BOB, 'select * from task_labels')).length, 1);
  assert.deepEqual(await as(MALLORY, 'select * from labels'), []);
});

test("another user's label cannot be attached to gain access to it", async () => {
  await addLabel(ALICE, 'secret');
  await addList(MALLORY, 'm1');
  await addTask(MALLORY, 'mt', 'm1');
  await denied(
    as(
      MALLORY,
      `insert into task_labels (id, task_id, label_id, created_at, updated_at)
       values ('x', 'mt', 'secret', $1, $1)`,
      [T],
    ),
  );
  assert.deepEqual(await as(MALLORY, 'select * from labels'), []);
});

test('a dependency on a private task stays hidden from other members', async () => {
  await addList(ALICE, 'shared');
  await addList(ALICE, 'private');
  await addTask(ALICE, 'pub', 'shared');
  await addTask(ALICE, 'pub2', 'shared');
  await addTask(ALICE, 'priv', 'private');
  await share('shared', ALICE, BOB, 'bob@example.com');
  const edge = (uid, id, task, pred) =>
    as(
      uid,
      `insert into task_dependencies (id, task_id, predecessor_id, created_at, updated_at)
       values ($1, $2, $3, $4, $4)`,
      [id, task, pred, T],
    );
  await edge(ALICE, 'e1', 'pub', 'priv');
  await edge(ALICE, 'e2', 'pub', 'pub2');
  assert.deepEqual(ids(await as(BOB, 'select id from task_dependencies')), ['e2']);
  await denied(edge(BOB, 'e3', 'pub2', 'priv'));
});

test('moving a task re-stamps its links so members pick them up', async () => {
  await addList(ALICE, 'a1');
  await addList(ALICE, 'a2');
  await addTask(ALICE, 't1', 'a1');
  await addLabel(ALICE, 'l1');
  await as(
    ALICE,
    `insert into task_labels (id, task_id, label_id, created_at, updated_at)
     values ('tl1', 't1', 'l1', $1, $1)`,
    [T],
  );
  const stamp = async () =>
    (await as(ALICE, `select server_updated_at s from task_labels where id = 'tl1'`))[0].s;
  const before = await stamp();
  await new Promise((r) => setTimeout(r, 5));
  await as(ALICE, `update tasks set group_id = 'a2' where id = 't1'`);
  assert.ok((await stamp()) > before);
});

test('a member cannot move a shared list for everyone', async () => {
  await addList(ALICE, 'a1');
  await share('a1', ALICE, BOB, 'bob@example.com');
  await as(BOB, `update task_groups set sort_key = 'z', name = 'renamed' where id = 'a1'`);
  const [g] = await as(ALICE, `select sort_key, name from task_groups where id = 'a1'`);
  assert.deepEqual(g, { sort_key: 'a', name: 'renamed' });
  await as(ALICE, `update task_groups set sort_key = 'b' where id = 'a1'`);
  const [o] = await as(ALICE, `select sort_key from task_groups where id = 'a1'`);
  assert.equal(o.sort_key, 'b');
});

test('my_lists shows reachable lists and whether they are shared', async () => {
  await addList(ALICE, 'a1');
  await addList(ALICE, 'a2');
  await share('a1', ALICE, BOB, 'bob@example.com');
  const mine = await as(ALICE, 'select * from my_lists() order by id');
  assert.deepEqual(mine, [
    { id: 'a1', is_shared: true },
    { id: 'a2', is_shared: false },
  ]);
  assert.deepEqual(await as(BOB, 'select * from my_lists()'), [
    { id: 'a1', is_shared: true },
  ]);
  assert.deepEqual(await as(MALLORY, 'select * from my_lists()'), []);
  await db.exec('set role anon;');
  try {
    await denied(db.query('select * from my_lists()'));
  } finally {
    await db.exec('reset role;');
  }
});

test('membership changes are not broadcast over realtime', async () => {
  const { rows } = await db.query(
    `select tablename from pg_publication_tables where pubname = 'supabase_realtime'`,
  );
  const tables = rows.map((r) => r.tablename);
  assert.ok(!tables.includes('list_members'));
  assert.ok(tables.includes('tasks'));
});

test('every public table has RLS enabled', async () => {
  const { rows } = await db.query(
    `select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity`,
  );
  assert.deepEqual(rows, []);
});
