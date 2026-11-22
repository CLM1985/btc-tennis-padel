-- Eindronde: thuisploeg in volgende rondes (tabblad "Eindronde" op de interclubpagina, enkel kapiteins).
-- Beslissing Chris Meert 22/11/2026: pagina live achter de rol kapitein; extra scraper voor de volledige
-- eindtabel; eindronde-tabellen enkel vanaf 2026; regel getoetst op de voorjaarsinterclub 2026.
-- Regel (reglement Tennis en Padel Vlaanderen 2026, art. 7.3.2.2), berekening in interclub/eindronde.js:
--   ronde 1 thuis = poulewinnaar; daarna = ploeg met de meeste uitwedstrijden in de eindronde
--   (vrij in ronde 1 telt als thuis); gelijk = eerst uitgelote ploeg (ronde-1-spelers van boven naar
--   beneden, dan de vrije ploegen van boven naar beneden).
-- Toets 22/11/2026 op alle 6 eindtabellen voorjaar 2026 met BTC: ronde 1 42/42, volgende rondes 122/122
-- (51 beslist door het aantal uitwedstrijden, 71 door de lotingsvolgorde). Najaar 2026 (gespeeld + gepland): 76/76.
-- Bron tabel: public.eindronde_tabel, gevuld door scraper/eindronde.py (repo padel-interclub).
-- Enkel ploeg- en clubnamen, geen spelers. Alleen-lezen.

CREATE TABLE IF NOT EXISTS public.eindronde_tabel (
    table_id          INTEGER NOT NULL,
    tab_id            INTEGER NOT NULL,
    periode_id        INTEGER,
    competitie        TEXT,
    ronde             INTEGER NOT NULL,
    ronde_naam        TEXT,
    positie           INTEGER NOT NULL,
    a_ploeg_id        INTEGER, a_naam TEXT, a_poule TEXT, a_plaats INTEGER,
    b_ploeg_id        INTEGER, b_naam TEXT, b_poule TEXT, b_plaats INTEGER,
    thuis             TEXT,
    winnaar_ploeg_id  INTEGER,
    match_id          INTEGER,
    gespeeld          BOOLEAN,
    status            TEXT,
    datum             TIMESTAMP,
    matchen_a         INTEGER, matchen_b INTEGER,
    sets_a            INTEGER, sets_b    INTEGER,
    games_a           INTEGER, games_b   INTEGER,
    bijgewerkt        TIMESTAMP,
    PRIMARY KEY (table_id, tab_id, ronde, positie)
);
ALTER TABLE public.eindronde_tabel ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.eindronde_tabel FROM anon, authenticated;

-- Tabellen van de recentste padelperiode met eindronde-gegevens waarin een BTC-ploeg staat.
-- 'mijn' = ploegen waarin je speelde of waarvan je kapitein bent (zelfde regel als club_ic_kalender).
create or replace function public.club_ic_eindronde(p_token text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare me int := club.sessie(p_token); per int;
begin
  if me is null then return jsonb_build_object('fout','niet aangemeld'); end if;
  if not club.heeft(me, array['kapitein']) then return jsonb_build_object('fout','enkel voor kapiteins'); end if;
  select max(e.periode_id) into per from public.eindronde_tabel e;
  return jsonb_build_object(
    'periode', (select p.naam from public.periodes p where p.periode_id = per),
    'tabellen', coalesce((
      select jsonb_agg(jsonb_build_object(
        'table_id', g.table_id, 'tab_id', g.tab_id, 'competitie', g.competitie, 'bijgewerkt', g.bijgewerkt,
        'rondes', (select jsonb_agg(r.ronde_naam order by r.ronde)
                     from (select distinct e.ronde, e.ronde_naam from public.eindronde_tabel e
                            where e.table_id = g.table_id and e.tab_id = g.tab_id) r),
        'paren', (select jsonb_agg(jsonb_build_object(
                    'ronde', e.ronde, 'positie', e.positie,
                    'a', e.a_ploeg_id, 'a_naam', e.a_naam, 'a_poule', e.a_poule, 'a_plaats', e.a_plaats,
                    'b', e.b_ploeg_id, 'b_naam', e.b_naam, 'b_poule', e.b_poule, 'b_plaats', e.b_plaats,
                    'thuis', e.thuis, 'winnaar', e.winnaar_ploeg_id, 'gespeeld', coalesce(e.gespeeld, false),
                    'datum', e.datum, 'matchen_a', e.matchen_a, 'matchen_b', e.matchen_b)
                    order by e.ronde, e.positie)
                  from public.eindronde_tabel e where e.table_id = g.table_id and e.tab_id = g.tab_id),
        'btc', (select jsonb_agg(jsonb_build_object(
                  'ploeg_id', pl.ploeg_id, 'ploeg', pl.naam, 'reeks', pl.reeks, 'kapitein', pl.kapitein,
                  'mijn', exists (select 1 from public.interclub_spelers s where s.ploeg_id = pl.ploeg_id and s.speler_id = me)
                       or exists (select 1 from club.v_kapiteins k where k.ploeg_id = pl.ploeg_id and k.speler_id = me))
                  order by pl.naam)
                from public.ploegen pl
                where pl.ploeg_id in (select e.a_ploeg_id from public.eindronde_tabel e where e.table_id = g.table_id and e.tab_id = g.tab_id
                                      union select e.b_ploeg_id from public.eindronde_tabel e where e.table_id = g.table_id and e.tab_id = g.tab_id))
      ) order by g.competitie, g.table_id)
      from (select e.table_id, e.tab_id, max(e.competitie) as competitie, max(e.bijgewerkt) as bijgewerkt
              from public.eindronde_tabel e where e.periode_id = per group by e.table_id, e.tab_id) g
      where exists (select 1 from public.ploegen pl join public.eindronde_tabel e
                      on pl.ploeg_id in (e.a_ploeg_id, e.b_ploeg_id)
                     where e.table_id = g.table_id and e.tab_id = g.tab_id)), '[]'::jsonb));
end $$;
revoke all on function public.club_ic_eindronde(text) from public;
grant execute on function public.club_ic_eindronde(text) to anon, authenticated;
