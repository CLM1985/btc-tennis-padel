-- Uitklapbare wedstrijddetails per interclubontmoeting (interclubpagina, tab Resultaten).
-- Per wedstrijd (D1..D4/D6): BTC-spelers met naam en klassement, klassement van de tegenstanders
-- (geen namen van externe spelers, conform de privacyregels), score en winst/verlies.
-- Score zoals Tennis en Padel Vlaanderen ze geeft (standpunt van de winnaar); de app draait ze om bij verlies.
-- Alleen-lezen; enkel voor aangemelde leden. Namen van eigen leden via leden.speler_id (recentste jaar).
create or replace function public.club_ic_ontmoeting(p_token text, p_match_id int, p_ploeg_id int)
returns jsonb language plpgsql stable security definer set search_path to '' as $$
declare me int := club.sessie(p_token);
begin
  if me is null then return jsonb_build_object('fout','niet aangemeld'); end if;
  if not exists (select 1 from public.v_onze_wedstrijden o
                  where o.match_id = p_match_id and o.ploeg_id = p_ploeg_id and o.sport = 'Padel') then
    return jsonb_build_object('fout','onbekende ontmoeting');
  end if;
  return jsonb_build_object('match_id', p_match_id, 'ploeg_id', p_ploeg_id, 'wedstrijden', coalesce((
    select jsonb_agg(x order by x->>'soort', (x->>'nr')::int) from (
      select jsonb_build_object(
        'soort', s.soort, 'nr', s.nr, 'gewonnen', bool_or(s.gewonnen), 'score', max(s.score),
        'btc', jsonb_agg(jsonb_build_object('naam', coalesce(l.naam, 'Onbekende speler'), 'klassement', s.klassement) order by s.positie),
        'tegen', (select jsonb_agg(t.klassement order by t.positie) from public.interclub_tegenstanders t
                   where t.match_id = s.match_id and t.ploeg_id = s.ploeg_id and t.soort = s.soort and t.nr = s.nr)) x
      from public.interclub_spelers s
      left join lateral (select l.naam from public.leden l where l.speler_id = s.speler_id order by l.jaar desc limit 1) l on true
      where s.match_id = p_match_id and s.ploeg_id = p_ploeg_id
      group by s.match_id, s.ploeg_id, s.soort, s.nr) q), '[]'::jsonb));
end $$;
revoke all on function public.club_ic_ontmoeting(text, int, int) from public;
grant execute on function public.club_ic_ontmoeting(text, int, int) to anon, authenticated;
