-- Wort-Duell · Update 2: Freunde, Punkte/Ränge, Wer bin ich?, Schiffe versenken
create extension if not exists fuzzystrmatch with schema extensions;

-- ---------- Spiele erweitern ----------
alter table public.duels drop constraint if exists duels_game_check;
alter table public.duels add constraint duels_game_check check (game in ('wordless','clueless','werbinich','schiffe'));
alter table public.duels add column if not exists state jsonb not null default '{}'::jsonb;

-- ---------- Freunde ----------
create table if not exists public.friendships (
  user_a uuid not null references public.profiles(id) on delete cascade,
  user_b uuid not null references public.profiles(id) on delete cascade,
  requested_by uuid not null references public.profiles(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending','accepted')),
  created_at timestamptz not null default now(),
  accepted_at timestamptz,
  primary key (user_a, user_b),
  check (user_a < user_b)
);
alter table public.friendships enable row level security;
drop policy if exists p_friend_read on public.friendships;
create policy p_friend_read on public.friendships for select to authenticated
  using (public.is_player() and (user_a = auth.uid() or user_b = auth.uid()));
grant select on public.friendships to authenticated;

create or replace function public.are_friends(x uuid, y uuid) returns boolean language sql stable security definer set search_path = public as
$$ select exists(select 1 from friendships where user_a = least(x,y) and user_b = greatest(x,y) and status = 'accepted') $$;

-- Bestehende Spieler sind automatisch untereinander befreundet (nur einmalig beim Update)
insert into public.friendships(user_a, user_b, requested_by, status, accepted_at)
select a.id, b.id, a.id, 'accepted', now() from public.profiles a join public.profiles b on a.id < b.id
on conflict do nothing;

create or replace function public.friend_request(p_user uuid) returns text
language plpgsql security definer set search_path = public as $$
declare f friendships; a uuid := least(auth.uid(), p_user); b uuid := greatest(auth.uid(), p_user);
begin
  if not is_player() then raise exception 'Kein Zugriff'; end if;
  if p_user = auth.uid() then raise exception 'Du kannst dich nicht selbst hinzufügen'; end if;
  if not exists(select 1 from profiles where id = p_user) then raise exception 'Spieler nicht gefunden'; end if;
  select * into f from friendships where user_a = a and user_b = b;
  if f.status = 'accepted' then return 'schon befreundet'; end if;
  if f.status = 'pending' and f.requested_by <> auth.uid() then
    update friendships set status = 'accepted', accepted_at = now() where user_a = a and user_b = b;
    return 'angenommen';
  end if;
  insert into friendships(user_a, user_b, requested_by) values (a, b, auth.uid()) on conflict do nothing;
  return 'gesendet';
end $$;

create or replace function public.friend_request_by_name(p_username text) returns text
language plpgsql security definer set search_path = public as $$
declare u uuid;
begin
  select id into u from profiles where username = lower(trim(both '@ ' from p_username));
  if u is null then raise exception 'Keinen Spieler mit diesem Benutzernamen gefunden'; end if;
  return friend_request(u);
end $$;

create or replace function public.friend_respond(p_user uuid, p_accept boolean) returns void
language plpgsql security definer set search_path = public as $$
declare a uuid := least(auth.uid(), p_user); b uuid := greatest(auth.uid(), p_user);
begin
  if p_accept then
    update friendships set status = 'accepted', accepted_at = now()
      where user_a = a and user_b = b and status = 'pending' and requested_by = p_user;
  else
    delete from friendships where user_a = a and user_b = b and status = 'pending' and requested_by = p_user;
  end if;
end $$;

create or replace function public.friend_remove(p_user uuid) returns void
language sql security definer set search_path = public as $$
  delete from friendships where user_a = least(auth.uid(), p_user) and user_b = greatest(auth.uid(), p_user)
$$;

-- Admin, der einen Account anlegt, ist automatisch mit ihm befreundet
create or replace function public.admin_create_user(p_username text, p_display text, p_password text, p_admin boolean default false) returns uuid
language plpgsql security definer set search_path = public as $$
declare u uuid;
begin
  if not is_admin() then raise exception 'Nur für Admins'; end if;
  u := _create_account(p_username, p_display, p_password, p_admin);
  insert into friendships(user_a, user_b, requested_by, status, accepted_at)
    values (least(u, auth.uid()), greatest(u, auth.uid()), auth.uid(), 'accepted', now()) on conflict do nothing;
  return u;
end $$;

-- Nachrichten nur unter Freunden
create or replace function public.send_message(p_to uuid, p_body text) returns bigint
language plpgsql security definer set search_path = public as $$
declare i bigint;
begin
  if not is_player() then raise exception 'Kein Zugriff'; end if;
  if p_to = auth.uid() then raise exception 'Du kannst dir nicht selbst schreiben'; end if;
  if not are_friends(auth.uid(), p_to) then raise exception 'Ihr müsst befreundet sein, um zu schreiben'; end if;
  if char_length(trim(p_body)) = 0 then raise exception 'Leere Nachricht'; end if;
  insert into messages(from_id, to_id, body) values (auth.uid(), p_to, trim(p_body)) returning id into i;
  return i;
end $$;

-- ---------- Duell erstellen (alle Spiele, nur Freunde) ----------
create table if not exists public.wbi_pool (name text primary key, category text);
alter table public.wbi_pool enable row level security;

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
    if n < 1 then raise exception 'Wer bin ich? braucht mindestens 2 Spieler'; end if;
    s := '-';
  elsif p_game = 'schiffe' then
    if n <> 1 then raise exception 'Schiffe versenken spielt man zu zweit – lade genau eine Person ein'; end if;
    s := '-';
  else raise exception 'Unbekanntes Spiel'; end if;
  if s is null then raise exception 'Wortdaten fehlen – Admin muss sie zuerst laden'; end if;
  insert into duels(game, word_length, max_attempts, created_by, state)
    values (p_game, case when p_game='wordless' then p_len end, case when p_game='wordless' then 6 end, auth.uid(),
      case p_game when 'werbinich' then '{"phase":"lobby"}'::jsonb when 'schiffe' then '{"phase":"place","ready":[]}'::jsonb else '{}'::jsonb end)
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

-- Gewinner-Ermittlung je Spiel
create or replace function public._check_finish(d uuid) returns void language plpgsql security definer set search_path = public as $$
declare w uuid; g text;
begin
  select game into g from duels where id = d;
  if g in ('werbinich','schiffe') then
    if exists(select 1 from duel_players where duel_id = d and status = 'invited') then return; end if;
    if (select count(*) from duel_players where duel_id = d and status = 'playing') > (case when g = 'schiffe' then 1 else 1 end) then return; end if;
    if g = 'werbinich' and (select state->>'phase' from duels where id = d) = 'lobby'
       and (select count(*) from duel_players where duel_id = d and status = 'playing') = 1
       and (select count(*) from duel_players where duel_id = d and status not in ('declined','playing')) = 0 then
      update duel_players set status = 'gave_up', finished_at = now() where duel_id = d and status = 'playing';
    end if;
    if g = 'schiffe' then
      -- wer übrig bleibt, gewinnt (Gegner hat aufgegeben)
      update duel_players set status = 'solved', finished_at = now()
        where duel_id = d and status = 'playing' and (select state->>'phase' from duels where id = d) = 'play';
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

-- ---------- Wer bin ich? ----------
create table if not exists public.wbi_names (
  duel_id uuid references public.duels(id) on delete cascade,
  user_id uuid references public.profiles(id) on delete cascade,
  name text not null,
  primary key (duel_id, user_id)
);
create table if not exists public.wbi_questions (
  id bigserial primary key,
  duel_id uuid references public.duels(id) on delete cascade,
  asker uuid references public.profiles(id) on delete cascade,
  kind text not null default 'q' check (kind in ('q','guess')),
  text text not null,
  result text check (result in ('yes','no')),
  yes int not null default 0, no int not null default 0,
  created_at timestamptz not null default now(),
  resolved_at timestamptz
);
create table if not exists public.wbi_votes (
  question_id bigint references public.wbi_questions(id) on delete cascade,
  voter uuid references public.profiles(id) on delete cascade,
  vote boolean not null,
  primary key (question_id, voter)
);
create index if not exists wbi_q_duel on public.wbi_questions(duel_id);
alter table public.wbi_names enable row level security;
alter table public.wbi_questions enable row level security;
alter table public.wbi_votes enable row level security;
drop policy if exists p_wbi_names on public.wbi_names;
create policy p_wbi_names on public.wbi_names for select to authenticated using (
  public.is_participant(duel_id) and (user_id <> auth.uid()
    or exists(select 1 from public.duels d where d.id = duel_id and d.status <> 'open')
    or exists(select 1 from public.duel_players p where p.duel_id = wbi_names.duel_id and p.user_id = auth.uid() and p.status <> 'playing')));
drop policy if exists p_wbi_q on public.wbi_questions;
create policy p_wbi_q on public.wbi_questions for select to authenticated using (public.is_participant(duel_id));
drop policy if exists p_wbi_v on public.wbi_votes;
create policy p_wbi_v on public.wbi_votes for select to authenticated using (
  exists(select 1 from public.wbi_questions q where q.id = question_id and public.is_participant(q.duel_id)));
grant select on public.wbi_names, public.wbi_questions, public.wbi_votes to authenticated;

create or replace function public._wbi_norm(t text) returns text language sql immutable as $$
  select regexp_replace(replace(replace(replace(replace(lower(coalesce(t,'')),'ä','ae'),'ö','oe'),'ü','ue'),'ß','ss'), '[^a-z0-9]', '', 'g')
$$;

-- nächster Spieler, der noch rät
create or replace function public._wbi_next(d uuid, cur uuid) returns uuid language plpgsql security definer set search_path = public as $$
declare ord jsonb; n int; i int; k int; cand uuid;
begin
  select state->'order' into ord from duels where id = d;
  n := jsonb_array_length(ord);
  i := 0;
  for k in 0..n-1 loop if (ord->>k)::uuid = cur then i := k; end if; end loop;
  for k in 1..n loop
    cand := (ord->>((i + k) % n))::uuid;
    if exists(select 1 from duel_players where duel_id = d and user_id = cand and status = 'playing') then return cand; end if;
  end loop;
  return null;
end $$;

create or replace function public._wbi_set_turn(d uuid, u uuid) returns void language sql security definer set search_path = public as $$
  update duels set state = jsonb_set(jsonb_set(state, '{turn}', coalesce(to_jsonb(u::text), 'null'::jsonb)), '{qid}', 'null'::jsonb) where id = d
$$;

create or replace function public._wbi_try_resolve(d uuid) returns void language plpgsql security definer set search_path = public as $$
declare q wbi_questions; voters int; y int; nn int;
begin
  select * into q from wbi_questions where id = (select (state->>'qid')::bigint from duels where id = d) and result is null;
  if q.id is null then return; end if;
  select count(*) into voters from duel_players where duel_id = d and user_id <> q.asker and status in ('playing','solved');
  select count(*) filter (where vote), count(*) filter (where not vote) into y, nn from wbi_votes v
    where v.question_id = q.id and exists(select 1 from duel_players p where p.duel_id = d and p.user_id = v.voter and p.status in ('playing','solved'));
  update wbi_questions set yes = y, no = nn where id = q.id;
  if voters = 0 then
    update wbi_questions set result = 'yes', resolved_at = now() where id = q.id;
    perform _wbi_set_turn(d, q.asker);
  elsif y * 2 > voters then
    update wbi_questions set result = 'yes', resolved_at = now() where id = q.id;
    perform _wbi_set_turn(d, q.asker);          -- RICHTIG: nochmal fragen
  elsif nn * 2 >= voters then
    update wbi_questions set result = 'no', resolved_at = now() where id = q.id;
    perform _wbi_set_turn(d, _wbi_next(d, q.asker));  -- FALSCH (oder Gleichstand): Nächster ist dran
  end if;
end $$;

create or replace function public.wbi_start(p_duel uuid) returns void language plpgsql security definer set search_path = public as $$
declare dl duels; ord jsonb; u uuid; nm text; first uuid;
begin
  select * into dl from duels where id = p_duel;
  if dl.game <> 'werbinich' or dl.status <> 'open' or dl.state->>'phase' <> 'lobby' then raise exception 'Spiel läuft schon oder ist beendet'; end if;
  if dl.created_by <> auth.uid() then raise exception 'Nur wer das Spiel erstellt hat, kann starten'; end if;
  if (select count(*) from duel_players where duel_id = p_duel and status = 'playing') < 2 then raise exception 'Es muss mindestens eine weitere Person angenommen haben'; end if;
  update duel_players set status = 'declined', finished_at = now() where duel_id = p_duel and status = 'invited';
  select jsonb_agg(user_id::text order by random()) into ord from duel_players where duel_id = p_duel and status = 'playing';
  for u in select user_id from duel_players where duel_id = p_duel and status = 'playing' loop
    select name into nm from wbi_pool where name not in (select name from wbi_names where duel_id = p_duel) order by random() limit 1;
    insert into wbi_names values (p_duel, u, nm);
  end loop;
  first := (ord->>0)::uuid;
  update duels set state = jsonb_build_object('phase','play','order',ord,'turn',first::text,'qid',null) where id = p_duel;
end $$;

create or replace function public.wbi_ask(p_duel uuid, p_text text) returns void language plpgsql security definer set search_path = public as $$
declare dl duels; qid bigint;
begin
  select * into dl from duels where id = p_duel;
  if dl.status <> 'open' or dl.state->>'phase' <> 'play' then raise exception 'Spiel läuft nicht'; end if;
  if dl.state->>'turn' <> auth.uid()::text then raise exception 'Du bist gerade nicht dran'; end if;
  if dl.state->>'qid' is not null then raise exception 'Es läuft schon eine Abstimmung'; end if;
  if char_length(trim(p_text)) < 2 then raise exception 'Bitte eine Frage eingeben'; end if;
  insert into wbi_questions(duel_id, asker, text) values (p_duel, auth.uid(), left(trim(p_text), 300)) returning id into qid;
  update duels set state = jsonb_set(state, '{qid}', to_jsonb(qid)) where id = p_duel;
  update duel_players set attempts = attempts + 1 where duel_id = p_duel and user_id = auth.uid();
  perform _wbi_try_resolve(p_duel);
end $$;

create or replace function public.wbi_vote(p_duel uuid, p_vote boolean) returns void language plpgsql security definer set search_path = public as $$
declare dl duels; q wbi_questions;
begin
  select * into dl from duels where id = p_duel;
  if dl.status <> 'open' or dl.state->>'qid' is null then raise exception 'Gerade keine Abstimmung'; end if;
  select * into q from wbi_questions where id = (dl.state->>'qid')::bigint;
  if q.asker = auth.uid() then raise exception 'Über deine eigene Frage stimmen die anderen ab'; end if;
  if not exists(select 1 from duel_players where duel_id = p_duel and user_id = auth.uid() and status in ('playing','solved')) then raise exception 'Du spielst nicht mit'; end if;
  insert into wbi_votes values (q.id, auth.uid(), p_vote) on conflict (question_id, voter) do update set vote = excluded.vote;
  perform _wbi_try_resolve(p_duel);
end $$;

create or replace function public.wbi_guess(p_duel uuid, p_text text) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare dl duels; nm text; g text := _wbi_norm(p_text); full_n text; last_n text; ok boolean;
begin
  select * into dl from duels where id = p_duel;
  if dl.status <> 'open' or dl.state->>'phase' <> 'play' then raise exception 'Spiel läuft nicht'; end if;
  if dl.state->>'turn' <> auth.uid()::text then raise exception 'Du bist gerade nicht dran'; end if;
  if dl.state->>'qid' is not null then raise exception 'Warte, bis die Abstimmung fertig ist'; end if;
  select name into nm from wbi_names where duel_id = p_duel and user_id = auth.uid();
  full_n := _wbi_norm(nm);
  last_n := _wbi_norm(regexp_replace(nm, '^.*\s', ''));
  ok := g = full_n or (char_length(last_n) >= 4 and g = last_n and position(' ' in nm) > 0)
        or (char_length(full_n) >= 6 and levenshtein(g, full_n) <= 2);
  update duel_players set attempts = attempts + 1 where duel_id = p_duel and user_id = auth.uid();
  insert into wbi_questions(duel_id, asker, kind, text, result, resolved_at)
    values (p_duel, auth.uid(), 'guess', left(trim(p_text), 120), case when ok then 'yes' else 'no' end, now());
  if ok then
    update duel_players set status = 'solved', finished_at = now() where duel_id = p_duel and user_id = auth.uid();
  end if;
  perform _wbi_set_turn(p_duel, _wbi_next(p_duel, auth.uid()));
  perform _check_finish(p_duel);
  return jsonb_build_object('correct', ok, 'name', case when ok then nm end);
end $$;

-- ---------- Schiffe versenken ----------
create table if not exists public.bs_boards (
  duel_id uuid references public.duels(id) on delete cascade,
  user_id uuid references public.profiles(id) on delete cascade,
  ships jsonb not null,
  primary key (duel_id, user_id)
);
create table if not exists public.bs_shots (
  id bigserial primary key,
  duel_id uuid references public.duels(id) on delete cascade,
  shooter uuid references public.profiles(id) on delete cascade,
  x int not null, y int not null,
  result text not null check (result in ('miss','hit','sunk')),
  sunk jsonb,
  created_at timestamptz not null default now(),
  unique (duel_id, shooter, x, y)
);
alter table public.bs_boards enable row level security;
alter table public.bs_shots enable row level security;
drop policy if exists p_bs_boards on public.bs_boards;
create policy p_bs_boards on public.bs_boards for select to authenticated using (
  user_id = auth.uid() or exists(select 1 from public.duels d where d.id = duel_id and d.status <> 'open' and public.is_participant(d.id)));
drop policy if exists p_bs_shots on public.bs_shots;
create policy p_bs_shots on public.bs_shots for select to authenticated using (public.is_participant(duel_id));
grant select on public.bs_boards, public.bs_shots to authenticated;

create or replace function public.bs_place(p_duel uuid, p_ships jsonb) returns void language plpgsql security definer set search_path = public as $$
declare dl duels; s jsonb; c jsonb; cells text[] := '{}'; lens int[] := '{}'; xs int[]; ys int[]; k text; rdy jsonb; other uuid;
begin
  select * into dl from duels where id = p_duel;
  if dl.game <> 'schiffe' or dl.status <> 'open' or dl.state->>'phase' <> 'place' then raise exception 'Platzieren gerade nicht möglich'; end if;
  if not exists(select 1 from duel_players where duel_id = p_duel and user_id = auth.uid() and status = 'playing') then raise exception 'Nimm zuerst die Einladung an'; end if;
  if jsonb_array_length(p_ships) <> 5 then raise exception 'Genau 5 Schiffe'; end if;
  for s in select * from jsonb_array_elements(p_ships) loop
    lens := lens || jsonb_array_length(s);
    select array_agg((e->>0)::int), array_agg((e->>1)::int) into xs, ys from jsonb_array_elements(s) e;
    if (select min(v) from unnest(xs || ys) v) < 0 or (select max(v) from unnest(xs || ys) v) > 9 then raise exception 'Schiff außerhalb des Felds'; end if;
    if not ((select count(distinct v) from unnest(xs) v) = 1 and (select max(v) - min(v) from unnest(ys) v) = array_length(ys,1) - 1 and (select count(distinct v) from unnest(ys) v) = array_length(ys,1))
       and not ((select count(distinct v) from unnest(ys) v) = 1 and (select max(v) - min(v) from unnest(xs) v) = array_length(xs,1) - 1 and (select count(distinct v) from unnest(xs) v) = array_length(xs,1))
    then raise exception 'Schiffe müssen gerade sein'; end if;
    for c in select * from jsonb_array_elements(s) loop
      k := (c->>0) || ',' || (c->>1);
      if k = any(cells) then raise exception 'Schiffe dürfen sich nicht überlappen'; end if;
      cells := cells || k;
    end loop;
  end loop;
  if (select array_agg(v order by v) from unnest(lens) v) <> array[2,3,3,4,5] then raise exception 'Flotte: 5er, 4er, zwei 3er, 2er'; end if;
  insert into bs_boards values (p_duel, auth.uid(), p_ships) on conflict (duel_id, user_id) do update set ships = excluded.ships;
  rdy := coalesce(dl.state->'ready', '[]'::jsonb);
  if not rdy ? auth.uid()::text then rdy := rdy || to_jsonb(auth.uid()::text); end if;
  if jsonb_array_length(rdy) >= 2 then
    select user_id into other from duel_players where duel_id = p_duel order by random() limit 1;
    update duels set state = jsonb_build_object('phase','play','ready',rdy,'turn',other::text) where id = p_duel;
  else
    update duels set state = jsonb_set(state, '{ready}', rdy) where id = p_duel;
  end if;
end $$;

create or replace function public.bs_shoot(p_duel uuid, p_x int, p_y int) returns jsonb language plpgsql security definer set search_path = public as $$
declare dl duels; opp uuid; sh jsonb; s jsonb; res text := 'miss'; sunk jsonb; hitset text[]; allhit boolean; total int; hits int;
begin
  select * into dl from duels where id = p_duel for update;
  if dl.game <> 'schiffe' or dl.status <> 'open' or dl.state->>'phase' <> 'play' then raise exception 'Spiel läuft nicht'; end if;
  if dl.state->>'turn' <> auth.uid()::text then raise exception 'Du bist nicht dran'; end if;
  if p_x not between 0 and 9 or p_y not between 0 and 9 then raise exception 'Ungültiges Feld'; end if;
  if exists(select 1 from bs_shots where duel_id = p_duel and shooter = auth.uid() and x = p_x and y = p_y) then raise exception 'Da hast du schon hingeschossen'; end if;
  select user_id into opp from duel_players where duel_id = p_duel and user_id <> auth.uid();
  select ships into sh from bs_boards where duel_id = p_duel and user_id = opp;
  select array_agg(x || ',' || y) into hitset from bs_shots where duel_id = p_duel and shooter = auth.uid() and result <> 'miss';
  hitset := coalesce(hitset, '{}') || (p_x || ',' || p_y);
  for s in select * from jsonb_array_elements(sh) loop
    if exists(select 1 from jsonb_array_elements(s) e where (e->>0)::int = p_x and (e->>1)::int = p_y) then
      res := 'hit';
      select bool_and(((e->>0) || ',' || (e->>1)) = any(hitset)) into allhit from jsonb_array_elements(s) e;
      if allhit then res := 'sunk'; sunk := s; end if;
    end if;
  end loop;
  insert into bs_shots(duel_id, shooter, x, y, result, sunk) values (p_duel, auth.uid(), p_x, p_y, res, sunk);
  update duel_players set attempts = attempts + 1 where duel_id = p_duel and user_id = auth.uid();
  select count(*) into hits from bs_shots where duel_id = p_duel and shooter = auth.uid() and result <> 'miss';
  if hits >= 17 then
    update duel_players set status = 'solved', finished_at = now() where duel_id = p_duel and user_id = auth.uid();
    update duel_players set status = 'failed', finished_at = now() where duel_id = p_duel and user_id = opp;
    update duels set status = 'finished', winner_id = auth.uid(), finished_at = now() where id = p_duel;
  elsif res = 'miss' then
    update duels set state = jsonb_set(state, '{turn}', to_jsonb(opp::text)) where id = p_duel;
  end if;
  return jsonb_build_object('result', res, 'sunk', sunk, 'won', hits >= 17);
end $$;

-- Aufgeben / Ablehnen / Beenden: auch Zugwechsel bei Wer bin ich
create or replace function public.give_up(p_duel uuid) returns void
language plpgsql security definer set search_path = public as $$
declare dl duels;
begin
  select * into dl from duels where id = p_duel;
  update duel_players set status = 'gave_up', finished_at = now() where duel_id = p_duel and user_id = auth.uid() and status = 'playing';
  if dl.game = 'werbinich' and dl.state->>'phase' = 'play' then
    if dl.state->>'turn' = auth.uid()::text then
      update wbi_questions set result = 'no', resolved_at = now() where id = (dl.state->>'qid')::bigint and result is null;
      perform _wbi_set_turn(p_duel, _wbi_next(p_duel, auth.uid()));
    else
      perform _wbi_try_resolve(p_duel);
    end if;
  end if;
  perform _check_finish(p_duel);
end $$;

-- ---------- Punkte & Rangliste ----------
drop function if exists public.leaderboard();
create or replace function public.leaderboard() returns table(user_id uuid, display_name text, username text, points bigint, wins bigint, played bigint,
  wins_wordless bigint, wins_clueless bigint, wins_werbinich bigint, wins_schiffe bigint)
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
    count(distinct r.id) filter (where r.winner_id = p.id and r.game = 'schiffe')
  from profiles p
  left join duel_players dp on dp.user_id = p.id and dp.status in ('solved','failed','gave_up')
  left join r on r.id = dp.duel_id
  where is_player()
  group by p.id order by 4 desc, 5 desc, 2 asc
$$;

-- ---------- Rechte & Live ----------
revoke all on public.wbi_pool from anon, authenticated;
revoke all on function public._wbi_next(uuid,uuid), public._wbi_set_turn(uuid,uuid), public._wbi_try_resolve(uuid), public._check_finish(uuid) from public, anon, authenticated;
grant execute on function public.friend_request(uuid), public.friend_request_by_name(text), public.friend_respond(uuid,boolean), public.friend_remove(uuid),
  public.are_friends(uuid,uuid), public.wbi_start(uuid), public.wbi_ask(uuid,text), public.wbi_vote(uuid,boolean), public.wbi_guess(uuid,text),
  public.bs_place(uuid,jsonb), public.bs_shoot(uuid,int,int), public.leaderboard(), public.create_duel(text,int,uuid[]), public.give_up(uuid),
  public.admin_create_user(text,text,text,boolean), public.send_message(uuid,text) to authenticated;
revoke execute on function public.friend_request(uuid), public.friend_request_by_name(text), public.friend_respond(uuid,boolean), public.friend_remove(uuid),
  public.are_friends(uuid,uuid), public.wbi_start(uuid), public.wbi_ask(uuid,text), public.wbi_vote(uuid,boolean), public.wbi_guess(uuid,text),
  public.bs_place(uuid,jsonb), public.bs_shoot(uuid,int,int), public.leaderboard() from anon, public;

do $$ begin
  begin alter publication supabase_realtime add table public.friendships; exception when others then null; end;
  begin alter publication supabase_realtime add table public.wbi_questions; exception when others then null; end;
  begin alter publication supabase_realtime add table public.wbi_votes; exception when others then null; end;
  begin alter publication supabase_realtime add table public.bs_shots; exception when others then null; end;
end $$;

-- ---------- Namen für Wer bin ich? ----------
insert into public.wbi_pool(name, category) values
('Albert Einstein','Promis'),
('Angela Merkel','Promis'),
('Arnold Schwarzenegger','Promis'),
('Barack Obama','Promis'),
('Donald Trump','Promis'),
('Elon Musk','Promis'),
('Taylor Swift','Promis'),
('Helene Fischer','Promis'),
('Dieter Bohlen','Promis'),
('Heidi Klum','Promis'),
('Michael Jackson','Promis'),
('Elvis Presley','Promis'),
('Madonna','Promis'),
('Beyoncé','Promis'),
('Rihanna','Promis'),
('Ed Sheeran','Promis'),
('Adele','Promis'),
('Lady Gaga','Promis'),
('Justin Bieber','Promis'),
('Leonardo DiCaprio','Promis'),
('Brad Pitt','Promis'),
('Tom Cruise','Promis'),
('Johnny Depp','Promis'),
('Will Smith','Promis'),
('Dwayne Johnson','Promis'),
('Kim Kardashian','Promis'),
('Mark Zuckerberg','Promis'),
('Bill Gates','Promis'),
('Steve Jobs','Promis'),
('Jeff Bezos','Promis'),
('Papst Franziskus','Promis'),
('Queen Elizabeth','Promis'),
('König Charles','Promis'),
('Prinz Harry','Promis'),
('Falco','Promis'),
('Udo Jürgens','Promis'),
('DJ Ötzi','Promis'),
('Andreas Gabalier','Promis'),
('Christoph Waltz','Promis'),
('Conchita Wurst','Promis'),
('Mozart','Promis'),
('Beethoven','Promis'),
('Sigmund Freud','Promis'),
('Marie Curie','Promis'),
('Isaac Newton','Promis'),
('Leonardo da Vinci','Promis'),
('Napoleon','Promis'),
('Kleopatra','Promis'),
('Julius Caesar','Promis'),
('Christoph Kolumbus','Promis'),
('Martin Luther','Promis'),
('Kaiserin Sisi','Promis'),
('Shakespeare','Promis'),
('Goethe','Promis'),
('Picasso','Promis'),
('Van Gogh','Promis'),
('Charlie Chaplin','Promis'),
('Marilyn Monroe','Promis'),
('Stefan Raab','Promis'),
('Joko Winterscheidt','Promis'),
('Mr. Beast','Promis'),
('Snoop Dogg','Promis'),
('Eminem','Promis'),
('Drake','Promis'),
('Billie Eilish','Promis'),
('Shakira','Promis'),
('Bruce Lee','Promis'),
('Jackie Chan','Promis'),
('Ozzy Osbourne','Promis'),
('Cristiano Ronaldo','Sport'),
('Lionel Messi','Sport'),
('David Alaba','Sport'),
('Marko Arnautović','Sport'),
('Marcel Hirscher','Sport'),
('Hermann Maier','Sport'),
('Niki Lauda','Sport'),
('Dominic Thiem','Sport'),
('Roger Federer','Sport'),
('Serena Williams','Sport'),
('Usain Bolt','Sport'),
('Michael Jordan','Sport'),
('LeBron James','Sport'),
('Michael Schumacher','Sport'),
('Lewis Hamilton','Sport'),
('Max Verstappen','Sport'),
('Muhammad Ali','Sport'),
('Mike Tyson','Sport'),
('Tiger Woods','Sport'),
('Neymar','Sport'),
('Kylian Mbappé','Sport'),
('Erling Haaland','Sport'),
('Manuel Neuer','Sport'),
('Thomas Müller','Sport'),
('David Beckham','Sport'),
('Zlatan Ibrahimović','Sport'),
('Rafael Nadal','Sport'),
('Novak Djokovic','Sport'),
('Michael Phelps','Sport'),
('Anna Gasser','Sport'),
('Harry Potter','Figuren'),
('Hermine Granger','Figuren'),
('Darth Vader','Figuren'),
('Luke Skywalker','Figuren'),
('Yoda','Figuren'),
('Spider-Man','Figuren'),
('Batman','Figuren'),
('Superman','Figuren'),
('Wonder Woman','Figuren'),
('Iron Man','Figuren'),
('Hulk','Figuren'),
('Thor','Figuren'),
('Captain America','Figuren'),
('Joker','Figuren'),
('James Bond','Figuren'),
('Sherlock Holmes','Figuren'),
('Mickey Mouse','Figuren'),
('Donald Duck','Figuren'),
('Dagobert Duck','Figuren'),
('Goofy','Figuren'),
('Bugs Bunny','Figuren'),
('Homer Simpson','Figuren'),
('Bart Simpson','Figuren'),
('SpongeBob','Figuren'),
('Patrick Star','Figuren'),
('Shrek','Figuren'),
('Pikachu','Figuren'),
('Super Mario','Figuren'),
('Luigi','Figuren'),
('Sonic','Figuren'),
('Lara Croft','Figuren'),
('Pinocchio','Figuren'),
('Rotkäppchen','Figuren'),
('Schneewittchen','Figuren'),
('Aschenputtel','Figuren'),
('Rapunzel','Figuren'),
('Elsa','Figuren'),
('Olaf','Figuren'),
('Simba','Figuren'),
('Nemo','Figuren'),
('Dory','Figuren'),
('Winnie Puuh','Figuren'),
('Biene Maja','Figuren'),
('Pippi Langstrumpf','Figuren'),
('Heidi','Figuren'),
('Asterix','Figuren'),
('Obelix','Figuren'),
('Garfield','Figuren'),
('Snoopy','Figuren'),
('Scooby-Doo','Figuren'),
('Pumuckl','Figuren'),
('Der Grinch','Figuren'),
('Weihnachtsmann','Figuren'),
('Osterhase','Figuren'),
('Dracula','Figuren'),
('Frankenstein','Figuren'),
('Gandalf','Figuren'),
('Frodo','Figuren'),
('Gollum','Figuren'),
('Jack Sparrow','Figuren'),
('Indiana Jones','Figuren'),
('Rocky Balboa','Figuren'),
('Forrest Gump','Figuren'),
('Barbie','Figuren'),
('Ken','Figuren'),
('Kermit','Figuren'),
('Krümelmonster','Figuren'),
('Peppa Wutz','Figuren'),
('Paw Patrol Chase','Figuren'),
('Minion','Figuren'),
('Groot','Figuren'),
('Deadpool','Figuren'),
('Wolverine','Figuren')
on conflict do nothing;
