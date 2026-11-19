// Runs the inline scripts of a Domain OS page (whats-new.html, guide.html) in node with a small fake DOM and prints
// what the page rendered as JSON: {ok, error, html: {id: innerHTML}, text: {id: textContent}, lang, clicks}.
//   node run-page.js <file.html> [navigatorLanguage] [action ...]
// Actions: "lang:ru" clicks the language button, "click:<n>" clicks the n-th [data-id] button (guide steps).
'use strict';
const fs = require('fs'), vm = require('vm');
const [file, navLang = 'en-US', ...actions] = process.argv.slice(2);
const html = fs.readFileSync(file, 'utf8');
const scripts = [...html.matchAll(/<script(\s[^>]*)?>([\s\S]*?)<\/script>/g)].filter(m => !/\bsrc=/.test(m[1] || '')).map(m => m[2]);

function el(id) {
  const e = { id, innerHTML: '', textContent: '', style: {}, dataset: {}, onclick: null,
    classList: { set: new Set(), toggle(c, on) { if (on === undefined ? !this.set.has(c) : on) this.set.add(c); else this.set.delete(c); }, contains(c) { return this.set.has(c); } } };
  return e;
}
const ids = {};
for (const m of html.matchAll(/\bid="([^"]+)"/g)) ids[m[1]] = el(m[1]);
const langButtons = [...html.matchAll(/<button data-l="([^"]+)">/g)].map(m => { const b = el(''); b.dataset.l = m[1]; return b; });
let dataButtons = [];
const storage = {};
const document = {
  documentElement: { lang: '' },
  getElementById(id) { if (!ids[id]) throw new Error('getElementById("' + id + '"): no such element in the page'); return ids[id]; },
  querySelectorAll(sel) {
    if (sel === '.lang button') return langButtons;
    if (sel === '[data-id]') {
      const src = Object.values(ids).map(e => e.innerHTML).join('\n');
      dataButtons = [...src.matchAll(/data-id="([^"]*)"/g)].map(m => { const b = el(''); b.dataset.id = m[1].replace(/&quot;/g, '"').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&amp;/g, '&'); return b; });
      return dataButtons;
    }
    throw new Error('querySelectorAll("' + sel + '") is not faked');
  },
};
const ctx = {
  document, navigator: { language: navLang }, console,
  localStorage: { getItem: k => (k in storage ? storage[k] : null), setItem: (k, v) => { storage[k] = String(v); } },
  requestAnimationFrame: f => f(), window: {},
};
vm.createContext(ctx);
const out = { ok: true, error: null, scripts: scripts.length, clicks: [] };
try {
  for (const s of scripts) vm.runInContext(s, ctx, { filename: file, timeout: 5000 });
  for (const a of actions) {
    if (a.startsWith('lang:')) { const b = langButtons.find(x => x.dataset.l === a.slice(5)); if (!b) throw new Error('no language button ' + a); b.onclick(); }
    else if (a.startsWith('click:')) { const b = dataButtons[+a.slice(6)]; if (!b || !b.onclick) throw new Error('no clickable step ' + a); b.onclick(); out.clicks.push(b.dataset.id); }
  }
} catch (e) { out.ok = false; out.error = String(e && e.stack || e); }
out.lang = document.documentElement.lang;
out.html = {}; out.text = {};
for (const [k, v] of Object.entries(ids)) { out.html[k] = v.innerHTML; out.text[k] = v.textContent; out[`style_${k}`] = v.style; }
out.storage = storage;
out.langOn = langButtons.filter(b => b.classList.contains('on')).map(b => b.dataset.l);
process.stdout.write(JSON.stringify(out));
