-- Uitkomst van een padelinterclubontmoeting vanuit BTC: 'w', 'v' of 'g' (gelijk), met wat besliste.
-- Bron: reglementen Tennis en Padel Vlaanderen 2026, art. 10.2.
--   Najaar (Padel Mixed Cup, Padel Senior Cup; 4 wedstrijden): bij 2-2 in de eindronde
--     A. saldo sets, B. saldo games, C. winnaar van de 3e wedstrijd.
--   Voorjaar (Schweppes Padel Interclub; 6 wedstrijden): bij 3-3 in de eindronde
--     Open P700/1000 en Dames P500: A. saldo sets, B. saldo games, C. winnaar 5e wedstrijd;
--     alle andere afdelingen: B. saldo games, C. winnaar 5e wedstrijd (sets tellen niet).
--   In de poulefase blijft gelijk gelijk (1 punt elk); de regels gelden daar enkel voor de rangschikking.
-- Getoetst op 26 historische gelijke eindrondeontmoetingen van BTC: 26/26 in lijn met wie doorging.
-- Oudere seizoenen (najaar 2021, Schweppes-formule) worden met de voorjaarsregel beoordeeld.
create or replace function public.ic_uitkomst(
  p_match_id int, p_ploeg_id int, p_competitie text, p_afdeling text, p_ronde text,
  mv int, mt int, sv int, st int, gv int, gt int)
returns jsonb language plpgsql stable set search_path to '' as $$
declare najaar boolean := coalesce(p_competitie, '') ~* 'cup';
        met_sets boolean := najaar or coalesce(p_afdeling, '') ~* '^PADEL (OPEN (700|1000)|DAMES 500)$';
        nr int := case when najaar then 3 else 5 end;
        gewonnen boolean;
begin
  if mv is null or mt is null then return null; end if;
  if mv > mt then return jsonb_build_object('uitkomst','w'); end if;
  if mv < mt then return jsonb_build_object('uitkomst','v'); end if;
  if coalesce(p_ronde, '') !~* 'finale' then return jsonb_build_object('uitkomst','g'); end if;
  if met_sets and sv is not null and sv <> st then
    return jsonb_build_object('uitkomst', case when sv > st then 'w' else 'v' end, 'beslist_door', 'sets');
  end if;
  if gv is not null and gv <> gt then
    return jsonb_build_object('uitkomst', case when gv > gt then 'w' else 'v' end, 'beslist_door', 'games');
  end if;
  select bool_or(s.gewonnen) into gewonnen from public.interclub_spelers s
   where s.match_id = p_match_id and s.ploeg_id = p_ploeg_id and s.nr = nr;
  if gewonnen is null then return jsonb_build_object('uitkomst','g', 'beslist_door', 'onbekend'); end if;
  return jsonb_build_object('uitkomst', case when gewonnen then 'w' else 'v' end, 'beslist_door', nr || 'e wedstrijd');
end $$;
revoke all on function public.ic_uitkomst(int,int,text,text,text,int,int,int,int,int,int) from public, anon, authenticated;

-- Resultaten: + gespeeld, competitie, afdeling, uitkomst, beslist_door.
create or replace function public.club_ic_resultaten(p_token text)
returns jsonb language plpgsql stable security definer set search_path to '' as $$
declare me int := club.sessie(p_token); per int;
begin
  if me is null then return jsonb_build_object('fout','niet aangemeld'); end if;
  select o.periode_id into per from public.v_onze_wedstrijden o
   where o.sport = 'Padel' and o.gespeeld order by o.datum desc limit 1;
  return jsonb_build_object(
    'periode', (select max(o.periode) from public.v_onze_wedstrijden o where o.periode_id = per and o.sport = 'Padel'),
    'wedstrijden', coalesce((
      select jsonb_agg(jsonb_build_object(
        'match_id', o.match_id, 'datum', o.datum, 'ronde', o.ronde, 'ploeg_id', o.ploeg_id, 'ploeg', o.ploeg,
        'competitie', o.competitie, 'afdeling', o.afdeling, 'gespeeld', o.gespeeld,
        'thuis_uit', o.thuis_uit, 'tegenstander', o.tegenstander,
        'matchen_voor', o.matchen_voor, 'matchen_tegen', o.matchen_tegen,
        'sets_voor', o.sets_voor, 'sets_tegen', o.sets_tegen, 'games_voor', o.games_voor, 'games_tegen', o.games_tegen,
        'mijn', exists (select 1 from public.interclub_spelers s where s.ploeg_id = o.ploeg_id and s.speler_id = me)
             or exists (select 1 from club.v_kapiteins k where k.ploeg_id = o.ploeg_id and k.speler_id = me)
      ) || coalesce(public.ic_uitkomst(o.match_id, o.ploeg_id, o.competitie, o.afdeling, o.ronde,
                       o.matchen_voor, o.matchen_tegen, o.sets_voor, o.sets_tegen, o.games_voor, o.games_tegen), '{}'::jsonb)
      order by o.datum desc, o.ploeg)
      from public.v_onze_wedstrijden o
      where o.sport = 'Padel' and o.gespeeld and o.periode_id = per), '[]'::jsonb));
end $$;
revoke all on function public.club_ic_resultaten(text) from public;
grant execute on function public.club_ic_resultaten(text) to anon, authenticated;

-- Kalender: + sets, games, uitkomst, beslist_door (voor gespeelde wedstrijden in "Deze week").
create or replace function public.club_ic_kalender(p_token text)
returns jsonb language plpgsql stable security definer set search_path to '' as $$
declare me int := club.sessie(p_token);
begin
  if me is null then return jsonb_build_object('fout','niet aangemeld'); end if;
  return jsonb_build_object('wedstrijden', coalesce((
    select jsonb_agg(jsonb_build_object(
      'match_id', o.match_id, 'datum', o.datum, 'periode', o.periode, 'competitie', o.competitie, 'afdeling', o.afdeling,
      'ronde', o.ronde, 'ploeg_id', o.ploeg_id, 'ploeg', o.ploeg, 'reeks', o.reeks, 'thuis_uit', o.thuis_uit,
      'tegenstander', o.tegenstander, 'gespeeld', o.gespeeld, 'matchen_voor', o.matchen_voor, 'matchen_tegen', o.matchen_tegen,
      'sets_voor', o.sets_voor, 'sets_tegen', o.sets_tegen, 'games_voor', o.games_voor, 'games_tegen', o.games_tegen,
      'kapitein', pl.kapitein,
      'mijn', exists (select 1 from public.interclub_spelers s where s.ploeg_id = o.ploeg_id and s.speler_id = me)
           or exists (select 1 from club.v_kapiteins k where k.ploeg_id = o.ploeg_id and k.speler_id = me)
    ) || coalesce(public.ic_uitkomst(o.match_id, o.ploeg_id, o.competitie, o.afdeling, o.ronde,
                     o.matchen_voor, o.matchen_tegen, o.sets_voor, o.sets_tegen, o.games_voor, o.games_tegen), '{}'::jsonb)
    order by o.datum, o.ploeg)
    from public.v_onze_wedstrijden o
    join public.ploegen pl on pl.ploeg_id = o.ploeg_id
    where o.sport = 'Padel'
      and ((not o.gespeeld and o.datum >= current_date) or (o.gespeeld and o.datum >= current_date - 21))), '[]'::jsonb));
end $$;
revoke all on function public.club_ic_kalender(text) from public;
grant execute on function public.club_ic_kalender(text) to anon, authenticated;
