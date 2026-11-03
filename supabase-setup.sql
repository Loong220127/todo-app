-- ============================================================
-- 待办清单 · Supabase 云同步建表脚本
-- 在 Supabase Dashboard -> SQL Editor 中整段运行一次即可。
-- 运行完成后，把 Project URL 和 anon public key 填入应用。
-- ============================================================

create extension if not exists pgcrypto;

create table if not exists public.todo_lists (
  id uuid primary key default gen_random_uuid(),
  sync_key text not null,
  payload jsonb not null default '{"version":1,"todos":[]}'::jsonb,
  updated_at timestamptz not null default now()
);

alter table public.todo_lists enable row level security;
revoke all on table public.todo_lists from anon, authenticated, public;
grant usage on schema public to anon;

-- 创建共享清单：返回新的清单 ID
create or replace function public.create_todo_list(p_key text)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  new_id uuid := gen_random_uuid();
begin
  if p_key is null or length(p_key) < 16 then
    raise exception 'invalid_key';
  end if;

  insert into public.todo_lists (id, sync_key, payload)
  values (new_id, p_key, '{"version":1,"todos":[]}'::jsonb);

  return new_id;
end;
$$;

-- 读取共享清单：必须提供清单 ID 和共享密钥
create or replace function public.get_todo_list(p_id uuid, p_key text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  result jsonb;
begin
  select payload into result
  from public.todo_lists
  where id = p_id and sync_key = p_key;

  if result is null then
    raise exception 'not_found';
  end if;

  return result;
end;
$$;

-- 保存共享清单：整份 JSON 覆盖写入（最后保存者生效）
create or replace function public.save_todo_list(p_id uuid, p_key text, p_payload jsonb)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if p_payload is null
     or jsonb_typeof(p_payload) <> 'object'
     or p_payload->'todos' is null
     or jsonb_typeof(p_payload->'todos') <> 'array' then
    raise exception 'invalid_payload';
  end if;

  update public.todo_lists
  set payload = p_payload, updated_at = now()
  where id = p_id and sync_key = p_key;

  if not found then
    raise exception 'not_found';
  end if;
end;
$$;

revoke all on function public.create_todo_list(text) from public;
revoke all on function public.get_todo_list(uuid, text) from public;
revoke all on function public.save_todo_list(uuid, text, jsonb) from public;

grant execute on function public.create_todo_list(text) to anon;
grant execute on function public.get_todo_list(uuid, text) to anon;
grant execute on function public.save_todo_list(uuid, text, jsonb) to anon;

-- ============================================================
-- 附件存储（PDF / Word / PPT / Excel / 文本 / 压缩包）
-- 文件内容以 Base64 存在独立表中，同样由共享密钥保护。
-- ============================================================

create table if not exists public.todo_files (
  list_id uuid not null references public.todo_lists(id) on delete cascade,
  file_id uuid not null,
  name text not null,
  mime text not null default 'application/octet-stream',
  size bigint not null,
  data text not null,
  created_at timestamptz not null default now(),
  primary key (list_id, file_id)
);

alter table public.todo_files enable row level security;
revoke all on table public.todo_files from anon, authenticated, public;

create or replace function public.save_todo_file(
  p_id uuid,
  p_key text,
  p_file_id uuid,
  p_name text,
  p_mime text,
  p_size bigint,
  p_data text
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if not exists (
    select 1 from public.todo_lists
    where id = p_id and sync_key = p_key
  ) then
    raise exception 'not_found';
  end if;

  if p_file_id is null or p_name is null or p_data is null then
    raise exception 'invalid_file';
  end if;

  if p_size is null or p_size < 0 or p_size > 5242880 then
    raise exception 'file_too_large';
  end if;

  insert into public.todo_files (list_id, file_id, name, mime, size, data)
  values (p_id, p_file_id, left(p_name, 200), coalesce(nullif(p_mime, ''), 'application/octet-stream'), p_size, p_data)
  on conflict (list_id, file_id) do update
  set name = excluded.name,
      mime = excluded.mime,
      size = excluded.size,
      data = excluded.data,
      created_at = now();
end;
$$;

create or replace function public.get_todo_file(
  p_id uuid,
  p_key text,
  p_file_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  result jsonb;
begin
  select jsonb_build_object(
    'name', f.name,
    'mime', f.mime,
    'size', f.size,
    'data', f.data
  )
  into result
  from public.todo_files f
  join public.todo_lists l on l.id = f.list_id
  where f.list_id = p_id
    and f.file_id = p_file_id
    and l.sync_key = p_key;

  if result is null then
    raise exception 'not_found';
  end if;

  return result;
end;
$$;

create or replace function public.delete_todo_file(
  p_id uuid,
  p_key text,
  p_file_id uuid
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if not exists (
    select 1 from public.todo_lists
    where id = p_id and sync_key = p_key
  ) then
    raise exception 'not_found';
  end if;

  delete from public.todo_files
  where list_id = p_id and file_id = p_file_id;
end;
$$;

revoke all on function public.save_todo_file(uuid, text, uuid, text, text, bigint, text) from public;
revoke all on function public.get_todo_file(uuid, text, uuid) from public;
revoke all on function public.delete_todo_file(uuid, text, uuid) from public;

grant execute on function public.save_todo_file(uuid, text, uuid, text, text, bigint, text) to anon;
grant execute on function public.get_todo_file(uuid, text, uuid) to anon;
grant execute on function public.delete_todo_file(uuid, text, uuid) to anon;

-- 让 PostgREST 立即刷新函数缓存（Supabase API）
notify pgrst, 'reload schema';
