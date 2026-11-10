-- 03_Competitie – Simulator interclubbijdrage (pagina commissie/interclubbijdrage/)
-- Levert per padelseizoen (de laatste 4 met wedstrijden) het aantal ploegen met 2 en met 3+ thuismatchen
-- in de poule, het totaal aan poulethuismatchen en de thuismatchen in de eindronde, plus de groepstarieven
-- van de lessen. Enkel aantallen, geen namen. Toegang: padelcommissie en bestuur (clublogin).

create or replace function public.club_ic_bijdrage_data(p_token text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare me int := club.sessie(p_token);
begin
  if me is null then return jsonb_build_object('fout', 'niet aangemeld'); end if;
  if not club.heeft(me, array['commissie','bestuur']) then
    return jsonb_build_object('fout', 'enkel voor de padelcommissie');
  end if;

  return jsonb_build_object(
    'seizoenen', (
      with per as (
        select p.periode_id, p.seizoen, p.jaar
        from public.periodes p
        where p.sport_id = 2
          and exists (select 1 from public.wedstrijden w where w.periode_id = p.periode_id)
        order by p.jaar desc, case p.seizoen when 'Najaar' then 2 else 1 end desc
        limit 4
      ),
      pl as (
        select pg.periode_id, pg.ploeg_id,
               count(*) filter (where w.thuis_ploeg_id = pg.ploeg_id and w.ronde like 'poule%')     as poule_thuis,
               count(*) filter (where w.thuis_ploeg_id = pg.ploeg_id and w.ronde not like 'poule%') as eind_thuis
        from public.ploegen pg
        join per on per.periode_id = pg.periode_id
        left join public.wedstrijden w
          on w.periode_id = pg.periode_id and (w.thuis_ploeg_id = pg.ploeg_id or w.uit_ploeg_id = pg.ploeg_id)
        group by pg.periode_id, pg.ploeg_id
      )
      select coalesce(jsonb_agg(s order by (s->>'jaar')::int, (s->>'volg')::int), '[]'::jsonb)
      from (
        select jsonb_build_object(
                 'naam', per.seizoen || ' ' || per.jaar, 'jaar', per.jaar,
                 'volg', case per.seizoen when 'Najaar' then 2 else 1 end,
                 'n2', count(pl.ploeg_id) filter (where pl.poule_thuis <= 2),
                 'n3', count(pl.ploeg_id) filter (where pl.poule_thuis >= 3),
                 'poule', coalesce(sum(pl.poule_thuis), 0),
                 'eind', coalesce(sum(pl.eind_thuis), 0)) s
        from per left join pl on pl.periode_id = per.periode_id
        group by per.periode_id, per.seizoen, per.jaar
      ) q
    ),
    'lestarief', (select coalesce(jsonb_object_agg(t.duur::text, t.prijs), '{}'::jsonb) from club.les_tarieven t where t.soort = 'groep'),
    'stand', (select to_char(max(w.bijgewerkt), 'YYYY-MM-DD') from public.wedstrijden w)
  );
end;
$$;

revoke all on function public.club_ic_bijdrage_data(text) from public;
grant execute on function public.club_ic_bijdrage_data(text) to anon, authenticated;
