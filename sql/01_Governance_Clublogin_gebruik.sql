-- =====================================================================
-- Clublogin – gebruik van de app opvolgen (10/11/2026)
-- Doel: enkel opvolgen hoe de app gebruikt wordt (geen beveiligingslogboek).
-- Gegevensminimalisatie: per dag, per lid, per pagina (en tabblad) één teller; geen IP-adres,
-- geen locatie, geen uur. Apparaat enkel als "gsm" of "computer". Bewaartermijn 12 maanden.
-- Niets wordt geregistreerd in de voorbeeldmodus ("Bekijk als rol").
-- Lezen enkel voor beheerders via club_beheer_gebruik. Schrijven enkel via club_bezoek
-- en club_login (B5).
-- =====================================================================

create table if not exists club.gebruik (
  dag        date        not null,
  speler_id  integer     not null,
  pagina     text        not null,          -- map van de pagina, bv. 'lessen', 'start'; 'aanmelding' = gelukte aanmelding
  onderdeel  text        not null default '',  -- tabblad binnen de pagina, bv. 'Overzicht coaches'
  apparaat   text        not null default '',  -- 'gsm', 'computer' of ''
  aantal     integer     not null default 1,
  eerste     timestamptz not null default now(),
  laatste    timestamptz not null default now(),
  primary key (dag, speler_id, pagina, onderdeel, apparaat),
  constraint gebruik_pagina_ok check (pagina ~ '^[a-z0-9-]{1,40}$'),
  constraint gebruik_onderdeel_ok check (char_length(onderdeel) <= 40),
  constraint gebruik_apparaat_ok check (apparaat in ('', 'gsm', 'computer'))
);
create index if not exists gebruik_speler on club.gebruik (speler_id, dag);
alter table club.gebruik enable row level security;
revoke all on club.gebruik from anon, authenticated;

-- ---------------------------------------------------------------------
-- Registreren: één oproep per paginabezoek of per eerste klik op een tabblad
-- ---------------------------------------------------------------------
create or replace function public.club_bezoek(p_token text, p_pagina text, p_onderdeel text default null, p_apparaat text default null)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_speler int; v_rol text;
  v_pagina text := lower(btrim(coalesce(p_pagina, '')));
  v_onderdeel text := left(regexp_replace(btrim(coalesce(p_onderdeel, '')), '\s+', ' ', 'g'), 40);
  v_apparaat text := case when p_apparaat in ('gsm', 'computer') then p_apparaat else '' end;
begin
  -- sessie zelf opzoeken: club.sessie() zet de transactie alleen-lezen in de voorbeeldmodus
  select s.speler_id, s.voorbeeld_rol into v_speler, v_rol
    from club.sessies s
   where s.token_hash = encode(extensions.digest(coalesce(p_token, ''), 'sha256'), 'hex')
     and s.verloopt > now();
  if v_speler is null then return jsonb_build_object('fout', 'niet aangemeld'); end if;
  if v_rol is not null then return jsonb_build_object('ok', false, 'reden', 'voorbeeldmodus'); end if;
  if v_pagina !~ '^[a-z0-9-]{1,40}$' or v_pagina = 'aanmelding' then return jsonb_build_object('fout', 'onbekende pagina'); end if;

  insert into club.gebruik (dag, speler_id, pagina, onderdeel, apparaat)
  values ((now() at time zone 'Europe/Brussels')::date, v_speler, v_pagina, v_onderdeel, v_apparaat)
  on conflict (dag, speler_id, pagina, onderdeel, apparaat)
  do update set aantal = club.gebruik.aantal + 1, laatste = now();

  -- bewaartermijn 12 maanden (af en toe opruimen volstaat)
  if random() < 0.02 then
    delete from club.gebruik where dag < (now() at time zone 'Europe/Brussels')::date - interval '12 months';
  end if;
  return jsonb_build_object('ok', true);
end $function$;
revoke all on function public.club_bezoek(text, text, text, text) from public;
grant execute on function public.club_bezoek(text, text, text, text) to anon, authenticated;

-- ---------------------------------------------------------------------
-- Aanmelden: ongewijzigd, behalve één regel die een gelukte aanmelding telt
-- ---------------------------------------------------------------------
create or replace function public.club_login(p_speler integer, p_code text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare t club.toegang; v_token text;
begin
  select * into t from club.toegang where speler_id = p_speler;
  if t.speler_id is null or not exists (select 1 from club.v_lid where speler_id = p_speler) then
    return jsonb_build_object('fout','naam of code klopt niet');
  end if;
  if t.geblokkeerd_tot is not null and t.geblokkeerd_tot > now() then
    return jsonb_build_object('fout','te veel pogingen; probeer opnieuw na '
      || to_char(t.geblokkeerd_tot at time zone 'Europe/Brussels','HH24:MI'));
  end if;
  if t.code_hash <> extensions.crypt(upper(btrim(coalesce(p_code,''))), t.code_hash) then
    update club.toegang set mislukte_pogingen = mislukte_pogingen + 1,
      geblokkeerd_tot = case when mislukte_pogingen + 1 >= 5 then now() + interval '15 minutes' end
     where speler_id = p_speler;
    return jsonb_build_object('fout','naam of code klopt niet');
  end if;
  update club.toegang set mislukte_pogingen = 0, geblokkeerd_tot = null where speler_id = p_speler;
  v_token := encode(extensions.gen_random_bytes(32),'hex');
  delete from club.sessies where verloopt < now();
  insert into club.sessies (token_hash, speler_id, verloopt)
  values (encode(extensions.digest(v_token,'sha256'),'hex'), p_speler, now() + interval '60 days');
  -- gebruik: gelukte aanmelding tellen (10/11/2026)
  insert into club.gebruik (dag, speler_id, pagina)
  values ((now() at time zone 'Europe/Brussels')::date, p_speler, 'aanmelding')
  on conflict (dag, speler_id, pagina, onderdeel, apparaat)
  do update set aantal = club.gebruik.aantal + 1, laatste = now();
  return jsonb_build_object('token', v_token);
end $function$;

-- ---------------------------------------------------------------------
-- Rapport voor beheerders
-- ---------------------------------------------------------------------
create or replace function public.club_beheer_gebruik(p_token text, p_van date default null, p_tot date default null)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $function$
declare
  me int := club.sessie(p_token);
  vandaag date := (now() at time zone 'Europe/Brussels')::date;
  v_tot date := least(coalesce(p_tot, vandaag), vandaag);
  v_van date := coalesce(p_van, v_tot - 29);
  v_dagen int; v_vvan date; v_vtot date;
  r jsonb;
begin
  if me is null or not club.heeft(me, array['beheerder']) then return jsonb_build_object('fout', 'enkel voor beheerders'); end if;
  if v_van > v_tot then v_van := v_tot; end if;
  v_dagen := v_tot - v_van + 1; v_vtot := v_van - 1; v_vvan := v_van - v_dagen;

  with
  g as (select * from club.gebruik where dag between v_van and v_tot),
  b as (select * from g where pagina <> 'aanmelding'),
  vb as (select * from club.gebruik where dag between v_vvan and v_vtot and pagina <> 'aanmelding'),
  codes as (select t.speler_id from club.toegang t join club.v_lid l using (speler_id)),
  rolset as (
    select speler_id, rol from club.rollen where speler_id in (select speler_id from codes)
    union select distinct speler_id, 'kapitein' from club.v_kapiteins where speler_id in (select speler_id from codes)
  )
  select jsonb_build_object(
    'van', v_van, 'tot', v_tot, 'dagen', v_dagen, 'vorige_van', v_vvan, 'vorige_tot', v_vtot,
    'eerste_meting', (select min(dag) from club.gebruik),
    'kpi', jsonb_build_object(
      'actief', (select count(distinct speler_id) from b),
      'actief_vorig', (select count(distinct speler_id) from vb),
      'bezoeken', (select coalesce(sum(aantal), 0) from b),
      'bezoeken_vorig', (select coalesce(sum(aantal), 0) from vb),
      'aanmeldingen', (select coalesce(sum(aantal), 0) from g where pagina = 'aanmelding'),
      'met_code', (select count(*) from codes),
      'actief_7', (select count(distinct speler_id) from club.gebruik where dag > vandaag - 7 and pagina <> 'aanmelding'),
      'actief_30', (select count(distinct speler_id) from club.gebruik where dag > vandaag - 30 and pagina <> 'aanmelding'),
      'nooit', (select count(*) from codes c where not exists (select 1 from club.gebruik u where u.speler_id = c.speler_id)),
      'actieve_dagen_gem', (select round(avg(n), 1) from (select count(distinct dag) n from b group by speler_id) x)),
    'per_dag', (select coalesce(jsonb_agg(jsonb_build_object('dag', d::date, 'leden', coalesce(x.leden, 0), 'bezoeken', coalesce(x.bezoeken, 0)) order by d), '[]')
                  from generate_series(v_van, v_tot, interval '1 day') d
                  left join (select dag, count(distinct speler_id) leden, sum(aantal) bezoeken from b group by dag) x on x.dag = d::date),
    'paginas', (select coalesce(jsonb_agg(p order by (p->>'bezoeken')::int desc), '[]') from (
                  select jsonb_build_object('pagina', pagina, 'bezoeken', sum(aantal), 'leden', count(distinct speler_id),
                    'vorig', (select coalesce(sum(aantal), 0) from vb where vb.pagina = b.pagina),
                    'onderdelen', (select coalesce(jsonb_agg(jsonb_build_object('onderdeel', onderdeel, 'bezoeken', n, 'leden', l) order by n desc), '[]')
                                     from (select onderdeel, sum(aantal) n, count(distinct speler_id) l from b b2
                                            where b2.pagina = b.pagina and b2.onderdeel <> '' group by onderdeel) o)) p
                  from b group by pagina) q),
    'weekdag', (select coalesce(jsonb_agg(jsonb_build_object('dag', w, 'bezoeken', coalesce(x.n, 0), 'leden', coalesce(x.l, 0)) order by w), '[]')
                  from generate_series(1, 7) w
                  left join (select extract(isodow from dag)::int wd, sum(aantal) n, count(distinct speler_id) l from b group by 1) x on x.wd = w),
    'apparaat', (select coalesce(jsonb_agg(jsonb_build_object('apparaat', coalesce(nullif(apparaat, ''), 'onbekend'), 'bezoeken', n, 'leden', l) order by n desc), '[]')
                   from (select apparaat, sum(aantal) n, count(distinct speler_id) l from b group by apparaat) x),
    'rollen', (select coalesce(jsonb_agg(jsonb_build_object('rol', rol, 'met_code', n, 'actief', a) order by volg), '[]') from (
                 select 'lid' rol, 0 volg, (select count(*) from codes) n, (select count(distinct speler_id) from b) a
                 union all
                 select rs.rol, case rs.rol when 'kapitein' then 1 when 'trainer' then 2 when 'hoofdcoach' then 3 when 'commissie' then 4
                                            when 'bestuur' then 5 when 'wedstrijdleider' then 6 else 7 end,
                        count(*), count(*) filter (where exists (select 1 from b where b.speler_id = rs.speler_id))
                   from rolset rs group by rs.rol) x),
    'leden', (select coalesce(jsonb_agg(jsonb_build_object('naam', club.naam(speler_id), 'laatst', laatst, 'dagen', dagen, 'bezoeken', bezoeken,
                 'pagina', (select pagina from b b3 where b3.speler_id = x.speler_id group by pagina order by sum(aantal) desc, pagina limit 1))
                 order by laatst desc), '[]')
               from (select speler_id, max(laatste) laatst, count(distinct dag) dagen, sum(aantal) bezoeken from b group by speler_id) x),
    'niet_actief', (select coalesce(jsonb_agg(jsonb_build_object('naam', club.naam(c.speler_id),
                       'laatst', (select max(laatste) from club.gebruik u where u.speler_id = c.speler_id and u.pagina <> 'aanmelding'))
                       order by club.naam(c.speler_id)), '[]')
                     from codes c where not exists (select 1 from b where b.speler_id = c.speler_id))
  ) into r;
  return r;
end $function$;
revoke all on function public.club_beheer_gebruik(text, date, date) from public;
grant execute on function public.club_beheer_gebruik(text, date, date) to anon, authenticated;
