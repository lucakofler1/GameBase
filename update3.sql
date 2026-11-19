-- Wort-Duell · Update 3: Wer bin ich? – Namen gegenseitig vergeben
alter table public.wbi_names add column if not exists assigned_by uuid references public.profiles(id) on delete set null;

drop function if exists public.wbi_start(uuid);

-- prüft, ob alle Namen vergeben sind (springt für Ausgestiegene mit Zufallsnamen ein) und startet dann
create or replace function public._wbi_check_assign(d uuid) returns void language plpgsql security definer set search_path = public as $$
declare ord jsonb; n int; k int; giver uuid; target uuid; nm text; first uuid;
begin
  select state->'order' into ord from duels where id = d and state->>'phase' = 'assign';
  if ord is null then return; end if;
  n := jsonb_array_length(ord);
  for k in 0..n-1 loop
    giver := (ord->>k)::uuid; target := (ord->>((k + 1) % n))::uuid;
    if not exists(select 1 from duel_players where duel_id = d and user_id = giver and status = 'playing')
       and not exists(select 1 from wbi_names where duel_id = d and user_id = target) then
      select name into nm from wbi_pool where name not in (select name from wbi_names where duel_id = d) order by random() limit 1;
      insert into wbi_names(duel_id, user_id, name) values (d, target, nm);
    end if;
  end loop;
  if exists(select 1 from duel_players p where p.duel_id = d and p.status = 'playing'
            and not exists(select 1 from wbi_names w where w.duel_id = d and w.user_id = p.user_id)) then return; end if;
  first := null;
  for k in 0..n-1 loop
    if first is null and exists(select 1 from duel_players where duel_id = d and user_id = (ord->>k)::uuid and status = 'playing') then first := (ord->>k)::uuid; end if;
  end loop;
  update duels set state = jsonb_build_object('phase','play','mode','assign','order',ord,'turn',first::text,'qid',null) where id = d;
end $$;

create or replace function public.wbi_start(p_duel uuid, p_mode text default 'random') returns void language plpgsql security definer set search_path = public as $$
declare dl duels; ord jsonb; u uuid; nm text; first uuid;
begin
  select * into dl from duels where id = p_duel;
  if dl.game <> 'werbinich' or dl.status <> 'open' or dl.state->>'phase' <> 'lobby' then raise exception 'Spiel läuft schon oder ist beendet'; end if;
  if dl.created_by <> auth.uid() then raise exception 'Nur wer das Spiel erstellt hat, kann starten'; end if;
  if (select count(*) from duel_players where duel_id = p_duel and status = 'playing') < 2 then raise exception 'Es muss mindestens eine weitere Person angenommen haben'; end if;
  update duel_players set status = 'declined', finished_at = now() where duel_id = p_duel and status = 'invited';
  select jsonb_agg(user_id::text order by random()) into ord from duel_players where duel_id = p_duel and status = 'playing';
  if p_mode = 'assign' then
    update duels set state = jsonb_build_object('phase','assign','mode','assign','order',ord,'done','[]'::jsonb) where id = p_duel;
    return;
  end if;
  for u in select user_id from duel_players where duel_id = p_duel and status = 'playing' loop
    select name into nm from wbi_pool where name not in (select name from wbi_names where duel_id = p_duel) order by random() limit 1;
    insert into wbi_names(duel_id, user_id, name) values (p_duel, u, nm);
  end loop;
  first := (ord->>0)::uuid;
  update duels set state = jsonb_build_object('phase','play','mode','random','order',ord,'turn',first::text,'qid',null) where id = p_duel;
end $$;

-- Namen für die Person nach dir in der Reihe vergeben (leer = Zufall)
create or replace function public.wbi_set_name(p_duel uuid, p_name text) returns text language plpgsql security definer set search_path = public as $$
declare dl duels; ord jsonb; n int; k int; me_i int := -1; target uuid; nm text := nullif(trim(coalesce(p_name,'')), '');
begin
  select * into dl from duels where id = p_duel;
  if dl.status <> 'open' or dl.state->>'phase' <> 'assign' then raise exception 'Namen werden gerade nicht vergeben'; end if;
  if not exists(select 1 from duel_players where duel_id = p_duel and user_id = auth.uid() and status = 'playing') then raise exception 'Du spielst nicht mit'; end if;
  ord := dl.state->'order'; n := jsonb_array_length(ord);
  for k in 0..n-1 loop if (ord->>k)::uuid = auth.uid() then me_i := k; end if; end loop;
  if me_i < 0 then raise exception 'Du spielst nicht mit'; end if;
  target := (ord->>((me_i + 1) % n))::uuid;
  if nm is null then
    select name into nm from wbi_pool where name not in (select name from wbi_names where duel_id = p_duel) order by random() limit 1;
  end if;
  if char_length(nm) < 2 or char_length(nm) > 60 then raise exception 'Name: 2–60 Zeichen'; end if;
  insert into wbi_names(duel_id, user_id, name, assigned_by) values (p_duel, target, nm, auth.uid())
    on conflict (duel_id, user_id) do update set name = excluded.name, assigned_by = excluded.assigned_by;
  update duels set state = jsonb_set(state, '{done}', (select coalesce(jsonb_agg(distinct x), '[]'::jsonb) from jsonb_array_elements(coalesce(state->'done','[]'::jsonb) || to_jsonb(auth.uid()::text)) x)) where id = p_duel;
  perform _wbi_check_assign(p_duel);
  return nm;
end $$;

-- Aufgeben während der Namensvergabe: Zufallsname springt ein
create or replace function public.give_up(p_duel uuid) returns void
language plpgsql security definer set search_path = public as $$
declare dl duels;
begin
  select * into dl from duels where id = p_duel;
  update duel_players set status = 'gave_up', finished_at = now() where duel_id = p_duel and user_id = auth.uid() and status = 'playing';
  if dl.game = 'werbinich' and dl.state->>'phase' = 'assign' then
    perform _wbi_check_assign(p_duel);
  elsif dl.game = 'werbinich' and dl.state->>'phase' = 'play' then
    if dl.state->>'turn' = auth.uid()::text then
      update wbi_questions set result = 'no', resolved_at = now() where id = (dl.state->>'qid')::bigint and result is null;
      perform _wbi_set_turn(p_duel, _wbi_next(p_duel, auth.uid()));
    else
      perform _wbi_try_resolve(p_duel);
    end if;
  end if;
  perform _check_finish(p_duel);
end $$;

-- vergebener Name: wer ihn vergeben hat, sieht ihn (das tut er sowieso), Ziel weiterhin nicht
revoke all on function public._wbi_check_assign(uuid) from public, anon, authenticated;
grant execute on function public.wbi_start(uuid,text), public.wbi_set_name(uuid,text), public.give_up(uuid) to authenticated;
revoke execute on function public.wbi_start(uuid,text), public.wbi_set_name(uuid,text) from anon, public;
