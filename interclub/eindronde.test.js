// node interclub/eindronde.test.js
// Toets van de thuisregel op de 6 eindtabellen van de voorjaarsinterclub 2026 met BTC-ploegen
// (uit public.eindronde_tabel, 22/11/2026; enkel ploeg-id's). Elke rij: ronde,positie,a,b,plaats_a,plaats_b,thuis,winnaar,gespeeld.
'use strict';
const E = require('./eindronde.js');
const fs = require('fs');
const regels = fs.readFileSync(__dirname + '/eindronde.test.data', 'utf8').trim().split('\n');
const n = v => v === '' ? null : Number(v);
let ok = 0, fout = 0, r1 = 0, rN = 0;
for (const regel of regels) {
  const [id, d] = regel.split('|');
  const rondes = [];
  d.split(';').forEach(x => {
    const [r, p, a, b, pa, pb, thuis, w, g] = x.split(',');
    (rondes[r - 1] = rondes[r - 1] || [])[p] = { a: n(a), b: n(b), poule_a: n(pa), poule_b: n(pb),
      thuis: thuis || null, winnaar: n(w), gespeeld: g === '1' };
  });
  for (const u of E.toets({ rondes })) {
    u.ok ? ok++ : (fout++, console.log('fout', id, u));
    u.ronde === 0 ? r1++ : rN++;
  }
  // Vooruitzicht na ronde 1 voor elke ploeg die ronde 2 speelde: de berekening moet altijd de
  // werkelijke thuis/uit van ronde 2 als zeker geven (enkel de ronde-1-uitslagen gekend).
  const tabel = { rondes: rondes.map((ronde, r) => ronde.map(m => r === 0 ? m
    : { a: null, b: null, thuis: null, winnaar: null, gespeeld: false })) };
  for (const [p, m] of rondes[1].entries()) for (const [kant, ploeg] of [['a', m.a], ['b', m.b]]) {
    const v = E.vooruitzicht(tabel, ploeg)[1];
    const verwacht = m.thuis === kant ? 1 : 0;
    if (v.kansThuis !== verwacht) { fout++; console.log('fout vooruitzicht', id, p, ploeg, v.kansThuis, verwacht); } else ok++;
  }
}
console.log(`ronde 1: ${r1}, volgende rondes: ${rN}, vooruitzicht ronde 2 meegeteld; ok ${ok}, fout ${fout}`);
process.exit(fout ? 1 : 0);
