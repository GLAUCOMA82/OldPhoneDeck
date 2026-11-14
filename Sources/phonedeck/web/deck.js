/* PhoneDeck deck renderer, shared by every device and by the Mac's Command Center preview.
   MUST stay ES5 (the iPhone 4S runs iOS 9 Safari): no let/const, arrows, template strings,
   for-of, Array#find/includes, Element#closest or NodeList#forEach.

   Layout model (stored on the Mac, edited in the Command Center):
     layout.devices[kind] = { density, labels, dock: { on, items }, pages: [{ id, name, icon, shortcut, items }] }
     item = { t: 'app', path, name } | { t: 'claude' } | { t: 'action', a } | { t: 'w', w: widget, s: 's'|'m'|'l' }
   Pages are grids of cells (one cell = one app key). Widgets come in four sizes:
     Small 2×1 (a glanceable strip), Bar 4×1 (a full-width strip), Medium 2×2 (a square), Large 4×2 (the full widget).
   Items flow into the grid in order, each taking the first free spot that fits. */
(function (root) {
  'use strict';
  var PD = root.PD = {};

  // ---------------------------------------------------------------- helpers
  function el(tag, cls, html) {
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    if (html !== undefined) e.innerHTML = html;
    return e;
  }
  function q(node, sel) { return node.querySelector(sel); }
  function esc(s) { return String(s === undefined || s === null ? '' : s).replace(/[&<>"]/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]; }); }
  function each(list, fn) { for (var i = 0; i < list.length; i++) fn(list[i], i); }
  function find(list, fn) { for (var i = 0; i < list.length; i++) if (fn(list[i], i)) return list[i]; return null; }
  function closest(node, attr, stop) {
    while (node && node !== stop && node.nodeType === 1) { if (node.getAttribute(attr) !== null) return node; node = node.parentNode; }
    return null;
  }
  function px(e, props) { for (var k in props) e.style[k] = Math.round(props[k]) + 'px'; }
  function store(k, v) { try { if (v === undefined) return localStorage.getItem(k); localStorage.setItem(k, v); } catch (e) { return null; } }
  function uid() { return Math.random().toString(36).slice(2, 9); }
  function clone(o) { return JSON.parse(JSON.stringify(o)); }
  function fmt(n) { return n >= 100 ? Math.round(n) : n >= 10 ? n.toFixed(0) : n.toFixed(1); }
  function mmss(s) { s = Math.max(0, Math.floor(s)); return Math.floor(s / 60) + ':' + ('0' + s % 60).slice(-2); }
  function ago(ms) {
    var s = Math.round((Date.now() - ms) / 1000);
    return s < 60 ? 'now' : s < 3600 ? Math.round(s / 60) + 'm' : s < 86400 ? Math.round(s / 3600) + 'h' : Math.round(s / 86400) + 'd';
  }
  var SVG_ATTR = ' viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"';
  function icon(path) { return '<svg' + SVG_ATTR + '>' + path + '</svg>'; }
  PD.esc = esc; PD.clone = clone; PD.uid = uid;

  // Tap: instant on touch (no 300 ms delay), works with a mouse, pressed state, optional hold.
  function tap(node, fn, hold) {
    var moved, held, timer, sx, sy;
    function unpress() { node.className = node.className.replace(/ down/g, ''); }
    node.addEventListener('touchstart', function (e) {
      moved = false; held = false; sx = e.touches[0].clientX; sy = e.touches[0].clientY;
      node.className += ' down';
      if (hold) timer = setTimeout(function () { held = true; unpress(); hold(e); }, 550);
    });
    node.addEventListener('touchmove', function (e) {
      if (Math.abs(e.touches[0].clientX - sx) + Math.abs(e.touches[0].clientY - sy) > 10) { moved = true; clearTimeout(timer); unpress(); }
    });
    node.addEventListener('touchend', function (e) {
      e.preventDefault(); clearTimeout(timer); unpress();
      if (!moved && !held) fn(e);
    });
    node.addEventListener('touchcancel', function () { clearTimeout(timer); unpress(); });
    node.addEventListener('click', function (e) { fn(e); });
  }
  PD.tap = tap;

  // ---------------------------------------------------------------- API
  var api = PD.api = {
    token: null,
    url: function (path, extra) { return path + '?k=' + api.token + (extra ? '&' + extra : ''); },
    req: function (method, path, body, cb, type) {
      var r = new XMLHttpRequest();
      r.open(method, path, true);
      if (body !== null && body !== undefined) r.setRequestHeader('Content-Type', type || 'application/x-www-form-urlencoded');
      r.onload = function () { if (cb) cb(r.status, r.responseText); };
      r.onerror = function () { if (cb) cb(0, ''); };
      r.send(body === undefined ? null : body);
    },
    get: function (path, extra, cb) { api.req('GET', api.url(path, extra), null, cb); },
    post: function (path, params, cb) {
      var parts = [];
      for (var k in params) parts.push(k + '=' + encodeURIComponent(params[k]));
      api.req('POST', api.url(path), parts.join('&'), cb);
    },
    json: function (path, extra, cb) {
      api.get(path, extra, function (s, t) { var j = null; try { j = s === 200 ? JSON.parse(t) : null; } catch (e) {} cb(j, s); });
    }
  };

  // ---------------------------------------------------------------- devices
  // stageH: logical height the deck is designed at (0 = native pixels). grid: [cols, rows] per density.
  var PROFILES = PD.PROFILES = {
    classic: { name: 'iPhone 4S', stageH: 320, minW: 480, maxW: 480, header: 42, foot: 4, pad: 12, gap: 8, font: 13, dotsInHeader: true,
               grid: { comfortable: [4, 3], compact: [5, 3] }, fx: false, tabs: false, dockH: 0, preview: [480, 320] },
    phone:   { name: 'iPhone 17', stageH: 320, minW: 480, maxW: 760, header: 46, foot: 16, pad: 16, gap: 8, font: 13,
               grid: { comfortable: [7, 3], compact: [8, 3] }, fx: true, tabs: true, dockH: 0, preview: [640, 320] },
    tablet:  { name: 'iPad mini', stageH: 0, minW: 900, maxW: 4000, header: 62, foot: 20, pad: 24, gap: 14, font: 16,
               grid: { comfortable: [6, 4], compact: [8, 4] }, fx: true, tabs: true, dockH: 104, preview: [1133, 744] }
  };
  PD.SIZES = { s: [2, 1], m: [2, 2], l: [4, 2], w: [4, 1], t: [2, 4] };   // Tall is clamped to the grid's height
  PD.SIZE_NAMES = { s: 'Small', m: 'Medium', l: 'Large', w: 'Bar', t: 'Tall' };
  PD.SIZE_ORDER = ['s', 'w', 'm', 't', 'l'];

  // Widget catalog (the Command Center lists these). modern: needs a recent iPhone/iPad (HTTPS camera).
  PD.WIDGETS = {
    clock:         { label: 'Clock', g: 'clock', tint: '#FF9230', sizes: 'swml', desc: 'Time and date; Large adds the weather.' },
    weather:       { label: 'Weather', g: 'cloudsun', tint: '#0091FF', sizes: 'swml', desc: 'Current conditions, high and low.' },
    calendar:      { label: 'Calendar', g: 'calendar', tint: '#FF4245', sizes: 'swmtl', desc: 'Your next events from the Mac calendar.' },
    music:         { label: 'Now Playing', g: 'music', tint: '#FF375F', sizes: 'swml', desc: 'Spotify or Apple Music with controls.' },
    notifications: { label: 'Notifications', g: 'bell', tint: '#FF4245', sizes: 'swmtl', desc: 'Latest Mac notifications (WhatsApp, Claude…).' },
    mac:           { label: 'Mac Performance', g: 'chart', tint: '#0091FF', sizes: 'swml', desc: 'CPU, memory and disk.' },
    controls:      { label: 'Controls', g: 'sliders', tint: '#8E8E93', sizes: 'swml', desc: 'Volume, brightness and quick toggles.' },
    internet:      { label: 'Internet', g: 'wifi', tint: '#00D2E0', sizes: 'swml', desc: 'Speed test and live throughput.' },
    batteries:     { label: 'Batteries', g: 'battery', tint: '#30D158', sizes: 'swml', desc: 'AirPods, keyboard, mouse and more.' },
    timer:         { label: 'Focus Timer', g: 'timer', tint: '#FF9230', sizes: 'swml', desc: '25-minute focus and 5-minute breaks.' },
    bluetooth:     { label: 'Bluetooth', g: 'bluetooth', tint: '#0091FF', sizes: 'ml', desc: 'Connected and paired devices.' },
    whatsapp:      { label: 'WhatsApp', g: 'bubble', tint: '#25D366', sizes: 'swmtl', desc: 'Recent chats and messages from WhatsApp on the Mac; tap a chat to reply.' },
    ink:           { label: 'Notes', g: 'note', tint: '#FFCC00', sizes: 'wmtl', desc: 'Write with Apple Pencil; it becomes a note in Apple Notes (handwriting read on the Mac).' },
    claude:        { label: 'Claude', g: 'claude', tint: '#D97757', sizes: 'wmtl', desc: 'Ask a question, take a note, or open a project in Claude Code.' },
    youtube:       { label: 'YouTube', g: 'youtube', tint: '#FF0033', sizes: 'swml', desc: 'Mirrors the video playing in Chrome or Safari; play, seek, volume and tabs.' },
    camera:        { label: 'Camera & Mic', g: 'camera', tint: '#8E8E93', sizes: 'ml', modern: true, desc: 'Use this phone as the Mac’s webcam and mic.' }
  };

  PD.widgetIcon = function (k, px2) {   // squircle with the widget's glyph (galleries)
    var w = PD.WIDGETS[k]; return '<span class="wglyph" style="background:' + w.tint + '">' + '<svg' + SVG_ATTR + '>' + G[w.g] + '</svg></span>';
  };
  var G = {   // glyphs, 24×24 stroke icons
    moon: '<path d="M20 14.5A8 8 0 0 1 9.5 4 8 8 0 1 0 20 14.5z"/>',
    dark: '<circle cx="12" cy="12" r="8"/><path d="M12 4a8 8 0 0 1 0 16z" fill="currentColor"/>',
    cup: '<path d="M5 9h11v4a5.5 5.5 0 0 1-11 0z"/><path d="M16 10h1.5a2.5 2.5 0 0 1 0 5H16M8 2.5v3M11.5 2.5v3"/>',
    mic: '<rect x="9" y="3" width="6" height="11" rx="3"/><path d="M5 11a7 7 0 0 0 14 0M12 18v3"/>',
    micoff: '<rect x="9" y="3" width="6" height="11" rx="3"/><path d="M5 11a7 7 0 0 0 14 0M12 18v3M4 4l16 16"/>',
    split: '<rect x="3" y="5" width="18" height="14" rx="2.5"/><path d="M12 5v14"/>',
    fill: '<rect x="3" y="5" width="18" height="14" rx="2.5"/><path d="M8 9.5L6.5 8M16 9.5L17.5 8M8 14.5l-1.5 1.5M16 14.5l1.5 1.5"/>',
    play: '<path d="M7 4.5v15l12.5-7.5z" fill="currentColor"/>',
    pause: '<path d="M6 4h4v16H6zM14 4h4v16h-4z" fill="currentColor"/>',
    playpause: '<path d="M3 5v14l9-7z" fill="currentColor"/><path d="M15 5v14M20 5v14"/>',
    prev: '<path d="M6 5v14M19 5.5v13L9.5 12z" fill="currentColor"/>',
    next: '<path d="M18 5v14M5 5.5v13L14.5 12z" fill="currentColor"/>',
    volup: '<path d="M4 9h4l5-4v14l-5-4H4z"/><path d="M16.5 9a4 4 0 0 1 0 6M19 6.5a7.5 7.5 0 0 1 0 11"/>',
    voldown: '<path d="M4 9h4l5-4v14l-5-4H4z"/><path d="M16.5 9a4 4 0 0 1 0 6"/>',
    sun: '<circle cx="12" cy="12" r="4"/><path d="M12 2.5v2M12 19.5v2M2.5 12h2M19.5 12h2M5.3 5.3l1.4 1.4M17.3 17.3l1.4 1.4M5.3 18.7l1.4-1.4M17.3 6.7l1.4-1.4"/>',
    sunlow: '<circle cx="12" cy="12" r="4"/><path d="M12 5.5v.5M12 18v.5M5.5 12h.5M18 12h.5"/>',
    gauge: '<path d="M4 17a8 8 0 1 1 16 0"/><path d="M12 17l4-5"/>',
    sleep: '<rect x="3" y="4" width="18" height="12" rx="2"/><path d="M8 20h8M10 8h4l-4 4h4"/>',
    shot: '<path d="M4 8V5.5A1.5 1.5 0 0 1 5.5 4H8M16 4h2.5A1.5 1.5 0 0 1 20 5.5V8M20 16v2.5a1.5 1.5 0 0 1-1.5 1.5H16M8 20H5.5A1.5 1.5 0 0 1 4 18.5V16"/><circle cx="12" cy="12" r="3"/>',
    cam: '<path d="M3 7h10a2 2 0 0 1 2 2v6a2 2 0 0 1-2 2H3z"/><path d="M15 10.5l6-3.5v10l-6-3.5"/>',
    flip: '<path d="M3 12a9 9 0 0 1 15.5-6.2L21 8M21 3v5h-5M21 12a9 9 0 0 1-15.5 6.2L3 16M3 21v-5h5"/>',
    bell: '<path d="M6 16V11a6 6 0 0 1 12 0v5l1.5 2h-15z"/><path d="M10 20.5a2 2 0 0 0 4 0"/>',
    claude: '<path d="M12 3v18M3 12h18M5.6 5.6l12.8 12.8M18.4 5.6L5.6 18.4" stroke-width="2.4"/>',
    house: '<path d="M4 11l8-6.5 8 6.5"/><path d="M6 9.5V19h4.5v-5h3v5H18V9.5"/>',
    briefcase: '<rect x="3.5" y="7" width="17" height="12" rx="2.5"/><path d="M9 7V5.5A1.5 1.5 0 0 1 10.5 4h3A1.5 1.5 0 0 1 15 5.5V7M3.5 12h17"/>',
    headphones: '<path d="M4 15v-3a8 8 0 0 1 16 0v3"/><rect x="3" y="14" width="4" height="6" rx="1.5"/><rect x="17" y="14" width="4" height="6" rx="1.5"/>',
    bubble: '<path d="M12 4.5c4.7 0 8 3 8 6.8s-3.3 6.8-8 6.8c-1 0-2-.1-2.9-.4L5 19.5l1.2-3.4C4.8 14.9 4 13.2 4 11.3 4 7.5 7.3 4.5 12 4.5z"/>',
    desktop: '<rect x="3" y="4.5" width="18" height="12" rx="2"/><path d="M9 20h6M12 16.5V20"/>',
    inhdmi1: '<rect x="3" y="4.5" width="18" height="12" rx="2"/><path d="M9 20h6M12 16.5V20"/><text x="12" y="13.2" text-anchor="middle" font-size="7.5" font-weight="700" font-family="-apple-system,Helvetica,Arial,sans-serif" fill="currentColor" stroke="none">H1</text>',
    inhdmi2: '<rect x="3" y="4.5" width="18" height="12" rx="2"/><path d="M9 20h6M12 16.5V20"/><text x="12" y="13.2" text-anchor="middle" font-size="7.5" font-weight="700" font-family="-apple-system,Helvetica,Arial,sans-serif" fill="currentColor" stroke="none">H2</text>',
    indp: '<rect x="3" y="4.5" width="18" height="12" rx="2"/><path d="M9 20h6M12 16.5V20"/><text x="12" y="13.2" text-anchor="middle" font-size="7.5" font-weight="700" font-family="-apple-system,Helvetica,Arial,sans-serif" fill="currentColor" stroke="none">DP</text>',
    inusbc: '<rect x="3" y="4.5" width="18" height="12" rx="2"/><path d="M9 20h6M12 16.5V20"/><text x="12" y="13.2" text-anchor="middle" font-size="7.5" font-weight="700" font-family="-apple-system,Helvetica,Arial,sans-serif" fill="currentColor" stroke="none">C</text>',
    camera: '<path d="M4 8.5A1.5 1.5 0 0 1 5.5 7h2l1.5-2h6l1.5 2h2A1.5 1.5 0 0 1 20 8.5v9a1.5 1.5 0 0 1-1.5 1.5h-13A1.5 1.5 0 0 1 4 17.5z"/><circle cx="12" cy="13" r="3.5"/>',
    sparkles: '<path d="M10 3.5l1.6 4.4L16 9.5l-4.4 1.6L10 15.5l-1.6-4.4L4 9.5l4.4-1.6z"/><path d="M17.5 14l.8 2.2 2.2.8-2.2.8-.8 2.2-.8-2.2-2.2-.8 2.2-.8z"/>',
    gamepad: '<path d="M6.5 8h11a4.5 4.5 0 0 1 4.3 5.8l-.9 3a2 2 0 0 1-3.4.7L15 15H9l-2.5 2.5a2 2 0 0 1-3.4-.7l-.9-3A4.5 4.5 0 0 1 6.5 8z"/><path d="M8 10.5v3M6.5 12h3"/>',
    film: '<rect x="3.5" y="5" width="17" height="14" rx="2.5"/><path d="M8 5v14M16 5v14M3.5 9.5H8M3.5 14.5H8M16 9.5h4.5M16 14.5h4.5"/>',
    book: '<path d="M4 5.5C6.5 4.5 9.5 4.5 12 6c2.5-1.5 5.5-1.5 8-.5v13c-2.5-1-5.5-1-8 .5-2.5-1.5-5.5-1.5-8-.5z"/><path d="M12 6v13"/>',
    heart: '<path d="M12 19s-7-4.4-7-9.4A3.9 3.9 0 0 1 12 7.4a3.9 3.9 0 0 1 7 2.2c0 5-7 9.4-7 9.4z"/>',
    star: '<path d="M12 4l2.4 5 5.4.6-4 3.7 1.1 5.4L12 16l-4.9 2.7 1.1-5.4-4-3.7 5.4-.6z"/>',
    bolt: '<path d="M13 3L5 13.5h6L10 21l8-10.5h-6z"/>',
    globe: '<circle cx="12" cy="12" r="8"/><path d="M4 12h16M12 4c2.5 2.2 3.5 5 3.5 8s-1 5.8-3.5 8c-2.5-2.2-3.5-5-3.5-8s1-5.8 3.5-8z"/>',
    music: '<path d="M9 17.5V6.5l10-2v11"/><circle cx="6.8" cy="17.5" r="2.2"/><circle cx="16.8" cy="15.5" r="2.2"/>',
    code: '<path d="M8.5 7.5L4 12l4.5 4.5M15.5 7.5L20 12l-4.5 4.5M13.5 5.5l-3 13"/>',
    terminal: '<rect x="3" y="4.5" width="18" height="15" rx="2.5"/><path d="M7 9.5l3 2.5-3 2.5M12.5 15h4.5"/>',
    brush: '<path d="M14.5 4.5l5 5-7 7-5-5z"/><path d="M7.5 11.5c-2 0-3.5 1.5-3.5 3.5 0 1.5-.5 2.5-1 3 3 .5 6-.5 6.5-3"/>',
    person: '<circle cx="12" cy="8.5" r="3.5"/><path d="M5 19.5c.8-3.3 3.6-5 7-5s6.2 1.7 7 5"/>',
    folder: '<path d="M3.5 7.5A1.5 1.5 0 0 1 5 6h4.5l2 2H19a1.5 1.5 0 0 1 1.5 1.5v8A1.5 1.5 0 0 1 19 19H5a1.5 1.5 0 0 1-1.5-1.5z"/>',
    calendar: '<rect x="4" y="5.5" width="16" height="14" rx="2.5"/><path d="M4 10h16M8.5 3.5v4M15.5 3.5v4"/>',
    chart: '<path d="M4 19.5h16M7 16v-5M12 16V7M17 16v-8"/>',
    battery: '<rect x="3" y="8" width="16" height="8" rx="2.5"/><path d="M21 11v2"/><rect x="5" y="10" width="8" height="4" rx="1" fill="currentColor" stroke="none"/>',
    wifi: '<path d="M4 9.5a12 12 0 0 1 16 0M7 12.8a7.5 7.5 0 0 1 10 0M10 16a3 3 0 0 1 4 0"/><circle cx="12" cy="18.8" r=".9" fill="currentColor"/>',
    timer: '<circle cx="12" cy="13" r="7"/><path d="M12 13V9.5M10 3.5h4M18 6.5l1.2-1.2"/>',
    sliders: '<path d="M5 8h9M18 8h1M5 16h1M10 16h9"/><circle cx="16" cy="8" r="2"/><circle cx="8" cy="16" r="2"/>',
    youtube: '<rect x="3" y="5.5" width="18" height="13" rx="3.5"/><path d="M10.5 9.5v5l4.2-2.5z" fill="currentColor"/>',
    waveform: '<path d="M4 11v2M7 8.5v7M10 5.5v13M13 8v8M16 10v4M19 11v2"/>',
    bluetooth: '<path d="M7.5 7.5l9 9-4.5 4V3.5l4.5 4-9 9"/>',
    clock: '<circle cx="12" cy="12" r="8"/><path d="M12 7.5V12l3 2"/>',
    cloud: '<path d="M7.5 18.5h9a4 4 0 0 0 .4-8 5.5 5.5 0 0 0-10.6 1.5A3.3 3.3 0 0 0 7.5 18.5z"/>',
    cloudsun: '<circle cx="8.5" cy="8.5" r="3"/><path d="M8.5 3v1M3 8.5h1M4.6 4.6l.7.7M12.4 4.6l-.7.7"/><path d="M9.5 19.5h7.5a3.5 3.5 0 0 0 .3-7 4.8 4.8 0 0 0-9.2 1.3 2.9 2.9 0 0 0 1.4 5.7z"/>',
    fog: '<path d="M4 9h16M6 13h12M4 17h16"/>',
    rain: '<path d="M7.5 14.5h9a3.8 3.8 0 0 0 .4-7.6 5.2 5.2 0 0 0-10 1.4 3.1 3.1 0 0 0 .6 6.2z"/><path d="M8.5 17.5l-1 2.5M12.5 17.5l-1 2.5M16.5 17.5l-1 2.5"/>',
    snow: '<path d="M7.5 14.5h9a3.8 3.8 0 0 0 .4-7.6 5.2 5.2 0 0 0-10 1.4 3.1 3.1 0 0 0 .6 6.2z"/><circle cx="8" cy="18.5" r=".9" fill="currentColor"/><circle cx="12" cy="19.5" r=".9" fill="currentColor"/><circle cx="16" cy="18.5" r=".9" fill="currentColor"/>',
    storm: '<path d="M7.5 14.5h9a3.8 3.8 0 0 0 .4-7.6 5.2 5.2 0 0 0-10 1.4 3.1 3.1 0 0 0 .6 6.2z"/><path d="M13 15.5l-2 3h3l-2 3"/>',
    plus: '<path d="M12 5v14M5 12h14"/>',
    note: '<path d="M14 4H6a2 2 0 0 0-2 2v12a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-8"/><path d="M17.5 3.5l3 3L12 15l-4 1 1-4z"/>',
    send: '<path d="M12 19V5M6 11l6-6 6 6"/>',
    group: '<circle cx="9" cy="9" r="3"/><circle cx="16.5" cy="10" r="2.4"/><path d="M3.5 18.5c.6-2.8 2.8-4.5 5.5-4.5s4.9 1.7 5.5 4.5M14.5 14.6c.6-.3 1.3-.4 2-.4 2.2 0 3.8 1.4 4.2 3.6"/>',
    undo: '<path d="M9 7L4.5 11.5 9 16"/><path d="M5 11.5h9.5a5 5 0 0 1 0 10H12"/>',
    trash: '<path d="M5 7h14M10 7V5h4v2M7 7l1 12h8l1-12"/>',
    check: '<path d="M5 12.5l4.5 4.5L19 7.5"/>',
    question: '<circle cx="12" cy="12" r="8.5"/><path d="M9.6 9.6a2.5 2.5 0 1 1 3.4 2.3c-.6.3-1 .8-1 1.5v.6"/><circle cx="12" cy="17" r=".9" fill="currentColor"/>',
    ellipsis: '<circle cx="6" cy="12" r="1.3" fill="currentColor"/><circle cx="12" cy="12" r="1.3" fill="currentColor"/><circle cx="18" cy="12" r="1.3" fill="currentColor"/>'
  };
  // Page icons the user can pick (Command Center); old emoji icons map onto these.
  PD.PAGE_ICONS = ['house', 'sun', 'briefcase', 'code', 'terminal', 'brush', 'headphones', 'music', 'bubble', 'person', 'film', 'gamepad', 'camera',
    'desktop', 'chart', 'book', 'heart', 'star', 'bolt', 'globe', 'folder', 'calendar', 'moon', 'sparkles'];
  var EMOJI_ICONS = { '🏠': 'house', '💼': 'briefcase', '🎧': 'headphones', '💬': 'bubble', '🖥': 'desktop', '🖥️': 'desktop', '☀️': 'sun', '☀': 'sun',
    '📷': 'camera', '✨': 'sparkles', '🎮': 'gamepad', '🎬': 'film', '🎵': 'music', '📚': 'book', '⭐️': 'star', '⚡️': 'bolt', '🌍': 'globe', '📁': 'folder' };
  PD.iconName = function (i) { return !i ? '' : G[i] ? i : EMOJI_ICONS[i] || ''; };
  PD.iconSvg = function (i) { var n = PD.iconName(i); return n ? '<svg' + SVG_ATTR + ' class="gly">' + G[n] + '</svg>' : ''; };
  PD.GLYPHS = G;

  // Action keys (Stream Deck style). state: reads the on/off look from the Mac's data.
  PD.ACTIONS = {
    dark:       { label: 'Dark Mode', g: 'dark', state: function (c) { return c.dark; } },
    awake:      { label: 'Keep Awake', g: 'cup', state: function (c) { return c.awake; } },
    micmute:    { label: 'Mute Mac Mic', g: 'micoff', alert: true, state: function (c) { return c.micMuted; } },
    focus:      { label: 'Focus', g: 'moon' },
    leftright:  { label: 'Left & Right', g: 'split' },
    fill:       { label: 'Fill Window', g: 'fill' },
    playpause:  { label: 'Play / Pause', g: 'playpause' },
    prev:       { label: 'Previous', g: 'prev' },
    next:       { label: 'Next', g: 'next' },
    volup:      { label: 'Volume Up', g: 'volup' },
    voldown:    { label: 'Volume Down', g: 'voldown' },
    briup:      { label: 'Brighter', g: 'sun' },
    bridown:    { label: 'Dimmer', g: 'sunlow' },
    speedtest:  { label: 'Speed Test', g: 'gauge' },
    sleep:      { label: 'Display Sleep', g: 'sleep' },
    screenshot: { label: 'Screenshot', g: 'shot' },
    inhdmi1:    { label: 'Monitor HDMI 1', g: 'inhdmi1' },
    inhdmi2:    { label: 'Monitor HDMI 2', g: 'inhdmi2' },
    indp:       { label: 'Monitor DisplayPort', g: 'indp' },
    inusbc:     { label: 'Monitor USB-C', g: 'inusbc' },
    cam:        { label: 'Camera → Mac', g: 'cam', modern: true },
    mic:        { label: 'Mic → Mac', g: 'mic', modern: true }
  };

  // ---------------------------------------------------------------- shared state
  PD.data = {};                         // latest /stats
  PD.launcher = { selected: [], all: [] };
  PD.appByPath = function (p) { return find(PD.launcher.all, function (a) { return a.path === p; }); };
  PD.appByName = function (n) { return find(PD.launcher.all, function (a) { return a.name === n; }); };
  PD.iconUrl = function (path) { return api.url('/icon', 'path=' + encodeURIComponent(path)); };
  PD.modern = 'isSecureContext' in root;

  // ---------------------------------------------------------------- default layout
  PD.defaultLayout = function (launcher) {
    var all = launcher.all || [];
    function app(a) { return { t: 'app', path: a.path, name: a.name }; }
    function named(names, max) {
      var out = [];
      each(names, function (n) { var a = find(all, function (x) { return x.name === n; }); if (a && out.length < (max || 99)) out.push(app(a)); });
      return out;
    }
    var picked = [];
    each(launcher.selected || [], function (p) { var a = find(all, function (x) { return x.path === p; }); if (a && a.name !== 'Claude' && picked.length < 7) picked.push(app(a)); });
    if (!picked.length) picked = named(['Safari', 'Mail', 'Messages', 'Notes', 'Calendar', 'Music', 'Finder'], 7);
    var work = named(['Notion', 'Slack', 'Linear', 'Figma', 'Visual Studio Code', 'Cursor', 'Xcode', 'Terminal', 'Mail', 'Calendar', 'Notes', 'Reminders', 'Obsidian', 'Microsoft Teams', 'zoom.us', 'Google Chrome', 'Arc', 'Safari']);
    var music = named(['Spotify', 'Music', 'Podcasts', 'SoundCloud', 'TIDAL', 'GarageBand', 'Logic Pro']);
    var fun = named(['WhatsApp', 'Messages', 'Discord', 'Telegram', 'FaceTime', 'TV', 'Netflix', 'Photos', 'Steam', 'Books', 'Prime Video', 'Photo Booth']);
    function w(name, s) { return { t: 'w', w: name, s: s }; }
    function a(name) { return { t: 'action', a: name }; }
    function page(name, glyph, items) { return { id: uid(), name: name, icon: glyph, shortcut: '', items: items }; }
    var claude = { t: 'claude' };
    return {
      v: 1, theme: 'auto', wallpaper: 'aurora', accent: '#0091FF', glass: true,
      notifications: { enabled: true, preview: true, badges: true, banners: true, muted: [] },
      devices: {
        classic: { density: 'comfortable', labels: true, dock: { on: false, items: [] }, pages: [
          page('Home', 'house', picked.concat([claude, w('music', 'w')])),
          page('Today', 'sun', [w('calendar', 'm'), w('internet', 's'), w('batteries', 's'), a('dark'), a('speedtest'), a('micmute'), a('sleep')]),
          page('Work', 'briefcase', [w('calendar', 'm')].concat(work.slice(0, 9), [a('leftright'), a('fill')])),
          page('Music', 'headphones', [w('music', 'l')].concat(music.slice(0, 2), [a('prev'), a('playpause'), a('next'), a('voldown'), a('volup')])),
          page('Social', 'bubble', [w('notifications', 'm')].concat(fun.slice(0, 11))),
          page('Mac', 'desktop', [w('controls', 'l'), w('mac', 'w')])
        ] },
        phone: { density: 'compact', labels: true, dock: { on: false, items: [] }, pages: [
          page('Home', 'house', [w('clock', 'm'), w('music', 'l')].concat(picked.slice(0, 4), [claude], picked.slice(4), [w('batteries', 's'), w('internet', 's')])),
          page('Work', 'briefcase', [w('calendar', 'm'), w('notifications', 'm')].concat(work.slice(0, 12), [w('timer', 's'), a('leftright'), a('fill')])),
          page('Music', 'headphones', [w('music', 'l'), w('controls', 'm')].concat(music.slice(0, 2), [a('prev'), a('playpause'), a('next'), a('voldown'), a('volup'), a('briup'), a('bridown')])),
          page('Social', 'bubble', [w('notifications', 'm')].concat(fun.slice(0, 18))),
          page('Camera', 'camera', [w('camera', 'l'), a('cam'), a('mic'), a('micmute'), a('screenshot'), claude, a('dark'), a('focus'), a('awake')]),
          page('Mac', 'desktop', [w('controls', 'l'), w('mac', 'm'), w('batteries', 's'), w('internet', 's'), a('sleep'), a('speedtest'), a('dark'), a('awake')])
        ] },
        tablet: { density: 'compact', labels: true, dock: { on: true, items: picked.concat([claude, a('cam'), a('mic')]) }, pages: [
          page('Home', 'house', [w('clock', 'l'), w('music', 'l'), w('calendar', 'm'), w('mac', 'm'), w('controls', 'm'), w('internet', 's'), w('batteries', 's')]),
          page('Work', 'briefcase', [w('calendar', 'l'), w('notifications', 'l'), w('timer', 'm')].concat(work.slice(0, 12), [a('leftright'), a('fill')])),
          page('Music', 'headphones', [w('music', 'l'), w('controls', 'l')].concat(music.slice(0, 4), [a('prev'), a('playpause'), a('next'), a('voldown'), a('volup'), a('briup'), a('bridown'), a('dark')])),
          page('Social', 'bubble', [w('notifications', 'l'), w('weather', 'm'), w('clock', 'm')].concat(fun.slice(0, 16))),
          page('Mac', 'desktop', [w('mac', 'l'), w('controls', 'l'), w('bluetooth', 'l'), w('internet', 'm'), w('batteries', 'm')])
        ] }
      }
    };
  };

  // ---------------------------------------------------------------- grid packing
  PD.sizeOf = function (item) { return item.t === 'w' ? PD.SIZES[item.s] || PD.SIZES.m : [1, 1]; };
  // Items may carry pos: [col, row], a spot the user chose (iOS-style free placement). Pinned items keep
  // their spot; the rest flow into the first free cells, in order. Overflowing items are reported, not drawn.
  function emptyGrid(rows, cols) { var g = [], r, c; for (r = 0; r < rows; r++) { g[r] = []; for (c = 0; c < cols; c++) g[r][c] = false; } return g; }
  function fits(occ, r0, c0, w, h, rows, cols) {
    if (r0 < 0 || c0 < 0 || r0 + h > rows || c0 + w > cols) return false;
    for (var y = r0; y < r0 + h; y++) for (var x = c0; x < c0 + w; x++) if (occ[y][x]) return false;
    return true;
  }
  function mark(occ, r0, c0, w, h) { for (var y = r0; y < r0 + h; y++) for (var x = c0; x < c0 + w; x++) occ[y][x] = true; }
  function dims(item, cols, rows) { var sz = PD.sizeOf(item); return [Math.min(sz[0], cols), Math.min(sz[1], rows)]; }
  PD.pack = function (items, cols, rows) {
    var occ = emptyGrid(rows, cols), out = [], r, c;
    each(items, function (item, i) {
      var p = item.pos, d = dims(item, cols, rows);
      if (p && fits(occ, p[1], p[0], d[0], d[1], rows, cols)) { mark(occ, p[1], p[0], d[0], d[1]); out[i] = { i: i, item: item, r: p[1], c: p[0], w: d[0], h: d[1], pinned: true }; }
    });
    each(items, function (item, i) {
      if (out[i]) return;
      var d = dims(item, cols, rows), spot = null;
      for (r = 0; r <= rows - d[1] && !spot; r++) for (c = 0; c <= cols - d[0] && !spot; c++) if (fits(occ, r, c, d[0], d[1], rows, cols)) spot = [r, c];
      if (!spot) { out[i] = { i: i, item: item, overflow: true }; return; }
      mark(occ, spot[0], spot[1], d[0], d[1]);
      out[i] = { i: i, item: item, r: spot[0], c: spot[1], w: d[0], h: d[1] };
    });
    out.free = [];
    for (r = 0; r < rows; r++) for (c = 0; c < cols; c++) if (!occ[r][c]) out.free.push([r, c]);
    return out;
  };
  // Freeze every item where it currently sits, so moving one never reshuffles the others.
  PD.pinAll = function (items, cols, rows) {
    each(PD.pack(items, cols, rows), function (pl) { if (pl.overflow) delete pl.item.pos; else pl.item.pos = [pl.c, pl.r]; });
  };
  // Move like iOS: the item takes the spot; a same-size item there swaps into its old spot,
  // anything else it covers slides to the nearest free spot.
  PD.moveItem = function (items, idx, c, r, cols, rows) {
    PD.pinAll(items, cols, rows);
    var it = items[idx], d = dims(it, cols, rows);
    c = Math.max(0, Math.min(cols - d[0], c)); r = Math.max(0, Math.min(rows - d[1], r));
    var old = it.pos; it.pos = [c, r];
    var hit = items.filter(function (o) {
      if (o === it || !o.pos) return false;
      var od = dims(o, cols, rows);
      return o.pos[0] < c + d[0] && o.pos[0] + od[0] > c && o.pos[1] < r + d[1] && o.pos[1] + od[1] > r;
    });
    if (hit.length === 1 && old) {
      var hd = dims(hit[0], cols, rows);
      if (hd[0] === d[0] && hd[1] === d[1]) { hit[0].pos = old; return; }
    }
    var occ = emptyGrid(rows, cols);
    each(items, function (o) { if (o.pos && hit.indexOf(o) < 0) { var od = dims(o, cols, rows); mark(occ, o.pos[1], o.pos[0], od[0], od[1]); } });
    each(hit, function (o) {
      var od = dims(o, cols, rows), from = o.pos, best = null, bd = 1e9;
      for (var y = 0; y <= rows - od[1]; y++) for (var x = 0; x <= cols - od[0]; x++) if (fits(occ, y, x, od[0], od[1], rows, cols)) {
        var dist = Math.abs(x - from[0]) + Math.abs(y - from[1]) * 1.2;
        if (dist < bd) { bd = dist; best = [x, y]; }
      }
      if (best) { o.pos = best; mark(occ, best[1], best[0], od[0], od[1]); } else delete o.pos;
    });
  };
  // Add to the first free spot (and pin it there). Returns false when the page is full.
  PD.addItem = function (items, item, cols, rows) {
    PD.pinAll(items, cols, rows);
    items.push(item);
    var pl = PD.pack(items, cols, rows)[items.length - 1];
    if (pl.overflow) { items.pop(); return false; }
    item.pos = [pl.c, pl.r];
    return true;
  };
  PD.saveLayout = function (layout, cb) {
    api.req('POST', api.url('/layout'), JSON.stringify(layout), function (s, t) {
      var j = {}; try { j = JSON.parse(t); } catch (e) {}
      if (s === 200 && j.version) PD.live.layoutVersion = j.version;   // our own save: no reload
      if (cb) cb(s === 200);
    }, 'application/json');
  };

  // ---------------------------------------------------------------- clock text (no Intl on iOS 9)
  var DAYS = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];
  var MONTHS = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
  PD.timeParts = function (d) {
    var m = /(\d{1,2}[:.]\d{2})(?:[:.]\d{2})?\s*([^\d\s]*)/.exec(d.toLocaleTimeString()) || [];
    return { time: m[1] || (d.getHours() + ':' + ('0' + d.getMinutes()).slice(-2)), ampm: m[2] || '',
             long: DAYS[d.getDay()] + ' · ' + d.getDate() + ' ' + MONTHS[d.getMonth()],
             short: DAYS[d.getDay()].slice(0, 3) + ' ' + d.getDate() + ' ' + MONTHS[d.getMonth()].slice(0, 3) };
  };
  function hm(ms) { var p = PD.timeParts(new Date(ms)); return p.time + (p.ampm ? ' ' + p.ampm.toLowerCase() : ''); }

  // ---------------------------------------------------------------- Mac commands
  var deckToast = function () {};
  function control(cmd, value, cb) {
    var body = { cmd: cmd }; if (value !== undefined) body.value = value.toFixed(3);
    api.post('/control', body, function (s, t) { var j = {}; try { j = JSON.parse(t); } catch (e) {} if (cb) cb(j, s); setTimeout(PD.refresh, 450); });
  }
  function media(cmd) { api.post('/media', { cmd: cmd }, function () { setTimeout(PD.refresh, 450); }); }
  function launch(path, name) { api.post('/launch', { path: path }, function (s) { deckToast(s === 200 ? 'Opening ' + (name || 'app') : 'Launch failed'); }); }
  function tile(cmd, done) {
    control(cmd, undefined, function (j) {
      deckToast(j.ok ? done : j.error === 'accessibility' ? 'Allow PhoneDeck in Privacy & Security → Accessibility' : 'The front app has no window to arrange');
    });
  }
  var ctl = function () { return (PD.data.controls) || {}; };
  PD.runAction = function (name) {
    var c = ctl();
    switch (name) {
      case 'dark': c.dark = !c.dark; control('dark'); deckToast(c.dark ? 'Dark mode on' : 'Dark mode off'); break;
      case 'awake': c.awake = !c.awake; control('awake'); deckToast(c.awake ? 'Mac stays awake' : 'Normal sleep'); break;
      case 'micmute': c.micMuted = !c.micMuted; control('micmute'); deckToast(c.micMuted ? 'Mac microphone muted' : 'Mac microphone on'); break;
      case 'focus': control('focus', undefined, function (j) { deckToast(j.ok ? 'Focus toggled' : 'Create the “PhoneDeck Focus” shortcut on the Mac'); }); break;
      case 'leftright': tile('leftright', 'Windows arranged left & right'); break;
      case 'fill': tile('fill', 'Window filled'); break;
      case 'playpause': case 'next': case 'prev': media(name === 'prev' ? 'previous' : name); break;
      case 'volup': case 'voldown':
        if (c.volume === undefined) { deckToast('This audio output has no volume control'); break; }
        c.volume = Math.max(0, Math.min(1, c.volume + (name === 'volup' ? .0625 : -.0625))); control('volume', c.volume);
        deckToast('Volume ' + Math.round(c.volume * 100) + '%'); break;
      case 'briup': case 'bridown':
        var b = c.brightness === undefined ? .5 : c.brightness;
        c.brightness = Math.max(0, Math.min(1, b + (name === 'briup' ? .0625 : -.0625))); control('brightness', c.brightness);
        deckToast('Brightness ' + Math.round(c.brightness * 100) + '%'); break;
      case 'speedtest': api.post('/speedtest', {}, function () { deckToast('Running a speed test (~20 s)'); }); break;
      case 'sleep': control('sleepdisplay'); break;
      case 'screenshot': control('screenshot'); deckToast('Drag to capture on the Mac'); break;
      case 'inhdmi1': case 'inhdmi2': case 'indp': case 'inusbc':
        api.post('/control', { cmd: 'input', input: name.slice(2) }, function (st, t) {
          deckToast(/true/.test(t) ? PD.ACTIONS[name].label : 'No external monitor answered');
        }); break;
      case 'cam': PD.media.toggleCam(); break;
      case 'mic': PD.media.toggleMic(); break;
    }
  };

  // ---------------------------------------------------------------- camera + mic → Mac (modern only)
  // Secure WebSocket messages: 1 type byte + payload. 'H' token, 'V' JPEG frame, 'A' 16 kHz mono s16le PCM.
  // Ports: plain http = base, https = base+2, secure WebSocket = base+3.
  PD.media = (function () {
    var secure = location.protocol === 'https:', here = Number(location.port || (secure ? 443 : 80));
    var httpPort = secure ? here - 2 : here;
    var ws = null, cam = null, mic = null, facing = 'user', frameTimer = null, encoding = false, actx = null, node = null;
    var listeners = [], video = el('video');
    video.setAttribute('playsinline', ''); video.muted = true; video.autoplay = true;
    var m = {
      httpPort: httpPort, video: video,
      get cam() { return !!cam; }, get mic() { return !!mic; }, get facing() { return facing; },
      ready: function () { return ws && ws.readyState === 1; },
      secureUrl: function () { return 'https://' + location.hostname + ':' + (httpPort + 2) + '/#k=' + api.token; },
      on: function (fn) { listeners.push(fn); },
      toggleCam: function () { if (cam) stopCam(); else startCam(); },
      toggleMic: function () { if (mic) stopMic(); else startMic(); },
      flip: function () { facing = facing === 'user' ? 'environment' : 'user'; if (cam) { stopCam(); startCam(); } emit(); deckToast(facing === 'user' ? 'Front camera' : 'Back camera'); }
    };
    function emit() { each(listeners, function (fn) { fn(); }); }
    function pack(t, bytes) { var b = new Uint8Array(bytes.length + 1); b[0] = t.charCodeAt(0); b.set(bytes, 1); return b.buffer; }
    function open() {
      if (ws) return;
      ws = new WebSocket('wss://' + location.hostname + ':' + (httpPort + 3) + '/');
      ws.binaryType = 'arraybuffer';
      ws.onopen = function () { ws.send(pack('H', new TextEncoder().encode(api.token))); emit(); };
      ws.onclose = function () { ws = null; emit(); if (cam || mic) setTimeout(open, 2000); };
    }
    function needSecure() { if (root.isSecureContext) return false; deckToast('Camera & mic need the secure page (see the Camera widget)'); return true; }
    function sendFrame() {
      if (!m.ready() || encoding || ws.bufferedAmount > 500000 || !video.videoWidth) return;
      var c = sendFrame.c || (sendFrame.c = el('canvas'));
      c.width = 1280; c.height = Math.round(1280 * video.videoHeight / video.videoWidth);
      c.getContext('2d').drawImage(video, 0, 0, c.width, c.height);
      encoding = true;
      c.toBlob(function (b) {
        if (!b) { encoding = false; return; }
        b.arrayBuffer().then(function (ab) { encoding = false; if (m.ready()) ws.send(pack('V', new Uint8Array(ab))); });
      }, 'image/jpeg', 0.62);
    }
    function startCam() {
      if (needSecure()) return;
      navigator.mediaDevices.getUserMedia({ video: { facingMode: facing, width: { ideal: 1280 }, height: { ideal: 720 } }, audio: false }).then(function (s) {
        cam = s; video.srcObject = s; video.play(); open(); frameTimer = setInterval(sendFrame, 1000 / 18); emit();
        deckToast('Camera → Mac (OBS: /camera.mjpg)');
      }, function () { deckToast('Camera blocked: allow it for this page'); });
    }
    function stopCam() { clearInterval(frameTimer); if (cam) cam.getTracks().forEach(function (t) { t.stop(); }); cam = null; video.srcObject = null; emit(); }
    function startMic() {
      if (needSecure()) return;
      var AC = root.AudioContext || root.webkitAudioContext;
      actx = new AC();   // created inside the tap so iOS lets it run
      navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: true, noiseSuppression: true }, video: false }).then(function (s) {
        mic = s;
        var src = actx.createMediaStreamSource(s), ratio = actx.sampleRate / 16000;
        node = actx.createScriptProcessor(4096, 1, 1);
        node.onaudioprocess = function (e) {
          if (!m.ready()) return;
          var input = e.inputBuffer.getChannelData(0), n = Math.floor(input.length / ratio), out = new Int16Array(n);
          for (var i = 0; i < n; i++) {   // average each window: a cheap low-pass while downsampling to 16 kHz
            var a = Math.floor(i * ratio), b = Math.floor((i + 1) * ratio), sum = 0;
            for (var j = a; j < b; j++) sum += input[j];
            var v = sum / Math.max(1, b - a);
            out[i] = v < -1 ? -32768 : v > 1 ? 32767 : v * 32767;
          }
          ws.send(pack('A', new Uint8Array(out.buffer)));
        };
        src.connect(node); node.connect(actx.destination);
        open(); emit(); deckToast('Mic → Mac (choose “BlackHole 2ch”)');
      }, function () { deckToast('Microphone blocked: allow it for this page'); actx.close(); actx = null; });
    }
    function stopMic() {
      if (node) node.disconnect();
      if (mic) mic.getTracks().forEach(function (t) { t.stop(); });
      if (actx) actx.close();
      mic = node = actx = null; emit();
    }
    return m;
  })();

  // ---------------------------------------------------------------- focus timer (shared by all timer widgets)
  var timer = { min: 25, end: 0, left: 25 * 60, run: false,
    remaining: function () { return timer.run ? Math.max(0, (timer.end - Date.now()) / 1000) : timer.left; },
    toggle: function () {
      if (timer.run) { timer.left = timer.remaining(); timer.run = false; }
      else { timer.end = Date.now() + timer.left * 1000; timer.run = true; }
    },
    set: function (min) { timer.min = min; timer.run = false; timer.left = min * 60; },
    check: function () {
      if (timer.run && timer.remaining() <= 0) {
        timer.run = false; timer.left = timer.min * 60;
        deckToast(timer.min === 25 ? 'Focus session done, take a break' : 'Break over');
        if (navigator.vibrate) navigator.vibrate([200, 100, 200]);
      }
    } };

  // ---------------------------------------------------------------- widgets
  // build(el, size, ctx) fills the tile and returns { update(data), tick() }. ctx: { w, h, fs, edit, deck }.
  var BICON = {
    phone: '<rect x="7" y="2" width="10" height="20" rx="2.5"/>', laptop: '<rect x="4" y="5" width="16" height="10" rx="1.5"/><path d="M2 19h20"/>',
    keyboard: '<rect x="2" y="6" width="20" height="12" rx="2.5"/><path d="M7 14h10"/>', mouse: '<rect x="7" y="3" width="10" height="18" rx="5"/><path d="M12 6v3"/>',
    trackpad: '<rect x="3" y="4" width="18" height="16" rx="3"/>', headphones: '<path d="M4 15v-3a8 8 0 0 1 16 0v3"/><rect x="3" y="14" width="4" height="6" rx="1.5"/><rect x="17" y="14" width="4" height="6" rx="1.5"/>',
    'case': '<rect x="4" y="7" width="16" height="12" rx="4"/><path d="M4 11h16"/>',
    gamepad: '<path d="M6.5 8h11a4.5 4.5 0 0 1 4.3 5.8l-.9 3a2 2 0 0 1-3.4.7L15 15H9l-2.5 2.5a2 2 0 0 1-3.4-.7l-.9-3A4.5 4.5 0 0 1 6.5 8z"/>',
    watch: '<rect x="6" y="6" width="12" height="12" rx="3.5"/><path d="M9 6l.5-3h5l.5 3M9 18l.5 3h5l.5-3"/>'
  };
  function batteryList(d) {
    var chips = [];
    each(d.batteries || [], function (b) {
      if (b.kind === 'laptop') return;   // the Mac running PhoneDeck is left out
      chips.push(b);
      if (b['case'] !== undefined) chips.push({ kind: 'case', level: b['case'], name: (b.name || '') + ' case' });
    });
    if (PD.phoneBattery) chips.unshift(PD.phoneBattery);
    return chips;
  }
  function levelClass(b) { return b.charging ? 'chg' : b.level <= 20 ? 'low' : b.level <= 40 ? 'mid' : ''; }
  function rows(ctx, perRowEm, reservedEm) { return Math.max(1, Math.floor((ctx.h / ctx.fs - (reservedEm || 0)) / perRowEm)); }
  // WMO weather code → SF-style glyph, colored like SF Symbols' multicolor set
  function wicon(code, day) {
    var n = code === undefined ? 'cloudsun' : !day && code <= 2 ? 'moon' : code === 0 ? 'sun' : code <= 2 ? 'cloudsun' : code === 3 ? 'cloud' :
      code <= 48 ? 'fog' : code <= 67 || (code >= 80 && code <= 82) ? 'rain' : code <= 86 ? 'snow' : 'storm';
    var c = { sun: 'var(--yellow)', cloudsun: 'var(--yellow)', moon: 'var(--label)', cloud: 'var(--label)', fog: 'var(--label2)', rain: 'var(--cyan)', snow: 'var(--label)', storm: 'var(--yellow)' }[n];
    return '<svg' + SVG_ATTR + ' class="wx-ic" style="color:' + c + '">' + G[n] + '</svg>';
  }

  var W = {};

  W.clock = function (e, s) {
    if (s === 'w') {
      e.innerHTML = '<div class="row grow"><div class="grow"><div class="t num"></div></div><div class="side"><div class="d" style="margin:0"></div><div class="wx" style="margin-top:.2em"></div></div></div>';
      var bar = function () {
        var tp = PD.timeParts(new Date()), w = PD.data.weather || {};
        q(e, '.t').innerHTML = esc(tp.time) + (tp.ampm ? '<small>' + esc(tp.ampm) + '</small>' : '');
        q(e, '.d').textContent = tp.long;
        if (w.temp !== undefined) q(e, '.wx').innerHTML = wicon(w.code, w.day) + ' ' + Math.round(w.temp) + '° ' + esc(w.summary || '');
      };
      return { update: bar, tick: bar };
    }
    e.innerHTML = s === 'l'
      ? '<div class="row grow" style="-webkit-align-items:flex-end;align-items:flex-end"><div class="grow"><div class="t num"></div><div class="d"></div></div>' +
        '<div class="side"><div class="row" style="-webkit-justify-content:flex-end;justify-content:flex-end"><span class="ic" style="font-size:2em;margin-right:.2em"></span><span class="wt num"></span></div><div class="wx ws"></div><div class="wx wc muted"></div></div></div>'
      : '<div class="t num"></div><div><div class="d"></div>' + (s === 'm' ? '<div class="wx" style="margin-top:.4em"></div>' : '') + '</div>';
    function upd() {
      var tp = PD.timeParts(new Date()), w = PD.data.weather || {};
      q(e, '.t').innerHTML = esc(tp.time) + (tp.ampm ? '<small>' + esc(tp.ampm) + '</small>' : '');
      q(e, '.d').textContent = s === 's' ? tp.short : tp.long;
      if (s === 'm' && w.temp !== undefined) q(e, '.wx').innerHTML = wicon(w.code, w.day) + ' ' + Math.round(w.temp) + '° ' + esc(w.summary || '');
      if (s === 'l' && w.temp !== undefined) {
        q(e, '.ic').innerHTML = wicon(w.code, w.day); q(e, '.wt').textContent = Math.round(w.temp) + '°';
        q(e, '.ws').textContent = (w.summary || '') + '  H ' + Math.round(w.high) + '° L ' + Math.round(w.low) + '°';
        q(e, '.wc').textContent = w.city || '';
      }
    }
    return { update: upd, tick: upd };
  };

  W.weather = function (e, s) {
    e.innerHTML = s === 's' || s === 'w'
      ? '<div class="row grow"><span class="ic"></span><span class="tp num"></span><div class="grow"><div class="sm ell"></div><div class="hl ell"></div></div></div>'
      : s === 'm'
      ? '<h3 class="city">Weather</h3><div class="row"><span class="tp num grow"></span><span class="ic"></span></div><div class="grow"></div><div class="sm ell"></div><div class="hl ell"></div>'
      : '<div class="row grow"><div class="grow col" style="height:100%"><h3 class="city">Weather</h3><span class="tp num"></span><div class="grow"></div><div class="sm ell"></div><div class="hl ell"></div></div><span class="ic"></span></div>';
    return { update: function (d) {
      var w = d.weather || {};
      if (w.temp === undefined) { q(e, '.sm').textContent = 'Loading weather…'; return; }
      q(e, '.ic').innerHTML = wicon(w.code, w.day);
      q(e, '.tp').textContent = Math.round(w.temp) + '°';
      q(e, '.sm').textContent = w.summary || '';
      q(e, '.hl').textContent = 'H ' + Math.round(w.high) + '°  L ' + Math.round(w.low) + '°' + (w.rain ? ' · Rain ' + Math.round(w.rain) + '%' : '');
      var c = q(e, '.city'); if (c) c.textContent = w.city || 'Weather';
    } };
  };

  W.calendar = function (e, s, ctx) {
    var small = s === 's' || s === 'w';
    e.innerHTML = (small ? '' : '<h3>Up next</h3>') + '<div class="list grow"></div>';
    var list = q(e, '.list'), n = s === 's' ? 1 : s === 'w' ? 2 : rows(ctx, 2.6, 1.6), key = '';
    if (small) list.style.cssText = 'display:-webkit-flex;display:flex;-webkit-align-items:center;align-items:center';
    return { update: function (d) {
      var a = d.agenda || {};
      if (a.status === 'denied') { list.innerHTML = '<div class="empty">Allow Calendar for PhoneDeck in Privacy &amp; Security.</div>'; return; }
      if (a.status !== 'ok') return;
      var evs = (a.events || []).slice(0, n), now = Date.now(), today = new Date().toDateString();
      var k = JSON.stringify(evs) + Math.floor(now / 60000); if (k === key) return; key = k;
      if (!evs.length) { list.innerHTML = '<div class="empty">Nothing else today</div>'; return; }
      list.innerHTML = evs.map(function (ev) {
        var live = !ev.allDay && ev.start <= now && ev.end > now, other = new Date(ev.start).toDateString() !== today;
        return '<div class="ev row"><span class="bar" style="background:' + esc(ev.color) + '"></span>' +
          '<div class="grow"><div class="nm ell">' + esc(ev.title) + '</div><div class="tm num">' +
          (ev.allDay ? 'All day' : (other ? 'Tomorrow ' : '') + esc(hm(ev.start)) + ' – ' + esc(hm(ev.end))) + '</div></div>' +
          (live ? '<span class="now">Now</span>' : '') + '</div>';
      }).join('');
    } };
  };

  var NOTE = '<svg' + SVG_ATTR + ' class="ph-gly">' + G.music + '</svg>';
  W.music = function (e, s, ctx) {
    var btn = function (cls, g) { return '<div class="mb press ' + cls + '">' + icon(G[g]) + '</div>'; };
    var ctl = '<div class="row btns">' + btn('prev', 'prev') + btn('play', 'play') + btn('next', 'next') + '</div>';
    e.innerHTML = '<div class="mbg"></div><div class="min ' + (s === 'l' ? 'row' : 'col') + '">' + (
      s === 's' ? '<div class="row grow"><div class="art">' + NOTE + '</div><div class="meta grow"><div class="ti ell"></div><div class="ar ell"></div></div>' + btn('play', 'play') + '</div>'
      : s === 'w' ? '<div class="row grow"><div class="art">' + NOTE + '</div><div class="meta grow"><div class="ti ell"></div><div class="ar ell"></div><div class="prog"><i></i></div></div><div style="width:.8em"></div>' + btn('prev', 'prev') + btn('play', 'play') + btn('next', 'next') + '</div>'
      : s === 'm' ? '<div class="row"><div class="art">' + NOTE + '</div><div class="meta grow"><div class="ti ell"></div><div class="ar ell"></div></div></div><div class="grow"></div><div class="prog"><i></i></div><div class="grow"></div>' + ctl
      : '<div class="art">' + NOTE + '</div><div class="col grow" style="height:100%"><div class="meta"><div class="ti ell"></div><div class="ar ell"></div></div><div class="grow"></div><div class="prog"><i></i></div><div class="row muted num" style="font-size:.7em;margin-top:.3em"><span class="pos grow">0:00</span><span class="dur">0:00</span></div><div class="grow"></div>' + ctl + '</div>'
    ) + '</div>';
    if (s === 'l') { var art = q(e, '.art'), side = Math.round(ctx.h - 2 * ctx.fs); px(art, { width: side, height: side, lineHeight: side }); art.style.fontSize = '2.4em'; }
    var track = { playing: false, position: 0, duration: 0, at: 0 }, artKey = null;
    function setPlay(on) { each(e.querySelectorAll('.mb.play'), function (b) { b.innerHTML = icon(G[on ? 'pause' : 'play']); }); }
    function tick() {
      var pos = Math.min(track.duration, track.position + (track.playing ? (Date.now() - track.at) / 1000 : 0));
      var p = q(e, '.prog i'); if (p) p.style.width = track.duration ? pos / track.duration * 100 + '%' : '0';
      var a = q(e, '.pos'); if (a) { a.textContent = mmss(pos); q(e, '.dur').textContent = mmss(track.duration); }
    }
    if (!ctx.edit) {
      each(e.querySelectorAll('.mb.play'), function (b) { tap(b, function () { track.playing = !track.playing; setPlay(track.playing); media('playpause'); }); });
      var nx = q(e, '.mb.next'), pv = q(e, '.mb.prev');
      if (nx) tap(nx, function () { media('next'); });
      if (pv) tap(pv, function () { media('previous'); });
      tap(q(e, '.meta'), function () { media('open'); deckToast('Opening the player on the Mac'); });
    }
    return { tick: tick, update: function (d) {
      var mu = d.music || {};
      q(e, '.ti').textContent = mu.title || 'Nothing playing';
      q(e, '.ar').textContent = mu.title ? (mu.artist || '') + (mu.app && s !== 's' ? ' · ' + mu.app : '') : 'Spotify or Apple Music';
      track = { playing: !!mu.playing, position: mu.position || 0, duration: mu.duration || 0, at: Date.now() };
      setPlay(track.playing);
      var key = mu.id && mu.hasArt ? mu.id : '';
      if (key !== artKey) {
        artKey = key;
        var bg = key ? 'url("' + api.url('/artwork', 'id=' + encodeURIComponent(key)) + '")' : '';
        var a = q(e, '.art'); a.style.backgroundImage = bg; a.innerHTML = key ? '' : NOTE;
        q(e, '.mbg').style.backgroundImage = bg;
      }
      tick();
    } };
  };

  function ringHtml(id, label, color, sizeEm) {
    return '<div class="ring" data-r="' + id + '"><div style="position:relative;width:' + sizeEm + 'em;height:' + sizeEm + 'em;margin:0 auto">' +
      '<svg width="100%" height="100%" viewBox="0 0 40 40"><circle class="bg" cx="20" cy="20" r="17"/><circle class="fg" cx="20" cy="20" r="17" stroke="' + color + '" stroke-dasharray="106.8" stroke-dashoffset="106.8"/></svg>' +
      '<b class="num" style="top:50%;margin-top:-.6em;font-size:' + (sizeEm / 4.2).toFixed(2) + 'em">–</b></div><span>' + label + '</span></div>';
  }
  W.mac = function (e, s) {
    if (s === 's' || s === 'w') {
      e.innerHTML = '<div class="bars col grow" style="-webkit-justify-content:center;justify-content:center">' +
        ['cpu:CPU:#64d2ff', 'mem:MEM:#ffd60a', 'disk:SSD:#30d158'].map(function (x) {
          var p = x.split(':'); return '<div class="br row" data-b="' + p[0] + '"><em>' + p[1] + '</em><div class="bt grow"><i style="width:0;background:' + p[2] + '"></i></div><b class="num">–</b></div>';
        }).join('') + '</div>';
    } else {
      var size = s === 'l' ? 5.2 : 3.4;
      e.innerHTML = '<h3>Mac</h3><div class="rings row grow">' + ringHtml('cpu', 'CPU', '#64d2ff', size) + ringHtml('mem', 'Memory', '#ffd60a', size) + ringHtml('disk', 'Disk', '#30d158', size) + '</div>';
    }
    return { update: function (d) {
      var p = (d.controls || {}).perf || {};
      each(['cpu', 'mem', 'disk'], function (k) {
        if (p[k] === undefined) return;
        var v = Math.round(p[k]), r = q(e, '[data-r="' + k + '"]'), b = q(e, '[data-b="' + k + '"]');
        if (r) { q(r, '.fg').setAttribute('stroke-dashoffset', (106.8 * (1 - v / 100)).toFixed(1)); q(r, 'b').textContent = v + '%'; }
        if (b) { q(b, 'i').style.width = v + '%'; q(b, 'b').textContent = v + '%'; }
      });
    } };
  };

  var TOGGLES = {
    focus: ['moon', 'focus'], dark: ['dark', ''], awake: ['cup', ''], micmute: ['micoff', 'alert'], leftright: ['split', ''], fill: ['fill', '']
  };
  function slider(sl, cmd, vertical, ctx) {
    var fill = q(sl, 'i'), state = { value: .5, dragging: false }, last = 0;
    var send = typeof cmd === 'function' ? cmd : function (v) { control(cmd, v); };
    state.set = function (v) { state.value = v; fill.style[vertical ? 'height' : 'width'] = Math.max(0, v * 100) + '%'; };
    if (ctx.edit) return state;
    function at(x, y) {
      var r = sl.getBoundingClientRect();
      var v = vertical ? 1 - (y - r.top) / r.height : (x - r.left) / r.width;
      v = Math.max(0, Math.min(1, v)); state.set(v);
      if (Date.now() - last > 90) { last = Date.now(); send(v); }
    }
    sl.addEventListener('touchstart', function (ev) { ev.stopPropagation(); state.dragging = true; at(ev.touches[0].clientX, ev.touches[0].clientY); });
    sl.addEventListener('touchmove', function (ev) { ev.preventDefault(); ev.stopPropagation(); at(ev.touches[0].clientX, ev.touches[0].clientY); });
    sl.addEventListener('touchend', function (ev) { ev.stopPropagation(); state.dragging = false; send(state.value); });
    sl.addEventListener('mousedown', function (ev) {
      state.dragging = true; at(ev.clientX, ev.clientY);
      function mv(e2) { at(e2.clientX, e2.clientY); }
      function up() { state.dragging = false; send(state.value); document.removeEventListener('mousemove', mv); document.removeEventListener('mouseup', up); }
      document.addEventListener('mousemove', mv); document.addEventListener('mouseup', up);
    });
    return state;
  }
  W.controls = function (e, s, ctx) {
    var names = s === 's' ? ['dark', 'awake', 'micmute', 'focus'] : s === 'm' ? ['dark', 'awake', 'micmute', 'focus'] : ['focus', 'dark', 'awake', 'micmute', 'leftright', 'fill'];
    var tg = names.map(function (n) { return '<div class="ctl press ' + TOGGLES[n][1] + '" data-t="' + n + '" title="' + esc(PD.ACTIONS[n].label) + '">' + icon(G[TOGGLES[n][0]]) + '</div>'; }).join('');
    var sv = function (cls, cmd, g) { return '<div class="sld ' + cls + '" data-s="' + cmd + '"><i></i>' + icon(G[g]) + '</div>'; };
    if (s === 's') e.innerHTML = '<div class="row grow" style="-webkit-justify-content:space-around;justify-content:space-around">' + tg + '</div>';
    else if (s === 'w') e.innerHTML = '<div class="row grow">' + tg.replace(/class="ctl/g, 'style="margin-right:.5em" class="ctl') + sv('h', 'volume', 'volup').replace('class="sld h"', 'class="sld h grow"') + '</div>';
    else if (s === 'm') e.innerHTML = sv('h', 'volume', 'volup') + sv('h', 'brightness', 'sun') + '<div class="row grow" style="-webkit-justify-content:space-between;justify-content:space-between">' + tg + '</div>';
    else {
      e.innerHTML = '<div class="row grow"><div class="tgs row grow" style="height:100%;margin-right:.8em">' + tg + '</div>' +
        sv('v', 'volume', 'volup') + '<div style="width:.6em"></div>' + sv('v', 'brightness', 'sun') + '</div>';
      each(e.querySelectorAll('.tgs .ctl'), function (t) {   // fixed 3 × 2 grid
        var cell = el('div', 'cell'); t.parentNode.insertBefore(cell, t); cell.appendChild(t);
      });
      each(e.querySelectorAll('.sld.v'), function (v) { v.style.width = '3.2em'; v.style.height = '100%'; });
    }
    var sliders = {};
    each(e.querySelectorAll('.sld'), function (sl) { sliders[sl.getAttribute('data-s')] = { el: sl, st: slider(sl, sl.getAttribute('data-s'), /\bv\b/.test(sl.className), ctx) }; });
    if (!ctx.edit) each(e.querySelectorAll('.ctl'), function (t) { tap(t, function () { PD.runAction(t.getAttribute('data-t')); setTimeout(function () { upd(PD.data); }, 0); }); });
    function upd(d) {
      var c = d.controls || {};
      each(e.querySelectorAll('.ctl'), function (t) {
        var a = PD.ACTIONS[t.getAttribute('data-t')], on = !!(a.state && a.state(c));
        t.className = t.className.replace(/ on\b/g, '') + (on ? ' on' : '');
      });
      each(['volume', 'brightness'], function (k) {
        var sl = sliders[k]; if (!sl) return;
        sl.el.className = sl.el.className.replace(/ off\b/g, '') + (c[k] === undefined ? ' off' : '');
        if (!sl.st.dragging && c[k] !== undefined) sl.st.set(c[k]);
      });
    }
    return { update: upd };
  };

  function drawSpark(c, hist, color) {
    var w = c.clientWidth * 2, h = c.clientHeight * 2;
    if (!w || !h) return;
    if (c.width !== w || c.height !== h) { c.width = w; c.height = h; }
    var g = c.getContext('2d'); g.clearRect(0, 0, w, h);
    if (!hist || hist.length < 2) return;
    var max = 1; each(hist, function (v) { if (v > max) max = v; });
    g.beginPath();
    each(hist, function (v, i) { var x = i * w / (hist.length - 1), y = h - 3 - v / max * (h - 6); if (i) g.lineTo(x, y); else g.moveTo(x, y); });
    g.strokeStyle = color; g.lineWidth = 2.5; g.lineJoin = 'round'; g.stroke();
    g.lineTo(w, h); g.lineTo(0, h); g.closePath();
    var gr = g.createLinearGradient(0, 0, 0, h); gr.addColorStop(0, 'rgba(100,210,255,.35)'); gr.addColorStop(1, 'rgba(100,210,255,0)');
    g.fillStyle = gr; g.fill();
  }
  W.internet = function (e, s, ctx) {
    var nums = '<div class="big num"><span class="arrow">↓</span> <span class="dn">–</span><small>Mbps</small></div><div class="sub num"><span class="arrow up">↑</span> <span class="upv">–</span> Mbps · <span class="pg">–</span> ms</div>';
    e.innerHTML = s === 's' ? '<div class="col grow" style="-webkit-justify-content:center;justify-content:center">' + nums + '</div>'
      : s === 'w' ? '<div class="row grow"><div class="col" style="-webkit-justify-content:center;justify-content:center">' + nums + '</div><canvas class="spark grow"></canvas></div>'
      : s === 'm' ? '<h3 class="nt">Internet</h3>' + nums + '<canvas class="spark grow"></canvas>'
      : '<div class="row grow"><div class="col" style="height:100%;margin-right:1em"><h3 class="nt">Internet</h3>' + nums + '<div class="grow"></div><div class="sub muted">Tap to test</div></div><canvas class="spark grow" style="height:100%"></canvas></div>';
    if (s === 'l') e.querySelector('.big').style.fontSize = '2.6em';
    if (!ctx.edit) tap(e, function () { PD.runAction('speedtest'); });
    return { update: function (d) {
      var sp = d.speed || {};
      q(e, '.dn').textContent = sp.down !== undefined ? fmt(sp.down) : '–';
      q(e, '.upv').textContent = sp.up !== undefined ? fmt(sp.up) : '–';
      q(e, '.pg').textContent = sp.ping !== undefined ? Math.round(sp.ping) : '–';
      var t = q(e, '.nt'); if (t) t.textContent = sp.running ? 'Testing…' : 'Internet';
      var c = q(e, 'canvas'); if (c) drawSpark(c, (d.net || {}).history, '#64d2ff');
    } };
  };

  W.batteries = function (e, s, ctx) {
    e.innerHTML = (s === 's' || s === 'w' ? '' : '<h3>Batteries</h3>') + '<div class="list grow ' + (s === 'l' ? 'col' : 'chips row') + '"></div>';
    var list = q(e, '.list'), max = s === 's' ? 4 : s === 'w' ? 8 : s === 'm' ? 2 * rows(ctx, 1.9, 2) : rows(ctx, 1.75, 2.2), key = '';
    return { update: function (d) {
      var chips = batteryList(d).slice(0, max), k = JSON.stringify(chips); if (k === key) return; key = k;
      if (!chips.length) { list.innerHTML = '<div class="empty">No devices reporting</div>'; return; }
      list.innerHTML = chips.map(function (b) {
        var cls = levelClass(b);
        if (s === 'l') return '<div class="bl row">' + icon(BICON[b.kind] || BICON.keyboard) + '<span class="grow ell">' + esc(b.name || b.kind) + '</span>' +
          '<span class="bt"><i style="width:' + b.level + '%;background:' + (cls === 'low' ? 'var(--red)' : cls === 'mid' ? 'var(--yellow)' : 'var(--green)') + '"></i></span><b class="num ' + cls + '">' + b.level + '%</b></div>';
        return '<div class="chip" title="' + esc(b.name) + '">' + icon(BICON[b.kind] || BICON.keyboard) + '<span class="num ' + cls + '">' + b.level + '%</span></div>';
      }).join('');
    } };
  };

  W.timer = function (e, s, ctx) {
    var size = s === 'l' ? 6.4 : 4.6;
    e.innerHTML = s === 's' || s === 'w'
      ? '<div class="row grow" style="width:100%"><span class="tl num grow">25:00</span>' + (s === 'w' ? '<span class="pill mt">25 min</span>' : '') + '<span class="pill go">Start</span></div>'
      : '<div style="position:relative;width:' + size + 'em;height:' + size + 'em"><svg width="100%" height="100%" viewBox="0 0 40 40" style="transform:rotate(-90deg);-webkit-transform:rotate(-90deg)">' +
        '<circle cx="20" cy="20" r="17" fill="none" stroke="var(--track)" stroke-width="3"/><circle class="fg" cx="20" cy="20" r="17" fill="none" stroke="var(--coral)" stroke-width="3" stroke-linecap="round" stroke-dasharray="106.8" stroke-dashoffset="106.8"/></svg>' +
        '<span class="tl num" style="position:absolute;left:0;right:0;top:50%;margin-top:-.6em;text-align:center;font-size:' + (size / 4).toFixed(2) + 'em">25:00</span></div>' +
        '<div>' + (s === 'l' ? '<span class="pill m25 on">Focus 25</span><span class="pill m5">Break 5</span>' : '<span class="pill mt">25 min</span>') + '<span class="pill go">Start</span></div>';
    if (!ctx.edit) {
      tap(q(e, '.go'), function () { timer.toggle(); tick(); });
      var a = q(e, '.m25'), b = q(e, '.m5'), mt = q(e, '.mt');
      if (a) { tap(a, function () { timer.set(25); tick(); }); tap(b, function () { timer.set(5); tick(); }); }
      if (mt) tap(mt, function () { timer.set(timer.min === 25 ? 5 : 25); tick(); });
    }
    function tick() {
      timer.check();
      var left = timer.remaining();
      q(e, '.tl').textContent = mmss(left);
      q(e, '.go').textContent = timer.run ? 'Pause' : left < timer.min * 60 ? 'Resume' : 'Start';
      var fg = q(e, '.fg'); if (fg) fg.setAttribute('stroke-dashoffset', (106.8 * left / (timer.min * 60)).toFixed(1));
      var a2 = q(e, '.m25'); if (a2) { a2.className = 'pill m25' + (timer.min === 25 ? ' on' : ''); q(e, '.m5').className = 'pill m5' + (timer.min === 5 ? ' on' : ''); }
      var mt2 = q(e, '.mt'); if (mt2) mt2.textContent = timer.min + ' min';
    }
    return { tick: tick, update: tick };
  };

  W.notifications = function (e, s, ctx) {
    var small = s === 's' || s === 'w';
    e.innerHTML = (small ? '' : '<div class="row" style="-webkit-flex:none;flex:none"><h3 class="grow">Notifications</h3><h3 class="clr" style="color:var(--accent);margin-left:.8em">Clear</h3></div>') + '<div class="list grow"></div>';
    var list = q(e, '.list'), n = s === 's' ? 1 : s === 'w' ? 2 : rows(ctx, s === 'l' ? 2.9 : 2.6, 2.2), key = '';
    if (small) list.style.cssText = 'display:-webkit-flex;display:flex;-webkit-align-items:center;align-items:center';
    var clr = q(e, '.clr');
    if (clr && !ctx.edit) tap(clr, function () { api.post('/notifications/clear', {}, function () { setTimeout(PD.refresh, 200); }); });
    if (!ctx.edit) list.addEventListener('click', function (ev) {
      var r = closest(ev.target, 'data-path', list); if (r && r.getAttribute('data-path')) launch(r.getAttribute('data-path'), r.getAttribute('data-app'));
    });
    return { update: function (d) {
      var notes = d.notes || {}, items = (notes.items || []).slice(0, n), k = JSON.stringify(items) + notes.access + Math.floor(Date.now() / 60000);
      if (k === key) return; key = k;
      if (!items.length) {
        list.innerHTML = '<div class="empty">' + (notes.access === 'denied' ? 'Only badges for now: give PhoneDeck Full Disk Access to see messages.' : 'No notifications') + '</div>';
        return;
      }
      list.innerHTML = items.map(function (it) {
        var img = it.path ? '<img src="' + esc(PD.iconUrl(it.path)) + '">' : '<span class="nfb">' + icon(G.bell) + '</span>';
        var body = it.body || it.sub || '';
        return '<div class="nrow row" data-path="' + esc(it.path) + '" data-app="' + esc(it.app) + '">' + img +
          '<div class="grow"><div class="row"><span class="nt ell grow">' + esc(it.title || it.app) + '</span><span class="na">' + ago(it.at) + '</span></div>' +
          (!small && body ? '<div class="nb ell">' + esc(body) + '</div>' : small ? '<div class="nb ell">' + esc(body || it.app) + '</div>' : '') + '</div></div>';
      }).join('');
    } };
  };

  W.camera = function (e, s, ctx) {
    if (!PD.modern || ctx.edit || !root.isSecureContext) {
      e.innerHTML = ctx.edit || !PD.modern
        ? '<div class="setup"><b>Camera &amp; Mic</b><br>' + (ctx.edit ? 'Live on the device: stream this phone’s camera and mic to the Mac.' : 'Needs a newer iPhone or iPad.') + '</div>'
        : '<div class="setup"><b>One-time setup for camera &amp; mic</b><br>1. <a href="/phonedeck.mobileconfig">Download the PhoneDeck profile</a> and install it in Settings.<br>' +
          '2. Settings → General → About → Certificate Trust Settings → turn on PhoneDeck CA.<br>3. Open the <a href="' + esc(PD.media.secureUrl()) + '">secure deck</a> and add it to the Home Screen.</div>';
      return { update: function () {} };
    }
    e.innerHTML = '<div class="vbox"></div><div class="off">Camera off</div><span class="live">LIVE</span><div class="cbtns">' +
      '<span class="ctl press cam">' + icon(G.cam) + '</span><span class="ctl press mic">' + icon(G.mic) + '</span><span class="ctl press flip">' + icon(G.flip) + '</span></div>';
    tap(q(e, '.cam'), function () { PD.media.toggleCam(); });
    tap(q(e, '.mic'), function () { PD.media.toggleMic(); });
    tap(q(e, '.flip'), function () { PD.media.flip(); });
    function upd() {
      var m = PD.media, v = m.video;
      if (m.cam && v.parentNode !== q(e, '.vbox')) q(e, '.vbox').appendChild(v);
      v.className = m.facing === 'user' ? 'mirror' : '';
      q(e, '.off').style.display = m.cam ? 'none' : '';
      q(e, '.live').style.display = m.cam && m.ready() ? 'block' : 'none';
      q(e, '.cam').className = 'ctl press cam' + (m.cam ? ' on' : '');
      q(e, '.mic').className = 'ctl press mic' + (m.mic ? ' on' : '');
    }
    PD.media.on(upd);
    return { update: upd };
  };

  W.bluetooth = function (e, s, ctx) {
    e.innerHTML = '<h3>Bluetooth</h3><div class="list grow"><div class="empty">Loading…</div></div>';
    var list = q(e, '.list'), n = rows(ctx, 1.9, 2.2), last = 0;
    function load() {
      last = Date.now();
      api.json('/bluetooth', '', function (j) {
        if (!j) { list.innerHTML = '<div class="empty">Could not read Bluetooth devices.</div>'; return; }
        var all = (j.connected || []).map(function (d) { d.on = true; return d; }).concat(j.paired || []).slice(0, n);
        list.innerHTML = all.map(function (d) {
          var lv = [d.left !== undefined ? 'L ' + d.left + '%' : '', d.right !== undefined ? 'R ' + d.right + '%' : '', d.battery !== undefined ? d.battery + '%' : ''].filter(function (x) { return x; }).join(' · ');
          return '<div class="bt-row row' + (d.on ? '' : ' off') + '">' + icon(BICON[d.kind] || BICON.headphones) + '<span class="grow ell">' + esc(d.name) + '</span>' + (lv ? '<span class="lv num">' + lv + '</span>' : '') + '</div>';
        }).join('') || '<div class="empty">No Bluetooth devices.</div>';
      });
    }
    return { update: function () { if (Date.now() - last > 60000) load(); } };
  };
  // YouTube in Chrome/Safari on the Mac: live frame (or thumbnail), title, progress, controls, volume and tab switching.
  W.youtube = function (e, s, ctx) {
    var b = function (cls, g, extra) { return '<div class="mb press ' + cls + '" data-c="' + cls + '">' + icon(G[g]) + (extra || '') + '</div>'; };
    var back = '<div class="mb press back" data-c="back"><svg' + SVG_ATTR + '><path d="M11 7l-5 5 5 5M18 7l-5 5 5 5" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"/></svg></div>';
    var fwd = '<div class="mb press forward" data-c="forward"><svg' + SVG_ATTR + '><path d="M6 7l5 5-5 5M13 7l5 5-5 5" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"/></svg></div>';
    var ctlRow = '<div class="row btns">' + back + b('playpause play', 'play') + fwd + (s === 'l' || s === 'm' ? b('next', 'next') : '') + '</div>';
    var meta = '<div class="meta grow"><div class="ti ell">YouTube</div><div class="ar ell"></div></div>';
    var shot = '<div class="shot"><img alt=""><span class="yt-ph">' + icon(G.youtube) + '</span></div>';
    e.innerHTML = s === 's' ? '<div class="row grow">' + shot + meta + b('playpause play', 'play') + '</div>'
      : s === 'w' ? '<div class="row grow">' + shot + '<div class="col grow">' + meta + '<div class="prog"><i></i></div></div><div style="width:.6em"></div>' + back + b('playpause play', 'play') + fwd + '</div>'
      : s === 'm' ? shot + '<div class="row" style="margin-top:.5em">' + meta + '</div>' + ctlRow
      : '<div class="row grow" style="-webkit-align-items:stretch;align-items:stretch">' + shot + '<div class="col grow" style="margin-left:1em;min-width:0">' + meta +
        '<div class="prog"><i></i></div><div class="row l2 num" style="font-size:.7em;margin-top:.3em"><span class="pos grow">0:00</span><span class="dur">0:00</span></div>' +
        '<div class="grow"></div>' + ctlRow + '<div class="sld h yv"><i></i>' + icon(G.volup) + '</div><div class="yt-tabs"></div></div></div>';
    var st = {}, last = 0, at = 0, vol = null;
    if (s === 'l') {
      var sh = q(e, '.shot'); sh.style.height = '100%'; sh.style.width = Math.round((ctx.h - 2 * 16) * 16 / 9) + 'px';
      vol = slider(q(e, '.yv'), function (v) { api.post('/youtube', { cmd: 'volume', value: v.toFixed(2) }); }, false, ctx);
    }
    function cmd(c) {
      if (c === 'playpause') { st.paused = !st.paused; paint(); }
      api.post('/youtube', { cmd: c }, function () { last = 0; setTimeout(fetch, 250); });
    }
    if (!ctx.edit) {
      each(e.querySelectorAll('[data-c]'), function (n) { tap(n, function () { cmd(n.getAttribute('data-c').split(' ')[0]); }); });
      tap(q(e, '.shot'), function () { api.post('/youtube', { cmd: 'show' }); deckToast('Showing the video on the Mac'); });
      var tabsEl = q(e, '.yt-tabs');
      if (tabsEl) tabsEl.addEventListener('click', function (ev) {
        var t = closest(ev.target, 'data-key', tabsEl); if (!t) return;
        api.post('/youtube', { cmd: 'select', key: t.getAttribute('data-key') }, function () { last = 0; fetch(); });
      });
    }
    function paint() {
      var none = st.status === 'none' || !st.status, needs = st.status === 'needs-js';
      q(e, '.ti').textContent = st.title || (none ? 'Nothing on YouTube' : 'YouTube');
      q(e, '.ar').textContent = needs ? (st.browser === 'safari' ? 'Safari: Develop › Allow JavaScript from Apple Events' : 'In the Chrome window playing it: View › Developer › Allow JavaScript from Apple Events')
        : none ? 'Open a video in Chrome or Safari on the Mac' : (st.channel || (st.browser === 'safari' ? 'Safari' : 'Chrome'));
      each(e.querySelectorAll('.mb.play'), function (n) { n.innerHTML = icon(G[st.paused === false ? 'pause' : 'play']); });
      var img = q(e, '.shot img'), ph = q(e, '.yt-ph');
      var src = st.frame ? api.url('/youtube/frame.jpg', 't=' + Date.now()) : st.id ? 'https://i.ytimg.com/vi/' + st.id + '/mqdefault.jpg' : '';
      if (src && img.getAttribute('data-src') !== (st.frame ? 'live' : src)) { img.src = src; img.setAttribute('data-src', st.frame ? 'live' : src); }
      else if (st.frame) img.src = src;
      img.style.display = src ? 'block' : 'none'; ph.style.display = src ? 'none' : 'block';
      tick();
      if (vol && !vol.dragging && st.vol !== undefined) vol.set(st.muted ? 0 : st.vol);
      var tabsEl = q(e, '.yt-tabs');
      if (tabsEl) tabsEl.innerHTML = (st.tabs || []).length > 1 ? st.tabs.slice(0, 4).map(function (t) {
        return '<span class="ytt' + (t.key === st.key ? ' on' : '') + '" data-key="' + esc(t.key) + '">' + esc(t.title) + '</span>';
      }).join('') : '';
    }
    function tick() {
      var pos = Math.min(st.d || 0, (st.t || 0) + (st.paused === false ? (Date.now() - at) / 1000 : 0));
      var p = q(e, '.prog i'); if (p) p.style.width = st.d ? pos / st.d * 100 + '%' : '0';
      var a = q(e, '.pos'); if (a) { a.textContent = mmss(pos); q(e, '.dur').textContent = mmss(st.d || 0); }
    }
    function fetch() {
      if (ctx.edit || Date.now() - last < 1800) return;
      last = Date.now();
      api.json('/youtube', s === 'm' || s === 'l' ? 'frame=1' : '', function (j) { if (j) { st = j; at = Date.now(); paint(); } });
    }
    paint();
    return { update: fetch, tick: tick };
  };

  // Claude: ask a question (voice or typed), take a note (Apple Notes), or open a Claude Code project.
  W.claude = function (e, s, ctx) {
    var act = function (a, g, label) { return '<div class="cact press" data-a="' + a + '"><span class="cic">' + icon(G[g]) + '</span>' + (label ? '<span class="cl">' + label + '</span>' : '') + '</div>'; };
    var orb = '<span class="corb">' + icon(G.claude) + '</span>';
    if (s === 'w') {
      e.innerHTML = '<div class="row grow">' + orb + '<div class="cask grow press" data-a="ask">Ask Claude…</div>' +
        act('talk', 'waveform') + act('note', 'note') + act('proj', 'folder') + '</div>';
    } else {
      e.innerHTML = '<div class="row chd">' + orb + '<b class="grow">Claude</b></div>' +
        '<div class="row cacts">' + act('ask', 'question', 'Ask') + act('note', 'note', 'Note') + act('new', 'plus', 'New chat') + '</div>' +
        (s === 'm' ? '' : '<h3 style="margin-top:.8em">Claude Code</h3><div class="cprj grow"></div>');
    }
    var list = q(e, '.cprj');
    function fillProjects() {
      if (!list) return;
      var n = rows(ctx, 2.1, s === 't' ? 9.5 : 8.5), ps = (PD.projects || []).slice(0, n);
      list.innerHTML = ps.length ? ps.map(function (p) {
        return '<div class="cpr row" data-p="' + esc(p.path) + '"><span class="cpi">' + icon(G.folder) + '</span><span class="grow ell">' + esc(p.name) + '</span>' + icon(G.next) + '</div>';
      }).join('') : '<div class="empty">' + (PD.projects ? 'No projects yet: use Claude Code in a folder once.' : 'Loading…') + '</div>';
    }
    if (!ctx.edit) {
      each(e.querySelectorAll('[data-a]'), function (n) {
        tap(n, function () {
          var a = n.getAttribute('data-a'), d = ctx.deck;
          if (a === 'ask' || a === 'talk') d.talk('ask');
          else if (a === 'note') d.talk('note');
          else if (a === 'new') api.post('/claude', { 'new': '1' }, function (st) { deckToast(st === 200 ? 'New Claude chat' : 'Could not reach the Mac'); });
          else if (a === 'proj') d.pickProject();
        });
      });
      if (list) list.addEventListener('click', function (ev) {
        var r = closest(ev.target, 'data-p', list); if (!r) return;
        var p = r.getAttribute('data-p');
        api.post('/project', { path: p }, function (st, t) { deckToast(st === 200 && /true/.test(t) ? 'Claude Code · ' + p.split('/').pop() : 'Could not open the project'); });
      });
    }
    if (list && !PD.projects) PD.loadProjects(fillProjects);
    fillProjects();
    return { update: function () {} };
  };

  // Notes: handwriting with Apple Pencil (pressure, palm rejection). Save sends black-on-white ink to the Mac,
  // which reads it with Vision and creates an Apple Notes note with the text and the drawing attached.
  PD.inkDrafts = {};   // unsaved handwriting per widget, survives re-renders
  W.ink = function (e, s, ctx) {
    var btn = function (cls, g) { return '<span class="nbtn press ' + cls + '">' + icon(G[g]) + '</span>'; };
    e.innerHTML = s === 'w'
      ? '<div class="row grow"><div class="npad grow"><canvas></canvas><span class="nhint">Write with Apple Pencil</span></div>' + btn('undo', 'undo') + btn('save on', 'check') + '</div>'
      : '<div class="row nhd"><h3 class="grow" style="margin:0">Notes</h3>' + btn('undo', 'undo') + btn('clr', 'trash') + btn('save on', 'check') + '</div>' +
        '<div class="npad grow"><canvas></canvas><span class="nhint">Write with Apple Pencil</span></div>';
    var c = q(e, 'canvas'), pad = q(e, '.npad'), hint = q(e, '.nhint'), g2 = c.getContext('2d');
    var dpr = root.devicePixelRatio || 1, strokes = PD.inkDrafts[ctx.key] || [], cur = null, penSeen = false, busy = false;
    function fit() {
      var w = pad.clientWidth, h = pad.clientHeight; if (!w || !h) return;
      c.style.width = w + 'px'; c.style.height = h + 'px';
      c.width = Math.round(w * dpr); c.height = Math.round(h * dpr);
      redraw();
    }
    function ink() { return root.getComputedStyle ? root.getComputedStyle(e).color : '#fff'; }
    function widthAt(p) { return 1.1 + 2.6 * (p === undefined ? .5 : p); }
    function seg(g, a, b, color, scale, ox, oy) {
      g.strokeStyle = color; g.lineCap = 'round'; g.lineJoin = 'round';
      g.lineWidth = widthAt((a[2] + b[2]) / 2) * scale;
      g.beginPath(); g.moveTo((a[0] - ox) * scale, (a[1] - oy) * scale); g.lineTo((b[0] - ox) * scale, (b[1] - oy) * scale); g.stroke();
    }
    function paint(g, color, scale, ox, oy) {
      each(strokes, function (st) {
        var p = st.pts;
        if (p.length === 1) { g.fillStyle = color; g.beginPath(); g.arc((p[0][0] - ox) * scale, (p[0][1] - oy) * scale, widthAt(p[0][2]) * scale / 2, 0, 7); g.fill(); }
        for (var i = 1; i < p.length; i++) seg(g, p[i - 1], p[i], color, scale, ox, oy);
      });
    }
    function redraw() {
      g2.setTransform(1, 0, 0, 1, 0, 0); g2.clearRect(0, 0, c.width, c.height);
      paint(g2, ink(), dpr, 0, 0);
      hint.style.display = strokes.length ? 'none' : '';
    }
    function point(x, y, p) { var r = c.getBoundingClientRect(); return [(x - r.left) * c.clientWidth / r.width, (y - r.top) * c.clientHeight / r.height, p]; }
    function start(x, y, p) { cur = { pts: [point(x, y, p)] }; strokes.push(cur); PD.inkDrafts[ctx.key] = strokes; hint.style.display = 'none'; redraw(); }
    function move(x, y, p) { if (!cur) return; var a = cur.pts[cur.pts.length - 1], b = point(x, y, p); cur.pts.push(b); seg(g2, a, b, ink(), dpr, 0, 0); }
    function end() { cur = null; }
    if (!ctx.edit) {
      // writing never reaches the deck (no page swipe, no long-press menu)
      each(['touchstart', 'touchmove', 'touchend'], function (t) { c.addEventListener(t, function (ev) { ev.stopPropagation(); if (t === 'touchmove' || root.PointerEvent) ev.preventDefault(); }); });
      if (root.PointerEvent) {
        c.addEventListener('pointerdown', function (ev) {
          if (ev.pointerType === 'pen') penSeen = true;
          if (penSeen && ev.pointerType === 'touch') return;   // palm rejection once the Pencil is in use
          ev.preventDefault(); ev.stopPropagation();
          try { c.setPointerCapture(ev.pointerId); } catch (x) {}
          start(ev.clientX, ev.clientY, ev.pointerType === 'pen' ? ev.pressure : .5);
        });
        c.addEventListener('pointermove', function (ev) {
          if (!cur) return;
          var list = ev.getCoalescedEvents ? ev.getCoalescedEvents() : [ev];
          each(list.length ? list : [ev], function (pe) { move(pe.clientX, pe.clientY, pe.pointerType === 'pen' ? pe.pressure : .5); });
        });
        c.addEventListener('pointerup', end); c.addEventListener('pointercancel', end);
      } else {   // iOS 9 (iPhone 4S): touch events, finger only
        c.addEventListener('touchstart', function (ev) { var t = ev.touches[0]; start(t.clientX, t.clientY, .5); });
        c.addEventListener('touchmove', function (ev) { var t = ev.touches[0]; move(t.clientX, t.clientY, .5); });
        c.addEventListener('touchend', end);
      }
      tap(q(e, '.undo'), function () { strokes.pop(); redraw(); });
      var clr = q(e, '.clr'); if (clr) tap(clr, function () { strokes.length = 0; redraw(); });
      tap(q(e, '.save'), function () { save(); });
    }
    function save() {
      if (busy) return;
      if (!strokes.length) { deckToast('Write something first'); return; }
      // crop to the ink, black on white at 2×: what Vision reads best
      var minX = 1e9, minY = 1e9, maxX = 0, maxY = 0;
      each(strokes, function (st) { each(st.pts, function (p) { minX = Math.min(minX, p[0]); minY = Math.min(minY, p[1]); maxX = Math.max(maxX, p[0]); maxY = Math.max(maxY, p[1]); }); });
      var m = 16, sc = 2, off = el('canvas');
      off.width = Math.round((maxX - minX + 2 * m) * sc); off.height = Math.round((maxY - minY + 2 * m) * sc);
      var og = off.getContext('2d'); og.fillStyle = '#fff'; og.fillRect(0, 0, off.width, off.height);
      paint(og, '#000', sc, minX - m, minY - m);
      var data = off.toDataURL('image/png').split(',')[1];
      busy = true; e.className += ' busy'; deckToast('Reading your handwriting…');
      api.post('/note/ink', { image: data }, function (st, t) {
        busy = false; e.className = e.className.replace(/ busy/g, '');
        var j = {}; try { j = JSON.parse(t); } catch (x) {}
        if (st !== 200 || !j.ok) { deckToast('Could not save: allow PhoneDeck to control Notes on the Mac'); return; }
        strokes.length = 0; delete PD.inkDrafts[ctx.key]; redraw();
        var first = (j.text || '').split('\n')[0];
        deckToast(first ? 'Saved to Notes: “' + (first.length > 28 ? first.slice(0, 28) + '…' : first) + '”' : 'Saved to Notes (no text recognized)');
      });
    }
    setTimeout(fit, 0);
    return { update: function () { if (c.width !== Math.round(pad.clientWidth * dpr)) fit(); } };
  };

  // WhatsApp: recent chats (from WhatsApp for Mac's local database); tap one to read and reply.
  var WA_COLORS = ['#25D366', '#34B7F1', '#FF9230', '#DB34F2', '#FF375F', '#6D7CFF', '#00C3D0', '#FFB800'];
  function waAvatar(c) {
    var h = 0, n = c.name || '?'; for (var i = 0; i < n.length; i++) h = (h * 31 + n.charCodeAt(i)) % 997;
    var initials = n.replace(/[^\w\s]/g, '').split(/\s+/).filter(function (x) { return x; }).slice(0, 2).map(function (x) { return x.charAt(0).toUpperCase(); }).join('') || '?';
    return '<span class="wav" style="background:' + WA_COLORS[h % WA_COLORS.length] + '">' + (c.group ? icon(G.group) : esc(initials)) + '</span>';
  }
  function waTime(ms) {
    var d = new Date(ms), now = new Date();
    if (d.toDateString() === now.toDateString()) return hm(ms);
    var y = new Date(now.getTime() - 86400000);
    return d.toDateString() === y.toDateString() ? 'Yesterday' : d.getDate() + '/' + (d.getMonth() + 1);
  }
  function waRow(c, compact) {
    return '<div class="war row" data-chat="' + c.id + '">' + waAvatar(c) + '<div class="grow"><div class="row"><b class="grow ell">' + esc(c.name) + '</b><span class="wat' + (c.unread ? ' un' : '') + '">' + waTime(c.at) + '</span></div>' +
      (compact ? '' : '<div class="row"><span class="was grow ell">' + (c.fromMe ? '<i class="wme">You: </i>' : '') + esc(c.text) + '</span>' + (c.unread ? '<span class="wau">' + c.unread + '</span>' : '') + '</div>') + '</div></div>';
  }
  W.whatsapp = function (e, s, ctx) {
    var head = '<div class="row wah"><h3 class="grow" style="margin:0">WhatsApp</h3><span class="wa-unread"></span></div>';
    e.innerHTML = s === 'l' ? '<div class="row grow" style="-webkit-align-items:stretch;align-items:stretch"><div class="col walist-col">' + head + '<div class="walist grow"></div></div><div class="wapane grow"></div></div>'
      : (s === 's' || s === 'w' ? '' : head) + '<div class="walist grow' + (s === 'w' ? ' row' : '') + '"></div>';
    var list = q(e, '.walist'), pane = q(e, '.wapane'), last = 0, key = '', selected = null;
    var n = s === 's' ? 1 : s === 'w' ? 2 : rows(ctx, 2.75, 2.2);
    function paint(j) {
      var chats = (j.chats || []).slice(0, n);
      if (j.access === 'denied' || j.access === 'missing') {
        list.innerHTML = '<div class="empty">' + (j.access === 'missing' ? 'WhatsApp for Mac isn’t set up on this Mac.' : 'Allow PhoneDeck to read WhatsApp: give it Full Disk Access on the Mac.') + '</div>';
        return;
      }
      var k = JSON.stringify(chats); if (k === key) return; key = k;
      list.innerHTML = chats.length ? chats.map(function (c) { return waRow(c, false); }).join('') : '<div class="empty">No chats yet</div>';
      var total = 0; each(j.chats || [], function (c) { total += c.unread; });
      var u = q(e, '.wa-unread'); if (u) u.textContent = total ? total + ' unread' : '';
      if (pane && !selected && chats[0]) { selected = chats[0].id; ctx.deck.waPane(pane, selected); }
    }
    function fetch() {
      if (ctx.edit) { if (!key) list.innerHTML = waRow({ name: 'Chat', text: 'Messages appear here', at: Date.now(), unread: 2, id: 0 }); key = 'x'; return; }
      if (Date.now() - last < 3500) return; last = Date.now();
      api.json('/whatsapp/chats', 'limit=' + Math.max(n, 8), function (j) { if (j) paint(j); });
    }
    if (!ctx.edit) list.addEventListener('click', function (ev) {
      var r = closest(ev.target, 'data-chat', list); if (!r) return;
      var id = +r.getAttribute('data-chat');
      if (pane) { selected = id; ctx.deck.waPane(pane, id); } else ctx.deck.waOpen(id);
    });
    fetch();
    return { update: fetch };
  };

  PD.W = W;

  // ---------------------------------------------------------------- the deck
  // opts: { edit, onSelect(zone, index, item), selected: { zone, i } }
  function Deck(host, kind, opts) {
    this.host = host; this.kind = kind; this.p = PROFILES[kind]; this.opts = opts || {};
    this.page = 0; this.live = []; this.seen = null; this.banners = [];
    this.root = el('div', 'pd pd-' + kind);
    host.appendChild(this.root);
    var self = this;
    deckToast = function (m) { self.toast(m); };
  }
  PD.Deck = Deck;

  Deck.prototype.device = function () { return this.layout.devices[this.kind]; };

  Deck.prototype.setLayout = function (layout, W, H) {
    this.layout = layout;
    if (W) { this.W = W; this.H = H; }
    var dev = this.device();
    if (this.page >= dev.pages.length) this.page = Math.max(0, dev.pages.length - 1);
    this.render();
  };

  Deck.prototype.resize = function (W, H) { this.W = W; this.H = H; if (this.layout) this.render(); };

  Deck.prototype.theme = function () {
    var L = this.layout, t = L.theme || 'auto';
    var night = t === 'night' || (t === 'auto' && (PD.data.dark === undefined ? true : PD.data.dark));
    var cls = 'pd pd-' + this.kind + (night ? ' night' : ' day') + ' wp-' + (L.wallpaper || 'aurora') +
      (this.p.fx && PD.modern ? ' fx' : '') + (L.glass === false ? ' noglass' : '') +
      (this.device().labels === false ? ' nolabels' : '') + (this.opts.edit ? ' edit' : '') + (this.arranging ? ' jiggle' : '');
    if (this.root.className !== cls) this.root.className = cls;
    this.root.style.setProperty('--accent', L.accent || '#0091FF');
  };

  Deck.prototype.geometry = function () {
    var p = this.p, dev = this.device(), W = this.W, H = this.H;
    var grid = p.grid[dev.density] || p.grid.compact, cols = grid[0], rows = grid[1];
    var dockH = dev.dock && dev.dock.on ? p.dockH : 0;
    var top = p.header, bottom = H - p.foot - dockH;
    var cw = (W - 2 * p.pad - (cols - 1) * p.gap) / cols, ch = (bottom - top - (rows - 1) * p.gap) / rows;
    // 1em = Body for this page; tablet capped at iOS's 17 pt Body.
    var fs = Math.max(12, Math.min(this.kind === 'tablet' ? 17 : 15, Math.round(Math.min(cw * 1.05, ch) / 6.1)));
    // Concentric corners: tiles take 13 % of a 2×2 widget's short side, like iOS home-screen widgets.
    var r = Math.round(Math.min(2 * cw + p.gap, 2 * ch + p.gap) * .13);
    return { cols: cols, rows: rows, cw: cw, ch: ch, top: top, areaH: bottom - top, dockH: dockH, fs: fs, pad: p.pad, gap: p.gap, r: r };
  };

  Deck.prototype.render = function () {
    var self = this, p = this.p, dev = this.device(), r = this.root, g = this.geo = this.geometry();
    this.theme();
    px(r, { width: this.W, height: this.H });
    r.style.fontSize = p.font + 'px';
    this.live = [];
    r.innerHTML = '<div class="wall"></div><div class="blobs"><i></i><i></i><i></i></div>';

    // header: clock · ticker or tabs · connection
    var hdr = el('div', 'hdr'); px(hdr, { height: p.header });
    hdr.innerHTML = '<div class="hclock"><span class="htime num"></span><span class="hampm"></span><span class="hdate"></span></div>' +
      '<div class="ticker"><span class="in"></span></div><div class="hright"><span class="link"></span><span class="mac">Mac</span></div>';
    px(q(hdr, '.hclock'), { left: p.pad + 2 }); px(q(hdr, '.hright'), { right: p.pad + 2 });
    var tk = q(hdr, '.ticker');
    if (p.tabs) {
      // Narrow screens with many pages: inactive tabs collapse to their icon.
      var tabs = el('div', 'tabs' + (this.kind === 'phone' && dev.pages.length > 3 && !find(dev.pages, function (pg) { return !PD.iconName(pg.icon); }) ? ' compact' : ''));
      each(dev.pages, function (pg, i) {
        var t = el('div', i === self.page ? 'on' : '', (PD.iconName(pg.icon) ? '<i>' + PD.iconSvg(pg.icon) + '</i>' : '') + esc(pg.name));
        tap(t, function () { if (!self.opts.edit) self.goTo(i); else if (self.opts.onPage) self.opts.onPage(i); });
        tabs.appendChild(t);
      });
      hdr.appendChild(tabs);
      tk.style.position = 'static'; tk.style.display = 'inline-block'; tk.style.verticalAlign = 'middle'; tk.style.marginTop = '0'; tk.style.maxWidth = Math.round(this.W * .2) + 'px';
      q(hdr, '.hright').insertBefore(tk, q(hdr, '.link'));
    } else {
      px(tk, { left: this.W / 2 - 100, width: 200, top: 7 });
      if (p.dotsInHeader) q(hdr, '.hright').style.top = '14px';   // same line as the battery ticker
    }
    // Edit mode (jiggle): "+" opens the gallery, Done leaves edit mode
    var abar = el('div', 'abar', '<div class="aplus">+</div><div class="adone">Done</div>');
    px(q(abar, '.aplus'), { left: p.pad }); px(q(abar, '.adone'), { right: p.pad });
    hdr.appendChild(abar);
    tap(q(abar, '.aplus'), function () { self.openGallery(); });
    tap(q(abar, '.adone'), function () { self.arrange(false); });
    r.appendChild(hdr);
    this.hdr = hdr;

    // pages
    // The pager clips horizontally (pages slide), so give it room above and below the grid: shadows and
    // glass then fade out under the header and dock instead of ending in a hard line.
    var bleed = this.bleed = Math.round(Math.min(g.top, 32));
    var pager = el('div', 'pager'); px(pager, { top: g.top - bleed, height: g.areaH + bleed * 2 });
    var track = el('div', 'track'); px(track, { width: this.W * dev.pages.length });
    pager.appendChild(track); r.appendChild(pager);
    this.pager = pager; this.track = track;
    this.pages = [];
    this.overflow = [];
    each(dev.pages, function (pg, i) {
      var pe = el('div', 'page'); px(pe, { left: i * self.W, width: self.W, top: bleed, height: g.areaH }); pe.style.fontSize = g.fs + 'px';
      pe.style.setProperty('--r', g.r + 'px');
      track.appendChild(pe);
      var placed = PD.pack(pg.items, g.cols, g.rows), live = [];
      self.renderPage = i;
      each(placed, function (pl) {
        if (pl.overflow) { if (i === self.page) self.overflow.push(pl.i); return; }
        var box = { left: g.pad + pl.c * (g.cw + g.gap), top: pl.r * (g.ch + g.gap), width: pl.w * g.cw + (pl.w - 1) * g.gap, height: pl.h * g.ch + (pl.h - 1) * g.gap };
        var node = self.item(pl.item, box, live, 'page', pl.i);
        if (node) pe.appendChild(node);
      });
      if (self.opts.edit) each(placed.free, function (rc) {
        var s = el('div', 'slot'); s.setAttribute('data-slot', rc[0] + ',' + rc[1]);
        px(s, { left: g.pad + rc[1] * (g.cw + g.gap) + 3, top: rc[0] * (g.ch + g.gap) + 3, width: g.cw - 6, height: g.ch - 6 });
        pe.appendChild(s);
      });
      self.pages.push({ el: pe, live: live });
    });

    // footer dots (+ page name on the 4S, which has no tab bar)
    var dots = el('div', 'dots');
    if (p.dotsInHeader) px(dots, { top: p.header - 13, height: 8 });
    else px(dots, { bottom: g.dockH + (p.foot - 7) / 2, height: 10 });
    each(dev.pages, function (pg, i) { var d = el('i', i === self.page ? 'on' : ''); dots.appendChild(d); });

    if (dev.pages.length < 2 && p.tabs) dots.style.display = 'none';
    r.appendChild(dots); this.dots = dots;

    // dock (iPad)
    this.dockLive = [];
    if (g.dockH) {
      var dock = el('div', 'dock'); px(dock, { bottom: 14 });
      var iconPx = Math.round(g.dockH - 34);
      each(dev.dock.items || [], function (it, i) {
        var node = self.item(it, { width: iconPx, height: iconPx }, self.dockLive, 'dock', i, true);
        if (node) dock.appendChild(node);
      });
      if (!(dev.dock.items || []).length) dock.innerHTML = '<span class="muted" style="padding:0 1em;line-height:' + iconPx + 'px">Add apps to the dock in the Command Center</span>';
      r.appendChild(dock);
    }

    this.pageName = el('div', 'pagename'); px(this.pageName, { top: p.header + 6 }); r.appendChild(this.pageName);
    this.bannerEl = el('div', 'banner'); px(this.bannerEl, { top: 8 }); r.appendChild(this.bannerEl);
    tap(this.bannerEl, function () { var b = self.bannerItem; if (b && b.path) launch(b.path, b.app); self.hideBanner(); });
    this.toastEl = el('div', 'toast'); px(this.toastEl, { top: p.header + 4 }); r.appendChild(this.toastEl);
    var rot = el('div', 'rotate', '↻<br>Turn to landscape'); r.appendChild(rot); this.rotateEl = rot;

    this.place(false);
    if (!this.opts.edit) this.swipe();
    else this.bindEdit();
    if (this.arranging) this.decorate();
    this.update(PD.data, true);
  };

  // One grid item: an app key, Claude key, action key or widget. box: px rect inside the page.
  Deck.prototype.item = function (it, box, live, zone, index, inDock) {
    var self = this, g = this.geo, edit = this.opts.edit, node;
    if (it.t === 'w') {
      var def = PD.WIDGETS[it.w], build = W[it.w];
      if (!def || !build) return null;
      node = el('div', 'tile w-' + it.w + ' s-' + it.s);
      px(node, box);
      var inner = el('div', 'tin w-' + it.w + ' s-' + it.s);   // clips content; the tile keeps its shadow
      node.appendChild(inner);
      // iOS insets widgets by ~10 % of their short side; inner corners stay concentric (r − pad).
      var pad = Math.max(9, Math.min(20, Math.round(Math.min(box.width, box.height) * .1)));
      node.style.setProperty('--pad', pad + 'px');
      node.style.setProperty('--r-in', Math.max(5, g.r - pad) + 'px');
      var inst;
      try { inst = build(inner, it.s, { w: box.width, h: box.height, fs: g.fs, edit: edit, deck: this, key: this.kind + ':' + (zone === 'dock' ? 'dock' : this.renderPage) + ':' + index }); }
      catch (err) {
        inner.innerHTML = '<div class="empty">' + esc(def.label) + ' couldn’t load</div>'; inst = { update: function () {} };
        if (root.onerror) root.onerror('widget ' + it.w + ': ' + (err && err.message), 'deck.js', 0, 0);
      }
      inst.widget = it.w;
      live.push(inst);
      if (edit) node.className += ' widget-inert';
      else this.bindItem(node, zone, index, it, null, null);
    } else {
      var labelH = this.device().labels === false || inDock ? 0 : 17;
      // cap = the visible squircle (macOS icon margins are cropped away), sized like iOS home-screen icons
      var size = inDock ? box.width : Math.round(Math.min(Math.min(box.width * .78, box.height - labelH - 2) * .86, this.kind === 'tablet' ? 72 : 999));
      var capTop = inDock ? 0 : Math.max(0, (box.height - size - labelH) / 2);
      node = el('div', 'key');
      if (!inDock) px(node, { left: box.left, top: box.top, width: box.width, height: box.height });
      var cap = el('div', 'cap'); px(cap, { width: size, height: size, marginTop: capTop });
      if (it.t === 'action') cap.style.borderRadius = Math.round(size * .2237) + 'px';
      node.appendChild(cap);
      var lbl = el('div', 'lbl'); node.appendChild(lbl);
      var path = null, label = '', run = null, hold = null;
      if (it.t === 'app') {
        var a = PD.appByPath(it.path) || (it.name && PD.appByName(it.name));
        path = a ? a.path : it.path; label = a ? a.name : it.name || 'App';
        cap.innerHTML = '<img src="' + esc(PD.iconUrl(path)) + '" alt="">'; cap.className += ' mac';
        run = function () { launch(path, label); };
      } else if (it.t === 'claude') {
        // Talk to Claude: tap to speak (the device's own mic) and start or continue a Claude conversation on the Mac
        var c = PD.appByName('Claude'); path = c ? c.path : null; label = 'Talk to Claude';
        cap.innerHTML = c ? '<img src="' + esc(PD.iconUrl(c.path)) + '" alt="">' : '<div class="claude-fb">' + icon(G.claude) + '</div>';
        if (c) cap.className += ' mac';
        cap.innerHTML += '<span class="talk-dot">' + icon(G.waveform) + '</span>';
        run = function () { self.talk(); };
        hold = function () { api.post('/claude', { 'new': '1' }, function (s) { self.toast(s === 200 ? 'New Claude chat' : 'Could not reach the Mac'); }); };
      } else if (it.t === 'project') {
        // Claude Code in a project folder (opens Terminal there with `claude` running)
        node.className += ' proj';
        label = it.name || 'Project';
        cap.innerHTML = '<div class="pj">' + icon(G.folder) + '<span>' + icon(G.code) + '</span></div>';
        run = function () { api.post('/project', { path: it.path }, function (s, t) { self.toast(s === 200 && /true/.test(t) ? 'Claude Code · ' + label : 'Could not open ' + label); }); };
      } else if (it.t === 'action') {
        var ac = PD.ACTIONS[it.a]; if (!ac) return null;
        node.className += ' act' + (ac.alert ? ' alert' : '');
        cap.innerHTML = icon(G[ac.g]); label = ac.label;
        run = function () { PD.runAction(it.a); setTimeout(function () { self.update(PD.data); }, 0); };
      } else return null;
      lbl.textContent = label;
      node.setAttribute('data-path', path || '');
      node.title = label;
      if (!edit) this.bindItem(node, zone, index, it, run, hold);
      live.push({ key: node, item: it, update: function (d) { self.keyState(node, it, d); } });
    }
    node.setAttribute('data-i', index); node.setAttribute('data-zone', zone);
    if (edit) {
      node.setAttribute('draggable', 'true');
      var sel = this.opts.selected;
      if (sel && sel.zone === zone && sel.i === index) node.className += ' sel';
    }
    return node;
  };

  Deck.prototype.keyState = function (node, it, d) {
    var notes = d.notes || {}, badges = notes.badges || {}, path = node.getAttribute('data-path');
    var label = path && badges[path];
    var b = q(node, '.badge');
    if (label) { if (!b) { b = el('span', 'badge'); q(node, '.cap').appendChild(b); } b.textContent = label === '•' || label === '' ? '' : label; }
    else if (b) b.parentNode.removeChild(b);
    if (it.t === 'action') {
      var ac = PD.ACTIONS[it.a], on = false;
      if (ac.state) on = !!ac.state(d.controls || {});
      if (it.a === 'cam') on = PD.media.cam;
      if (it.a === 'mic') on = PD.media.mic;
      var cls = node.className.replace(/ on\b/g, '') + (on ? ' on' : '');
      if (cls !== node.className) node.className = cls;
    }
  };

  // ---------------------------------------------------------------- paging
  Deck.prototype.place = function (animate) {
    var t = this.track, x = -this.page * this.W;
    t.className = 'track' + (animate === false ? ' drag' : '');
    t.style.webkitTransform = t.style.transform = 'translate3d(' + x + 'px,0,0)';
    var dev = this.device(), self = this;
    each(this.pages || [], function (pg, i) { pg.el.className = 'page' + (Math.abs(i - self.page) > 1 ? ' far' : ''); });
    each(this.dots.querySelectorAll('i'), function (d, i) { d.className = i === self.page ? 'on' : ''; });
    var nm = q(this.dots, 'span'); if (nm) nm.textContent = dev.pages[this.page] ? dev.pages[this.page].name : '';
    var tabs = q(this.hdr, '.tabs');
    if (tabs) each(tabs.children, function (c, i) { c.className = i === self.page ? 'on' : ''; });
  };

  Deck.prototype.goTo = function (i, fromSwipe) {
    var dev = this.device(), self = this;
    i = Math.max(0, Math.min(dev.pages.length - 1, i));
    var changed = i !== this.page;
    this.page = i;
    this.place(true);
    if (!changed) return;
    store('page-' + this.kind, String(i));
    this.update(PD.data, true);
    if (this.arranging) this.decorate();
    if (!this.p.tabs || fromSwipe) {
      this.pageName.innerHTML = PD.iconSvg(dev.pages[i].icon) + esc(dev.pages[i].name);
      this.pageName.className = 'pagename on';
      clearTimeout(this.pnT); this.pnT = setTimeout(function () { self.pageName.className = 'pagename'; }, 900);
    }
    // A page can switch the Mac's Focus (or run any shortcut) when it opens. Wait for the swipe to settle.
    clearTimeout(this.scT);
    var sc = dev.pages[i].shortcut;
    if (sc && !this.opts.edit) this.scT = setTimeout(function () {
      api.post('/shortcut', { name: sc }, function (s) { self.toast(s === 200 ? 'Ran “' + sc + '”' : 'Shortcut “' + sc + '” failed'); });
    }, 900);
    if (this.opts.onPage) this.opts.onPage(i);
  };

  Deck.prototype.swipe = function () {
    var self = this, pager = this.pager, sx = 0, sy = 0, st = 0, dx = 0, mode = null;
    var lp = null, onItem = false;
    pager.addEventListener('touchstart', function (e) {
      if (e.touches.length !== 1) return;
      sx = e.touches[0].clientX; sy = e.touches[0].clientY; st = Date.now(); dx = 0; mode = null;
      onItem = !!closest(e.target, 'data-zone', pager);
      clearTimeout(lp);
      if (!onItem && !self.arranging) lp = setTimeout(function () { self.arrange(true); if (navigator.vibrate) navigator.vibrate(10); }, 600);
    });
    pager.addEventListener('touchmove', function (e) {
      if (self.dragging) return;
      var x = e.touches[0].clientX - sx, y = e.touches[0].clientY - sy;
      if (Math.abs(x) + Math.abs(y) > 10) clearTimeout(lp);
      if (!mode) { if (Math.abs(x) < 8 && Math.abs(y) < 8) return; mode = Math.abs(x) > Math.abs(y) ? 'h' : 'v'; }
      if (mode !== 'h') return;
      e.preventDefault();
      var scale = self.scale || 1; dx = x / scale;
      var n = self.device().pages.length;
      if ((self.page === 0 && dx > 0) || (self.page === n - 1 && dx < 0)) dx = dx / 3;   // rubber band at the ends
      self.track.className = 'track drag';
      self.track.style.webkitTransform = self.track.style.transform = 'translate3d(' + (-self.page * self.W + dx) + 'px,0,0)';
    }, false);
    pager.addEventListener('touchend', function () {
      clearTimeout(lp);
      if (self.dragging) return;
      if (!mode && !onItem && self.arranging && Date.now() - st < 400) { self.arrange(false); return; }
      if (mode !== 'h') return;
      var fast = Date.now() - st < 300 && Math.abs(dx) > 30;
      if (dx < -self.W * .18 || (fast && dx < 0)) self.goTo(self.page + 1, true);
      else if (dx > self.W * .18 || (fast && dx > 0)) self.goTo(self.page - 1, true);
      else self.place(true);
      mode = null;
    });
    // Mac trackpad / mouse wheel (Command Center window, desktop Safari)
    var wheelT = 0;
    pager.addEventListener('wheel', function (e) {
      if (Math.abs(e.deltaX) < Math.abs(e.deltaY) || Math.abs(e.deltaX) < 20 || Date.now() - wheelT < 600) return;
      wheelT = Date.now(); self.goTo(self.page + (e.deltaX > 0 ? 1 : -1), true);
    });
  };

  // ---------------------------------------------------------------- iOS-style editing on the device
  // Tap = run. Long-press = context menu (like iOS quick actions); keep dragging from the menu, or drag
  // anything while jiggling, to move it to any free cell. Long-press empty space also starts jiggling.
  Deck.prototype.bindItem = function (node, zone, idx, it, run, hold) {
    var self = this, timer = null, sx = 0, sy = 0, moved = false, mode = null;
    function unpress() { node.className = node.className.replace(/ down/g, ''); }
    node.addEventListener('touchstart', function (e) {
      if (e.touches.length !== 1 || self.menuEl || self.galEl) return;
      sx = e.touches[0].clientX; sy = e.touches[0].clientY; moved = false; mode = null;
      if (self.arranging) return;
      if (it.t !== 'w') node.className += ' down';
      timer = setTimeout(function () {
        unpress(); mode = 'menu'; self.openMenu(node, zone, idx, it, run, hold);
        if (navigator.vibrate) navigator.vibrate(10);
      }, 480);
    });
    node.addEventListener('touchmove', function (e) {
      var x = e.touches[0].clientX, y = e.touches[0].clientY, d = Math.abs(x - sx) + Math.abs(y - sy);
      if (mode === 'drag') { e.preventDefault(); self.dragMove(x, y); return; }
      if ((self.arranging || mode === 'menu') && zone === 'page' && d > 8) {
        if (mode === 'menu') { self.closeMenu(); self.arrange(true); }
        mode = 'drag'; e.preventDefault(); self.dragStart(node, idx, sx, sy); self.dragMove(x, y);
        return;
      }
      if (d > 10) { moved = true; clearTimeout(timer); unpress(); }
    });
    node.addEventListener('touchend', function (e) {
      clearTimeout(timer); unpress();
      if (mode === 'drag') { e.preventDefault(); mode = null; self.dragEnd(); return; }
      if (mode === 'menu') { e.preventDefault(); mode = null; return; }
      if (self.arranging) { e.preventDefault(); return; }
      if (!moved && run) { e.preventDefault(); run(); }
    });
    node.addEventListener('touchcancel', function () { clearTimeout(timer); unpress(); if (mode === 'drag') self.dragEnd(true); mode = null; });
    node.addEventListener('click', function () { if (!self.arranging && run && !self.menuEl) run(); });
  };

  function onTap(node, fn) {   // tap that never reaches the item underneath
    node.addEventListener('touchstart', function (e) { e.stopPropagation(); });
    node.addEventListener('touchmove', function (e) { e.stopPropagation(); });
    node.addEventListener('touchend', function (e) { e.stopPropagation(); e.preventDefault(); fn(); });
    node.addEventListener('click', function (e) { e.stopPropagation(); fn(); });
  }
  var G_RESIZE = '<path d="M14 4h6v6M10 20H4v-6M20 4l-7 7M4 20l7-7"/>';

  Deck.prototype.arrange = function (on) {
    on = !!on;
    if (!!this.arranging === on) return;
    this.arranging = on;
    this.closeMenu(); this.closeGallery();
    this.theme();
    if (on) this.decorate();
    else {
      each(this.root.querySelectorAll('.del, .rsz'), function (n) { n.parentNode.removeChild(n); });
      if (this.pendingReload && this.opts.reload) { this.pendingReload = false; this.opts.reload(); }
    }
  };

  // Delete badges (and a size button on widgets) on every item.
  Deck.prototype.decorate = function () {
    var self = this, nodes = [], pg = this.pages[this.page], dock = q(this.root, '.dock');
    if (pg) each(pg.el.querySelectorAll('[data-zone]'), function (n) { nodes.push(n); });
    if (dock) each(dock.querySelectorAll('[data-zone]'), function (n) { nodes.push(n); });
    each(nodes, function (n) {
      if (q(n, '.del')) return;
      var zone = n.getAttribute('data-zone'), i = +n.getAttribute('data-i'), tile = /\btile\b/.test(n.className);
      var d = el('div', 'del', '<i></i>');
      (tile ? n : q(n, '.cap') || n).appendChild(d);
      onTap(d, function () { self.removeItem(zone, i); });
      if (tile) {
        var it = self.device().pages[self.page] && self.listFor(zone)[i], def = it && PD.WIDGETS[it.w];
        if (def && def.sizes.length > 1) { var z = el('div', 'rsz', icon(G_RESIZE)); n.appendChild(z); onTap(z, function () { self.cycleSize(n, i); }); }
      }
    });
  };

  Deck.prototype.listFor = function (zone, pageIdx) {
    var dev = this.device();
    return zone === 'dock' ? dev.dock.items : dev.pages[pageIdx === undefined ? this.pageOf(zone) : pageIdx].items;
  };
  Deck.prototype.pageOf = function () { return this.page; };

  Deck.prototype.commit = function () {
    var self = this;
    this.render();
    PD.saveLayout(this.layout, function (ok) { if (!ok) self.toast('Could not save to the Mac'); });
  };

  Deck.prototype.removeItem = function (zone, i) {
    var list = this.listFor(zone);
    if (!list[i]) return;
    list.splice(i, 1);
    this.commit();
  };

  Deck.prototype.cycleSize = function (node, i) {
    var g = this.geo, items = this.listFor('page'), it = items[i], def = PD.WIDGETS[it.w];
    var sizes = PD.SIZE_ORDER.filter(function (sz) { return def.sizes.indexOf(sz) >= 0; });
    it.s = sizes[(sizes.indexOf(it.s) + 1) % sizes.length];
    PD.pinAll(items, g.cols, g.rows);
    if (it.pos) PD.moveItem(items, i, it.pos[0], it.pos[1], g.cols, g.rows);
    this.toast(def.label + ' · ' + PD.SIZE_NAMES[it.s]);
    this.commit();
  };

  // ----- context menu (long-press)
  Deck.prototype.openMenu = function (node, zone, idx, it, run, hold) {
    var self = this, s = this.scale || 1, rr = this.root.getBoundingClientRect(), nr = node.getBoundingClientRect();
    this.closeMenu();
    var scrim = el('div', 'ctx-scrim'), menu = el('div', 'ctx'), opts = [];
    function opt(label, glyph, fn, cls) { opts.push({ label: label, glyph: glyph, fn: fn, cls: cls || '' }); }
    var where = zone === 'dock' ? 'Dock' : 'Page';
    if (it.t === 'app') { opt('Open', G.next, run); }
    if (it.t === 'claude') {
      opt('Talk to Claude', G.waveform, run); opt('New Chat', G.plus, hold);
      opt('Open Claude', G.next, function () { api.post('/claude', { text: '' }); self.toast('Opening Claude'); });
    }
    if (it.t === 'project') { opt('Open in Claude Code', G.terminal, run); }
    if (it.t === 'action') { opt(PD.ACTIONS[it.a].label, G[PD.ACTIONS[it.a].g], run); }
    if (it.t === 'w') {
      var def = PD.WIDGETS[it.w];
      each(PD.SIZE_ORDER, function (sz) {
        if (def.sizes.indexOf(sz) < 0) return;
        opt(PD.SIZE_NAMES[sz] + ' · ' + PD.SIZES[sz].join('×'), it.s === sz ? '<path d="M5 12.5l4.5 4.5L19 7.5"/>' : '', function () {
          var g = self.geo, items = self.listFor('page');
          it.s = sz; PD.pinAll(items, g.cols, g.rows);
          if (it.pos) PD.moveItem(items, idx, it.pos[0], it.pos[1], g.cols, g.rows);
          self.commit();
        });
      });
    }
    opt('Edit Deck', '<rect x="4" y="4" width="7" height="7" rx="2"/><rect x="13" y="4" width="7" height="7" rx="2"/><rect x="4" y="13" width="7" height="7" rx="2"/><rect x="13" y="13" width="7" height="7" rx="2"/>', function () { self.arrange(true); });
    opt('Remove from ' + where, '<path d="M5 7h14M10 7V5h4v2M7 7l1 12h8l1-12"/>', function () { self.removeItem(zone, idx); }, 'red');
    menu.innerHTML = opts.map(function (o, i) { return '<div class="ci ' + o.cls + '" data-o="' + i + '"><span>' + esc(o.label) + '</span>' + (o.glyph ? icon(o.glyph) : '') + '</div>'; }).join('');
    this.root.appendChild(scrim); this.root.appendChild(menu);
    // place under the item, or above it when there is no room
    var x = (nr.left - rr.left) / s, y = (nr.bottom - rr.top) / s + 8, mw = menu.offsetWidth, mh = menu.offsetHeight;
    if (y + mh > this.H - 8) y = (nr.top - rr.top) / s - mh - 8;
    px(menu, { left: Math.max(8, Math.min(this.W - mw - 8, x)), top: Math.max(8, y) });
    this.menuEl = menu; this.scrimEl = scrim;
    onTap(scrim, function () { self.closeMenu(); });
    each(menu.querySelectorAll('.ci'), function (c) {
      onTap(c, function () { var o = opts[+c.getAttribute('data-o')]; self.closeMenu(); if (o.fn) o.fn(); });
    });
  };
  Deck.prototype.closeMenu = function () {
    if (this.menuEl) { this.root.removeChild(this.menuEl); this.root.removeChild(this.scrimEl); }
    this.menuEl = this.scrimEl = null;
  };

  // ----- free dragging between cells (and across pages at the screen edge)
  Deck.prototype.dragStart = function (node, idx) {
    var D = this.dragging = { node: node, idx: idx, left: parseFloat(node.style.left) || 0, top: parseFloat(node.style.top) || 0, cell: null, edge: 0 };
    var t = node.getBoundingClientRect(); D.sx = null; D.rect = t;
    node.className += ' lifted';
    this.ph = el('div', 'ph');
    this.pages[this.page].el.insertBefore(this.ph, this.pages[this.page].el.firstChild);
  };
  Deck.prototype.dragMove = function (x, y) {
    var D = this.dragging, self = this; if (!D) return;
    if (D.sx === null) { D.sx = x; D.sy = y; }
    var s = this.scale || 1, g = this.geo, dx = (x - D.sx) / s, dy = (y - D.sy) / s;
    D.node.style.webkitTransform = D.node.style.transform = 'translate3d(' + dx + 'px,' + dy + 'px,0) scale(1.06)';
    var it = this.listFor('page')[D.idx], d = dims(it, g.cols, g.rows);
    var c = Math.round((D.left + dx - g.pad) / (g.cw + g.gap)), r = Math.round((D.top + dy) / (g.ch + g.gap));
    c = Math.max(0, Math.min(g.cols - d[0], c)); r = Math.max(0, Math.min(g.rows - d[1], r));
    D.cell = [c, r];
    px(this.ph, { left: g.pad + c * (g.cw + g.gap), top: r * (g.ch + g.gap), width: d[0] * g.cw + (d[0] - 1) * g.gap, height: d[1] * g.ch + (d[1] - 1) * g.gap });
    var stageX = (x - this.root.getBoundingClientRect().left) / s, edge = stageX < 24 ? -1 : stageX > this.W - 24 ? 1 : 0;
    if (edge !== D.edge) {
      clearTimeout(D.et); D.edge = edge;
      if (edge) D.et = setTimeout(function () { self.dragToPage(edge); }, 650);
    }
  };
  Deck.prototype.dragEnd = function (cancel) {
    var D = this.dragging; if (!D) return;
    clearTimeout(D.et); this.dragging = null;
    if (cancel || !D.cell) { this.render(); return; }
    var g = this.geo;
    PD.moveItem(this.listFor('page'), D.idx, D.cell[0], D.cell[1], g.cols, g.rows);
    this.commit();
  };
  Deck.prototype.dragToPage = function (dir) {
    var D = this.dragging, dev = this.device(), to = this.page + dir; if (!D) return;
    if (to < 0 || to >= dev.pages.length) return;
    var g = this.geo, item = dev.pages[this.page].items.splice(D.idx, 1)[0];
    delete item.pos;
    var ok = PD.addItem(dev.pages[to].items, item, g.cols, g.rows);
    if (!ok) dev.pages[this.page].items.splice(D.idx, 0, item);
    clearTimeout(D.et); this.dragging = null;
    if (ok) { this.page = to; store('page-' + this.kind, String(to)); if (this.opts.onPage) this.opts.onPage(to); }
    this.toast(ok ? 'Moved to ' + dev.pages[to].name : dev.pages[to].name + ' is full');
    this.commit();
  };

  // ----- Talk to Claude (Siri-style sheet). Modern Safari on the secure page listens with the device's own
  // mic (iPads aren't Continuity microphones for the Mac, so the words travel instead of the audio);
  // elsewhere the sheet takes typed or keyboard-dictated text. The first message starts a new chat,
  // anything within 5 minutes continues it.
  PD.talkAt = 0;
  Deck.prototype.talk = function (mode) {
    var self = this, R = root.SpeechRecognition || root.webkitSpeechRecognition, listen = !!(R && root.isSecureContext);
    this.closeTalk();
    var note = mode === 'note', cont = !note && mode !== 'ask' && Date.now() - PD.talkAt < 5 * 60000;
    var scrim = el('div', 'ctx-scrim'), t = el('div', 'talk');
    t.innerHTML = '<div class="tk-orb' + (note ? ' note' : '') + '"><i></i><i></i>' + icon(note ? G.note : G.claude) + '</div>' +
      '<div class="tk-h">' + (note ? 'New Note' : cont ? 'Reply to Claude' : mode === 'ask' ? 'Ask Claude' : 'Talk to Claude') + '</div>' +
      (listen ? '<div class="tk-tx">Listening…</div>' : '<textarea class="tk-in" placeholder="Type, or use the keyboard’s dictation key"></textarea>') +
      '<div class="tk-b"><span class="tk-x">Cancel</span><span class="tk-s">' + (listen ? 'Done' : 'Send') + '</span></div>' +
      (!listen && PD.modern && !root.isSecureContext ? '<div class="tk-hint">Open the secure deck to talk instead of typing.</div>' : '');
    this.root.appendChild(scrim); this.root.appendChild(t);
    this.talkEl = t; this.talkScrim = scrim;
    var text = '', rec = null, sent = false;
    function setState(cls, msg) { t.className = 'talk ' + cls; var tx = q(t, '.tk-tx'); if (tx && msg !== undefined) tx.textContent = msg; }
    function send() {
      if (sent) return;
      var msg = (listen ? text : q(t, '.tk-in').value).replace(/^\s+|\s+$/g, '');
      if (!msg) { if (listen) setState('idle', 'Didn’t catch that. Tap the orb to try again.'); return; }
      sent = true;
      if (note) {
        api.post('/note', { text: msg }, function (s, tx) {
          var ok = s === 200 && /true/.test(tx);
          self.closeTalk();
          self.toast(ok ? 'Saved to Notes' : 'Could not save the note (allow PhoneDeck to control Notes on the Mac)');
        });
        return;
      }
      var body = cont ? { text: msg, mode: 'reply' } : { text: msg, send: '1' };
      api.post('/claude', body, function (s) {
        if (s !== 200) { self.toast('Could not reach the Mac'); sent = false; return; }
        PD.talkAt = Date.now();
        self.closeTalk();
        self.toast(cont ? 'Sent to Claude' : 'New conversation with Claude');
      });
    }
    function start() {
      if (!listen) { var inp = q(t, '.tk-in'); inp.focus(); return; }
      text = ''; sent = false;
      rec = new R(); rec.lang = navigator.language || 'en-US'; rec.interimResults = true; rec.continuous = false;
      rec.onresult = function (e) {
        var fin = '', interim = '';
        for (var i = 0; i < e.results.length; i++) { if (e.results[i].isFinal) fin += e.results[i][0].transcript; else interim += e.results[i][0].transcript; }
        text = fin + interim; setState('live', text || 'Listening…');
      };
      rec.onerror = function (e) { setState('idle', e.error === 'not-allowed' ? 'Allow the microphone for this page in Safari.' : 'Could not hear you. Tap to try again.'); rec = null; };
      rec.onend = function () { rec = null; if (text) send(); else if (!sent) setState('idle', 'Didn’t catch that. Tap the orb to try again.'); };
      setState('live', 'Listening…');
      rec.start();
    }
    onTap(q(t, '.tk-orb'), function () { if (rec) rec.stop(); else start(); });
    onTap(q(t, '.tk-x'), function () { if (rec) rec.abort(); self.closeTalk(); });
    onTap(q(t, '.tk-s'), function () { if (rec) rec.stop(); else send(); });
    onTap(scrim, function () { if (rec) rec.abort(); self.closeTalk(); });
    start();   // must run inside the tap so iOS allows the mic / keyboard
  };
  // ----- WhatsApp conversation: bubbles, quick replies, reply field (voice dictation on modern devices)
  Deck.prototype.waOpen = function (chat) {
    var self = this; this.waClose();
    var scrim = el('div', 'ctx-scrim'), sh = el('div', 'wa-sheet');
    this.root.appendChild(scrim); this.root.appendChild(sh);
    this.waEl = sh; this.waScrim = scrim;
    onTap(scrim, function () { self.waClose(); });
    this.waPane(sh, chat, true);
  };
  Deck.prototype.waClose = function () {
    if (this.waEl) { clearInterval(this.waEl.timer); this.root.removeChild(this.waEl); this.root.removeChild(this.waScrim); }
    this.waEl = this.waScrim = null;
  };
  Deck.prototype.waPane = function (box, chat, sheet) {
    var self = this, info = {}, R = root.SpeechRecognition || root.webkitSpeechRecognition, canTalk = !!(R && root.isSecureContext);
    clearInterval(box.timer);
    box.innerHTML = '<div class="row wa-top">' + (sheet ? '<span class="wa-x press">' + icon('<path d="M15 5l-7 7 7 7"/>') + '</span>' : '') +
      '<span class="wa-who grow ell">…</span></div><div class="wa-msgs"></div><div class="wa-quick"></div>' +
      '<div class="row wa-comp"><input class="wa-in" placeholder="Message" autocorrect="on">' + (canTalk ? '<span class="wa-mic press">' + icon(G.mic) + '</span>' : '') + '<span class="wa-send press">' + icon(G.send) + '</span></div><div class="wa-note"></div>';
    var msgs = q(box, '.wa-msgs'), input = q(box, '.wa-in'), key = '';
    each(['touchstart', 'touchmove', 'touchend'], function (t) { box.addEventListener(t, function (ev) { ev.stopPropagation(); }); });   // no page swipe / long-press inside
    if (sheet) onTap(q(box, '.wa-x'), function () { self.waClose(); });
    function load() {
      api.json('/whatsapp/messages', 'chat=' + chat, function (j) {
        if (!j) return;
        info = j;
        q(box, '.wa-who').innerHTML = waAvatar({ name: j.name, group: j.group }) + '<b>' + esc(j.name || 'Chat') + '</b>';
        q(box, '.wa-note').textContent = j.canSend ? '' : (j.group ? 'Group chat: ' : '') + 'your reply is copied and WhatsApp opens on the Mac to paste it.';
        var k = JSON.stringify(j.messages || []); if (k === key) return; key = k;
        var lastDay = '';
        msgs.innerHTML = (j.messages || []).map(function (m) {
          var day = new Date(m.at).toDateString(), sep = day !== lastDay ? '<div class="wa-day">' + waTime(m.at).replace(/^\d+:\d+.*$/, 'Today') + '</div>' : '';
          lastDay = day;
          return sep + '<div class="wa-b ' + (m.me ? 'me' : 'them') + (m.media ? ' media' : '') + '">' + (j.group && !m.me && m.from ? '<i class="wa-from">' + esc(m.from) + '</i>' : '') +
            esc(m.text) + '<span class="wa-t">' + hm(m.at) + '</span></div>';
        }).join('');
        msgs.scrollTop = msgs.scrollHeight;
      });
    }
    function send(text) {
      text = (text === undefined ? input.value : text).replace(/^\s+|\s+$/g, '');
      if (!text) return;
      input.value = ''; input.blur();
      var b = el('div', 'wa-b me pending', esc(text) + '<span class="wa-t">…</span>'); msgs.appendChild(b); msgs.scrollTop = msgs.scrollHeight;
      api.post('/whatsapp/reply', { chat: chat, text: text }, function (st, t) {
        var j = {}; try { j = JSON.parse(t); } catch (x) {}
        if (j.result === 'sent') { self.toast('Sent'); b.className = 'wa-b me'; setTimeout(load, 1500); }
        else if (j.result === 'copied') { self.toast('Reply copied: paste it in WhatsApp on the Mac'); b.className = 'wa-b me copied'; }
        else { self.toast('Could not send'); b.parentNode.removeChild(b); input.value = text; }
      });
    }
    q(box, '.wa-quick').innerHTML = ['OK', 'On my way', 'Call you later', 'Thanks!'].map(function (t) { return '<span class="wa-q press">' + esc(t) + '</span>'; }).join('');
    each(box.querySelectorAll('.wa-q'), function (qb) { onTap(qb, function () { send(qb.textContent); }); });
    onTap(q(box, '.wa-send'), function () { send(); });
    input.addEventListener('keydown', function (ev) { if (ev.keyCode === 13) { ev.preventDefault(); send(); } });
    var mic = q(box, '.wa-mic');
    if (mic) onTap(mic, function () {
      var rec = new R(); rec.lang = navigator.language || 'en-US'; rec.interimResults = true;
      mic.className = 'wa-mic press live';
      rec.onresult = function (ev) { var t = ''; for (var i = 0; i < ev.results.length; i++) t += ev.results[i][0].transcript; input.value = t; };
      rec.onend = function () { mic.className = 'wa-mic press'; };
      rec.onerror = function () { mic.className = 'wa-mic press'; self.toast('Could not hear you'); };
      rec.start();
    });
    load();
    box.timer = setInterval(load, 4000);
  };

  Deck.prototype.pickProject = function () {
    this.galPick = true;   // tapping a project opens it instead of adding a key
    this.openGallery('projects');
  };
  Deck.prototype.closeTalk = function () {
    if (this.talkEl) { this.root.removeChild(this.talkEl); this.root.removeChild(this.talkScrim); }
    this.talkEl = this.talkScrim = null;
  };

  // ----- "+" gallery: add widgets (in any size), controls and apps to the current page
  Deck.prototype.openGallery = function (tab) {
    var self = this, picking = this.galPick && tab === 'projects'; this.closeGallery(); this.galPick = picking;
    tab = tab || 'widgets';
    var gal = this.galEl = el('div', 'gal');
    gal.innerHTML = '<div class="gh"><div class="gseg"><span data-t="widgets">Widgets</span><span data-t="controls">Controls</span><span data-t="apps">Apps</span><span data-t="projects">Projects</span></div><div class="gx">Done</div></div>' +
      (tab === 'apps' ? '<input class="gf" placeholder="Search apps" autocorrect="off" autocapitalize="none">' : '') + '<div class="gb"></div>';
    this.root.appendChild(gal);
    if (this.galPick) q(gal, '.gseg').innerHTML = '<span class="on">Open in Claude Code</span>';
    each(gal.querySelectorAll('.gseg span'), function (sp) {
      if (sp.getAttribute('data-t') === tab) sp.className = 'on';
      tap(sp, function () { self.openGallery(sp.getAttribute('data-t')); });
    });
    tap(q(gal, '.gx'), function () { self.closeGallery(); });
    var body = q(gal, '.gb');
    function fill(filter) {
      var html = [];
      if (tab === 'widgets') each(Object.keys(PD.WIDGETS), function (k) {
        var w = PD.WIDGETS[k]; if (w.modern && !PD.modern) return;
        html.push('<div class="gw row"><span class="ge">' + PD.widgetIcon(k) + '</span><div class="grow"><b>' + esc(w.label) + '</b><small>' + esc(w.desc) + '</small></div><div class="gsz">' +
          PD.SIZE_ORDER.filter(function (sz) { return w.sizes.indexOf(sz) >= 0; }).map(function (sz) { return '<span data-add="w:' + k + ':' + sz + '">' + PD.SIZE_NAMES[sz] + '</span>'; }).join('') + '</div></div>');
      });
      if (tab === 'controls') each(Object.keys(PD.ACTIONS), function (k) {
        var a = PD.ACTIONS[k]; if (a.modern && !PD.modern) return;
        html.push('<div class="gk" data-add="a:' + k + '"><div class="gi">' + icon(G[a.g]) + '</div><span>' + esc(a.label) + '</span></div>');
      });
      if (tab === 'projects') {
        if (!PD.projects) { body.innerHTML = '<div class="empty" style="padding:20px">Loading projects…</div>'; PD.loadProjects(function () { fill(filter); }); return; }
        if (!PD.projects.length) html.push('<div class="empty" style="padding:20px">No projects found. Open a folder in Claude Code once, or keep repositories in ~/Developer, ~/Projects or ~/code.</div>');
        each(PD.projects, function (p) {
          html.push('<div class="ga row" data-add="j:' + esc(p.path) + '"><span class="gi pjg">' + icon(G.code) + '</span><div class="grow"><span>' + esc(p.name) + '</span><small>' + esc(p.path.replace(/^\/Users\/[^\/]+/, '~')) + '</small></div></div>');
        });
      }
      if (tab === 'apps') {
        var f = (filter || '').toLowerCase(), n = 0;
        if (!f || 'claude'.indexOf(f) >= 0) html.push('<div class="ga row" data-add="c:"><span class="gi" style="background:#d97757;color:#fff">' + icon(G.waveform) + '</span><span>Talk to Claude</span></div>');
        each(PD.launcher.all, function (a) {
          if (f && a.name.toLowerCase().indexOf(f) < 0) return;
          if (n++ > 60) return;
          html.push('<div class="ga row" data-add="p:' + esc(a.path) + '"><img src="' + esc(PD.iconUrl(a.path)) + '"><span>' + esc(a.name) + '</span></div>');
        });
      }
      body.innerHTML = html.join('');
    }
    fill('');
    var f = q(gal, '.gf'); if (f) f.addEventListener('input', function () { fill(f.value); });
    // tap (not scroll) on an entry adds it
    var bx = 0, by = 0, bm = false;
    body.addEventListener('touchstart', function (e) { bx = e.touches[0].clientX; by = e.touches[0].clientY; bm = false; });
    body.addEventListener('touchmove', function (e) { if (Math.abs(e.touches[0].clientX - bx) + Math.abs(e.touches[0].clientY - by) > 8) bm = true; });
    body.addEventListener('touchend', function (e) { if (!bm) { var t = closest(e.target, 'data-add', body); if (t) { e.preventDefault(); self.addFromGallery(t.getAttribute('data-add')); } } });
    body.addEventListener('click', function (e) { var t = closest(e.target, 'data-add', body); if (t) self.addFromGallery(t.getAttribute('data-add')); });
  };
  Deck.prototype.closeGallery = function () { if (this.galEl) this.root.removeChild(this.galEl); this.galEl = null; this.galPick = false; };
  Deck.prototype.addFromGallery = function (code) {
    var kind = code.slice(0, 1), rest = code.slice(2), item, self = this;
    if (this.galPick && kind === 'j') {
      this.closeGallery();
      api.post('/project', { path: rest }, function (st, t) { self.toast(st === 200 && /true/.test(t) ? 'Claude Code · ' + rest.split('/').pop() : 'Could not open the project'); });
      return;
    }
    if (kind === 'w') { var p = rest.split(':'); item = { t: 'w', w: p[0], s: p[1] }; }
    else if (kind === 'a') item = { t: 'action', a: rest };
    else if (kind === 'c') item = { t: 'claude' };
    else if (kind === 'j') { var pj = find(PD.projects || [], function (x) { return x.path === rest; }); item = { t: 'project', path: rest, name: pj ? pj.name : rest.split('/').pop() }; }
    else { var a = PD.appByPath(rest); item = { t: 'app', path: rest, name: a ? a.name : '' }; }
    var g = this.geo, page = this.device().pages[this.page];
    if (!PD.addItem(page.items, item, g.cols, g.rows)) { this.toast('No room on this page: remove something first'); return; }
    this.closeGallery();
    this.toast('Added to ' + page.name);
    this.commit();
  };

  // ---------------------------------------------------------------- data
  Deck.prototype.update = function (d, all) {
    if (!this.layout) return;
    this.theme();
    var tp = PD.timeParts(new Date());
    q(this.hdr, '.htime').textContent = tp.time;
    q(this.hdr, '.hampm').textContent = tp.ampm;
    q(this.hdr, '.hdate').textContent = tp.long;
    q(this.hdr, '.link').className = 'link' + (d.mac ? ' ok' : '');
    if (d.mac) q(this.hdr, '.mac').textContent = d.mac.replace(/^\S+['’]s?\s+/, '');
    this.ticker(d);
    var self = this;
    // Only the visible page and its neighbours update: keeps the 4S responsive.
    each(this.pages, function (pg, i) {
      if (!all && Math.abs(i - self.page) > 1) return;
      each(pg.live, function (w) { try { w.update(d); } catch (e) { if (root.console) console.log(e); } });
    });
    each(this.dockLive, function (w) { w.update(d); });
    this.tabBadges(d);
    if (!this.opts.edit) this.notes(d.notes);
  };

  Deck.prototype.tick = function () {
    var pg = this.pages && this.pages[this.page];
    if (pg) each(pg.live, function (w) { if (w.tick) w.tick(); });
    if (this.hdr) { var tp = PD.timeParts(new Date()); q(this.hdr, '.htime').textContent = tp.time; }
  };

  Deck.prototype.ticker = function (d) {
    var t = q(this.hdr, '.ticker'), inner = q(t, '.in');
    var html = batteryList(d).map(function (b) {
      return '<span class="tk ' + levelClass(b) + '"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round">' + (BICON[b.kind] || BICON.keyboard) + '</svg>' + b.level + '%</span>';
    }).join('');
    if (html === this.tickerHtml) return;
    this.tickerHtml = html;
    inner.className = 'in'; inner.innerHTML = html;
    if (html && t.scrollWidth > t.clientWidth + 2) { inner.innerHTML = html + html; inner.className = 'in roll'; }
  };

  Deck.prototype.tabBadges = function (d) {
    var tabs = this.hdr && q(this.hdr, '.tabs'); if (!tabs) return;
    var badges = (d.notes || {}).badges || {}, dev = this.device();
    each(tabs.children, function (t, i) {
      var n = 0;
      each(dev.pages[i].items, function (it) {
        var a = it.t === 'app' ? PD.appByPath(it.path) || (it.name && PD.appByName(it.name)) : it.t === 'claude' ? PD.appByName('Claude') : null;
        var v = a && badges[a.path]; if (v) n += parseInt(v, 10) || 1;
      });
      var b = q(t, 'b');
      if (n && !b) { b = el('b'); t.appendChild(b); }
      if (b) { if (n) b.textContent = n > 99 ? '99+' : n; else t.removeChild(b); }
    });
  };

  // New Mac notifications slide in as banners (the first poll only records what is already there).
  Deck.prototype.notes = function (notes) {
    if (!notes) return;
    var items = notes.items || [], self = this, cfg = this.layout.notifications || {};
    if (!this.seen) { this.seen = {}; each(items, function (it) { self.seen[it.id] = 1; }); return; }
    var fresh = items.filter(function (it) { return !self.seen[it.id]; });
    each(fresh, function (it) { self.seen[it.id] = 1; });
    if (cfg.banners === false) return;
    fresh.slice(0, 3).reverse().forEach(function (it) { self.banners.push(it); });
    if (!this.bannerItem) this.nextBanner();
  };
  Deck.prototype.nextBanner = function () {
    var it = this.banners.shift(), self = this, b = this.bannerEl;
    this.bannerItem = it || null;
    if (!it) return;
    var img = it.path ? '<img src="' + esc(PD.iconUrl(it.path)) + '">' : '<span class="nfb big">' + icon(G.bell) + '</span>';
    b.innerHTML = '<div class="row">' + img + '<div class="grow"><div class="row"><span class="ba grow ell">' + esc(it.app) + '</span><span class="ba">now</span></div>' +
      '<div class="bt ell">' + esc(it.title || it.app) + '</div>' + (it.body ? '<div class="bb ell">' + esc(it.body) + '</div>' : '') + '</div></div>';
    b.className = 'banner on';
    clearTimeout(this.bT); this.bT = setTimeout(function () { self.hideBanner(); }, 4200);
  };
  Deck.prototype.hideBanner = function () {
    var self = this;
    this.bannerEl.className = 'banner';
    clearTimeout(this.bT);
    setTimeout(function () { self.bannerItem = null; self.nextBanner(); }, 450);
  };

  Deck.prototype.toast = function (msg) {
    var t = this.toastEl; if (!t) return;
    t.textContent = msg; t.style.display = 'block';
    clearTimeout(this.tT); this.tT = setTimeout(function () { t.style.display = 'none'; }, 1800);
  };

  // ---------------------------------------------------------------- edit mode (Command Center)
  Deck.prototype.bindEdit = function () {
    var self = this, r = this.root;
    r.onclick = function (e) {
      var n = closest(e.target, 'data-i', r);
      if (self.opts.onSelect) self.opts.onSelect(n ? n.getAttribute('data-zone') : null, n ? +n.getAttribute('data-i') : -1);
    };
  };

  // ---------------------------------------------------------------- live data
  // Polls /stats; reloads the layout when the Command Center saves a new one.
  PD.live = {
    listeners: [], layoutVersion: null, dev: null, page: 0, timer: null,
    start: function (dev, interval) {
      PD.live.dev = dev;
      PD.refresh();
      PD.live.timer = setInterval(PD.refresh, interval || 2000);
      setInterval(function () { each(PD.live.listeners, function (l) { if (l.tick) l.tick(); }); }, 1000);
    },
    on: function (l) { PD.live.listeners.push(l); }
  };
  PD.refresh = function () {
    var L = PD.live, extra = 'full=1' + (L.dev ? '&dev=' + L.dev + '&page=' + L.page + '&w=' + (root.innerWidth || 0) + '&h=' + (root.innerHeight || 0) : '');
    api.get('/stats', extra, function (s, text) {
      var d = {};
      if (s === 200) { try { d = JSON.parse(text); } catch (e) {} }
      PD.data = d;
      if (s === 200 && L.layoutVersion !== null && d.layout !== L.layoutVersion) each(L.listeners, function (l) { if (l.layoutChanged) l.layoutChanged(d.layout); });
      if (s === 200) L.layoutVersion = d.layout;
      each(L.listeners, function (l) { if (l.data) l.data(d, s); });
    });
  };
  PD.loadProjects = function (cb) { api.json('/projects', '', function (j) { PD.projects = j || []; if (cb) cb(); }); };
  PD.loadLauncher = function (cb) {
    api.json('/launcher', '', function (j) { if (j) PD.launcher = { selected: j.selected || [], all: j.all || [] }; if (cb) cb(!!j); });
  };
  PD.loadLayout = function (cb) {
    api.json('/layout', '', function (j, s) { cb(j && j.devices ? PD.normalize(j) : PD.defaultLayout(PD.launcher), s); });
  };
  // Fill in anything an older or hand-edited layout is missing.
  PD.normalize = function (L) {
    var def = PD.defaultLayout(PD.launcher);
    each(['theme', 'wallpaper', 'accent', 'glass', 'notifications'], function (k) { if (L[k] === undefined) L[k] = def[k]; });
    for (var k in def.devices) {
      var d = L.devices[k];
      if (!d || !d.pages || !d.pages.length) { L.devices[k] = def.devices[k]; continue; }
      if (!d.density) d.density = 'compact';
      if (!d.dock) d.dock = { on: false, items: [] };
      each(d.pages, function (p) { if (!p.id) p.id = uid(); if (!p.items) p.items = []; if (p.icon && !G[p.icon]) p.icon = PD.iconName(p.icon); });
    }
    return L;
  };

  // ---------------------------------------------------------------- device boot (index.html)
  PD.detect = function () {
    var m = /device=(classic|phone|tablet)/.exec(location.search);
    if (m) return m[1];
    if (!PD.modern) return 'classic';
    var tablet = navigator.maxTouchPoints > 1 && /Macintosh|iPad/.test(navigator.userAgent) && Math.min(screen.width, screen.height) >= 700;
    return tablet || /ipad/.test(location.pathname) ? 'tablet' : 'phone';
  };

  // Device script errors go to the Mac's log (~/.phonedeck/log.txt), so problems on a phone or iPad can be diagnosed.
  PD.diag = function (kind, msg) {
    if (!api.token) return;
    try { api.post('/clientlog', { dev: kind, msg: 'diag: ' + msg, at: '', ua: navigator.userAgent.slice(0, 120) }); } catch (e) {}
  };
  PD.reportErrors = function (kind) {
    var sent = 0;
    root.addEventListener('unhandledrejection', function (e) { PD.diag(kind, 'unhandled rejection ' + (e.reason && e.reason.message)); });
    root.addEventListener('pagehide', function () { PD.diag(kind, 'pagehide'); });
    root.onerror = function (msg, src, line, col) {
      if (sent++ > 5 || !api.token) return;
      try { api.post('/clientlog', { dev: kind, msg: String(msg).slice(0, 300), at: (src || '').split('/').pop() + ':' + line + ':' + col, ua: navigator.userAgent.slice(0, 120) }); } catch (e) {}
    };
  };
  PD.boot = function (host) {
    var m = /k=([a-z0-9]+)/.exec(location.hash);
    api.token = m ? m[1] : store('token');
    if (m) store('token', api.token);
    var kind = PD.detect(), p = PROFILES[kind], deck = PD.current = new Deck(host, kind, {});
    PD.reportErrors(kind);
    var saved = parseInt(store('page-' + kind) || '0', 10);
    deck.page = isNaN(saved) ? 0 : saved;
    deck.opts.onPage = function (i) { PD.live.page = i; };
    var safe = el('div'); safe.style.cssText = 'position:fixed;left:0;top:0;visibility:hidden;pointer-events:none;padding:env(safe-area-inset-top) env(safe-area-inset-right) env(safe-area-inset-bottom) env(safe-area-inset-left)';
    document.body.appendChild(safe);

    // The deck is designed landscape-only. Phones: a 320pt-tall stage scaled to fit the safe area.
    // iPad: native pixels; a home-screen web app gets a viewport shorter than the screen, so use the screen.
    function fit() {
      var cs = root.getComputedStyle(safe), ins = { t: parseFloat(cs.paddingTop) || 0, r: parseFloat(cs.paddingRight) || 0, b: parseFloat(cs.paddingBottom) || 0, l: parseFloat(cs.paddingLeft) || 0 };
      var iw = root.innerWidth, ih = root.innerHeight;
      if (kind === 'tablet') {
        var standalone = navigator.standalone || (root.matchMedia && matchMedia('(display-mode: standalone)').matches);
        var screenH = iw > ih ? Math.min(screen.width, screen.height) : Math.max(screen.width, screen.height), gap = screenH - ih;
        ih = standalone || (gap > 0 && gap <= 40) ? Math.max(ih, screenH) : ih;
      }
      var aw = iw - ins.l - ins.r, ah = ih - ins.t - ins.b, portrait = ah > aw;
      var W, H, s;
      if (portrait) { aw = ih - ins.t - ins.b; ah = iw - ins.l - ins.r; }
      if (p.stageH) { H = p.stageH; W = Math.max(p.minW, Math.min(p.maxW, Math.round(H * aw / ah))); s = Math.min(aw / W, ah / H); }
      else { W = aw; H = ah; s = 1; }
      deck.scale = s;
      deck.resize(W, H);
      var r = deck.root;
      r.style.webkitTransform = r.style.transform = 'scale(' + s + ')';
      r.style.left = ins.l + (aw - W * s) / 2 + 'px';
      r.style.top = ins.t + (ah - H * s) / 2 + 'px';
      if (deck.rotateEl) deck.rotateEl.style.display = portrait ? 'block' : 'none';
    }
    root.addEventListener('resize', function () { clearTimeout(fit.t); fit.t = setTimeout(fit, 60); });
    root.addEventListener('orientationchange', function () { setTimeout(fit, 300); });

    if (navigator.getBattery) navigator.getBattery().then(function (b) {
      function upd() { PD.phoneBattery = { kind: kind === 'tablet' ? 'phone' : 'phone', name: 'This device', level: Math.round(b.level * 100), charging: b.charging }; }
      upd(); b.addEventListener('levelchange', upd); b.addEventListener('chargingchange', upd);
    });

    function login() {
      var box = el('div', '', '<div style="position:fixed;left:0;top:0;right:0;bottom:0;background:#000;color:#fff;font:15px -apple-system,Helvetica;text-align:center;padding-top:60px;z-index:99">' +
        'Enter the access code from the Mac<br><br><input id="pdCode" autocapitalize="none" autocorrect="off" style="font-size:18px;padding:8px;border-radius:9px;border:0;text-align:center;width:60%"><br><br>' +
        '<button id="pdGo" style="font-size:16px;padding:8px 22px;border-radius:16px;border:0;background:#0a84ff;color:#fff">Connect</button></div>');
      document.body.appendChild(box);
      document.getElementById('pdGo').onclick = function () {
        api.token = document.getElementById('pdCode').value.replace(/\s/g, '').toLowerCase();
        store('token', api.token); location.hash = 'k=' + api.token; location.reload();
      };
    }
    function start() {
      PD.loadLauncher(function (ok) {
        if (!ok) { setTimeout(start, 2000); return; }
        PD.loadLayout(function (layout) {
          var t0 = Date.now();
          deck.layout = layout;
          var reload = deck.opts.reload = function () { PD.loadLauncher(function () { PD.loadLayout(function (l) { deck.setLayout(l); }); }); };
          fit();
          PD.live.page = deck.page;
          PD.live.on({
            data: function (d) { deck.update(d); },
            tick: function () { deck.tick(); },
            layoutChanged: function () { if (deck.arranging || deck.dragging) deck.pendingReload = true; else reload(); }
          });
          PD.live.start(kind, kind === 'classic' ? 2500 : 2000);
          if (/diag/.test(location.search)) {   // ?diag: report render stats and a heartbeat to the Mac log
            PD.diag(kind, 'rendered ' + document.querySelectorAll('.tile').length + ' tiles, ' + document.querySelectorAll('.key').length + ' keys in ' + (Date.now() - t0) + 'ms; stage ' + deck.W + 'x' + deck.H + ' scale ' + deck.scale + '; window ' + root.innerWidth + 'x' + root.innerHeight + ' dpr ' + root.devicePixelRatio);
            var beats = 0, hb = setInterval(function () { PD.diag(kind, 'alive ' + (++beats * 5) + 's page ' + deck.page); if (beats >= 12) clearInterval(hb); }, 5000);
          }
        });
      });
    }
    api.req('GET', api.url('/info'), null, function (s) {
      if (s === 403 || !api.token) { login(); return; }
      start();
    });
    return deck;
  };
})(window);
