-- Listo cloud schema: per-user data, last-write-wins sync and shared lists.
--
-- Access model
--   * A list (task_groups row) has one owner and any number of members.
--   * Tasks, and the links between them, are reachable through their list.
--   * Labels belong to a user. A label attached to a task in a list you can
--     reach is readable and editable by you too, so shared tasks render fully.
--   * A dependency is visible only if you can reach both of its tasks, so an
--     edge between a shared and a private task never leaks the private one.
--
-- Sync model
--   * Clients upsert rows carrying their own updated_at; the newest wins.
--   * server_updated_at is stamped here and is what clients page on, because
--     client clocks cannot be trusted as a cursor.
--   * Rows are soft-deleted (deleted_at). list_members and list_invites hold
--     access control rather than user data, so they are really deleted.

-- ---------------------------------------------------------------- tables

create table public.task_groups (
  id text primary key,
  owner_id uuid not null default auth.uid()
    references auth.users (id) on delete cascade,
  name text not null check (char_length(name) between 1 and 60),
  sort_key text not null,
  is_system boolean not null default false,
  created_at timestamptz not null,
  updated_at timestamptz not null,
  deleted_at timestamptz,
  server_updated_at timestamptz not null default now()
);

create table public.tasks (
  id text primary key,
  group_id text not null references public.task_groups (id) on delete cascade,
  title text not null check (char_length(title) between 1 and 500),
  notes text not null default '',
  sort_key text not null,
  due_date timestamptz,
  completed_at timestamptz,
  created_at timestamptz not null,
  updated_at timestamptz not null,
  deleted_at timestamptz,
  server_updated_at timestamptz not null default now()
);
create index tasks_group_id_idx on public.tasks (group_id);

create table public.labels (
  id text primary key,
  owner_id uuid not null default auth.uid()
    references auth.users (id) on delete cascade,
  name text not null check (char_length(name) between 1 and 40),
  color bigint not null,
  created_at timestamptz not null,
  updated_at timestamptz not null,
  deleted_at timestamptz,
  server_updated_at timestamptz not null default now()
);

create table public.task_labels (
  id text primary key,
  task_id text not null references public.tasks (id) on delete cascade,
  label_id text not null references public.labels (id) on delete cascade,
  created_at timestamptz not null,
  updated_at timestamptz not null,
  deleted_at timestamptz,
  server_updated_at timestamptz not null default now(),
  unique (task_id, label_id)
);
create index task_labels_label_id_idx on public.task_labels (label_id);

create table public.task_dependencies (
  id text primary key,
  task_id text not null references public.tasks (id) on delete cascade,
  predecessor_id text not null references public.tasks (id) on delete cascade,
  created_at timestamptz not null,
  updated_at timestamptz not null,
  deleted_at timestamptz,
  server_updated_at timestamptz not null default now(),
  unique (task_id, predecessor_id)
);
create index task_dependencies_predecessor_idx
  on public.task_dependencies (predecessor_id);

create table public.list_members (
  list_id text not null references public.task_groups (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  added_at timestamptz not null default now(),
  primary key (list_id, user_id)
);
create index list_members_user_id_idx on public.list_members (user_id);

create table public.list_invites (
  id uuid primary key default gen_random_uuid(),
  list_id text not null references public.task_groups (id) on delete cascade,
  email text not null check (email = lower(email)),
  invited_by uuid not null references auth.users (id) on delete cascade,
  created_at timestamptz not null default now(),
  unique (list_id, email)
);
create index list_invites_email_idx on public.list_invites (email);

create index task_groups_cursor_idx on public.task_groups (server_updated_at);
create index tasks_cursor_idx on public.tasks (server_updated_at);
create index labels_cursor_idx on public.labels (server_updated_at);
create index task_labels_cursor_idx on public.task_labels (server_updated_at);
create index task_dependencies_cursor_idx
  on public.task_dependencies (server_updated_at);

-- ------------------------------------------------------- access helpers
-- security definer so policies can consult each other's tables without
-- recursing through RLS. search_path is pinned because of that privilege.

create function public.can_access_list(p_list_id text)
returns boolean language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.task_groups g
    where g.id = p_list_id and g.owner_id = auth.uid()
  ) or exists (
    select 1 from public.list_members m
    where m.list_id = p_list_id and m.user_id = auth.uid()
  );
$$;

create function public.is_list_owner(p_list_id text)
returns boolean language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.task_groups g
    where g.id = p_list_id and g.owner_id = auth.uid()
  );
$$;

create function public.can_access_task(p_task_id text)
returns boolean language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.tasks t
    where t.id = p_task_id and public.can_access_list(t.group_id)
  );
$$;

-- Soft-deleted links still count, so tombstones can be applied on clients.
create function public.can_access_label(p_label_id text)
returns boolean language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.labels l
    where l.id = p_label_id and l.owner_id = auth.uid()
  ) or exists (
    select 1 from public.task_labels tl
    where tl.label_id = p_label_id and public.can_access_task(tl.task_id)
  );
$$;

-- The caller's email, only once it has been proven. An invite is claimed by
-- email address, so an unverified address must never match one.
create function public.verified_email()
returns text language sql stable security definer set search_path = ''
as $$
  select lower(u.email) from auth.users u
  where u.id = auth.uid() and u.email_confirmed_at is not null;
$$;

-- -------------------------------------------------------------- triggers

-- Last-write-wins. Returning null drops a stale update without an error, so
-- a device that was offline cannot overwrite newer data. A client clock far
-- in the future is clamped, or that device would win every conflict.
create function public.sync_stamp()
returns trigger language plpgsql set search_path = ''
as $$
begin
  new.updated_at := least(new.updated_at, now() + interval '5 minutes');
  if tg_op = 'UPDATE' and new.updated_at < old.updated_at then
    return null;
  end if;
  new.server_updated_at := now();
  return new;
end;
$$;

create trigger sync_stamp before insert or update on public.task_groups
  for each row execute function public.sync_stamp();
create trigger sync_stamp before insert or update on public.tasks
  for each row execute function public.sync_stamp();
create trigger sync_stamp before insert or update on public.labels
  for each row execute function public.sync_stamp();
create trigger sync_stamp before insert or update on public.task_labels
  for each row execute function public.sync_stamp();
create trigger sync_stamp before insert or update on public.task_dependencies
  for each row execute function public.sync_stamp();

-- Ownership comes from the session, never the request. Members may rename and
-- reorder a list, but only its owner can delete it. A non-owner's delete is
-- ignored rather than rejected, so one stale device cannot wedge its sync.
create function public.guard_owned_row()
returns trigger language plpgsql set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    new.owner_id := auth.uid();
    return new;
  end if;
  new.owner_id := old.owner_id;
  if old.owner_id is distinct from auth.uid() then
    new.deleted_at := old.deleted_at;
  end if;
  return new;
end;
$$;

create trigger guard_owned_row before insert or update on public.task_groups
  for each row execute function public.guard_owned_row();
create trigger guard_owned_row before insert or update on public.labels
  for each row execute function public.guard_owned_row();

create function public.guard_system_flag()
returns trigger language plpgsql set search_path = ''
as $$
begin
  new.is_system := old.is_system;
  return new;
end;
$$;

create trigger guard_system_flag before update on public.task_groups
  for each row execute function public.guard_system_flag();

-- A task moved into a list brings its links along: their own timestamps have
-- not changed, so without this, members already past them would never see them.
create function public.touch_task_links()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  update public.task_labels set server_updated_at = now()
    where task_id = new.id;
  update public.task_dependencies set server_updated_at = now()
    where task_id = new.id or predecessor_id = new.id;
  return null;
end;
$$;

create trigger touch_task_links after update of group_id on public.tasks
  for each row when (old.group_id is distinct from new.group_id)
  execute function public.touch_task_links();

-- ------------------------------------------------------------------- RLS

alter table public.task_groups enable row level security;
alter table public.tasks enable row level security;
alter table public.labels enable row level security;
alter table public.task_labels enable row level security;
alter table public.task_dependencies enable row level security;
alter table public.list_members enable row level security;
alter table public.list_invites enable row level security;

-- No delete policies on the synced tables: nothing is ever hard-deleted.

create policy task_groups_select on public.task_groups for select
  to authenticated using (public.can_access_list(id));
create policy task_groups_insert on public.task_groups for insert
  to authenticated with check (owner_id = auth.uid());
create policy task_groups_update on public.task_groups for update
  to authenticated using (public.can_access_list(id))
  with check (public.can_access_list(id));

create policy tasks_select on public.tasks for select
  to authenticated using (public.can_access_list(group_id));
create policy tasks_insert on public.tasks for insert
  to authenticated with check (public.can_access_list(group_id));
create policy tasks_update on public.tasks for update
  to authenticated using (public.can_access_list(group_id))
  with check (public.can_access_list(group_id));

create policy labels_select on public.labels for select
  to authenticated using (public.can_access_label(id));
create policy labels_insert on public.labels for insert
  to authenticated with check (owner_id = auth.uid());
create policy labels_update on public.labels for update
  to authenticated using (public.can_access_label(id))
  with check (public.can_access_label(id));

create policy task_labels_select on public.task_labels for select
  to authenticated using (public.can_access_task(task_id));
create policy task_labels_insert on public.task_labels for insert
  to authenticated with check (
    public.can_access_task(task_id) and public.can_access_label(label_id)
  );
create policy task_labels_update on public.task_labels for update
  to authenticated using (public.can_access_task(task_id))
  with check (
    public.can_access_task(task_id) and public.can_access_label(label_id)
  );

create policy task_dependencies_select on public.task_dependencies for select
  to authenticated using (
    public.can_access_task(task_id) and public.can_access_task(predecessor_id)
  );
create policy task_dependencies_insert on public.task_dependencies for insert
  to authenticated with check (
    public.can_access_task(task_id) and public.can_access_task(predecessor_id)
  );
create policy task_dependencies_update on public.task_dependencies for update
  to authenticated using (
    public.can_access_task(task_id) and public.can_access_task(predecessor_id)
  ) with check (
    public.can_access_task(task_id) and public.can_access_task(predecessor_id)
  );

-- Read-only to clients; changes go through the functions below.
create policy list_members_select on public.list_members for select
  to authenticated using (public.can_access_list(list_id));
create policy list_invites_select on public.list_invites for select
  to authenticated using (public.is_list_owner(list_id));

-- --------------------------------------------------------- sharing API

-- Records an invite whether or not the address has an account, and reports
-- nothing about it, so this cannot be used to discover who uses Listo.
create function public.invite_to_list(p_list_id text, p_email text)
returns void language plpgsql security definer set search_path = ''
as $$
declare
  v_email text := lower(trim(p_email));
begin
  if not public.is_list_owner(p_list_id) then
    raise exception 'Only the owner can share this list' using errcode = '42501';
  end if;
  if exists (
    select 1 from public.task_groups g
    where g.id = p_list_id and (g.is_system or g.deleted_at is not null)
  ) then
    raise exception 'This list cannot be shared' using errcode = '22023';
  end if;
  if v_email !~ '^[^@\s]+@[^@\s]+$' then
    raise exception 'Invalid email address' using errcode = '22023';
  end if;
  insert into public.list_invites (list_id, email, invited_by)
    values (p_list_id, v_email, auth.uid())
    on conflict (list_id, email) do nothing;
end;
$$;

create function public.cancel_invite(p_invite_id uuid)
returns void language sql security definer set search_path = ''
as $$
  delete from public.list_invites i
  where i.id = p_invite_id and public.is_list_owner(i.list_id);
$$;

-- Invites addressed to the caller's verified email. The list has no RLS path
-- for them yet, so its name and the inviter's email are returned here.
create function public.my_invites()
returns table (id uuid, list_id text, list_name text, invited_by_email text)
language sql stable security definer set search_path = ''
as $$
  select i.id, i.list_id, g.name, u.email::text
  from public.list_invites i
  join public.task_groups g on g.id = i.list_id and g.deleted_at is null
  join auth.users u on u.id = i.invited_by
  where i.email = public.verified_email();
$$;

create function public.accept_invite(p_invite_id uuid)
returns text language plpgsql security definer set search_path = ''
as $$
declare
  v_list_id text;
begin
  delete from public.list_invites i
    where i.id = p_invite_id and i.email = public.verified_email()
    returning i.list_id into v_list_id;
  if v_list_id is null then
    raise exception 'Invite not found' using errcode = 'P0002';
  end if;
  insert into public.list_members (list_id, user_id)
    select v_list_id, auth.uid()
    where not public.is_list_owner(v_list_id)
    on conflict do nothing;
  return v_list_id;
end;
$$;

create function public.decline_invite(p_invite_id uuid)
returns void language sql security definer set search_path = ''
as $$
  delete from public.list_invites i
  where i.id = p_invite_id and i.email = public.verified_email();
$$;

create function public.list_people(p_list_id text)
returns table (user_id uuid, email text, is_owner boolean)
language sql stable security definer set search_path = ''
as $$
  select u.id, u.email::text, true
  from public.task_groups g join auth.users u on u.id = g.owner_id
  where g.id = p_list_id and public.can_access_list(p_list_id)
  union all
  select u.id, u.email::text, false
  from public.list_members m join auth.users u on u.id = m.user_id
  where m.list_id = p_list_id and public.can_access_list(p_list_id);
$$;

-- The owner removes anyone; a member can remove only themselves (leave).
create function public.remove_member(p_list_id text, p_user_id uuid)
returns void language plpgsql security definer set search_path = ''
as $$
begin
  if not (public.is_list_owner(p_list_id) or p_user_id = auth.uid()) then
    raise exception 'Not allowed' using errcode = '42501';
  end if;
  delete from public.list_members m
    where m.list_id = p_list_id and m.user_id = p_user_id;
end;
$$;

-- --------------------------------------------------------------- grants

-- Supabase's default privileges grant everything on new objects, including
-- TRUNCATE, which ignores RLS. Start from nothing and grant only what is used.
revoke all on all tables in schema public from anon, authenticated;
revoke execute on all functions in schema public
  from public, anon, authenticated;

grant select, insert, update on public.task_groups, public.tasks,
  public.labels, public.task_labels, public.task_dependencies to authenticated;
grant select on public.list_members, public.list_invites to authenticated;

-- Policies run as the caller, so these must stay callable.
grant execute on function
  public.can_access_list(text), public.is_list_owner(text),
  public.can_access_task(text), public.can_access_label(text),
  public.invite_to_list(text, text), public.cancel_invite(uuid),
  public.my_invites(), public.accept_invite(uuid), public.decline_invite(uuid),
  public.list_people(text), public.remove_member(text, uuid)
  to authenticated;

-- Realtime only tells clients to sync; RLS still decides what they receive.
alter publication supabase_realtime add table public.task_groups, public.tasks,
  public.labels, public.task_labels, public.task_dependencies,
  public.list_members;
