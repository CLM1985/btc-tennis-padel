-- Scouting interclubtegenstanders (beslissingen CLM 10/11/2026: namen intern achter login, eigen schema, voorlopig enkel eigen ploeg)
-- Toegepast in Supabase padel-interclub: migraties scouting_schema en club_planner_scouting.

create schema if not exists scouting;            -- geen rechten voor anon/authenticated
-- scouting.tegenstander_spelers(match_id, tgn_ploeg_id, speler_id, naam, geslacht, klassement, speelsterkte, sterkte_datum, bron, wissen_na)
-- scouting.simulaties(match_id, btc_1, btc_2, tgn_1, tgn_2, kans_btc, bron 'padelstats'|'formule', wissen_na)
-- scouting.opruimen(): wist rijen met wissen_na < vandaag (7 dagen na de ontmoeting)

-- public.club_planner_scouting(p_token, p_ploeg) -> {ontmoetingen:[{match_id, datum, ronde, tegen, tu, spelers[], metingen[]}]}
--   enkel voor wie de ploeg mag zien in de planner (club.planner_ploegen), enkel ontmoetingen die nog gespeeld moeten worden.
--   Spelers van de tegenstander krijgen een negatieve id (-lidnummer) zodat ze nooit botsen met eigen leden.

-- 10/11/2026 (migratie scouting_duos): scouting.tegenstander_duos(match_id, speler_1, speler_2, samen, gewonnen, bron, wissen_na)
--   = hoe vaak een duo van de tegenstander samen speelde in hun poule en hoeveel keer het won (uit de uitslagenbladen).
--   club_planner_scouting geeft dit terug als 'duos': [{ids:[-lid,-lid], n, w}]; opruimen() wist ook deze tabel.
