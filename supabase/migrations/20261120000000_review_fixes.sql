-- Fixes from review of the first migration.

-- Lists the caller can reach, and whether anyone else can too. Clients page
-- through this by id; reading task_groups and list_members separately could
-- not be paged together.
create function public.my_lists()
returns table (id text, is_shared boolean)
language sql stable set search_path = ''
as $$
  select g.id,
    g.owner_id <> auth.uid()
      or exists (select 1 from public.list_members m where m.list_id = g.id)
  from public.task_groups g;
$$;
revoke execute on function public.my_lists() from public, anon;
grant execute on function public.my_lists() to authenticated;

-- Realtime does not apply RLS to DELETE events, so every subscriber was sent
-- the (list_id, user_id) of anyone leaving any list. Clients notice losing
-- access on their next pass instead.
alter publication supabase_realtime drop table public.list_members;

-- A member reordering their own lists rewrote the shared list's position for
-- everyone. List order stays the owner's; a member's reorder applies only on
-- their device until the next change from the server.
create or replace function public.guard_owned_row()
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
    if tg_table_name = 'task_groups' then
      new.sort_key := old.sort_key;
    end if;
  end if;
  return new;
end;
$$;
