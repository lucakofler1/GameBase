-- GameBase · Update 6: Gruppenchat in Spielen
create table if not exists public.duel_messages (
  id bigserial primary key,
  duel_id uuid not null references public.duels(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  body text not null check (char_length(body) between 1 and 500),
  created_at timestamptz not null default now()
);
create index if not exists duel_messages_duel on public.duel_messages(duel_id, id);
alter table public.duel_messages enable row level security;
drop policy if exists p_dm_read on public.duel_messages;
create policy p_dm_read on public.duel_messages for select to authenticated using (public.is_participant(duel_id));
grant select on public.duel_messages to authenticated;

create or replace function public.send_duel_message(p_duel uuid, p_body text) returns bigint
language plpgsql security definer set search_path = public as $$
declare i bigint;
begin
  if not exists(select 1 from duel_players where duel_id = p_duel and user_id = auth.uid() and status <> 'declined') then
    raise exception 'Du bist in diesem Spiel nicht dabei';
  end if;
  if char_length(trim(coalesce(p_body,''))) = 0 then raise exception 'Leere Nachricht'; end if;
  insert into duel_messages(duel_id, user_id, body) values (p_duel, auth.uid(), left(trim(p_body), 500)) returning id into i;
  return i;
end $$;
revoke execute on function public.send_duel_message(uuid,text) from anon, public;
grant execute on function public.send_duel_message(uuid,text) to authenticated;

do $$ begin
  begin alter publication supabase_realtime add table public.duel_messages; exception when others then null; end;
end $$;
