-- Communicatie: interclubdata voor Canva (Bulk Create)
-- Opgezet 16/11/2026 op vraag van Chris Meert. Namen van BTC-kapiteins in de communicatie toegestaan
-- (beslissing 9/11/2026, volgens Chris Meert). Enkel kapiteinsnamen van BTC; geen namen van tegenstanders.
-- Rol 'communicatie' (handmatig via beheer/). Toegang tot de export: communicatie, commissie, bestuur.
-- Alleen-lezen, behalve de vertaaltabel met nette clubnamen (club.comm_clubnamen), die deze rollen mogen aanvullen.

-- 1. Nieuwe rol
alter table club.rollen drop constraint if exists rollen_rol_check;
alter table club.rollen add constraint rollen_rol_check
  check (rol = any (array['commissie','bestuur','wedstrijdleider','beheerder','trainer','hoofdcoach','communicatie']));

create or replace function public.club_beheer_rol(p_token text, p_speler integer, p_rol text, p_aan boolean)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare me int := club.sessie(p_token);
begin
  if me is null or not club.heeft(me, array['beheerder']) then return jsonb_build_object('fout','enkel voor beheerders'); end if;
  if p_rol not in ('commissie','bestuur','wedstrijdleider','beheerder','trainer','hoofdcoach','communicatie') then return jsonb_build_object('fout','onbekende rol'); end if;
  if not exists (select 1 from club.v_lid where speler_id = p_speler) then return jsonb_build_object('fout','geen lid'); end if;
  if p_rol = 'beheerder' and not p_aan and p_speler = me then return jsonb_build_object('fout','je kunt je eigen beheerdersrol niet intrekken'); end if;
  if p_aan then
    insert into club.rollen (speler_id, rol, toegekend_door) values (p_speler, p_rol, me) on conflict do nothing;
  else
    delete from club.rollen where speler_id = p_speler and rol = p_rol;
  end if;
  insert into club.logboek (door, actie, speler_id, detail) values (me, case when p_aan then 'rol toegekend' else 'rol ingetrokken' end, p_speler, p_rol);
  return jsonb_build_object('ok', true);
end $function$;

-- Voorbeeldmodus: ook als communicatieverantwoordelijke kunnen kijken
create or replace function club.voorbeeld_rollen(p_rol text)
returns text[] language sql immutable set search_path to '' as $function$
  select case p_rol
    when 'lid'          then array[]::text[]
    when 'kapitein'     then array['kapitein']
    when 'trainer'      then array['trainer']
    when 'hoofdcoach'   then array['hoofdcoach','trainer']
    when 'commissie'    then array['commissie']
    when 'bestuur'      then array['bestuur']
    when 'communicatie' then array['communicatie']
  end
$function$;

-- Sessietabel: voorbeeldrol 'communicatie' toelaten (migratie voorbeeldrol_communicatie, 16/11/2026)
alter table club.sessies drop constraint if exists sessies_voorbeeld_rol_check;
alter table club.sessies add constraint sessies_voorbeeld_rol_check
  check (voorbeeld_rol = any (array['lid','kapitein','trainer','hoofdcoach','commissie','bestuur','communicatie']));

-- 2. club_mij: onderdeel 'communicatie'
create or replace function public.club_mij(p_token text)
returns jsonb language plpgsql stable security definer set search_path to '' as $function$
declare
  me  int  := club.sessie(p_token);
  vb  text := nullif(current_setting('club.voorbeeld', true), '');
  echt_beheerder boolean;
begin
  if me is null then return jsonb_build_object('fout','niet aangemeld'); end if;
  echt_beheerder := exists (select 1 from club.rollen where speler_id = me and rol = 'beheerder');
  return jsonb_build_object(
    'naam', club.naam(me),
    'rollen', case when vb is null
                then coalesce((select jsonb_agg(rol order by rol) from club.rollen where speler_id = me), '[]')
                else to_jsonb(club.voorbeeld_rollen(vb)) end,
    'kapitein_van', case when club.heeft(me, array['kapitein'])
                then coalesce((select jsonb_agg(jsonb_build_object('ploeg_id',ploeg_id,'ploeg',ploeg,'reeks',reeks) order by ploeg)
                                 from club.v_kapiteins where speler_id = me), '[]')
                else '[]'::jsonb end,
    'voorbeeld', vb,
    'kan_voorbeeld', echt_beheerder,
    'onderdelen', jsonb_build_object(
      'tornooien', true, 'klassement', true, 'lessen', true, 'interclub', true,
      'trainer', club.heeft(me, array['trainer']),
      'hoofdcoach', club.heeft(me, array['hoofdcoach']),
      'ploegen', club.heeft(me, array['kapitein']),
      'intern', club.heeft(me, array['commissie','bestuur']),
      'interclub_beheer', club.heeft(me, array['commissie','bestuur']),
      'commissie', club.heeft(me, array['commissie']),
      'communicatie', club.heeft(me, array['communicatie','commissie','bestuur']),
      'beheer', club.heeft(me, array['beheerder'])));
end $function$;

-- 3. Nette clubnamen voor publicatie
create table if not exists club.comm_clubnamen (
  bron         text primary key,           -- clubnaam zoals Tennis en Padel Vlaanderen ze levert, zonder ploegletter, in hoofdletters
  naam         text not null check (length(btrim(naam)) between 1 and 60),
  gewijzigd_op timestamptz not null default now(),
  gewijzigd_door int
);
alter table club.comm_clubnamen enable row level security;
revoke all on club.comm_clubnamen from anon, authenticated;

insert into club.comm_clubnamen (bron, naam) values
  ('SPORTACULAIR IN.TERNATIONAL', 'Sportaculair International'),
  ('BLUE LIONS HOCKEY, TENNIS EN PADEL CLUB TERVUREN', 'Blue Lions Tervuren'),
  ('KONINKLIJKE TENNIS- EN PADELCLUB BEUKENHOF', 'Beukenhof'),
  ('REINAERT TENNIS & PADELCLUB LOKEREN VZW', 'Reinaert Lokeren'),
  ('TENNIS- EN PADELCLUB DE JONGE WINGERD', 'De Jonge Wingerd'),
  ('TENNIS- EN PADELCLUB SMASH LONDERZEEL', 'Smash Londerzeel'),
  ('TENNIS- EN PADELCLUB ''T SPUI', '''t Spui'),
  ('TENNIS EN PADELCLUB ROELANDSVELD', 'Roelandsveld'),
  ('BALLS AND MORE - LUBBEEK', 'Balls and More Lubbeek'),
  ('YCFIVE SPORTS COMPLEX', 'YCFive')
on conflict (bron) do nothing;

-- Clubdeel en ploegletter: "ATP WEZEMAAL B" -> ('ATP WEZEMAAL', 'B')
create or replace function club.club_deel(p text)
returns text language sql immutable set search_path to '' as $function$
  select upper(btrim(regexp_replace(btrim(p), '\s+[A-Z]$', '')))
$function$;

-- Regel als er geen vertaling is: hoofdletters -> gewone schrijfwijze; afkortingen (met punt of max. 3 letters)
-- blijven in hoofdletters, behalve gewone lidwoorden; "vzw" valt weg. Gemengde schrijfwijze blijft zoals ze is.
create or replace function club.nette_clubnaam(p text)
returns text language plpgsql stable security definer set search_path to '' as $function$
declare
  letter text := substring(btrim(p) from '\s([A-Z])$');
  deel   text := btrim(regexp_replace(btrim(p), '\s+[A-Z]$', ''));
  vast   text;
  uit    text;
begin
  if p is null then return null; end if;
  select c.naam into vast from club.comm_clubnamen c where c.bron = upper(deel);
  if vast is not null then
    uit := vast;
  elsif deel <> upper(deel) then
    uit := deel;
  else
    select string_agg(
             case
               when w in ('DE','HET','EN','VAN','TER','HOF','THE','FOR','OP','AAN','BIJ','EL','LA','LE') then initcap(w)
               when w = '''T' then '''t'
               when w ~ '\.' or w ~ '&' or w ~ '\d' or length(w) <= 3 then w
               else initcap(w)
             end, ' ' order by i)
      into uit
      from unnest(regexp_split_to_array(deel, '\s+')) with ordinality as t(w, i);
  end if;
  uit := btrim(regexp_replace(uit, '\s+(vzw|VZW|v\.z\.w\.|V\.Z\.W\.)(\s|$)', ' ', 'g'));
  uit := btrim(regexp_replace(uit, '^(V\.Z\.W\.|VZW)\s+', ''));
  return uit || coalesce(' ' || letter, '');
end $function$;
revoke all on function club.nette_clubnaam(text) from public;
revoke all on function club.club_deel(text) from public;

-- "PADEL DAMES 40 - 3 ploeg A" -> "Dames 40 3A"
create or replace function club.korte_ploeg(p text)
returns text language sql immutable set search_path to '' as $function$
  select coalesce(
    (select initcap(m[1]) || ' ' || m[2] || m[3]
       from regexp_match(p, '^PADEL\s+(.+?)\s+-\s+(\d+)\s+ploeg\s+(\w+)$', 'i') m),
    p)
$function$;

-- 4. Export: één rij per ontmoeting; de pagina groepeert per post (dag of week) voor Bulk Create
create or replace function public.club_comm_post(p_token text, p_van date, p_tot date)
returns jsonb language plpgsql stable security definer set search_path to '' as $function$
declare me int := club.sessie(p_token);
begin
  if me is null then return jsonb_build_object('fout','niet aangemeld'); end if;
  if not club.heeft(me, array['communicatie','commissie','bestuur']) then
    return jsonb_build_object('fout','enkel voor communicatie, commissie en bestuur'); end if;
  if p_van is null or p_tot is null or p_tot < p_van or p_tot - p_van > 62 then
    return jsonb_build_object('fout','kies een periode van hoogstens 2 maanden'); end if;
  return jsonb_build_object('wedstrijden', coalesce((
    select jsonb_agg(jsonb_build_object(
      'datum', o.datum::date,
      'uur', case when o.datum::time = '00:00' then null else to_char(o.datum, 'HH24:MI') end,
      'ploeg', club.korte_ploeg(o.ploeg),
      'competitie', o.competitie,
      'thuis_uit', o.thuis_uit,
      'tegenstander', club.nette_clubnaam(o.tegenstander),
      'tegenstander_bron', club.club_deel(o.tegenstander),
      'ronde', o.ronde,
      'kapitein', pl.kapitein,
      'gespeeld', o.gespeeld,
      'matchen_voor', o.matchen_voor, 'matchen_tegen', o.matchen_tegen,
      'sets_voor', o.sets_voor, 'sets_tegen', o.sets_tegen, 'games_voor', o.games_voor, 'games_tegen', o.games_tegen,
      'uitkomst', case when o.gespeeld then public.ic_uitkomst(o.match_id, o.ploeg_id, o.competitie, o.afdeling, o.ronde,
                      o.matchen_voor, o.matchen_tegen, o.sets_voor, o.sets_tegen, o.games_voor, o.games_tegen) ->> 'uitkomst' end
    ) order by o.datum, o.ploeg)
    from public.v_onze_wedstrijden o
    left join public.ploegen pl on pl.ploeg_id = o.ploeg_id
    where o.sport = 'Padel' and o.datum::date between p_van and p_tot), '[]'::jsonb));
end $function$;
revoke all on function public.club_comm_post(text, date, date) from public;
grant execute on function public.club_comm_post(text, date, date) to anon, authenticated;

-- 5. Nette clubnaam aanpassen (communicatie, commissie, bestuur); lege naam = vertaling wissen
create or replace function public.club_comm_clubnaam(p_token text, p_bron text, p_naam text)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare me int := club.sessie(p_token); b text := upper(btrim(p_bron)); n text := btrim(p_naam);
begin
  if me is null then return jsonb_build_object('fout','niet aangemeld'); end if;
  if not club.heeft(me, array['communicatie','commissie','bestuur']) then
    return jsonb_build_object('fout','enkel voor communicatie, commissie en bestuur'); end if;
  if b is null or b = '' then return jsonb_build_object('fout','geen club'); end if;
  if not exists (select 1 from public.v_onze_wedstrijden o where club.club_deel(o.tegenstander) = b) then
    return jsonb_build_object('fout','onbekende club'); end if;
  if n is null or n = '' then
    delete from club.comm_clubnamen where bron = b;
  elsif length(n) > 60 then
    return jsonb_build_object('fout','hoogstens 60 tekens');
  else
    insert into club.comm_clubnamen (bron, naam, gewijzigd_door) values (b, n, me)
    on conflict (bron) do update set naam = excluded.naam, gewijzigd_op = now(), gewijzigd_door = me;
  end if;
  insert into club.logboek (door, actie, detail) values (me, 'clubnaam communicatie', b || ' -> ' || coalesce(nullif(n,''), '(standaard)'));
  return jsonb_build_object('ok', true, 'naam', club.nette_clubnaam(b));
end $function$;
revoke all on function public.club_comm_clubnaam(text, text, text) from public;
grant execute on function public.club_comm_clubnaam(text, text, text) to anon, authenticated;
