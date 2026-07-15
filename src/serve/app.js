(function () {
  "use strict";

  function intervalFor(element) {
    var trigger = element.getAttribute("hx-trigger") || "";
    var match = trigger.match(/every\s+(\d+)s/);
    return match ? Number(match[1]) * 1000 : 0;
  }

  async function refresh(element) {
    try {
      var response = await fetch(element.getAttribute("hx-get"), {
        headers: { accept: "text/html" },
        credentials: "same-origin"
      });
      if (!response.ok) throw new Error("HTTP " + response.status);
      element.innerHTML = await response.text();
      element.dispatchEvent(new CustomEvent("htmx:afterSwap", { bubbles: true }));
    } catch (_) {
      element.innerHTML = '<p class="p-4 text-sm text-slate-400">temporarily unavailable</p>';
    }
  }

  document.querySelectorAll("[hx-get]").forEach(function (element) {
    refresh(element);
    var interval = intervalFor(element);
    if (interval) window.setInterval(function () { refresh(element); }, interval);
  });

  var input = document.getElementById("cc-search");
  var results = document.getElementById("cc-results");
  var meta = document.getElementById("cc-search-meta");
  var docs = [];

  function text(value) { return String(value == null ? "" : value); }
  function badge(tier) {
    var span = document.createElement("span");
    span.className = "cc-tier " + (tier >= 1 && tier <= 3 ? "t" + tier : "");
    span.textContent = tier >= 1 && tier <= 3 ? "T" + tier : "-";
    return span;
  }

  async function loadIndex() {
    try {
      var response = await fetch("/ui/search-index", { headers: { accept: "application/json" } });
      if (!response.ok) throw new Error("HTTP " + response.status);
      docs = await response.json();
      meta.textContent = docs.length + " indexed";
    } catch (_) {
      meta.textContent = "index unavailable";
    }
  }

  function runSearch() {
    var term = input.value.trim().toLowerCase();
    results.replaceChildren();
    if (!term) {
      results.hidden = true;
      meta.textContent = docs.length + " indexed";
      return;
    }
    var terms = term.split(/\s+/);
    var matches = docs.filter(function (doc) {
      var corpus = [doc.title, doc.source, doc.detail, doc.kind, doc.event].map(text).join(" ").toLowerCase();
      return terms.every(function (part) { return corpus.indexOf(part) !== -1; });
    }).slice(0, 40);
    results.hidden = false;
    meta.textContent = matches.length + " result" + (matches.length === 1 ? "" : "s");
    if (!matches.length) {
      var empty = document.createElement("div");
      empty.className = "cc-res-empty";
      empty.textContent = 'no matches for "' + input.value.trim() + '"';
      results.appendChild(empty);
      return;
    }
    matches.forEach(function (doc) {
      var row = document.createElement("div");
      row.className = "cc-res-row";
      if (/^https:\/\//i.test(text(doc.url))) {
        row.dataset.readerUrl = doc.url;
        row.dataset.readerLabel = text(doc.title);
      }
      var source = document.createElement("span");
      source.className = "cc-res-src";
      source.textContent = text(doc.source);
      var title = document.createElement("span");
      title.className = "cc-res-title";
      title.textContent = text(doc.title) || "(untitled)";
      var when = document.createElement("span");
      when.className = "cc-res-when";
      when.textContent = text(doc.when);
      row.append(badge(doc.tier), source, title, when);
      results.appendChild(row);
    });
  }

  var timer;
  input.addEventListener("input", function () {
    window.clearTimeout(timer);
    timer = window.setTimeout(runSearch, 100);
  });
  document.addEventListener("keydown", function (event) {
    var tag = (document.activeElement && document.activeElement.tagName || "").toLowerCase();
    if (event.key === "/" && tag !== "input" && tag !== "textarea") {
      event.preventDefault();
      input.focus();
    }
  });
  loadIndex();
}());
