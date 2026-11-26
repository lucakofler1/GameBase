-- Wort-Duell · Datenbank-Setup (Supabase) · von Luca Kofler
create extension if not exists vector with schema extensions;
create extension if not exists pgcrypto with schema extensions;

-- ---------- Tabellen ----------
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text unique not null,
  display_name text not null,
  is_admin boolean not null default false,
  created_at timestamptz not null default now()
);

create table if not exists public.words_cl (
  id serial primary key,
  word text not null,
  lw text unique not null,
  vec extensions.vector(96) not null
);
create table if not exists public.cl_secrets (word text primary key);
create table if not exists public.wl_answers (word text primary key, len int not null);

create table if not exists public.duels (
  id uuid primary key default gen_random_uuid(),
  game text not null check (game in ('wordless','clueless')),
  word_length int,
  max_attempts int,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  status text not null default 'open' check (status in ('open','finished','cancelled')),
  winner_id uuid references public.profiles(id) on delete set null,
  finished_at timestamptz
);
create table if not exists public.duel_secrets (
  duel_id uuid primary key references public.duels(id) on delete cascade,
  secret text not null
);
create table if not exists public.duel_players (
  duel_id uuid references public.duels(id) on delete cascade,
  user_id uuid references public.profiles(id) on delete cascade,
  status text not null default 'invited' check (status in ('invited','playing','solved','failed','gave_up','declined')),
  attempts int not null default 0,
  best_rank int,
  joined_at timestamptz,
  finished_at timestamptz,
  primary key (duel_id, user_id)
);
create table if not exists public.guesses (
  id bigserial primary key,
  duel_id uuid references public.duels(id) on delete cascade,
  user_id uuid references public.profiles(id) on delete cascade,
  n int not null,
  guess text not null,
  result jsonb,
  created_at timestamptz not null default now()
);
create index if not exists guesses_duel_user on public.guesses(duel_id, user_id);
create index if not exists dp_user on public.duel_players(user_id);

-- ---------- Hilfsfunktionen ----------
create or replace function public.is_player() returns boolean language sql stable security definer set search_path = public as
$$ select exists(select 1 from profiles where id = auth.uid()) $$;
create or replace function public.is_admin() returns boolean language sql stable security definer set search_path = public as
$$ select exists(select 1 from profiles where id = auth.uid() and is_admin) $$;
create or replace function public.is_participant(d uuid) returns boolean language sql stable security definer set search_path = public as
$$ select exists(select 1 from duel_players where duel_id = d and user_id = auth.uid()) $$;

-- ---------- RLS ----------
alter table public.profiles enable row level security;
alter table public.words_cl enable row level security;
alter table public.cl_secrets enable row level security;
alter table public.wl_answers enable row level security;
alter table public.duels enable row level security;
alter table public.duel_secrets enable row level security;
alter table public.duel_players enable row level security;
alter table public.guesses enable row level security;

drop policy if exists p_profiles_read on public.profiles;
create policy p_profiles_read on public.profiles for select to authenticated using (public.is_player());
drop policy if exists p_duels_read on public.duels;
create policy p_duels_read on public.duels for select to authenticated using (public.is_participant(id));
drop policy if exists p_dp_read on public.duel_players;
create policy p_dp_read on public.duel_players for select to authenticated using (public.is_participant(duel_id));
drop policy if exists p_guesses_read on public.guesses;
create policy p_guesses_read on public.guesses for select to authenticated using (user_id = auth.uid());
-- words_cl, cl_secrets, wl_answers, duel_secrets: keine Policies = nicht direkt lesbar (geheim)

-- ---------- Interne Logik ----------
create or replace function public._wl_score(secret text, guess text) returns text language plpgsql immutable as $$
declare s text[] := regexp_split_to_array(secret,''); g text[] := regexp_split_to_array(guess,'');
  r text[]; i int; j int; used boolean[];
begin
  r := array_fill('x'::text, array[array_length(g,1)]);
  used := array_fill(false, array[array_length(s,1)]);
  for i in 1..array_length(g,1) loop
    if g[i] = s[i] then r[i] := 'g'; used[i] := true; end if;
  end loop;
  for i in 1..array_length(g,1) loop
    if r[i] <> 'g' then
      for j in 1..array_length(s,1) loop
        if not used[j] and s[j] = g[i] then r[i] := 'y'; used[j] := true; exit; end if;
      end loop;
    end if;
  end loop;
  return array_to_string(r,'');
end $$;

create or replace function public._check_finish(d uuid) returns void language plpgsql security definer set search_path = public as $$
declare w uuid;
begin
  if exists(select 1 from duel_players where duel_id = d and status in ('invited','playing')) then return; end if;
  select user_id into w from duel_players where duel_id = d and status = 'solved'
    order by attempts asc, finished_at asc limit 1;
  update duels set status = 'finished', winner_id = w, finished_at = now() where id = d and status = 'open';
end $$;

-- ---------- Spiel-Funktionen ----------
create or replace function public.create_duel(p_game text, p_len int, p_invitees uuid[]) returns uuid
language plpgsql security definer set search_path = public as $$
declare d uuid; s text; u uuid;
begin
  if not is_player() then raise exception 'Kein Zugriff'; end if;
  if p_game = 'wordless' then
    if p_len not between 3 and 8 then raise exception 'Wortlänge 3–8'; end if;
    select word into s from wl_answers where len = p_len order by random() limit 1;
  elsif p_game = 'clueless' then
    select word into s from cl_secrets order by random() limit 1;
  else raise exception 'Unbekanntes Spiel'; end if;
  if s is null then raise exception 'Wortdaten fehlen – Admin muss sie zuerst laden'; end if;
  insert into duels(game, word_length, max_attempts, created_by)
    values (p_game, case when p_game='wordless' then p_len end, case when p_game='wordless' then 6 end, auth.uid())
    returning id into d;
  insert into duel_secrets values (d, s);
  insert into duel_players(duel_id, user_id, status, joined_at) values (d, auth.uid(), 'playing', now());
  if p_invitees is not null then
    foreach u in array p_invitees loop
      if u <> auth.uid() and exists(select 1 from profiles where id = u) then
        insert into duel_players(duel_id, user_id) values (d, u) on conflict do nothing;
      end if;
    end loop;
  end if;
  return d;
end $$;

create or replace function public.respond_invite(p_duel uuid, p_accept boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  update duel_players set status = case when p_accept then 'playing' else 'declined' end,
    joined_at = case when p_accept then now() end,
    finished_at = case when p_accept then null else now() end
  where duel_id = p_duel and user_id = auth.uid() and status = 'invited';
  perform _check_finish(p_duel);
end $$;

create or replace function public.submit_guess(p_duel uuid, p_guess text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare dl duels; sec text; me duel_players; g text := lower(trim(p_guess)); res jsonb; sc text; sv extensions.vector; gv extensions.vector; dist float8; rnk int; disp text; newst text;
begin
  select * into dl from duels where id = p_duel;
  if dl.id is null or dl.status <> 'open' then raise exception 'Duell ist nicht mehr offen'; end if;
  select * into me from duel_players where duel_id = p_duel and user_id = auth.uid();
  if me.status is distinct from 'playing' then raise exception 'Du spielst in diesem Duell gerade nicht'; end if;
  select secret into sec from duel_secrets where duel_id = p_duel;
  newst := 'playing';
  if dl.game = 'wordless' then
    if char_length(g) <> dl.word_length or g !~ '^[a-zäöü]+$' then raise exception 'Ungültiges Wort'; end if;
    sc := _wl_score(sec, g);
    res := jsonb_build_object('colors', sc);
    if g = sec then newst := 'solved'; elsif me.attempts + 1 >= dl.max_attempts then newst := 'failed'; end if;
  else
    select vec, word into gv, disp from words_cl where lw = g;
    if gv is null then raise exception 'Dieses Wort kenne ich nicht'; end if;
    if exists(select 1 from guesses where duel_id = p_duel and user_id = auth.uid() and guess = g) then raise exception 'Schon geraten'; end if;
    select vec into sv from words_cl where lw = sec;
    dist := sv <=> gv;
    if g = sec then rnk := 1; else select count(*) + 1 into rnk from words_cl where (vec <=> sv) < dist and lw <> g; end if;
    res := jsonb_build_object('rank', rnk, 'word', disp);
    if g = sec then newst := 'solved'; end if;
  end if;
  insert into guesses(duel_id, user_id, n, guess, result) values (p_duel, auth.uid(), me.attempts + 1, g, res);
  update duel_players set attempts = attempts + 1, status = newst,
    best_rank = case when res ? 'rank' then least(coalesce(best_rank, 999999), (res->>'rank')::int) else best_rank end,
    finished_at = case when newst <> 'playing' then now() else null end
  where duel_id = p_duel and user_id = auth.uid();
  perform _check_finish(p_duel);
  return res || jsonb_build_object('status', newst, 'attempts', me.attempts + 1);
end $$;

create or replace function public.give_up(p_duel uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  update duel_players set status = 'gave_up', finished_at = now() where duel_id = p_duel and user_id = auth.uid() and status = 'playing';
  perform _check_finish(p_duel);
end $$;

create or replace function public.end_duel(p_duel uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not exists(select 1 from duels where id = p_duel and (created_by = auth.uid() or is_admin())) then raise exception 'Nur wer das Duell erstellt hat, kann es beenden'; end if;
  update duel_players set status = 'declined', finished_at = now() where duel_id = p_duel and status = 'invited';
  update duel_players set status = 'gave_up', finished_at = now() where duel_id = p_duel and status = 'playing';
  perform _check_finish(p_duel);
end $$;

create or replace function public.duel_secret(p_duel uuid) returns text
language sql stable security definer set search_path = public as $$
  select s.secret from duel_secrets s join duels d on d.id = s.duel_id
  where s.duel_id = p_duel and d.status = 'finished' and is_participant(p_duel)
$$;

create or replace function public.leaderboard() returns table(user_id uuid, display_name text, username text, wins bigint, played bigint, wins_wordless bigint, wins_clueless bigint)
language sql stable security definer set search_path = public as $$
  with real_duels as (
    select d.* from duels d where d.status = 'finished'
      and (select count(*) from duel_players x where x.duel_id = d.id and x.status in ('solved','failed','gave_up')) >= 2
  )
  select p.id, p.display_name, p.username,
    count(distinct d.id) filter (where d.winner_id = p.id),
    count(distinct d.id) filter (where dp.status in ('solved','failed','gave_up')),
    count(distinct d.id) filter (where d.winner_id = p.id and d.game = 'wordless'),
    count(distinct d.id) filter (where d.winner_id = p.id and d.game = 'clueless')
  from profiles p
  left join duel_players dp on dp.user_id = p.id
  left join real_duels d on d.id = dp.duel_id
  where is_player()
  group by p.id order by 4 desc, 5 asc, 2 asc
$$;

-- ---------- Admin ----------
create or replace function public._create_account(p_username text, p_display text, p_password text, p_admin boolean) returns uuid
language plpgsql security definer set search_path = public, extensions, auth as $$
declare uid uuid := gen_random_uuid(); em text := lower(trim(p_username)) || '@wortduell.local';
begin
  if lower(trim(p_username)) !~ '^[a-z0-9._-]{3,30}$' then raise exception 'Benutzername: 3–30 Zeichen, nur a–z, 0–9, . _ -'; end if;
  if char_length(p_password) < 6 then raise exception 'Passwort mindestens 6 Zeichen'; end if;
  if exists(select 1 from profiles where username = lower(trim(p_username))) then raise exception 'Benutzername schon vergeben'; end if;
  insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at, confirmation_token, email_change, email_change_token_new, recovery_token)
  values ('00000000-0000-0000-0000-000000000000', uid, 'authenticated', 'authenticated', em, crypt(p_password, gen_salt('bf')), now(),
    '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', '', '', '');
  insert into auth.identities (id, user_id, provider_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
  values (gen_random_uuid(), uid, uid::text, jsonb_build_object('sub', uid::text, 'email', em, 'email_verified', true), 'email', now(), now(), now());
  insert into profiles(id, username, display_name, is_admin) values (uid, lower(trim(p_username)), trim(p_display), p_admin);
  return uid;
end $$;
revoke all on function public._create_account(text,text,text,boolean) from public, anon, authenticated;

create or replace function public.admin_create_user(p_username text, p_display text, p_password text, p_admin boolean default false) returns uuid
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Nur für Admins'; end if;
  return _create_account(p_username, p_display, p_password, p_admin);
end $$;

create or replace function public.admin_set_password(p_user uuid, p_password text) returns void
language plpgsql security definer set search_path = public, extensions, auth as $$
begin
  if not is_admin() then raise exception 'Nur für Admins'; end if;
  if char_length(p_password) < 6 then raise exception 'Passwort mindestens 6 Zeichen'; end if;
  update auth.users set encrypted_password = crypt(p_password, gen_salt('bf')), updated_at = now() where id = p_user;
end $$;

create or replace function public.admin_update_user(p_user uuid, p_display text, p_admin boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Nur für Admins'; end if;
  if p_user = auth.uid() and not p_admin then raise exception 'Du kannst dir selbst die Admin-Rechte nicht nehmen'; end if;
  update profiles set display_name = trim(p_display), is_admin = p_admin where id = p_user;
end $$;

create or replace function public.admin_delete_user(p_user uuid) returns void
language plpgsql security definer set search_path = public, auth as $$
begin
  if not is_admin() then raise exception 'Nur für Admins'; end if;
  if p_user = auth.uid() then raise exception 'Du kannst dich nicht selbst löschen'; end if;
  delete from auth.users where id = p_user;
end $$;

create or replace function public.admin_load_words(p_rows jsonb) returns int
language sql security definer set search_path = public, extensions as $$
  with ins as (
    insert into words_cl(word, lw, vec)
      select x->>0, lower(x->>0), (x->>1)::extensions.vector from jsonb_array_elements(p_rows) x
      where is_admin()
      on conflict (lw) do nothing returning 1)
  select count(*)::int from ins
$$;

create or replace function public.admin_load_lists(p_secrets jsonb, p_answers jsonb) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Nur für Admins'; end if;
  insert into cl_secrets(word) select lower(x) from jsonb_array_elements_text(p_secrets) x on conflict do nothing;
  insert into wl_answers(word, len) select x, char_length(x) from jsonb_array_elements_text(p_answers) x on conflict do nothing;
end $$;

create or replace function public.data_status() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('words', (select count(*) from words_cl), 'secrets', (select count(*) from cl_secrets), 'answers', (select count(*) from wl_answers))
$$;

-- ---------- Rechte ----------
grant usage on schema public to anon, authenticated;
grant select on public.profiles, public.duels, public.duel_players, public.guesses to authenticated;
revoke all on public.words_cl, public.cl_secrets, public.wl_answers, public.duel_secrets from anon, authenticated;
revoke all on function public._wl_score(text,text) from public, anon, authenticated;
revoke all on function public._check_finish(uuid) from public, anon, authenticated;
grant execute on function public.create_duel(text,int,uuid[]), public.respond_invite(uuid,boolean), public.submit_guess(uuid,text),
  public.give_up(uuid), public.end_duel(uuid), public.duel_secret(uuid), public.leaderboard(), public.admin_create_user(text,text,text,boolean),
  public.admin_set_password(uuid,text), public.admin_update_user(uuid,text,boolean), public.admin_delete_user(uuid),
  public.admin_load_words(jsonb), public.admin_load_lists(jsonb,jsonb), public.data_status(), public.is_player(), public.is_admin(), public.is_participant(uuid)
  to authenticated;
revoke execute on function public.create_duel(text,int,uuid[]), public.respond_invite(uuid,boolean), public.submit_guess(uuid,text),
  public.give_up(uuid), public.end_duel(uuid), public.duel_secret(uuid), public.leaderboard(), public.admin_create_user(text,text,text,boolean),
  public.admin_set_password(uuid,text), public.admin_update_user(uuid,text,boolean), public.admin_delete_user(uuid),
  public.admin_load_words(jsonb), public.admin_load_lists(jsonb,jsonb), public.data_status() from anon, public;

-- ---------- Live-Updates ----------
do $$ begin
  begin alter publication supabase_realtime add table public.duel_players; exception when others then null; end;
  begin alter publication supabase_realtime add table public.duels; exception when others then null; end;
end $$;
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
-- Wort-Duell · Update 5: Selbst registrieren
create table if not exists public.signup_log (id bigserial primary key, created_at timestamptz not null default now());
alter table public.signup_log enable row level security;

create or replace function public.register_account(p_username text, p_display text, p_password text) returns uuid
language plpgsql security definer set search_path = public as $$
begin
  if char_length(trim(coalesce(p_display,''))) < 2 or char_length(trim(p_display)) > 40 then raise exception 'Anzeigename: 2–40 Zeichen'; end if;
  -- Schutz vor Massen-Anmeldungen
  if (select count(*) from signup_log where created_at > now() - interval '1 hour') >= 30 then
    raise exception 'Gerade zu viele Anmeldungen – bitte später nochmal versuchen';
  end if;
  insert into signup_log default values;
  return _create_account(p_username, p_display, p_password, false);
end $$;

revoke all on public.signup_log from anon, authenticated;
grant execute on function public.register_account(text,text,text) to anon, authenticated;
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
