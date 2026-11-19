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
