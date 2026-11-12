-- WhatsApp-groepen per niveau, met toegangscontrole (migratie club_whatsapp_groepen, 13/11/2026).
-- Regels (CLM, 13/11/2026):
--  W1 Een lid mag in een groep als zijn niveau binnen het bereik valt.
--  W2 Eén klassement hoger mag in de groep eronder (P500 mag in P300-P400).
--  W3 Ligt de speelsterkte (padelstats) hoger dan het klassement, dan telt ze ook als niveau (W1 en W2).
--  W4 De hoogste groep staat open voor iedereen boven het bereik (P700, P1000).
-- De uitnodigingslinks staan enkel in de database en worden pas na de controle per groep teruggegeven.

create table if not exists club.whatsapp_groepen (
  id serial primary key,
  naam text not null,
  niveau_min int not null,
  niveau_max int not null check (niveau_max >= niveau_min),
  link text check (link is null or link ~ '^https://chat\.whatsapp\.com/[A-Za-z0-9]+$'),
  actief boolean not null default true,
  volgorde int not null default 0,
  gewijzigd timestamptz not null default now(),
  gewijzigd_door int
);
alter table club.whatsapp_groepen enable row level security;
revoke all on club.whatsapp_groepen from public, anon, authenticated;
revoke all on sequence club.whatsapp_groepen_id_seq from public, anon, authenticated;

insert into club.whatsapp_groepen (naam, niveau_min, niveau_max, volgorde)
select * from (values ('P50 – P100',50,100,1),('P100 – P200',100,200,2),('P200 – P300',200,300,3),
                      ('P300 – P400',300,400,4),('P400 – P500',400,500,5)) v
where not exists (select 1 from club.whatsapp_groepen);

create or replace function club.zk_sterkte(p_speler int) returns int
language sql stable security definer set search_path = '' as $$
  select ps.speelsterkte from public.padelstats_sterkte ps where ps.speler_id = p_speler $$;

-- Toegang: null = toegelaten, anders de reden
create or replace function club.wa_weigering(p_groep int, p_speler int) returns text
language plpgsql stable security definer set search_path = '' as $$
declare g club.whatsapp_groepen; L int[] := club.les_ladder(); k int := club.zk_niveau(p_speler);
        s int := club.zk_sterkte(p_speler); e int; vloer int; top int; volgende int;
begin
  select * into g from club.whatsapp_groepen where id = p_groep and actief;
  if not found then return 'groep niet beschikbaar'; end if;
  select max(niveau_max) into top from club.whatsapp_groepen where actief;
  volgende := L[array_position(L, g.niveau_max) + 1];
  foreach e in array (case when s is not null and s > k then array[k, s] else array[k] end) loop
    select max(x) into vloer from unnest(L) x where x <= e;
    if e >= g.niveau_min and (e <= g.niveau_max or g.niveau_max = top) then return null; end if;   -- W1, W4
    if volgende is not null and vloer = volgende then return null; end if;                          -- W2
  end loop;
  if greatest(k, coalesce(s, 0)) < g.niveau_min then return 'vanaf P' || g.niveau_min; end if;
  return 'voor lagere niveaus';
end $$;

revoke all on function club.zk_sterkte(int), club.wa_weigering(int,int) from public, anon, authenticated;

-- Lijst voor het lid (zonder links); commissie/beheerder krijgt ook de links om te beheren
create or replace function public.club_wa_groepen(p_token text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare me int := club.sessie(p_token); beheer boolean;
begin
  if me is null then return jsonb_build_object('fout','niet aangemeld'); end if;
  beheer := club.heeft(me, array['commissie','beheerder']);
  return jsonb_build_object(
    'ik', jsonb_build_object('klassement', club.zk_niveau(me), 'speelsterkte', club.zk_sterkte(me)),
    'beheer', beheer,
    'groepen', coalesce((select jsonb_agg(jsonb_build_object(
        'id', g.id, 'naam', g.naam, 'min', g.niveau_min, 'max', g.niveau_max,
        'toegang', club.wa_weigering(g.id, me) is null, 'reden', club.wa_weigering(g.id, me),
        'heeft_link', g.link is not null) || case when beheer then jsonb_build_object('link', g.link) else '{}'::jsonb end
        order by g.volgorde) from club.whatsapp_groepen g where g.actief), '[]'::jsonb));
end $$;

-- Link opvragen: enkel na controle, gelogd
create or replace function public.club_wa_link(p_token text, p_groep int)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare me int := club.sessie(p_token); r text; l text;
begin
  if me is null then return jsonb_build_object('fout','niet aangemeld'); end if;
  r := club.wa_weigering(p_groep, me);
  if r is not null then return jsonb_build_object('fout', 'deze groep is ' || r); end if;
  select link into l from club.whatsapp_groepen where id = p_groep;
  if l is null then return jsonb_build_object('fout','de commissie heeft de link nog niet ingesteld'); end if;
  if not club.zk_voorbeeld() then
    insert into club.logboek (door, actie, speler_id, detail) values (me, 'whatsapp link', me, p_groep::text);
  end if;
  return jsonb_build_object('ok', true, 'link', l);
end $$;

-- Beheer: link instellen of vervangen (na een reset in WhatsApp)
create or replace function public.club_wa_beheer(p_token text, p_groep int, p_link text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare me int := club.sessie(p_token); l text := nullif(btrim(p_link), '');
begin
  if me is null then return jsonb_build_object('fout','niet aangemeld'); end if;
  if club.zk_voorbeeld() then return jsonb_build_object('fout','niet mogelijk in voorbeeldmodus'); end if;
  if not club.heeft(me, array['commissie','beheerder']) then return jsonb_build_object('fout','geen toegang'); end if;
  if l is not null and l !~ '^https://chat\.whatsapp\.com/[A-Za-z0-9]+$' then
    return jsonb_build_object('fout','geen geldige WhatsApp-uitnodigingslink (https://chat.whatsapp.com/…)'); end if;
  update club.whatsapp_groepen set link = l, gewijzigd = now(), gewijzigd_door = me where id = p_groep;
  if not found then return jsonb_build_object('fout','groep niet gevonden'); end if;
  insert into club.logboek (door, actie, speler_id, detail) values (me, 'whatsapp link gewijzigd', me, p_groep::text);
  return jsonb_build_object('ok', true);
end $$;

revoke all on function public.club_wa_groepen(text), public.club_wa_link(text,int), public.club_wa_beheer(text,int,text) from public;
grant execute on function public.club_wa_groepen(text), public.club_wa_link(text,int), public.club_wa_beheer(text,int,text) to anon, authenticated;
