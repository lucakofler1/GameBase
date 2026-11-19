-- Wort-Duell · Update 4: Mensch ärgere dich nicht
alter table public.duels drop constraint if exists duels_game_check;
alter table public.duels add constraint duels_game_check check (game in ('wordless','clueless','werbinich','schiffe','mensch'));

-- Positionen relativ zum eigenen Start: -1 = Haus, 0..39 = Laufbahn, 40..43 = Ziel
create or replace function public._mad_target(st jsonb, me uuid, piece int, dice int) returns int
language plpgsql immutable as $$
declare seats jsonb := st->'seats'; my int[]; r int; nr int; k int; seat int := -1; i int;
begin
  select array_agg(x::int) into my from jsonb_array_elements_text(st->'pos'->(me::text)) x;
  r := my[piece + 1];
  if r is null or r < -1 then return null; end if;
  if r = -1 then
    if dice <> 6 then return null; end if;
    if 0 = any(my) then return null; end if;
    return 0;
  end if;
  nr := r + dice;
  if nr > 43 then return null; end if;
  if nr <= 39 then
    if nr = any(my) then return null; end if;
    return nr;
  end if;
  -- im Ziel nicht überspringen
  for k in greatest(r + 1, 40)..nr loop
    if k = any(my) then return null; end if;
  end loop;
  return nr;
end $$;

create or replace function public._mad_movable(st jsonb, me uuid, dice int) returns int[]
language plpgsql immutable as $$
declare res int[] := '{}'; i int;
begin
  for i in 0..3 loop
    if public._mad_target(st, me, i, dice) is not null then res := res || i; end if;
  end loop;
  return res;
end $$;

create or replace function public._mad_next(d uuid, cur uuid) returns uuid language plpgsql security definer set search_path = public as $$
declare seats jsonb; n int; i int := 0; k int; cand uuid;
begin
  select state->'seats' into seats from duels where id = d;
  n := jsonb_array_length(seats);
  for k in 0..n-1 loop if (seats->>k)::uuid = cur then i := k; end if; end loop;
  for k in 1..n loop
    cand := (seats->>((i + k) % n))::uuid;
    if exists(select 1 from duel_players where duel_id = d and user_id = cand and status = 'playing') then return cand; end if;
  end loop;
  return cur;
end $$;

create or replace function public._mad_event(st jsonb, ev jsonb) returns jsonb language sql immutable as $$
  select jsonb_set(jsonb_set(st, '{seq}', to_jsonb(coalesce((st->>'seq')::int, 0) + 1)), '{events}',
    (select coalesce(jsonb_agg(e order by (e->>'seq')::int), '[]'::jsonb) from (
      select e from jsonb_array_elements(coalesce(st->'events','[]'::jsonb)) e
      union all select ev || jsonb_build_object('seq', coalesce((st->>'seq')::int, 0) + 1)
    ) s(e) where (e->>'seq')::int > coalesce((st->>'seq')::int, 0) - 7))
$$;

create or replace function public.mad_start(p_duel uuid) returns void language plpgsql security definer set search_path = public as $$
declare dl duels; seats jsonb; pos jsonb := '{}'::jsonb; u text;
begin
  select * into dl from duels where id = p_duel;
  if dl.game <> 'mensch' or dl.status <> 'open' or dl.state->>'phase' <> 'lobby' then raise exception 'Spiel läuft schon oder ist beendet'; end if;
  if dl.created_by <> auth.uid() then raise exception 'Nur wer das Spiel erstellt hat, kann starten'; end if;
  if (select count(*) from duel_players where duel_id = p_duel and status = 'playing') < 2 then raise exception 'Es muss mindestens eine weitere Person angenommen haben'; end if;
  update duel_players set status = 'declined', finished_at = now() where duel_id = p_duel and status = 'invited';
  select jsonb_agg(user_id::text order by random()) into seats from duel_players where duel_id = p_duel and status = 'playing';
  for u in select jsonb_array_elements_text(seats) loop pos := pos || jsonb_build_object(u, '[-1,-1,-1,-1]'::jsonb); end loop;
  update duels set state = jsonb_build_object('phase','play','seats',seats,'pos',pos,'turn',seats->>0,'dice',null,'tries',0,'seq',0,'events','[]'::jsonb) where id = p_duel;
end $$;

create or replace function public.mad_roll(p_duel uuid) returns jsonb language plpgsql security definer set search_path = public as $$
declare dl duels; st jsonb; me uuid := auth.uid(); dice int; mv int[]; my int[]; on_track boolean; tries int;
begin
  select * into dl from duels where id = p_duel for update;
  st := dl.state;
  if dl.game <> 'mensch' or dl.status <> 'open' or st->>'phase' <> 'play' then raise exception 'Spiel läuft nicht'; end if;
  if st->>'turn' <> me::text then raise exception 'Du bist nicht dran'; end if;
  if st->>'dice' is not null then raise exception 'Erst ziehen, dann würfeln'; end if;
  dice := 1 + floor(random() * 6)::int;
  update duel_players set attempts = attempts + 1 where duel_id = p_duel and user_id = me;
  st := _mad_event(st, jsonb_build_object('t','roll','u',me::text,'d',dice));
  mv := _mad_movable(st, me, dice);
  if array_length(mv, 1) is not null then
    st := jsonb_set(st, '{dice}', to_jsonb(dice));
  else
    select array_agg(x::int) into my from jsonb_array_elements_text(st->'pos'->(me::text)) x;
    on_track := exists(select 1 from unnest(my) v where v between 0 and 39);
    tries := coalesce((st->>'tries')::int, 0) + 1;
    if dice = 6 then
      st := jsonb_set(st, '{tries}', '0'::jsonb);            -- 6 ohne Zug: nochmal
    elsif not on_track and tries < 3 then
      st := jsonb_set(st, '{tries}', to_jsonb(tries));        -- bis zu 3 Versuche
    else
      st := jsonb_set(jsonb_set(st, '{tries}', '0'::jsonb), '{turn}', to_jsonb(_mad_next(p_duel, me)::text));
    end if;
  end if;
  update duels set state = st where id = p_duel;
  return jsonb_build_object('dice', dice, 'movable', to_jsonb(coalesce(mv, '{}')));
end $$;

create or replace function public.mad_move(p_duel uuid, p_piece int) returns jsonb language plpgsql security definer set search_path = public as $$
declare dl duels; st jsonb; me uuid := auth.uid(); dice int; nr int; seats jsonb; n int; myseat int; k int; other text; opos jsonb; j int;
  abs_t int; oseat int; victim text := null; my int[]; done boolean; kicks jsonb := '[]'::jsonb;
begin
  select * into dl from duels where id = p_duel for update;
  st := dl.state;
  if dl.game <> 'mensch' or dl.status <> 'open' or st->>'phase' <> 'play' then raise exception 'Spiel läuft nicht'; end if;
  if st->>'turn' <> me::text then raise exception 'Du bist nicht dran'; end if;
  dice := (st->>'dice')::int;
  if dice is null then raise exception 'Erst würfeln'; end if;
  nr := _mad_target(st, me, p_piece, dice);
  if nr is null then raise exception 'Diese Figur kann nicht ziehen'; end if;
  seats := st->'seats'; n := jsonb_array_length(seats);
  for k in 0..n-1 loop if seats->>k = me::text then myseat := k; end if; end loop;
  st := jsonb_set(st, array['pos', me::text, p_piece::text], to_jsonb(nr));
  -- Rauswerfen
  if nr <= 39 then
    abs_t := (myseat * 10 + nr) % 40;
    for k in 0..n-1 loop
      other := seats->>k;
      if other <> me::text then
        for j in 0..3 loop
          if (st->'pos'->other->>j)::int between 0 and 39 and (k * 10 + (st->'pos'->other->>j)::int) % 40 = abs_t then
            st := jsonb_set(st, array['pos', other, j::text], '-1'::jsonb);
            victim := other;
            kicks := kicks || jsonb_build_object('t','kick','u',me::text,'v',other,'f',abs_t,'p',j);
          end if;
        end loop;
      end if;
    end loop;
  end if;
  st := _mad_event(st, jsonb_build_object('t','move','u',me::text,'p',p_piece,'to',nr));
  for j in 0..jsonb_array_length(kicks)-1 loop st := _mad_event(st, kicks->j); end loop;
  select array_agg(x::int) into my from jsonb_array_elements_text(st->'pos'->(me::text)) x;
  done := (select bool_and(v >= 40) from unnest(my) v);
  if done then
    st := jsonb_set(jsonb_set(_mad_event(st, jsonb_build_object('t','win','u',me::text)), '{dice}', 'null'::jsonb), '{turn}', 'null'::jsonb);
    update duels set state = st where id = p_duel;
    update duel_players set status = 'solved', finished_at = now() where duel_id = p_duel and user_id = me;
    update duel_players set status = 'failed', finished_at = now() where duel_id = p_duel and status = 'playing';
    update duels set status = 'finished', winner_id = me, finished_at = now() where id = p_duel;
    return jsonb_build_object('won', true, 'kicked', victim);
  end if;
  st := jsonb_set(jsonb_set(st, '{dice}', 'null'::jsonb), '{tries}', '0'::jsonb);
  if dice <> 6 then st := jsonb_set(st, '{turn}', to_jsonb(_mad_next(p_duel, me)::text)); end if;
  update duels set state = st where id = p_duel;
  return jsonb_build_object('won', false, 'kicked', victim, 'again', dice = 6);
end $$;

-- create_duel: Mensch ärgere dich nicht ergänzen (2–4 Spieler)
create or replace function public.create_duel(p_game text, p_len int, p_invitees uuid[]) returns uuid
language plpgsql security definer set search_path = public as $$
declare d uuid; s text; u uuid; n int := coalesce(array_length(p_invitees,1),0);
begin
  if not is_player() then raise exception 'Kein Zugriff'; end if;
  if p_invitees is not null then
    foreach u in array p_invitees loop
      if not are_friends(auth.uid(), u) then raise exception 'Du kannst nur Freunde einladen'; end if;
    end loop;
  end if;
  if p_game = 'wordless' then
    if p_len not between 3 and 8 then raise exception 'Wortlänge 3–8'; end if;
    select word into s from wl_answers where len = p_len order by random() limit 1;
  elsif p_game = 'clueless' then
    select word into s from cl_secrets order by random() limit 1;
  elsif p_game = 'werbinich' then
    if n < 1 then raise exception 'Wer bin ich? braucht mindestens 2 Spieler'; end if; s := '-';
  elsif p_game = 'schiffe' then
    if n <> 1 then raise exception 'Schiffe versenken spielt man zu zweit – lade genau eine Person ein'; end if; s := '-';
  elsif p_game = 'mensch' then
    if n < 1 or n > 3 then raise exception 'Mensch ärgere dich nicht: 2 bis 4 Spieler'; end if; s := '-';
  else raise exception 'Unbekanntes Spiel'; end if;
  if s is null then raise exception 'Wortdaten fehlen – Admin muss sie zuerst laden'; end if;
  insert into duels(game, word_length, max_attempts, created_by, state)
    values (p_game, case when p_game='wordless' then p_len end, case when p_game='wordless' then 6 end, auth.uid(),
      case p_game when 'werbinich' then '{"phase":"lobby"}'::jsonb when 'mensch' then '{"phase":"lobby"}'::jsonb when 'schiffe' then '{"phase":"place","ready":[]}'::jsonb else '{}'::jsonb end)
    returning id into d;
  insert into duel_secrets values (d, s);
  insert into duel_players(duel_id, user_id, status, joined_at) values (d, auth.uid(), 'playing', now());
  if p_invitees is not null then
    foreach u in array p_invitees loop
      if u <> auth.uid() then insert into duel_players(duel_id, user_id) values (d, u) on conflict do nothing; end if;
    end loop;
  end if;
  return d;
end $$;

-- Ende / Aufgeben für Mensch ärgere dich nicht
create or replace function public._check_finish(d uuid) returns void language plpgsql security definer set search_path = public as $$
declare w uuid; g text; ph text;
begin
  select game, state->>'phase' into g, ph from duels where id = d;
  if g in ('werbinich','schiffe','mensch') then
    if exists(select 1 from duel_players where duel_id = d and status = 'invited') then return; end if;
    if (select count(*) from duel_players where duel_id = d and status = 'playing') > 1 then return; end if;
    if g in ('schiffe','mensch') then
      update duel_players set status = 'solved', finished_at = now() where duel_id = d and status = 'playing' and ph = 'play';
      update duel_players set status = 'gave_up', finished_at = now() where duel_id = d and status = 'playing';
    else
      update duel_players set status = 'failed', finished_at = now() where duel_id = d and status = 'playing';
    end if;
    select user_id into w from duel_players where duel_id = d and status = 'solved' order by finished_at asc limit 1;
  else
    if exists(select 1 from duel_players where duel_id = d and status in ('invited','playing')) then return; end if;
    select user_id into w from duel_players where duel_id = d and status = 'solved' order by attempts asc, finished_at asc limit 1;
  end if;
  update duels set status = 'finished', winner_id = w, finished_at = now() where id = d and status = 'open';
end $$;

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
  elsif dl.game = 'mensch' and dl.state->>'phase' = 'play' then
    update duels set state = jsonb_set(jsonb_set(jsonb_set(state, array['pos', auth.uid()::text], '[-9,-9,-9,-9]'::jsonb), '{dice}', 'null'::jsonb), '{turn}',
      case when state->>'turn' = auth.uid()::text then to_jsonb(_mad_next(p_duel, auth.uid())::text) else state->'turn' end) where id = p_duel;
  end if;
  perform _check_finish(p_duel);
end $$;

-- Rangliste mit Mensch-Siegen
drop function if exists public.leaderboard();
create or replace function public.leaderboard() returns table(user_id uuid, display_name text, username text, points bigint, wins bigint, played bigint,
  wins_wordless bigint, wins_clueless bigint, wins_werbinich bigint, wins_schiffe bigint, wins_mensch bigint)
language sql stable security definer set search_path = public as $$
  with real_duels as (
    select d.*, (select count(*) from duel_players x where x.duel_id = d.id and x.status in ('solved','failed','gave_up')) as n
    from duels d where d.status = 'finished'
  ), r as (select * from real_duels where n >= 2)
  select p.id, p.display_name, p.username,
    coalesce(sum(case when r.id is null then 0 else 2 + case when r.winner_id = p.id then 20 + 5 * (r.n - 2) else 0 end end), 0)::bigint,
    count(distinct r.id) filter (where r.winner_id = p.id),
    count(distinct r.id),
    count(distinct r.id) filter (where r.winner_id = p.id and r.game = 'wordless'),
    count(distinct r.id) filter (where r.winner_id = p.id and r.game = 'clueless'),
    count(distinct r.id) filter (where r.winner_id = p.id and r.game = 'werbinich'),
    count(distinct r.id) filter (where r.winner_id = p.id and r.game = 'schiffe'),
    count(distinct r.id) filter (where r.winner_id = p.id and r.game = 'mensch')
  from profiles p
  left join duel_players dp on dp.user_id = p.id and dp.status in ('solved','failed','gave_up')
  left join r on r.id = dp.duel_id
  where is_player()
  group by p.id order by 4 desc, 5 desc, 2 asc
$$;

revoke all on function public._mad_next(uuid,uuid), public._check_finish(uuid) from public, anon, authenticated;
grant execute on function public.mad_start(uuid), public.mad_roll(uuid), public.mad_move(uuid,int), public.leaderboard(), public.create_duel(text,int,uuid[]), public.give_up(uuid) to authenticated;
revoke execute on function public.mad_start(uuid), public.mad_roll(uuid), public.mad_move(uuid,int), public.leaderboard() from anon, public;
