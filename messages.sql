-- Wort-Duell · Nachrichten (Update 1)
create table if not exists public.messages (
  id bigserial primary key,
  from_id uuid not null references public.profiles(id) on delete cascade,
  to_id uuid not null references public.profiles(id) on delete cascade,
  body text not null check (char_length(body) between 1 and 2000),
  created_at timestamptz not null default now(),
  read_at timestamptz
);
create index if not exists messages_to on public.messages(to_id, created_at);
create index if not exists messages_from on public.messages(from_id, created_at);
alter table public.messages enable row level security;
drop policy if exists p_messages_read on public.messages;
create policy p_messages_read on public.messages for select to authenticated
  using (public.is_player() and (from_id = auth.uid() or to_id = auth.uid()));
grant select on public.messages to authenticated;

create or replace function public.send_message(p_to uuid, p_body text) returns bigint
language plpgsql security definer set search_path = public as $$
declare i bigint;
begin
  if not is_player() then raise exception 'Kein Zugriff'; end if;
  if p_to = auth.uid() then raise exception 'Du kannst dir nicht selbst schreiben'; end if;
  if not exists(select 1 from profiles where id = p_to) then raise exception 'Empfänger gibt es nicht'; end if;
  if char_length(trim(p_body)) = 0 then raise exception 'Leere Nachricht'; end if;
  insert into messages(from_id, to_id, body) values (auth.uid(), p_to, trim(p_body)) returning id into i;
  return i;
end $$;

create or replace function public.mark_read(p_other uuid) returns void
language sql security definer set search_path = public as $$
  update messages set read_at = now() where to_id = auth.uid() and from_id = p_other and read_at is null and is_player()
$$;

revoke execute on function public.send_message(uuid,text), public.mark_read(uuid) from anon, public;
grant execute on function public.send_message(uuid,text), public.mark_read(uuid) to authenticated;

do $$ begin
  begin alter publication supabase_realtime add table public.messages; exception when others then null; end;
end $$;
