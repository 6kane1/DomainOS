/* Domain OS site · site: scroll progress + chart scan width. No libraries. */
(function(){
  var bar=document.querySelector('.progress'),ticking=false;
  function upd(){ticking=false;var h=document.documentElement,max=h.scrollHeight-h.clientHeight;
    if(bar)bar.style.transform='scaleX('+(max>0?Math.min(1,h.scrollTop/max):0)+')';}
  window.addEventListener('scroll',function(){if(!ticking){ticking=true;requestAnimationFrame(upd);}},{passive:true});
  function sizeScan(){document.querySelectorAll('.chart').forEach(function(c){c.style.setProperty('--scan-w',c.clientWidth+'px');});}
  window.addEventListener('resize',sizeScan);sizeScan();upd();
  /* stop the scan line when the chart is off screen */
  if('IntersectionObserver' in window){var io=new IntersectionObserver(function(es){es.forEach(function(e){
    var s=e.target.querySelector('.scan');if(s)s.style.animationPlayState=e.isIntersecting?'running':'paused';});});
    document.querySelectorAll('.chart').forEach(function(c){io.observe(c);});}
})();

// What's new: the key lists of the two panels get the same height, so both "All changes" buttons sit on one line.
// Each panel still opens on its own (the grid aligns panels to the top).
(function () {
  function even() {
    document.querySelectorAll('.newgrid:not(.one)').forEach(function (g) {
      var ls = g.querySelectorAll('.keyl');
      ls.forEach(function (l) { l.style.minHeight = ''; });
      if (getComputedStyle(g).gridTemplateColumns.split(' ').length < 2) return;
      var h = 0; ls.forEach(function (l) { h = Math.max(h, l.offsetHeight); });
      ls.forEach(function (l) { l.style.minHeight = h + 'px'; });
    });
  }
  window.addEventListener('resize', even);
  if (document.fonts && document.fonts.ready) document.fonts.ready.then(even);
  even();
})();

// Narrow screens: the page links scroll inside the header; show the link of the open page.
(function () {
  var cur = document.querySelector('.nav a[aria-current="page"]');
  var nav = cur && cur.parentElement;
  if (nav && nav.scrollWidth > nav.clientWidth) nav.scrollLeft = cur.offsetLeft - (nav.clientWidth - cur.offsetWidth) / 2;
})();

// 27.11.2026: hints for technical words (first mention on the page; hover, focus or tap shows a short explanation)
(function () {
  var ru = (document.documentElement.lang || '').indexOf('ru') === 0;
  var T = ru ? [
    [/AME Wizard/, 'Бесплатная программа, которая ставит плейбук: применяет его настройки к Windows по шагам.'],
    [/плейбук/i, 'Набор настроек Windows в одном файле .apbx. Его открывают в AME Wizard.'],
    [/1% low/, 'FPS самого медленного 1% кадров. Чем выше, тем меньше заметных просадок.'],
    [/DPC/, 'Короткие задачи драйверов. Если они затягиваются, игра ловит рывки.'],
    [/HAGS/, 'Аппаратное планирование видеокарты: она сама ведёт свою очередь задач.'],
    [/телеметри/i, 'Данные о работе ПК, которые Windows отправляет в Microsoft.']
  ] : [
    [/AME Wizard/, 'A free program that installs the playbook: it applies its settings to Windows step by step.'],
    [/playbook/i, 'A set of Windows settings in one .apbx file. You open it in AME Wizard.'],
    [/1% low/, 'The FPS of the slowest 1% of frames. Higher means fewer visible drops.'],
    [/DPC/, 'Short driver jobs. When they run long, the game stutters.'],
    [/HAGS/, 'Hardware-accelerated GPU scheduling: the graphics card runs its own work queue.'],
    [/telemetry/i, 'Data about how the PC works that Windows sends to Microsoft.']
  ];
  var main = document.querySelector('main') || document.body;
  T.forEach(function (t) {
    var w = document.createTreeWalker(main, NodeFilter.SHOW_TEXT, { acceptNode: function (n) {
      var p = n.parentElement;
      if (!p || p.closest('a,code,pre,button,h1,h2,h3,.gl,script,style,svg,.btn,nav,summary,.dz-open,.kicker,.label,.cap,.meta,.k,.tag')) return NodeFilter.FILTER_REJECT;
      return t[0].test(n.nodeValue) ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_SKIP;
    } });
    var n = w.nextNode(); if (!n) return;
    var m = n.nodeValue.match(t[0]), after = n.splitText(m.index); after.splitText(m[0].length);
    var s = document.createElement('span'); s.className = 'gl'; s.tabIndex = 0; s.setAttribute('data-tip', t[1]); s.setAttribute('aria-label', m[0] + ': ' + t[1]);
    s.textContent = m[0]; after.parentNode.replaceChild(s, after);
  });
})();

// 27.11.2026: extra details live in slide-out panels. The page keeps the heading, the short text and a "More" button.
// Without JavaScript the sections stay open as before. A link to the section (or to anything inside it) opens its panel.
(function () {
  var ru = (document.documentElement.lang || '').indexOf('ru') === 0;
  var secs = document.querySelectorAll('section.dz'); if (!secs.length) return;
  var R = document.documentElement, scrim = document.createElement('div'); scrim.className = 'dz-scrim'; document.body.appendChild(scrim);
  var open = null, back = null, panels = {};
  function close() {
    if (!open) return; open.classList.remove('on'); open.setAttribute('aria-hidden', 'true'); R.classList.remove('dz-on');
    open = null; if (back) back.focus({ preventScroll: true });
  }
  function show(id, from) {
    var p = panels[id]; if (!p) return false; if (open && open !== p) close();
    back = from || document.activeElement; open = p; p.classList.add('on'); p.removeAttribute('aria-hidden'); R.classList.add('dz-on');
    p.querySelector('.dz-body').scrollTop = 0; setTimeout(function () { p.querySelector('.dz-x').focus({ preventScroll: true }); }, 60);
    window.dispatchEvent(new Event('resize')); return true;
  }
  secs.forEach(function (sec) {
    var wrap = sec.querySelector('.wrap'), sh = wrap && wrap.querySelector('.sh'); if (!sh) return;
    var h2 = sh.querySelector('h2'), lead = sh.querySelector('p'), id = sec.id;
    var p = document.createElement('aside'); p.className = 'dz-panel'; p.setAttribute('role', 'dialog'); p.setAttribute('aria-modal', 'true');
    p.setAttribute('aria-hidden', 'true'); p.setAttribute('aria-label', h2 ? h2.textContent : id);
    p.innerHTML = '<div class="dz-head"><h2></h2><button type="button" class="dz-x" aria-label="' + (ru ? 'Закрыть' : 'Close') + '">×</button></div><div class="dz-body"></div>';
    p.querySelector('h2').textContent = h2 ? h2.textContent : '';
    var body = p.querySelector('.dz-body'), kids = Array.prototype.slice.call(wrap.children);
    kids.forEach(function (k) { if (k !== sh) body.appendChild(k); });
    if (lead) { var lc = lead.cloneNode(true); lc.className = 'dz-lead'; body.insertBefore(lc, body.firstChild); }
    document.body.appendChild(p); panels[id] = p;
    var t = document.createElement('div'); t.className = 'dz-teaser';
    var tp = document.createElement('p'); tp.textContent = lead ? lead.textContent : '';
    var b = document.createElement('button'); b.type = 'button'; b.className = 'dz-open'; b.innerHTML = (ru ? 'Подробнее' : 'Details') + ' <i>→</i>';
    b.setAttribute('aria-haspopup', 'dialog'); b.addEventListener('click', function () { show(id, b); });
    if (lead) lead.remove(); t.appendChild(tp); t.appendChild(b); wrap.appendChild(t);
    p.querySelector('.dz-x').addEventListener('click', close);
    // ids inside the panel point at the panel too
    p.querySelectorAll('[id]').forEach(function (el) { panels[el.id] = p; });
  });
  scrim.addEventListener('click', close);
  document.addEventListener('keydown', function (e) {
    if (!open) return;
    if (e.key === 'Escape') { close(); return; }
    if (e.key === 'Tab') { var f = open.querySelectorAll('a[href],button,summary,[tabindex="0"]'); if (!f.length) return;
      var a = f[0], z = f[f.length - 1];
      if (e.shiftKey && document.activeElement === a) { e.preventDefault(); z.focus(); } else if (!e.shiftKey && document.activeElement === z) { e.preventDefault(); a.focus(); } }
  });
  function fromHash() {
    var id = decodeURIComponent((location.hash || '').slice(1)), p = panels[id]; if (!p) return;
    show(id); var el = document.getElementById(id);
    if (el && p.contains(el)) setTimeout(function () { el.scrollIntoView({ block: 'start' }); }, 450);
  }
  // a second click on the same link does not change the hash, so links open the panel directly too
  document.addEventListener('click', function (e) {
    var a = e.target.closest && e.target.closest('a[href^="#"]'); if (!a) return;
    var id = decodeURIComponent(a.getAttribute('href').slice(1));
    if (panels[id] && location.hash === '#' + id) { e.preventDefault(); fromHash(); }
  });
  window.addEventListener('hashchange', fromHash); fromHash();
})();
