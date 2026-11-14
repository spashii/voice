/* Download buttons. On a computer, pressing one opens the three install steps directly under it, in
   the button's place, and hides the sold-out price line meanwhile, so only the
   founding line stays. The download itself is the button's own link. On a phone there is no Mac to
   install on, so every Download button becomes a "Send to my Mac" button (or "Copy link" where the
   share sheet is missing) for the page address and never navigates to the DMG.
   Prices are written in dollars; for visitors in a eurozone country they switch to euros, decided from the
   time zone, then the language region. [data-price] is Dictate's own price, where only the sign changes.
   [data-eur] holds the euro text for a price that is not the same number in both, such as another app's.
   The founding spots count is fetched once and appends "N spots left." to the founding sentence in every [data-left]; if the
   request fails the sentence stands alone. At zero the sentence says the spots are taken. Each
   Download block that holds a [data-left] then gets the price line under it ("After early access, a regular
   lifetime license is $49." in euros where the rest switch) and a form for the one email sent when licenses go on sale, so
   every page with the block gets them without markup. The price appears only in that state. Preview hosts
   (localhost and the tailnet) can add ?spots=0 to show that sold-out state without the fetch. */
(function () {
  var STEPS = ["Open the DMG and drag Dictate to Applications.", "Open Dictate.", "In the window Dictate opens, press Activate in Browser."];
  var FOUNDING = "https://dictate.tech/api/activate/founding";
  // Preview hosts can show the sold-out state with ?spots=0 and use the Turnstile test key; production ignores both.
  var PREVIEW = /^(localhost|127\.0\.0\.1)$|\.ts\.net$/.test(location.hostname);

  // Touch, coarse pointer and a narrow screen together; the user agent alone is not trusted.
  function isPhone() {
    try {
      return !!(window.matchMedia && window.matchMedia("(hover: none) and (pointer: coarse)").matches &&
        Math.min(screen.width, screen.height) < 600);
    } catch (e) { return false; }
  }

  // Time zones of the countries that use the euro, France's overseas departments included because they use it too.
  // Europe/Busingen is left out on purpose: Germany's exclave on the Swiss side bills in francs.
  var EURO_ZONES = ("Europe/Vienna Europe/Brussels Europe/Sofia Europe/Zagreb Asia/Nicosia Asia/Famagusta Europe/Nicosia " +
    "Europe/Tallinn Europe/Helsinki Europe/Mariehamn Europe/Paris Europe/Berlin Europe/Athens Europe/Dublin Eire " +
    "Europe/Rome Europe/Riga Europe/Vilnius Europe/Luxembourg Europe/Malta Europe/Amsterdam Europe/Monaco Europe/Andorra Europe/San_Marino Europe/Vatican Europe/Podgorica " +
    "Europe/Lisbon Atlantic/Madeira Atlantic/Azores Portugal Europe/Bratislava Europe/Ljubljana Europe/Madrid Africa/Ceuta Atlantic/Canary " +
    "Indian/Reunion Indian/Mayotte America/Martinique America/Guadeloupe America/Cayenne America/Marigot America/St_Barthelemy America/Miquelon").split(" ");
  var EURO_REGIONS = "AT BE BG HR CY EE FI FR DE GR IE IT LV LT LU MT NL PT SK SI ES MC AD SM VA ME XK".split(" ");

  // true for euro, false for dollar. The zone wins when it is a real place; only a missing or generic zone
  // (UTC, Etc/*) hands the decision to the browser's language regions.
  function inEurozone() {
    var zone = "";
    try { zone = Intl.DateTimeFormat().resolvedOptions().timeZone || ""; } catch (e) {}
    if (zone && !/^(UTC|GMT|Etc\/|Zulu|Universal|UCT|Greenwich)/i.test(zone)) return EURO_ZONES.indexOf(zone) >= 0;
    var langs = navigator.languages && navigator.languages.length ? navigator.languages : [navigator.language || ""];
    for (var i = 0; i < langs.length; i++) {
      var m = /^[A-Za-z]{2,3}(?:-[A-Za-z]{4})?-([A-Za-z]{2})(?:-|$)/.exec(langs[i]);
      if (m) return EURO_REGIONS.indexOf(m[1].toUpperCase()) >= 0;
    }
    return false;
  }

  // Takes a list of [data-price] nodes so a price line built later (the sold-out one) gets the same switch
  // from the same zone list, with no second copy of the rules.
  function toEuro(prices) {
    if (!inEurozone()) return;
    for (var i = 0; i < prices.length; i++) prices[i].textContent = prices[i].textContent.replace("$", "\u20ac");
  }

  function currency() {
    if (!inEurozone()) return;
    toEuro(document.querySelectorAll("[data-price]"));
    var other = document.querySelectorAll("[data-eur]");
    for (var j = 0; j < other.length; j++) other[j].textContent = other[j].getAttribute("data-eur");
  }

  function liveRegion(parent) {
    var live = document.createElement("p");
    live.className = "sr";
    live.setAttribute("role", "status");
    live.setAttribute("aria-live", "polite");
    parent.appendChild(live);
    return live;
  }

  function founding() {
    var spots = document.querySelectorAll("[data-left]");
    if (!spots.length || !window.fetch) return;
    for (var k = 0; k < spots.length; k++) spots[k].setAttribute("data-base", spots[k].textContent);
    if (PREVIEW && /[?&]spots=0(&|$)/.test(location.search)) { soldOut(spots); return; }
    fetch(FOUNDING).then(function (r) { return r.ok ? r.json() : null; }).then(function (j) {
      if (!j || !Number.isInteger(j.left) || j.left < 0) return;
      if (j.left === 0) { soldOut(spots); return; }
      for (var i = 0; i < spots.length; i++) { spots[i].textContent = spots[i].getAttribute("data-base") + " " + j.left + (j.left === 1 ? " spot left." : " spots left."); }
    }).catch(function () {});
  }

  var LAUNCH = "https://dictate.tech/api/launch-list";
  var SITEKEY = PREVIEW ? "1x00000000000000000000AA" : "0x4AAAAAAF-MEHP47FLn7LEY";
  var NOTIFY_ERRORS = {
    bad_email: "That email address does not look right.",
    turnstile: "I could not confirm you are a person. Try again in a moment.",
    rate_limited: "Too many tries. Wait a minute and try again."
  };
  var NOTIFY_FAILED = "I could not save your address. Try again in a minute.";
  var NOTIFY_DONE = "You are on the list.";
  var tsScript = null, tsBlocked = false, tsBlockedListeners = [], tsWaiting = [];
  var notifyForms = [];

  // Turnstile loads only when the sold-out state shows, so visitors who never see the form never load it.
  // Every form waits in tsWaiting and renders its widget once the script is there.
  function loadTurnstile(cb) {
    if (window.turnstile) return cb();
    tsWaiting.push(cb);
    if (tsScript) return;
    tsScript = document.createElement("script");
    tsScript.src = "https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit";
    tsScript.async = true;
    tsScript.addEventListener("load", function () {
      var run = tsWaiting;
      tsWaiting = [];
      run.forEach(function (f) { f(); });
    });
    tsScript.addEventListener("error", function () {
      tsBlocked = true;
      tsBlockedListeners.forEach(function (l) { l(); });
    });
    document.head.appendChild(tsScript);
  }

  // A script that failed to load (blocked, offline) is replaced by a fresh one on the next submit, so a
  // visitor who fixes the connection does not have to reload the page. Forms still waiting render when it arrives.
  function retryTurnstileScript() {
    if (!tsBlocked) return;
    tsBlocked = false;
    if (tsScript && tsScript.parentNode) tsScript.parentNode.removeChild(tsScript);
    tsScript = null;
    loadTurnstile(function () {});
  }

  // A blocked or failed script never reports back on its own, so each form listens for the error and stops waiting.
  function onTurnstileBlocked(cb) {
    tsBlockedListeners.push(cb);
  }

  function el(tag, cls, text) {
    var n = document.createElement(tag);
    if (cls) n.className = cls;
    if (text) n.textContent = text;
    return n;
  }

  // The form is built here, not written into each page, so every Download block gets it without page edits.
  // It goes last in the block, after the founding and price lines.
  function buildForm(group, i) {
    var id = "notify-" + i;
    var form = el("form", "notify");
    form.setAttribute("novalidate", "");
    var label = el("label", "", "Get an email when licenses go on sale.");
    label.htmlFor = id;
    var row = el("div", "notify-row");
    var input = el("input");
    input.id = id;
    input.name = "email";
    input.type = "email";
    input.setAttribute("autocomplete", "email");
    input.setAttribute("inputmode", "email");
    input.setAttribute("autocapitalize", "none");
    input.setAttribute("spellcheck", "false");
    input.required = true;
    input.setAttribute("aria-describedby", id + "-consent");
    var button = el("button", "button", "Notify me");
    button.type = "submit";
    row.appendChild(input);
    row.appendChild(button);
    var done = el("p", "notify-done");
    done.hidden = true;
    var err = el("p", "notify-err");
    err.setAttribute("role", "alert");
    var ts = el("div", "notify-ts");
    var consent = el("p", "meta");
    consent.id = id + "-consent";
    consent.appendChild(el("span", "", "I'll email you once, when licenses go on sale."));
    [label, row, done, err, ts, consent].forEach(function (n) { form.appendChild(n); });
    group.appendChild(form);
    return form;
  }

  // The page names no price while spots remain; once they are gone this line states it, between the sold-out
  // line and the form. It carries data-install-hide so it leaves with the install steps like the old price line did.
  function buildPriceLine(group) {
    var spot = group.querySelector("[data-left]");
    var after = spot.closest ? spot.closest("p") : spot.parentNode;
    var p = el("p", "meta");
    p.setAttribute("data-install-hide", "");
    var outer = el("span", "", "After early access, a regular ");
    var nowrap = el("span", "nowrap", "lifetime license is ");
    var price = el("span", "", "$49");
    price.setAttribute("data-price", "");
    nowrap.appendChild(price);
    outer.appendChild(nowrap);
    outer.appendChild(document.createTextNode("."));
    p.appendChild(outer);
    toEuro([price]);
    after.parentNode.insertBefore(p, after.nextSibling);
  }

  function soldOut(spots) {
    for (var i = 0; i < spots.length; i++) spots[i].textContent = "All 50 early access spots are taken.";
    var groups = document.querySelectorAll(".get");
    var n = 0;
    for (var g = 0; g < groups.length; g++) {
      if (!groups[g].querySelector("[data-left]") || groups[g].querySelector(".notify")) continue;
      // A page's own price line would repeat the injected one; it stays in the markup for the spots-left state.
      var old = groups[g].querySelectorAll(".meta[data-install-hide]");
      for (var k = 0; k < old.length; k++) old[k].hidden = true;
      buildPriceLine(groups[g]);
      notify(buildForm(groups[g], n++));
    }
  }

  function notify(form) {
    var label = form.querySelector("label");
    var input = form.querySelector("input[type=email]");
    var button = form.querySelector("button");
    var row = form.querySelector(".notify-row");
    var err = form.querySelector(".notify-err");
    var done = form.querySelector(".notify-done");
    var tsBox = form.querySelector(".notify-ts");
    var token = "", widget = null, busy = false, failed = false, waiting = null;
    var started = false, ran = false, interactive = false, finished = false, timer = null;

    var me = {
      // The address is saved: this form swaps to the confirmation, and the widget is removed so no challenge reappears.
      finish: function (focus) {
        finished = true;
        if (widget !== null && window.turnstile) window.turnstile.remove(widget);
        widget = null;
        label.hidden = true;
        row.hidden = true;
        tsBox.classList.remove("is-shown");
        err.textContent = "";
        done.textContent = NOTIFY_DONE;
        done.hidden = false;
        // The form row is gone, so focus would fall to the body; the confirmation takes it.
        if (focus) { done.setAttribute("tabindex", "-1"); done.focus(); }
      }
    };
    notifyForms.push(me);

    // The challenge starts when the visitor first engages with this form, so a page that is only read never runs one.
    function start() {
      started = true;
      if (widget !== null && !ran && !finished) { ran = true; window.turnstile.execute(widget); }
    }

    // "interaction-only" keeps the widget invisible unless Cloudflare needs the person to act.
    loadTurnstile(function () {
      if (finished) return;
      widget = window.turnstile.render(tsBox, {
        sitekey: SITEKEY,
        appearance: "interaction-only",
        execution: "execute",
        callback: function (t) { token = t; failed = false; if (waiting) waiting(); },
        "expired-callback": function () { token = ""; },
        "error-callback": function () { token = ""; failed = true; if (waiting) waiting(); },
        "before-interactive-callback": function () {
          interactive = true;
          if (timer) { clearTimeout(timer); timer = null; }
          tsBox.classList.add("is-shown");
        },
        "after-interactive-callback": function () { interactive = false; tsBox.classList.remove("is-shown"); }
      });
      if (started) start();
    });

    onTurnstileBlocked(function () { if (waiting) waiting(); });
    input.addEventListener("focus", start);

    // Only a bad address marks the field invalid; any other failure is not the visitor's to fix in the field.
    function fail(text, field) {
      err.textContent = text;
      if (field) input.setAttribute("aria-invalid", "true"); else input.removeAttribute("aria-invalid");
    }

    // Resolves with a token, or "" once the check has failed or taken too long. While the visitor is solving
    // an interactive challenge there is no time limit; the callback or the error ends the wait.
    function getToken() {
      if (token) return Promise.resolve(token);
      if (failed || tsBlocked) return Promise.resolve("");
      return new Promise(function (resolve) {
        if (!interactive) timer = setTimeout(function () { timer = null; waiting = null; resolve(""); }, 15000);
        waiting = function () {
          if (token || failed || tsBlocked) {
            if (timer) { clearTimeout(timer); timer = null; }
            waiting = null;
            resolve(token);
          }
        };
      });
    }

    form.addEventListener("submit", function (e) {
      e.preventDefault();
      if (busy) return;
      var email = input.value.trim();
      err.textContent = "";
      input.removeAttribute("aria-invalid");
      if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) { fail(NOTIFY_ERRORS.bad_email, true); input.focus(); return; }
      busy = true;
      button.setAttribute("aria-disabled", "true");
      button.classList.add("is-disabled");
      retryTurnstileScript();
      start();
      var saved = false;
      getToken().then(function (t) {
        if (!t) throw "turnstile";
        return fetch(LAUNCH, {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ email: email, turnstile: t, attribution: window.dictateAttribution || {} })
        }).then(function (r) {
          return r.json().catch(function () { return {}; }).then(function (j) { return { status: r.status, json: j }; });
        });
      }).then(function (r) {
        if (r.status === 200 && r.json.ok) {
          saved = true;
          notifyForms.forEach(function (f) { f.finish(f === me); });
          return;
        }
        var code = r.json && r.json.error;
        fail(NOTIFY_ERRORS[code] || NOTIFY_FAILED, code === "bad_email");
        (code === "bad_email" ? input : button).focus();
      }, function (why) {
        fail(why === "turnstile" && !tsBlocked ? NOTIFY_ERRORS.turnstile : NOTIFY_FAILED);
        button.focus();
      }).then(function () {
        busy = false;
        button.removeAttribute("aria-disabled");
        button.classList.remove("is-disabled");
        if (saved) return;
        // A token works once; after a failure ask for the next one now so a retry does not wait.
        token = "";
        failed = false;
        ran = false;
        if (widget !== null && window.turnstile) { window.turnstile.reset(widget); start(); }
      });
    });
  }

  function copyText(text) {
    if (navigator.clipboard && navigator.clipboard.writeText) {
      return navigator.clipboard.writeText(text).catch(function () { return legacyCopy(text); });
    }
    return legacyCopy(text);
  }
  function legacyCopy(text) {
    return new Promise(function (resolve, reject) {
      var t = document.createElement("textarea");
      t.value = text;
      t.setAttribute("readonly", "");
      t.style.cssText = "position:fixed;top:0;left:0;opacity:0";
      document.body.appendChild(t);
      t.select();
      var ok = false;
      try { ok = document.execCommand("copy"); } catch (e) {}
      document.body.removeChild(t);
      if (ok) resolve(); else reject(new Error("copy failed"));
    });
  }

  function phone() {
    var live = liveRegion(document.body);
    var canShare = typeof navigator.share === "function";
    var idle = canShare ? "Send to my Mac" : "Copy link";
    var buttons = [];
    var nodes = document.querySelectorAll("a[data-get], nav a.button.primary");
    for (var i = 0; i < nodes.length; i++) {
      var a = nodes[i];
      var b = document.createElement("button");
      b.type = "button";
      b.className = a.className;
      b.textContent = idle;
      a.parentNode.replaceChild(b, a);
      buttons.push(b);
    }
    // Hold the wider of the idle label and "Link copied" so the width does not change when the text swaps.
    buttons.forEach(function (b) {
      var w = b.offsetWidth;
      b.textContent = "Link copied";
      w = Math.max(w, b.offsetWidth);
      b.textContent = idle;
      if (w) b.style.minWidth = w + "px";
    });

    var timer = null;
    function copied(btn) {
      buttons.forEach(function (b) { b.textContent = idle; });
      btn.textContent = "Link copied";
      live.textContent = "Link copied";
      clearTimeout(timer);
      timer = setTimeout(function () {
        btn.textContent = idle;
        live.textContent = "";
      }, 2000);
    }
    function copy(url, btn) { copyText(url).then(function () { copied(btn); }, function () {}); }

    buttons.forEach(function (b) {
      b.addEventListener("click", function () {
        var btn = b;
        var url = location.href.split("#")[0];
        if (canShare) {
          var p;
          try { p = navigator.share({ url: url }); } catch (e) { p = Promise.reject(e); }
          Promise.resolve(p).then(null, function (err) {
            if (err && err.name === "AbortError") return;
            copy(url, btn);
          });
        } else {
          copy(url, btn);
        }
      });
    });
  }

  function desktop() {
    document.querySelectorAll("a[data-get]").forEach(function (a) {
      var group = a.closest(".get");
      if (!group) return;
      var actions = a.closest(".actions") || a.parentNode;
      var box = document.createElement("div");
      box.className = "steps";
      box.hidden = true;
      var inner = document.createElement("div");
      var ol = document.createElement("ol");
      STEPS.forEach(function (t) { var li = document.createElement("li"); li.textContent = t; ol.appendChild(li); });
      inner.appendChild(ol);
      box.appendChild(inner);
      // Right after the buttons, so the steps take the button's place on the same left edge.
      group.insertBefore(box, actions.nextSibling);
      var live = liveRegion(group);
      a.addEventListener("click", function () {
        group.querySelectorAll("[data-install-hide]").forEach(function (m) { m.hidden = true; });
        if (box.hidden) {
          box.hidden = false;
          void box.offsetHeight; // start from the closed state so the opening animates
          box.classList.add("is-open");
        }
        live.textContent = "Downloading. Three steps follow.";
      });
    });
  }

  currency();
  founding();
  if (isPhone()) phone(); else desktop();
})();
