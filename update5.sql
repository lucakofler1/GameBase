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
