(function () {
  "use strict";
  var STALE_MS = 15 * 60 * 1000;
  var LABEL = { ok: "OK", warn: "Warnung", fail: "Fehler", info: "Hinweis", unknown: "Unbekannt" };
  var CHECK_LABEL = { dns: "DNS", http: "HTTP", tls: "TLS (Edge)", origin_tls: "TLS (Origin)",
    uptimerobot: "UptimeRobot", mx: "MX", spf: "SPF", dkim: "DKIM" };
  var NEUTRAL = { unavailable: 1, not_configured: 1, none: 1, paused: 1, unknown: 1 };
  var COLORS = { ok: "var(--ok)", warn: "var(--warn)", fail: "var(--fail)", info: "var(--info)", unknown: "var(--unknown)" };

  function el(tag, cls, text) {
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text !== undefined) e.textContent = text;
    return e;
  }

  function describe(name, c) {
    var s = c.status;
    if (name === "http") {
      if (c.code) return { t: "HTTP " + c.code + " · " + c.time_ms + " ms", s: s };
      return { t: c.detail || "keine Antwort", s: s };
    }
    if (name === "tls" || name === "origin_tls") {
      if (s === "unavailable") return { t: "nicht prüfbar", s: "neutral" };
      return { t: c.expires ? "gültig bis " + c.expires : (c.detail || s), s: s };
    }
    if (name === "uptimerobot") {
      if (s === "not_configured") return { t: "nicht konfiguriert", s: "neutral" };
      if (s === "none") return { t: "kein Monitor", s: "neutral" };
      if (s === "paused") return { t: "pausiert", s: "neutral" };
      if (s === "unavailable") return { t: "Abfrage fehlgeschlagen", s: "neutral" };
      var u = (typeof c.uptime_30d === "number") ? " · " + c.uptime_30d.toFixed(2) + " % (30 d)" : "";
      return { t: (s === "ok" ? "Up" : s === "fail" ? "Down" : s) + u, s: s };
    }
    if (s === "ok") return { t: "OK", s: "ok" };
    if (s === "fail") return { t: c.detail || "Fehler", s: "fail" };
    return { t: c.detail || s, s: NEUTRAL[s] ? "neutral" : s };
  }

  function strip(history, id, intervalSec) {
    var wrap = el("div");
    var bar = el("div", "strip");
    var entries = history.slice(-96);
    entries.forEach(function (h) {
      var i = el("i");
      var st = h.tiles && h.tiles[id];
      if (st) i.style.setProperty("--c", COLORS[st] || COLORS.unknown);
      bar.appendChild(i);
    });
    wrap.appendChild(bar);
    var mins = Math.round(entries.length * intervalSec / 60);
    wrap.appendChild(el("p", "strip-label", !entries.length ? "Noch kein Verlauf" :
      "Verlauf: letzte " + (mins >= 90 ? Math.round(mins / 60) + " h" : mins + " min")));
    return wrap;
  }

  function donut(counts) {
    var svg = document.getElementById("donut");
    while (svg.firstChild) svg.removeChild(svg.firstChild);
    var ns = "http://www.w3.org/2000/svg", total = 0, k;
    for (k in counts) total += counts[k];
    var r = 46, c = 2 * Math.PI * r, off = 0;
    var bg = document.createElementNS(ns, "circle");
    bg.setAttribute("cx", 60); bg.setAttribute("cy", 60); bg.setAttribute("r", r);
    bg.setAttribute("fill", "none"); bg.setAttribute("stroke", "var(--line)"); bg.setAttribute("stroke-width", 14);
    svg.appendChild(bg);
    ["ok", "info", "warn", "fail", "unknown"].forEach(function (key) {
      if (!counts[key]) return;
      var len = c * counts[key] / total;
      var ring = document.createElementNS(ns, "circle");
      ring.setAttribute("cx", 60); ring.setAttribute("cy", 60); ring.setAttribute("r", r);
      ring.setAttribute("fill", "none"); ring.setAttribute("stroke", COLORS[key]); ring.setAttribute("stroke-width", 14);
      ring.setAttribute("stroke-dasharray", len + " " + (c - len));
      ring.setAttribute("stroke-dashoffset", -off);
      ring.setAttribute("transform", "rotate(-90 60 60)");
      svg.appendChild(ring);
      off += len;
    });
    var t = document.createElementNS(ns, "text");
    t.setAttribute("x", 60); t.setAttribute("y", 66); t.setAttribute("text-anchor", "middle");
    t.setAttribute("font-size", "22"); t.setAttribute("font-weight", "700"); t.setAttribute("fill", "currentColor");
    t.textContent = (counts.ok || 0) + "/" + total;
    svg.appendChild(t);
  }

  function render(status, history) {
    var now = Date.now();
    var gen = Date.parse(status.generated_at);
    var age = now - gen;
    var stale = isNaN(gen) || age > STALE_MS;

    document.getElementById("meta").textContent =
      "Stand: " + (isNaN(gen) ? "unbekannt" : new Date(gen).toLocaleString("de-DE")) +
      " · Intervall " + Math.round(status.interval_seconds / 60) + " min";

    var banner = document.getElementById("stale");
    if (stale) {
      banner.hidden = false;
      banner.className = "banner fail";
      banner.textContent = "Daten veraltet: letzte Prüfung vor " + (isNaN(age) ? "unbekannter Zeit" : Math.round(age / 60000) + " Minuten") +
        ". Der Checker liefert möglicherweise nicht mehr.";
    } else banner.hidden = true;

    var counts = {};
    status.tiles.forEach(function (t) { counts[t.status] = (counts[t.status] || 0) + 1; });
    donut(counts);

    var overall = document.getElementById("overall");
    var o = stale ? "unknown" : status.overall;
    overall.textContent = stale ? "Gesamtstand: veraltet" :
      status.overall === "ok" ? "Alles in Ordnung" :
      status.overall === "warn" ? "Warnungen vorhanden" : "Fehler erkannt";

    var legend = document.getElementById("legend");
    legend.textContent = "";
    ["ok", "info", "warn", "fail", "unknown"].forEach(function (k) {
      if (!counts[k]) return;
      var li = el("li", null, LABEL[k] + ": " + counts[k]);
      li.style.setProperty("--c", COLORS[k]);
      legend.appendChild(li);
    });

    var grid = document.getElementById("tiles");
    grid.textContent = "";
    var hist = (history && history.entries) || [];
    status.tiles.forEach(function (t) {
      var card = el("article", "tile s-" + (stale ? "unknown" : t.status));
      var h2 = el("h2");
      h2.appendChild(el("span", null, t.name));
      h2.appendChild(el("span", "badge", LABEL[t.status] || t.status));
      card.appendChild(h2);
      card.appendChild(el("p", "host", t.hostname));
      var ul = el("ul", "checks");
      Object.keys(t.checks).forEach(function (name) {
        var d = describe(name, t.checks[name]);
        var li = el("li");
        li.appendChild(el("span", "k", CHECK_LABEL[name] || name));
        li.appendChild(el("span", "v " + d.s, d.t));
        ul.appendChild(li);
      });
      if (t.kind === "unassigned") {
        var li = el("li");
        li.appendChild(el("span", "k", "Anwendung"));
        li.appendChild(el("span", "v neutral", "keine dokumentiert"));
        ul.appendChild(li);
      }
      card.appendChild(ul);
      card.appendChild(strip(hist, t.id, status.interval_seconds || 300));
      grid.appendChild(card);
    });
  }

  function fetchJson(url) {
    return fetch(url + "?t=" + Date.now(), { cache: "no-store" }).then(function (r) {
      if (!r.ok) throw new Error(url + " " + r.status);
      return r.json();
    });
  }

  function load() {
    Promise.all([fetchJson("status.json"), fetchJson("history.json").catch(function () { return { entries: [] }; })])
      .then(function (res) { render(res[0], res[1]); })
      .catch(function () {
        var b = document.getElementById("stale");
        b.hidden = false; b.className = "banner fail";
        b.textContent = "Noch keine Statusdaten verfügbar (status.json fehlt). Der Checker hat noch nicht geliefert.";
        document.getElementById("meta").textContent = "Keine Daten";
      });
  }
  load();
  setInterval(load, 60 * 1000);
})();
