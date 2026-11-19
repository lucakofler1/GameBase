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
