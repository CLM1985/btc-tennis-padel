// Thuisploeg in de eindronde van de padelinterclub (Tennis en Padel Vlaanderen, art. 7.3.2.2)
// en de kans dat een ploeg in een volgende ronde thuis speelt.
//
// Regel:
//  - Ronde 1: thuis = poulewinnaar (staat al in de tabel als (T)/(U)).
//  - Volgende rondes: thuis = ploeg met de meeste uitwedstrijden in de eindronde. Een ploeg die
//    in ronde 1 vrij was, telt die ronde als thuis (0 uit).
//  - Gelijk: de eerst uitgelote ploeg. Volgorde: ploegen die ronde 1 speelden, van boven naar
//    beneden in de tabel; daarna de ploegen die in ronde 1 vrij waren, van boven naar beneden.
//  - Een thuis/uit die al in de tabel staat (gespeeld of gepland door TV) gaat altijd voor.
//
// Tabel = { rondes: [ [ {a, b, thuis, winnaar, gespeeld}, ... ], ... ] }
//   ronde 0 = eerste ronde; match p in ronde r wordt gevoed door matchen 2p (a) en 2p+1 (b) van r-1.
//   a/b = ploeg_id of null (vrij of nog onbekend); thuis = 'a' | 'b' | null; winnaar = ploeg_id | null.
// Kansen per wedstrijd: standaard 50/50; kans(x, y) geeft de kans dat x wint (optioneel).
(function (root) {
  'use strict';

  // Volgorde voor gelijkstand: lager = eerder uitgeloot.
  function volgorde(tabel) {
    const r1 = tabel.rondes[0] || [];
    const spelers = [], vrij = [];
    r1.forEach(m => {
      const beide = m.a != null && m.b != null;
      [m.a, m.b].forEach(x => { if (x != null) (beide ? spelers : vrij).push(x); });
    });
    const rang = new Map();
    spelers.concat(vrij).forEach((x, i) => rang.set(x, i));
    return rang;
  }

  // Thuisploeg volgens het reglement, gegeven het aantal uitwedstrijden van beide.
  function thuisVolgensRegel(x, ux, y, uy, rang) {
    if (ux !== uy) return ux > uy ? x : y;
    const rx = rang.has(x) ? rang.get(x) : 1e9, ry = rang.has(y) ? rang.get(y) : 1e9;
    return rx <= ry ? x : y;
  }

  // Werkelijke uitwedstrijden per ploeg vóór ronde r (uit de tabel).
  function uitTot(tabel, r) {
    const uit = new Map();
    for (let i = 0; i < r; i++) for (const m of tabel.rondes[i] || []) {
      if (m.a == null || m.b == null || !m.thuis) continue;
      const u = m.thuis === 'a' ? m.b : m.a;
      uit.set(u, (uit.get(u) || 0) + 1);
    }
    return uit;
  }

  // Controle: voorspelling voor elke match vanaf ronde 2 met beide ploegen en een gekende thuis.
  function toets(tabel) {
    const rang = volgorde(tabel), uitkomst = [];
    tabel.rondes.forEach((ronde, r) => ronde.forEach((m, p) => {
      if (m.a == null || m.b == null || !m.thuis) return;
      const echt = m.thuis === 'a' ? m.a : m.b;
      let voorspeld;
      if (r === 0) {
        if (m.poule_a === m.poule_b) return;              // twee winnaars of twee tweedes: geen regel
        voorspeld = m.poule_a < m.poule_b ? m.a : m.b;    // plaats 1 tegen plaats 2
      } else {
        const uit = uitTot(tabel, r);
        voorspeld = thuisVolgensRegel(m.a, uit.get(m.a) || 0, m.b, uit.get(m.b) || 0, rang);
      }
      uitkomst.push({ ronde: r, positie: p, a: m.a, b: m.b, echt, voorspeld, ok: echt === voorspeld });
    }));
    return uitkomst;
  }

  // Verdeling van (winnaar, aantal uit) uit de knoop (r, p): Map "id|uit" -> kans.
  // dwing = ploeg die voorwaardelijk altijd wint in haar pad (de eigen ploeg), of null.
  function verdeling(tabel, r, p, rang, kans, dwing, cache) {
    const sleutel = r + ':' + p;
    if (cache.has(sleutel)) return cache.get(sleutel);
    const m = (tabel.rondes[r] || [])[p] || {};
    let L, R;
    if (r === 0) {
      L = m.a != null ? new Map([[m.a + '|0', 1]]) : new Map();
      R = m.b != null ? new Map([[m.b + '|0', 1]]) : new Map();
    } else {
      L = verdeling(tabel, r - 1, 2 * p, rang, kans, dwing, cache);
      R = verdeling(tabel, r - 1, 2 * p + 1, rang, kans, dwing, cache);
      // Staat een ploeg al vast in de tabel, dan geldt die (bv. na een gespeelde vorige ronde).
      if (m.a != null) L = vastzetten(L, m.a);
      if (m.b != null) R = vastzetten(R, m.b);
    }
    const uit = new Map();
    const voeg = (id, u, w) => { const k = id + '|' + u; uit.set(k, (uit.get(k) || 0) + w); };
    if (L.size === 0 || R.size === 0) {                   // vrij: de enige ploeg gaat door, telt als thuis
      for (const [k, w] of (L.size ? L : R)) { const [id, u] = splits(k); voeg(id, u, w); }
    } else {
      for (const [kx, wx] of L) for (const [ky, wy] of R) {
        const [x, ux] = splits(kx), [y, uy] = splits(ky);
        const thuis = m.thuis && m.a === x && m.b === y ? (m.thuis === 'a' ? x : y)
                    : thuisVolgensRegel(x, ux, y, uy, rang);
        const nx = ux + (thuis === x ? 0 : 1), ny = uy + (thuis === y ? 0 : 1);
        let px;
        if (m.winnaar != null && (m.winnaar === x || m.winnaar === y)) px = m.winnaar === x ? 1 : 0;
        else if (dwing === x) px = 1; else if (dwing === y) px = 0;
        else px = kans ? kans(x, y) : 0.5;
        if (px > 0) voeg(x, nx, wx * wy * px);
        if (px < 1) voeg(y, ny, wx * wy * (1 - px));
      }
    }
    cache.set(sleutel, uit);
    return uit;
  }

  function splits(k) { const i = k.lastIndexOf('|'); return [Number(k.slice(0, i)), Number(k.slice(i + 1))]; }

  function vastzetten(verd, id) {
    let tot = 0; const uit = new Map();
    for (const [k, w] of verd) if (splits(k)[0] === id) { uit.set(k, w); tot += w; }
    if (tot === 0) return new Map([[id + '|0', 1]]);
    for (const [k, w] of uit) uit.set(k, w / tot);
    return uit;
  }

  // Waar zit de ploeg in ronde 1 (positie, kant)?
  function startpositie(tabel, ploeg) {
    const r1 = tabel.rondes[0] || [];
    for (let p = 0; p < r1.length; p++) {
      if (r1[p].a === ploeg) return p;
      if (r1[p].b === ploeg) return p;
    }
    return -1;
  }

  // Per ronde vanaf de huidige: kans thuis (als de ploeg die ronde haalt) en de scenario's.
  function vooruitzicht(tabel, ploeg, opties) {
    const kans = opties && opties.kans;
    const rang = volgorde(tabel);
    const p0 = startpositie(tabel, ploeg);
    if (p0 < 0) return [];
    const res = [];
    for (let r = 0, p = p0; r < tabel.rondes.length; r++, p = Math.floor(p / 2)) {
      const m = tabel.rondes[r][p];
      if (!m) break;
      const eigenKant = r === 0 ? (m.a === ploeg ? 'a' : 'b') : ((p0 >> (r - 1)) % 2 === 0 ? 'a' : 'b');
      const item = { ronde: r, positie: p, gespeeld: !!m.gespeeld };
      const tegenstanderBekend = eigenKant === 'a' ? m.b : m.a;
      if (m.thuis && m[eigenKant] === ploeg) {
        item.bron = 'tabel'; item.kansThuis = m.thuis === eigenKant ? 1 : 0;
        item.tegenstander = tegenstanderBekend; item.scenarios = [];
      } else if (r === 0) {
        item.bron = 'vrij'; item.kansThuis = null; item.scenarios = [];
      } else {
        const cacheEigen = new Map(), cacheAnder = new Map();
        const eigenR = r - 1, eigenP = eigenKant === 'a' ? 2 * p : 2 * p + 1;
        const eigen = vastzetten(verdeling(tabel, eigenR, eigenP, rang, kans, ploeg, cacheEigen), ploeg);
        const ander = verdeling(tabel, eigenR, eigenKant === 'a' ? 2 * p + 1 : 2 * p, rang, kans, null, cacheAnder);
        let thuis = 0, tot = 0;
        const perTegenstander = new Map();
        if (ander.size === 0) { item.bron = 'vrij'; item.kansThuis = null; item.scenarios = []; res.push(item); continue; }
        for (const [ke, we] of eigen) for (const [ka, wa] of ander) {
          const [, ue] = splits(ke), [y, uy] = splits(ka);
          const h = thuisVolgensRegel(ploeg, ue, y, uy, rang) === ploeg;
          const w = we * wa; tot += w; if (h) thuis += w;
          const s = perTegenstander.get(y) || { tegenstander: y, kans: 0, thuis: 0, eigenUit: new Set(), uitTegen: new Set() };
          s.kans += w; if (h) s.thuis += w; s.eigenUit.add(ue); s.uitTegen.add(uy);
          perTegenstander.set(y, s);
        }
        item.bron = 'berekend';
        item.kansThuis = tot ? thuis / tot : null;
        item.scenarios = [...perTegenstander.values()].map(s => ({
          tegenstander: s.tegenstander, kans: s.kans / tot, kansThuis: s.kans ? s.thuis / s.kans : 0,
          eigenUit: [...s.eigenUit].sort(), uitTegenstander: [...s.uitTegen].sort(),
          vroegerUitgeloot: rang.get(ploeg) < (rang.has(s.tegenstander) ? rang.get(s.tegenstander) : 1e9),
        })).sort((a, b) => b.kans - a.kans);
      }
      res.push(item);
      // Verloren (gespeeld, of gekozen in wat-als): de volgende rondes vallen weg.
      if (m.winnaar != null && m.winnaar !== ploeg && (m.a === ploeg || m.b === ploeg)) {
        item.uitgeschakeld = true; item.watAls = !m.gespeeld; break;
      }
    }
    return res;
  }

  const api = { volgorde, thuisVolgensRegel, uitTot, toets, vooruitzicht };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  else root.Eindronde = api;
})(typeof window !== 'undefined' ? window : globalThis);
