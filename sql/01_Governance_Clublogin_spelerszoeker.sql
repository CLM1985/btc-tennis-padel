-- Spelerszoeker (clublogin). Migratie club_spelerszoeker, 12/11/2026.
-- Beslissingen S1-S5 + 12/11: volledige naam altijd zichtbaar; enkel klassement; wie eerst komt;
-- max. 3 lopende oproepen per lid; terrein reserveerbaar tot 7 dagen vooruit (Elit).

create table if not exists club.zoekoproepen (
  id bigserial primary key,
  maker int not null,
  van timestamp not null,
  tot timestamp not null,
  terrein text not null default 'niet_gereserveerd' check (terrein in ('gereserveerd','niet_gereserveerd')),
  gezocht_m smallint not null default 0 check (gezocht_m >= 0),
  gezocht_v smallint not null default 0 check (gezocht_v >= 0),
  gezocht_x smallint not null default 0 check (gezocht_x >= 0),
  niveau_min int,
  niveau_max int,
  opmerking text check (length(opmerking) <= 200),
  geannuleerd timestamptz,
  aangemaakt timestamptz not null default now(),
  check (gezocht_m + gezocht_v + gezocht_x between 1 and 3),
  check ((niveau_min is null) = (niveau_max is null) and (niveau_min is null or niveau_min <= niveau_max)),
  check (tot > van and tot <= van + interval '4 hours')
);
create index if not exists zoekoproepen_van on club.zoekoproepen (van) where geannuleerd is null;
create index if not exists zoekoproepen_maker on club.zoekoproepen (maker);

create table if not exists club.zoekoproep_deelnemers (
  id bigserial primary key,
  oproep bigint not null references club.zoekoproepen(id) on delete cascade,
  speler int not null,
  plaats char(1) not null check (plaats in ('M','V','X')),   -- ingevulde plek: heer, dame of vrij
  status text not null default 'bevestigd' check (status in ('bevestigd','afgemeld')),
  ingeschreven timestamptz not null default now(),
  afgemeld timestamptz
);
create unique index if not exists zoekoproep_deelnemer_actief on club.zoekoproep_deelnemers (oproep, speler) where status = 'bevestigd';
create index if not exists zoekoproep_deelnemers_speler on club.zoekoproep_deelnemers (speler);

create table if not exists club.zoeker_instelling (
  speler int primary key,
  meldingen boolean not null default false,     -- opt-in: melding bij nieuwe passende oproep
  gewijzigd timestamptz not null default now()
);

alter table club.zoekoproepen enable row level security;
alter table club.zoekoproep_deelnemers enable row level security;
alter table club.zoeker_instelling enable row level security;
revoke all on club.zoekoproepen, club.zoekoproep_deelnemers, club.zoeker_instelling from public, anon, authenticated;
revoke all on sequence club.zoekoproepen_id_seq, club.zoekoproep_deelnemers_id_seq from public, anon, authenticated;

-- ---------------------------------------------------------------- hulpfuncties
-- Klassement = padel_niveau van het laatste ledenjaar (S3: geen speelsterkte)
create or replace function club.zk_niveau(p_speler int) returns int
language sql stable security definer set search_path = '' as $$
  select coalesce((select l.padel_niveau from public.leden l where l.speler_id = p_speler order by l.jaar desc limit 1), 50) $$;

create or replace function club.zk_geslacht(p_speler int) returns char
language sql stable security definer set search_path = '' as $$
  select case v.geslacht when 'Man' then 'M' when 'Vrouw' then 'V' end from club.v_lid v where v.speler_id = p_speler $$;

create or replace function club.zk_naam(p_speler int) returns text
language sql stable security definer set search_path = '' as $$
  select v.naam from club.v_lid v where v.speler_id = p_speler $$;

-- Nog vrije plaatsen per soort
create or replace function club.zk_vrij(p_oproep bigint, out m int, out v int, out x int)
language sql stable security definer set search_path = '' as $$
  select o.gezocht_m - count(d.id) filter (where d.plaats = 'M'),
         o.gezocht_v - count(d.id) filter (where d.plaats = 'V'),
         o.gezocht_x - count(d.id) filter (where d.plaats = 'X')
    from club.zoekoproepen o
    left join club.zoekoproep_deelnemers d on d.oproep = o.id and d.status = 'bevestigd'
   where o.id = p_oproep
   group by o.id $$;

-- Afgeleide status: geannuleerd / voorbij / volzet / open
create or replace function club.zk_status(p_oproep bigint) returns text
language sql stable security definer set search_path = '' as $$
  select case when o.geannuleerd is not null then 'geannuleerd'
              when o.tot <= club.nu() then 'voorbij'
              when (select f.m + f.v + f.x from club.zk_vrij(o.id) f) <= 0 then 'volzet'
              else 'open' end
    from club.zoekoproepen o where o.id = p_oproep $$;

-- Plaats die een speler zou innemen (null = geen plaats voor hem)
create or replace function club.zk_plaats(p_oproep bigint, p_speler int) returns char
language sql stable security definer set search_path = '' as $$
  select case when g = 'M' and f.m > 0 then 'M'
              when g = 'V' and f.v > 0 then 'V'
              when f.x > 0 then 'X' end
    from club.zk_vrij(p_oproep) f, club.zk_geslacht(p_speler) g $$;

-- Mag dit lid de oproep zien en meedoen? (S5: niveau buiten bereik = niet zichtbaar)
create or replace function club.zk_ziet(p_oproep bigint, p_speler int) returns boolean
language sql stable security definer set search_path = '' as $$
  select o.maker <> p_speler
     and club.zk_status(o.id) = 'open'
     and o.van > club.nu()
     and not exists (select 1 from club.zoekoproep_deelnemers d where d.oproep = o.id and d.speler = p_speler and d.status = 'bevestigd')
     and club.zk_plaats(o.id, p_speler) is not null
     and (o.niveau_min is null or club.zk_niveau(p_speler) between o.niveau_min and o.niveau_max)
    from club.zoekoproepen o where o.id = p_oproep $$;

create or replace function club.zk_terreintekst(p_terrein text, p_van timestamp) returns text
language sql stable set search_path = '' as $$
  select case when p_terrein = 'gereserveerd' then 'Terrein gereserveerd'
              when p_van > club.nu() + interval '7 days' then 'Planning – reserveerbaar vanaf ' || club.dagtekst(p_van - interval '7 days')
              else 'Terrein nog te reserveren' end $$;

create or replace function club.zk_json(p_oproep bigint, p_me int) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'id', o.id, 'van', o.van, 'tot', o.tot, 'moment', club.dagtekst(o.van) || '–' || to_char(o.tot, 'HH24:MI'),
    'terrein', o.terrein, 'terreintekst', club.zk_terreintekst(o.terrein, o.van),
    'reserveerbaar', o.van <= club.nu() + interval '7 days',
    'maker', jsonb_build_object('naam', club.zk_naam(o.maker), 'klassement', 'P' || club.zk_niveau(o.maker), 'geslacht', club.zk_geslacht(o.maker)),
    'gezocht', jsonb_build_object('m', o.gezocht_m, 'v', o.gezocht_v, 'x', o.gezocht_x),
    'vrij', (select jsonb_build_object('m', f.m, 'v', f.v, 'x', f.x) from club.zk_vrij(o.id) f),
    'niveau', case when o.niveau_min is null then null else jsonb_build_object('min', o.niveau_min, 'max', o.niveau_max) end,
    'opmerking', o.opmerking, 'status', club.zk_status(o.id),
    'ben_maker', o.maker = p_me,
    'doe_mee', exists (select 1 from club.zoekoproep_deelnemers d where d.oproep = o.id and d.speler = p_me and d.status = 'bevestigd'),
    'deelnemers', coalesce((select jsonb_agg(jsonb_build_object('naam', club.zk_naam(d.speler), 'klassement', 'P' || club.zk_niveau(d.speler),
                                    'geslacht', club.zk_geslacht(d.speler)) order by d.ingeschreven)
                              from club.zoekoproep_deelnemers d where d.oproep = o.id and d.status = 'bevestigd'), '[]'::jsonb))
  from club.zoekoproepen o where o.id = p_oproep $$;

-- Melding naar maker en alle bevestigde deelnemers (behalve p_behalve)
create or replace function club.zk_meld_groep(p_oproep bigint, p_behalve int, p_soort text, p_titel text, p_tekst text)
returns void language plpgsql security definer set search_path = '' as $$
declare sp int;
begin
  for sp in select o.maker from club.zoekoproepen o where o.id = p_oproep
            union select d.speler from club.zoekoproep_deelnemers d where d.oproep = p_oproep and d.status = 'bevestigd' loop
    if sp is distinct from p_behalve then perform club.meld(sp, p_soort, p_titel, p_tekst, 'spelerszoeker/'); end if;
  end loop;
end $$;

create or replace function club.zk_voorbeeld() returns boolean
language sql stable set search_path = '' as $$ select coalesce(current_setting('club.voorbeeld', true), '') <> '' $$;

revoke all on function club.zk_niveau(int), club.zk_geslacht(int), club.zk_naam(int), club.zk_vrij(bigint), club.zk_status(bigint),
  club.zk_plaats(bigint,int), club.zk_ziet(bigint,int), club.zk_terreintekst(text,timestamp), club.zk_json(bigint,int),
  club.zk_meld_groep(bigint,int,text,text,text), club.zk_voorbeeld() from public, anon, authenticated;

-- ---------------------------------------------------------------- functies voor de site
-- Overzicht: mijn oproepen, oproepen waar ik meedoe, open oproepen die voor mij passen
create or replace function public.club_zoeker(p_token text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare me int := club.sessie(p_token); k int; L int[] := club.les_ladder(); i int;
begin
  if me is null then return jsonb_build_object('fout','niet aangemeld'); end if;
  k := club.zk_niveau(me);
  i := coalesce(array_position(L, k), 1);
  return jsonb_build_object(
    'ik', jsonb_build_object('klassement', k, 'geslacht', club.zk_geslacht(me),
            'standaard_min', L[greatest(i-1,1)], 'standaard_max', L[least(i+1, array_length(L,1))], 'ladder', to_jsonb(L),
            'meldingen', coalesce((select z.meldingen from club.zoeker_instelling z where z.speler = me), false),
            'lopend', (select count(*) from club.zoekoproepen o where o.maker = me and o.geannuleerd is null and o.tot > club.nu()),
            'max_lopend', 3, 'nu', club.nu()),
    'mijn', coalesce((select jsonb_agg(club.zk_json(o.id, me) order by o.van) from club.zoekoproepen o
                      where o.maker = me and o.tot > club.nu() - interval '1 day'), '[]'::jsonb),
    'mee', coalesce((select jsonb_agg(club.zk_json(o.id, me) order by o.van) from club.zoekoproepen o
                     join club.zoekoproep_deelnemers d on d.oproep = o.id and d.speler = me and d.status = 'bevestigd'
                     where o.tot > club.nu() - interval '1 day'), '[]'::jsonb),
    'open', coalesce((select jsonb_agg(club.zk_json(t.id, me) order by t.van) from
                      (select o.id, o.van from club.zoekoproepen o
                        where o.geannuleerd is null and o.van > club.nu() and club.zk_ziet(o.id, me)
                        order by o.van limit 100) t), '[]'::jsonb));
end $$;

create or replace function public.club_zoeker_plaats(p_token text, p_van timestamp, p_tot timestamp, p_terrein text,
  p_m int, p_v int, p_x int, p_niveau_min int, p_niveau_max int, p_opmerking text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare me int := club.sessie(p_token); L int[] := club.les_ladder(); nid bigint; sp int; t text;
begin
  if me is null then return jsonb_build_object('fout','niet aangemeld'); end if;
  if club.zk_voorbeeld() then return jsonb_build_object('fout','niet mogelijk in voorbeeldmodus'); end if;
  if p_van is null or p_tot is null or p_van <= club.nu() then return jsonb_build_object('fout','kies een moment in de toekomst'); end if;
  if p_van > club.nu() + interval '60 days' then return jsonb_build_object('fout','maximaal 60 dagen vooruit'); end if;
  if p_tot <= p_van or p_tot > p_van + interval '4 hours' then return jsonb_build_object('fout','eind na begin, maximaal 4 uur'); end if;
  if coalesce(p_terrein,'') not in ('gereserveerd','niet_gereserveerd') then return jsonb_build_object('fout','kies de terreinstatus'); end if;
  if p_terrein = 'gereserveerd' and p_van > club.nu() + interval '7 days' then
    return jsonb_build_object('fout','meer dan 7 dagen vooruit kan nog niet gereserveerd zijn'); end if;
  if coalesce(p_m,0) < 0 or coalesce(p_v,0) < 0 or coalesce(p_x,0) < 0 or coalesce(p_m,0)+coalesce(p_v,0)+coalesce(p_x,0) not between 1 and 3 then
    return jsonb_build_object('fout','zoek 1 tot 3 spelers'); end if;
  if (p_niveau_min is null) <> (p_niveau_max is null)
     or (p_niveau_min is not null and (not p_niveau_min = any(L) or not p_niveau_max = any(L) or p_niveau_min > p_niveau_max)) then
    return jsonb_build_object('fout','ongeldig niveaubereik'); end if;
  if length(p_opmerking) > 200 then return jsonb_build_object('fout','opmerking maximaal 200 tekens'); end if;
  if (select count(*) from club.zoekoproepen o where o.maker = me and o.geannuleerd is null and o.tot > club.nu()) >= 3 then
    return jsonb_build_object('fout','je hebt al 3 lopende oproepen'); end if;

  insert into club.zoekoproepen (maker, van, tot, terrein, gezocht_m, gezocht_v, gezocht_x, niveau_min, niveau_max, opmerking)
  values (me, p_van, p_tot, p_terrein, coalesce(p_m,0), coalesce(p_v,0), coalesce(p_x,0), p_niveau_min, p_niveau_max, nullif(btrim(p_opmerking),''))
  returning id into nid;
  insert into club.logboek (door, actie, speler_id, detail) values (me, 'zoekoproep geplaatst', me, nid::text);

  t := club.dagtekst(p_van);
  for sp in select z.speler from club.zoeker_instelling z where z.meldingen and z.speler <> me loop
    if club.zk_ziet(nid, sp) then
      perform club.meld(sp, 'zoeker_nieuw', 'Speler gezocht', 'Er wordt een speler gezocht op ' || t || '. Doe je mee?', 'spelerszoeker/');
    end if;
  end loop;
  return jsonb_build_object('ok', true, 'oproep', club.zk_json(nid, me));
end $$;

-- Wie eerst komt: meteen bevestigd zolang er een passende plaats vrij is
create or replace function public.club_zoeker_doe_mee(p_token text, p_oproep bigint)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare me int := club.sessie(p_token); o club.zoekoproepen; pl char; t text;
begin
  if me is null then return jsonb_build_object('fout','niet aangemeld'); end if;
  if club.zk_voorbeeld() then return jsonb_build_object('fout','niet mogelijk in voorbeeldmodus'); end if;
  select * into o from club.zoekoproepen where id = p_oproep for update;   -- volgorde bij gelijktijdige aanmeldingen
  if not found or not club.zk_ziet(p_oproep, me) then
    return jsonb_build_object('fout', case when found and club.zk_status(p_oproep) = 'volzet' then 'deze oproep is net volzet' else 'oproep niet beschikbaar' end); end if;
  pl := club.zk_plaats(p_oproep, me);
  insert into club.zoekoproep_deelnemers (oproep, speler, plaats) values (p_oproep, me, pl);
  insert into club.logboek (door, actie, speler_id, detail) values (me, 'zoekoproep meedoen', me, p_oproep::text);

  t := club.dagtekst(o.van);
  if club.zk_status(p_oproep) = 'volzet' then
    perform club.zk_meld_groep(p_oproep, null, 'zoeker_volzet', 'Groep volledig',
      'Jullie groep voor ' || t || ' is volledig.' || case when o.terrein = 'gereserveerd' then '' else ' Het terrein is nog niet gereserveerd.' end);
  else
    perform club.meld(o.maker, 'zoeker_mee', 'Iemand doet mee', 'Een lid doet mee met je oproep op ' || t || '.', 'spelerszoeker/');
  end if;
  return jsonb_build_object('ok', true, 'oproep', club.zk_json(p_oproep, me));
end $$;

create or replace function public.club_zoeker_afmelden(p_token text, p_oproep bigint)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare me int := club.sessie(p_token); o club.zoekoproepen;
begin
  if me is null then return jsonb_build_object('fout','niet aangemeld'); end if;
  if club.zk_voorbeeld() then return jsonb_build_object('fout','niet mogelijk in voorbeeldmodus'); end if;
  select * into o from club.zoekoproepen where id = p_oproep for update;
  if not found or o.van <= club.nu() then return jsonb_build_object('fout','afmelden kan enkel voor het begin'); end if;
  update club.zoekoproep_deelnemers set status = 'afgemeld', afgemeld = now()
   where oproep = p_oproep and speler = me and status = 'bevestigd';
  if not found then return jsonb_build_object('fout','je doet niet mee met deze oproep'); end if;
  insert into club.logboek (door, actie, speler_id, detail) values (me, 'zoekoproep afgemeld', me, p_oproep::text);
  if o.geannuleerd is null then
    perform club.zk_meld_groep(p_oproep, me, 'zoeker_af', 'Afmelding',
      'Een speler meldde zich af voor ' || club.dagtekst(o.van) || '. De oproep staat weer open.');
  end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.club_zoeker_annuleer(p_token text, p_oproep bigint)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare me int := club.sessie(p_token); o club.zoekoproepen;
begin
  if me is null then return jsonb_build_object('fout','niet aangemeld'); end if;
  if club.zk_voorbeeld() then return jsonb_build_object('fout','niet mogelijk in voorbeeldmodus'); end if;
  select * into o from club.zoekoproepen where id = p_oproep and maker = me for update;
  if not found or o.geannuleerd is not null or o.tot <= club.nu() then return jsonb_build_object('fout','oproep niet te annuleren'); end if;
  update club.zoekoproepen set geannuleerd = now() where id = p_oproep;
  insert into club.logboek (door, actie, speler_id, detail) values (me, 'zoekoproep geannuleerd', me, p_oproep::text);
  perform club.zk_meld_groep(p_oproep, me, 'zoeker_geannuleerd', 'Gaat niet door',
    'Het speelmoment op ' || club.dagtekst(o.van) || ' is geannuleerd.');
  return jsonb_build_object('ok', true);
end $$;

-- Maker meldt dat het terrein intussen gereserveerd is
create or replace function public.club_zoeker_terrein(p_token text, p_oproep bigint)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare me int := club.sessie(p_token); o club.zoekoproepen;
begin
  if me is null then return jsonb_build_object('fout','niet aangemeld'); end if;
  if club.zk_voorbeeld() then return jsonb_build_object('fout','niet mogelijk in voorbeeldmodus'); end if;
  select * into o from club.zoekoproepen where id = p_oproep and maker = me for update;
  if not found or o.geannuleerd is not null or o.tot <= club.nu() then return jsonb_build_object('fout','oproep niet beschikbaar'); end if;
  if o.van > club.nu() + interval '7 days' then return jsonb_build_object('fout','nog niet reserveerbaar (meer dan 7 dagen vooruit)'); end if;
  if o.terrein = 'gereserveerd' then return jsonb_build_object('ok', true); end if;
  update club.zoekoproepen set terrein = 'gereserveerd' where id = p_oproep;
  insert into club.logboek (door, actie, speler_id, detail) values (me, 'zoekoproep terrein', me, p_oproep::text);
  perform club.zk_meld_groep(p_oproep, me, 'zoeker_terrein', 'Terrein gereserveerd',
    'Het terrein voor ' || club.dagtekst(o.van) || ' is gereserveerd.');
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.club_zoeker_meldingen(p_token text, p_aan boolean)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare me int := club.sessie(p_token);
begin
  if me is null then return jsonb_build_object('fout','niet aangemeld'); end if;
  if club.zk_voorbeeld() then return jsonb_build_object('fout','niet mogelijk in voorbeeldmodus'); end if;
  insert into club.zoeker_instelling (speler, meldingen) values (me, coalesce(p_aan,false))
  on conflict (speler) do update set meldingen = excluded.meldingen, gewijzigd = now();
  return jsonb_build_object('ok', true, 'meldingen', coalesce(p_aan,false));
end $$;

revoke all on function public.club_zoeker(text),
  public.club_zoeker_plaats(text,timestamp,timestamp,text,int,int,int,int,int,text),
  public.club_zoeker_doe_mee(text,bigint), public.club_zoeker_afmelden(text,bigint),
  public.club_zoeker_annuleer(text,bigint), public.club_zoeker_terrein(text,bigint),
  public.club_zoeker_meldingen(text,boolean) from public;
grant execute on function public.club_zoeker(text),
  public.club_zoeker_plaats(text,timestamp,timestamp,text,int,int,int,int,int,text),
  public.club_zoeker_doe_mee(text,bigint), public.club_zoeker_afmelden(text,bigint),
  public.club_zoeker_annuleer(text,bigint), public.club_zoeker_terrein(text,bigint),
  public.club_zoeker_meldingen(text,boolean) to anon, authenticated;
