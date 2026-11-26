-- GameBase · Update 7: Schwimmen (31)
alter table public.duels drop constraint if exists duels_game_check;
alter table public.duels add constraint duels_game_check check (game in ('wordless','clueless','werbinich','schiffe','mensch','schwimmen'));

create table if not exists public.sw_hands (
  duel_id uuid references public.duels(id) on delete cascade,
  user_id uuid references public.profiles(id) on delete cascade,
  cards jsonb not null,
  primary key (duel_id, user_id)
);
create table if not exists public.sw_deck (duel_id uuid primary key references public.duels(id) on delete cascade, deck jsonb not null);
alter table public.sw_hands enable row level security;
alter table public.sw_deck enable row level security;
drop policy if exists p_sw_hands on public.sw_hands;
create policy p_sw_hands on public.sw_hands for select to authenticated using (user_id = auth.uid());
grant select on public.sw_hands to authenticated;
revoke all on public.sw_deck from anon, authenticated;

-- Karten: Farbe (c=Kreuz, s=Pik, h=Herz, d=Karo) + Wert (7,8,9,T,J,Q,K,A)
create or replace function public._sw_val(c text) returns int language sql immutable as $$
  select case substr(c,2,1) when 'A' then 11 when 'T' then 10 when 'J' then 10 when 'Q' then 10 when 'K' then 10 else substr(c,2,1)::int end
$$;
create or replace function public._sw_score(cards jsonb) returns numeric language plpgsql immutable as $$
declare a text := cards->>0; b text := cards->>1; c text := cards->>2; best numeric := 0; s text;
begin
  if substr(a,2,1) = 'A' and substr(b,2,1) = 'A' and substr(c,2,1) = 'A' then return 32; end if;
  foreach s in array array['c','s','h','d'] loop
    best := greatest(best, (case when left(a,1) = s then _sw_val(a) else 0 end) + (case when left(b,1) = s then _sw_val(b) else 0 end) + (case when left(c,1) = s then _sw_val(c) else 0 end));
  end loop;
  if substr(a,2,1) = substr(b,2,1) and substr(b,2,1) = substr(c,2,1) then best := greatest(best, 30.5); end if;
  return best;
end $$;

create or replace function public._sw_active(st jsonb) returns text[] language sql immutable as $$
  select coalesce(array_agg(s order by o), '{}') from jsonb_array_elements_text(st->'seats') with ordinality x(s, o) where coalesce((st->'lives'->>s)::int, -1) >= 0
$$;
create or replace function public._sw_next(st jsonb, cur text) returns text language plpgsql immutable as $$
declare seats jsonb := st->'seats'; n int := jsonb_array_length(seats); i int := 0; k int; cand text;
begin
  for k in 0..n-1 loop if seats->>k = cur then i := k; end if; end loop;
  for k in 1..n loop
    cand := seats->>((i + k) % n);
    if coalesce((st->'lives'->>cand)::int, -1) >= 0 then return cand; end if;
  end loop;
  return cur;
end $$;

-- Runde auswerten
create or replace function public._sw_reveal(d uuid, reason text) returns void language plpgsql security definer set search_path = public as $$
declare st jsonb; act text[]; u text; rev jsonb := '{}'::jsonb; sc numeric; mn numeric := 100; fire text := null; losers text[] := '{}'; l int; alive int; w text;
begin
  select state into st from duels where id = d;
  act := _sw_active(st);
  foreach u in array act loop
    select _sw_score(cards) into sc from sw_hands where duel_id = d and user_id = u::uuid;
    rev := rev || jsonb_build_object(u, jsonb_build_object('cards', (select cards from sw_hands where duel_id = d and user_id = u::uuid), 'score', sc));
    if sc = 32 then fire := u; end if;
    mn := least(mn, sc);
  end loop;
  foreach u in array act loop
    sc := (rev->u->>'score')::numeric;
    if (fire is not null and u <> fire) or (fire is null and sc = mn) then losers := losers || u; end if;
  end loop;
  st := _mad_event(st, jsonb_build_object('t','reveal','reason',reason,'losers',to_jsonb(losers),'fire',fire));
  foreach u in array losers loop
    l := (st->'lives'->>u)::int - 1;
    st := jsonb_set(st, array['lives', u], to_jsonb(l));
    if l = 0 then st := _mad_event(st, jsonb_build_object('t','swim','u',u));
    elsif l < 0 then
      st := _mad_event(st, jsonb_build_object('t','out','u',u));
      update duel_players set status = 'failed', finished_at = now() where duel_id = d and user_id = u::uuid;
    else st := _mad_event(st, jsonb_build_object('t','life','u',u,'l',l)); end if;
  end loop;
  st := st || jsonb_build_object('phase','reveal','reveal',rev,'losers',to_jsonb(losers),'turn',null);
  update duels set state = st where id = d;
  alive := array_length(_sw_active(st), 1);
  if coalesce(alive,0) <= 1 then
    w := (_sw_active(st))[1];
    if w is not null then
      update duel_players set status = 'solved', finished_at = now() where duel_id = d and user_id = w::uuid;
    end if;
    update duel_players set status = 'failed', finished_at = now() where duel_id = d and status = 'playing';
    update duels set state = _mad_event(state, jsonb_build_object('t','win','u',w)), status = 'finished', winner_id = w::uuid, finished_at = now() where id = d;
  end if;
end $$;

-- neue Runde geben
create or replace function public._sw_deal(d uuid) returns void language plpgsql security definer set search_path = public as $$
declare st jsonb; deck jsonb; act text[]; u text; k int := 0; dealer text; instant boolean := false;
begin
  select state into st from duels where id = d;
  act := _sw_active(st);
  select jsonb_agg(c order by random()) into deck from (
    select s || r as c from unnest(array['c','s','h','d']) s, unnest(array['7','8','9','T','J','Q','K','A']) r) x;
  delete from sw_hands where duel_id = d;
  foreach u in array act loop
    insert into sw_hands values (d, u::uuid, jsonb_build_array(deck->k, deck->(k+1), deck->(k+2)));
    k := k + 3;
  end loop;
  dealer := case when st->>'dealer' is null then (st->'seats'->>0) else _sw_next(st, st->>'dealer') end;
  st := st || jsonb_build_object('phase','play','dealer',dealer,'turn',_sw_next(st, dealer),'table',jsonb_build_array(deck->k, deck->(k+1), deck->(k+2)),
    'knock',null,'passes',0,'round',coalesce((st->>'round')::int,0) + 1,'reveal',null,'losers',null);
  st := _mad_event(st, jsonb_build_object('t','deal','round',(st->>'round')::int));
  insert into sw_deck values (d, coalesce((select jsonb_agg(e) from jsonb_array_elements(deck) with ordinality x(e,o) where o > k + 3), '[]'::jsonb))
    on conflict (duel_id) do update set deck = excluded.deck;
  update duels set state = st where id = d;
  -- 31 oder Feuer schon beim Geben?
  for u in select user_id::text from sw_hands where duel_id = d and _sw_score(cards) >= 31 loop instant := true; end loop;
  if instant then perform _sw_reveal(d, 'deal31'); end if;
end $$;

create or replace function public.sw_start(p_duel uuid) returns void language plpgsql security definer set search_path = public as $$
declare dl duels; seats jsonb; lives jsonb := '{}'::jsonb; u text;
begin
  select * into dl from duels where id = p_duel;
  if dl.game <> 'schwimmen' or dl.status <> 'open' or dl.state->>'phase' <> 'lobby' then raise exception 'Spiel läuft schon oder ist beendet'; end if;
  if dl.created_by <> auth.uid() then raise exception 'Nur wer das Spiel erstellt hat, kann starten'; end if;
  if (select count(*) from duel_players where duel_id = p_duel and status = 'playing') < 2 then raise exception 'Es muss mindestens eine weitere Person angenommen haben'; end if;
  update duel_players set status = 'declined', finished_at = now() where duel_id = p_duel and status = 'invited';
  select jsonb_agg(user_id::text order by random()) into seats from duel_players where duel_id = p_duel and status = 'playing';
  for u in select jsonb_array_elements_text(seats) loop lives := lives || jsonb_build_object(u, 3); end loop;
  update duels set state = jsonb_build_object('phase','deal','seats',seats,'lives',lives,'seq',0,'events','[]'::jsonb,'round',0) where id = p_duel;
  perform _sw_deal(p_duel);
end $$;

-- Zug: 'one' (eine Karte tauschen), 'all' (alle drei), 'pass' (schieben), 'knock' (klopfen)
create or replace function public.sw_action(p_duel uuid, p_action text, p_hand int default null, p_table int default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare dl duels; st jsonb; me text := auth.uid()::text; hand jsonb; tbl jsonb; tmp jsonb; sc numeric; nxt text; act int; dk jsonb;
begin
  select * into dl from duels where id = p_duel for update;
  st := dl.state;
  if dl.game <> 'schwimmen' or dl.status <> 'open' or st->>'phase' <> 'play' then raise exception 'Gerade läuft keine Runde'; end if;
  if st->>'turn' <> me then raise exception 'Du bist nicht dran'; end if;
  select cards into hand from sw_hands where duel_id = p_duel and user_id = me::uuid;
  tbl := st->'table';
  update duel_players set attempts = attempts + 1 where duel_id = p_duel and user_id = me::uuid;
  if p_action = 'one' then
    if p_hand not between 0 and 2 or p_table not between 0 and 2 then raise exception 'Ungültige Karte'; end if;
    tmp := hand->p_hand;
    hand := jsonb_set(hand, array[p_hand::text], tbl->p_table);
    tbl := jsonb_set(tbl, array[p_table::text], tmp);
    st := jsonb_set(st, '{passes}', '0'::jsonb);
    st := _mad_event(st, jsonb_build_object('t','one','u',me,'took',hand->p_hand,'gave',tmp));
  elsif p_action = 'all' then
    tmp := hand; hand := tbl; tbl := tmp;
    st := jsonb_set(st, '{passes}', '0'::jsonb);
    st := _mad_event(st, jsonb_build_object('t','all','u',me));
  elsif p_action = 'pass' then
    st := jsonb_set(st, '{passes}', to_jsonb(coalesce((st->>'passes')::int,0) + 1));
    st := _mad_event(st, jsonb_build_object('t','pass','u',me));
  elsif p_action = 'knock' then
    if st->>'knock' is not null then raise exception 'Es wurde schon geklopft'; end if;
    st := jsonb_set(st, '{knock}', to_jsonb(me));
    st := _mad_event(st, jsonb_build_object('t','knock','u',me));
  else raise exception 'Unbekannter Zug'; end if;
  update sw_hands set cards = hand where duel_id = p_duel and user_id = me::uuid;
  st := jsonb_set(st, '{table}', tbl);
  update duels set state = st where id = p_duel;
  -- 31 / Feuer = sofort aufdecken
  sc := _sw_score(hand);
  if sc >= 31 then
    update duels set state = _mad_event(state, jsonb_build_object('t', case when sc = 32 then 'fire' else 'schnauz' end, 'u', me)) where id = p_duel;
    perform _sw_reveal(p_duel, case when sc = 32 then 'fire' else 'schnauz' end);
    return jsonb_build_object('score', sc, 'reveal', true);
  end if;
  -- alle haben geschoben: neue Karten in die Mitte
  act := array_length(_sw_active(st), 1);
  if p_action = 'pass' and (st->>'passes')::int >= act and st->>'knock' is null then
    select deck into dk from sw_deck where duel_id = p_duel;
    if jsonb_array_length(dk) >= 3 then
      st := jsonb_set(jsonb_set(st, '{table}', jsonb_build_array(dk->0, dk->1, dk->2)), '{passes}', '0'::jsonb);
      st := _mad_event(st, jsonb_build_object('t','newtable'));
      update sw_deck set deck = (select coalesce(jsonb_agg(e), '[]'::jsonb) from jsonb_array_elements(dk) with ordinality x(e,o) where o > 3) where duel_id = p_duel;
    else
      update duels set state = st where id = p_duel;
      perform _sw_reveal(p_duel, 'deckempty');
      return jsonb_build_object('score', sc, 'reveal', true);
    end if;
  end if;
  nxt := _sw_next(st, me);
  if st->>'knock' is not null and nxt = st->>'knock' then
    update duels set state = st where id = p_duel;
    perform _sw_reveal(p_duel, 'knock');
    return jsonb_build_object('score', sc, 'reveal', true);
  end if;
  st := jsonb_set(st, '{turn}', to_jsonb(nxt));
  update duels set state = st where id = p_duel;
  return jsonb_build_object('score', sc, 'reveal', false);
end $$;

create or replace function public.sw_next_round(p_duel uuid) returns void language plpgsql security definer set search_path = public as $$
declare dl duels;
begin
  select * into dl from duels where id = p_duel for update;
  if dl.game <> 'schwimmen' or dl.status <> 'open' or dl.state->>'phase' <> 'reveal' then return; end if;
  if not is_participant(p_duel) then raise exception 'Du spielst nicht mit'; end if;
  perform _sw_deal(p_duel);
end $$;

-- create_duel um Schwimmen erweitern
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
  elsif p_game = 'schwimmen' then
    if n < 1 or n > 8 then raise exception 'Schwimmen: 2 bis 9 Spieler'; end if; s := '-';
  else raise exception 'Unbekanntes Spiel'; end if;
  if s is null then raise exception 'Wortdaten fehlen – Admin muss sie zuerst laden'; end if;
  insert into duels(game, word_length, max_attempts, created_by, state)
    values (p_game, case when p_game='wordless' then p_len end, case when p_game='wordless' then 6 end, auth.uid(),
      case when p_game in ('werbinich','mensch','schwimmen') then '{"phase":"lobby"}'::jsonb when p_game = 'schiffe' then '{"phase":"place","ready":[]}'::jsonb else '{}'::jsonb end)
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

create or replace function public._check_finish(d uuid) returns void language plpgsql security definer set search_path = public as $$
declare w uuid; g text; ph text;
begin
  select game, state->>'phase' into g, ph from duels where id = d;
  if g in ('werbinich','schiffe','mensch','schwimmen') then
    if exists(select 1 from duel_players where duel_id = d and status = 'invited') then return; end if;
    if (select count(*) from duel_players where duel_id = d and status = 'playing') > 1 then return; end if;
    if g in ('schiffe','mensch','schwimmen') then
      update duel_players set status = 'solved', finished_at = now() where duel_id = d and status = 'playing' and ph in ('play','reveal','deal');
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
declare dl duels; st jsonb; me text := auth.uid()::text; nxt text;
begin
  select * into dl from duels where id = p_duel;
  update duel_players set status = 'gave_up', finished_at = now() where duel_id = p_duel and user_id = auth.uid() and status = 'playing';
  if dl.game = 'werbinich' and dl.state->>'phase' = 'assign' then
    perform _wbi_check_assign(p_duel);
  elsif dl.game = 'werbinich' and dl.state->>'phase' = 'play' then
    if dl.state->>'turn' = me then
      update wbi_questions set result = 'no', resolved_at = now() where id = (dl.state->>'qid')::bigint and result is null;
      perform _wbi_set_turn(p_duel, _wbi_next(p_duel, auth.uid()));
    else
      perform _wbi_try_resolve(p_duel);
    end if;
  elsif dl.game = 'mensch' and dl.state->>'phase' = 'play' then
    update duels set state = jsonb_set(jsonb_set(jsonb_set(state, array['pos', me], '[-9,-9,-9,-9]'::jsonb), '{dice}', 'null'::jsonb), '{turn}',
      case when state->>'turn' = me then to_jsonb(_mad_next(p_duel, auth.uid())::text) else state->'turn' end) where id = p_duel;
  elsif dl.game = 'schwimmen' and dl.state ? 'lives' then
    st := jsonb_set(dl.state, array['lives', me], '-1'::jsonb);
    st := _mad_event(st, jsonb_build_object('t','out','u',me,'quit',true));
    delete from sw_hands where duel_id = p_duel and user_id = auth.uid();
    if st->>'knock' = me then st := jsonb_set(st, '{knock}', 'null'::jsonb); end if;
    if st->>'turn' = me then
      nxt := _sw_next(st, me);
      if st->>'knock' is not null and nxt = st->>'knock' then
        update duels set state = st where id = p_duel; perform _sw_reveal(p_duel, 'knock');
      else st := jsonb_set(st, '{turn}', to_jsonb(nxt)); update duels set state = st where id = p_duel; end if;
    else
      update duels set state = st where id = p_duel;
    end if;
  end if;
  perform _check_finish(p_duel);
end $$;

-- Rangliste mit Schwimmen
drop function if exists public.leaderboard();
create or replace function public.leaderboard() returns table(user_id uuid, display_name text, username text, points bigint, wins bigint, played bigint,
  wins_wordless bigint, wins_clueless bigint, wins_werbinich bigint, wins_schiffe bigint, wins_mensch bigint, wins_schwimmen bigint)
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
    count(distinct r.id) filter (where r.winner_id = p.id and r.game = 'mensch'),
    count(distinct r.id) filter (where r.winner_id = p.id and r.game = 'schwimmen')
  from profiles p
  left join duel_players dp on dp.user_id = p.id and dp.status in ('solved','failed','gave_up')
  left join r on r.id = dp.duel_id
  where is_player()
  group by p.id order by 4 desc, 5 desc, 2 asc
$$;

revoke all on function public._sw_reveal(uuid,text), public._sw_deal(uuid), public._check_finish(uuid) from public, anon, authenticated;
grant execute on function public.sw_start(uuid), public.sw_action(uuid,text,int,int), public.sw_next_round(uuid), public.leaderboard(), public.create_duel(text,int,uuid[]), public.give_up(uuid) to authenticated;
revoke execute on function public.sw_start(uuid), public.sw_action(uuid,text,int,int), public.sw_next_round(uuid), public.leaderboard() from anon, public;
