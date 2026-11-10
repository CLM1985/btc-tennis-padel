-- =====================================================================
-- Clublogin – gebruiksrapport per lid (10/11/2026, vervolg op 01_Governance_Clublogin_gebruik.sql)
-- club_beheer_gebruik krijgt een vierde parameter p_speler: het hele rapport voor één lid.
-- Leden en niet-actieve leden krijgen hun speler_id mee zodat de pagina erop kan filteren.
-- Enkel beheerders. Geen nieuwe gegevens, geen tabelwijziging.
-- =====================================================================

drop function if exists public.club_beheer_gebruik(text, date, date);

create or replace function public.club_beheer_gebruik(p_token text, p_van date default null, p_tot date default null, p_speler integer default null)
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
  g as (select * from club.gebruik where dag between v_van and v_tot and (p_speler is null or speler_id = p_speler)),
  b as (select * from g where pagina <> 'aanmelding'),
  vb as (select * from club.gebruik where dag between v_vvan and v_vtot and pagina <> 'aanmelding' and (p_speler is null or speler_id = p_speler)),
  codes as (select t.speler_id from club.toegang t join club.v_lid l using (speler_id)),
  rolset as (
    select speler_id, rol from club.rollen where speler_id in (select speler_id from codes)
    union select distinct speler_id, 'kapitein' from club.v_kapiteins where speler_id in (select speler_id from codes)
  )
  select jsonb_build_object(
    'van', v_van, 'tot', v_tot, 'dagen', v_dagen, 'vorige_van', v_vvan, 'vorige_tot', v_vtot,
    'eerste_meting', (select min(dag) from club.gebruik),
    'lid', case when p_speler is null then null else jsonb_build_object(
      'speler_id', p_speler, 'naam', club.naam(p_speler),
      'rollen', coalesce((select jsonb_agg(rol order by rol) from rolset where speler_id = p_speler), '[]'),
      'heeft_code', exists (select 1 from codes where speler_id = p_speler),
      'eerst_actief', (select min(eerste) from club.gebruik where speler_id = p_speler and pagina <> 'aanmelding'),
      'laatst_actief', (select max(laatste) from club.gebruik where speler_id = p_speler and pagina <> 'aanmelding'),
      'actieve_dagen', (select count(distinct dag) from b),
      'aanmeldingen_totaal', (select coalesce(sum(aantal), 0) from club.gebruik where speler_id = p_speler and pagina = 'aanmelding')) end,
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
    'leden', (select coalesce(jsonb_agg(jsonb_build_object('speler_id', speler_id, 'naam', club.naam(speler_id), 'laatst', laatst, 'dagen', dagen, 'bezoeken', bezoeken,
                 'pagina', (select pagina from b b3 where b3.speler_id = x.speler_id group by pagina order by sum(aantal) desc, pagina limit 1))
                 order by laatst desc), '[]')
               from (select speler_id, max(laatste) laatst, count(distinct dag) dagen, sum(aantal) bezoeken from b group by speler_id) x),
    'niet_actief', (select coalesce(jsonb_agg(jsonb_build_object('speler_id', c.speler_id, 'naam', club.naam(c.speler_id),
                       'laatst', (select max(laatste) from club.gebruik u where u.speler_id = c.speler_id and u.pagina <> 'aanmelding'))
                       order by club.naam(c.speler_id)), '[]')
                     from codes c where p_speler is null and not exists (select 1 from b where b.speler_id = c.speler_id))
  ) into r;
  return r;
end $function$;
revoke all on function public.club_beheer_gebruik(text, date, date, integer) from public;
grant execute on function public.club_beheer_gebruik(text, date, date, integer) to anon, authenticated;
