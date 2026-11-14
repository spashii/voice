/* Activation page script. It reads the nonce from the URL fragment (never sent to any server), talks to
   the worker's activation API, and hands the token back to the app through its URL scheme. On dictate.tech
   (and its staging host) the API is the page's own origin; a copy served anywhere else calls dictate.tech.
   Turnstile keys and the API host switch to test values only on localhost. */
(() => {
  const $ = (id) => document.getElementById(id);
  const local = location.hostname === "localhost" || location.hostname === "127.0.0.1";
  const API = local ? "http://localhost:8799" : /(^|\.)dictate\.tech$/.test(location.hostname) ? location.origin : "https://dictate.tech";
  const sitekey = local ? "1x00000000000000000000AA" : "0x4AAAAAAF-MEHP47FLn7LEY";
  const attribution = window.dictateAttribution || {};
  let reply = "";
  const hash = new URLSearchParams(location.hash.slice(1));
  const nonce = hash.get("n") || "";
  const version = hash.get("v") || "";
  // Debug builds of the app use a second scheme; anything else falls back to the release one.
  const scheme = hash.get("s") === "in.firstversion.dictate.dev" ? "in.firstversion.dictate.dev" : "in.firstversion.dictate";
  const COOLDOWN = 30;

  let tsToken = "";
  let tsWidget = null;
  let requestId = "";
  let email = "";
  let busy = false;
  let timer = 0;

  const START_ERRORS = {
    bad_email: "That email address does not look right.",
    turnstile: "I could not confirm you are a person. Reload the page and try again.",
    too_many: "Too many tries from here. Wait a little and try again.",
    busy: "Lots of people are activating right now. Try again in a few minutes.",
    too_many_for_address: "I cannot send more codes to this address for now.",
  };
  const NETWORK = "I could not reach the site. Try again in a minute.";
  const MAIL = "I could not send the email. Try again in a minute.";

  function show(step) {
    for (const s of document.querySelectorAll("[data-step]")) s.hidden = s.dataset.step !== step;
    const heading = document.querySelector(`[data-step="${step}"] h1`);
    if (heading) heading.focus();
  }

  function setError(id, text, input) {
    $(id).textContent = text;
    if (input) input.setAttribute("aria-invalid", text ? "true" : "false");
  }

  async function api(path, body) {
    try {
      const r = await fetch(API + path, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) });
      return { status: r.status, json: await r.json().catch(() => ({})) };
    } catch {
      return { status: 0, json: {} };
    }
  }

  function updateStart() { $("b-start").disabled = busy || !tsToken; }
  function updateResend(left) {
    const b = $("b-resend");
    b.disabled = left > 0 || busy || !tsToken;
    b.textContent = left > 0 ? `Send a new code in ${left} s` : "Send a new code";
  }

  function startCooldown() {
    clearInterval(timer);
    let left = COOLDOWN;
    updateResend(left);
    timer = setInterval(() => { left -= 1; updateResend(Math.max(left, 0)); if (left <= 0) clearInterval(timer); }, 1000);
  }

  function resetTurnstile() {
    tsToken = "";
    if (window.turnstile && tsWidget !== null) window.turnstile.reset(tsWidget);
    updateStart();
  }

  function initTurnstile(tries = 0) {
    if (window.turnstile) {
      tsWidget = window.turnstile.render("#ts", {
        sitekey,
        appearance: "interaction-only",
        callback: (t) => { tsToken = t; updateStart(); updateResend(parseInt(($("b-resend").textContent.match(/\d+/) || [0])[0], 10)); },
        "expired-callback": () => { tsToken = ""; updateStart(); },
        "error-callback": () => { tsToken = ""; updateStart(); setError("err-start", START_ERRORS.turnstile); },
      });
    } else if (tries < 100) {
      setTimeout(() => initTurnstile(tries + 1), 100);
    } else {
      setError("err-start", "The check did not load. Reload the page and try again.");
    }
  }

  async function sendCode() {
    busy = true;
    updateStart();
    $("b-start").textContent = "Sending";
    const r = await api("/api/activate/start", { email, nonce, app_version: version, attribution, turnstile: tsToken });
    busy = false;
    $("b-start").textContent = "Email me a code";
    resetTurnstile();
    return r;
  }

  $("f-start").addEventListener("submit", async (e) => {
    e.preventDefault();
    if (busy || !tsToken) return;
    email = $("email").value.trim();
    setError("err-start", "", $("email"));
    $("extra-start").hidden = true;
    if (!email) { setError("err-start", START_ERRORS.bad_email, $("email")); $("email").focus(); return; }
    const r = await sendCode();
    if (r.status === 200 && r.json.request_id) {
      requestId = r.json.request_id;
      $("sent-to").textContent = email;
      $("code").value = "";
      setError("err-code", "", $("code"));
      show("code");
      startCooldown();
      return;
    }
    const e2 = r.json.error;
    if (e2 === "mail_failed" || r.status === 503) setError("err-start", MAIL);
    else if (START_ERRORS[e2]) setError("err-start", START_ERRORS[e2], e2 === "bad_email" ? $("email") : null);
    else setError("err-start", NETWORK);
    reply = r.json.contact || "";
    if (e2 === "too_many_for_address" && reply) { $("writeme").href = `mailto:${reply}`; $("extra-start").hidden = false; }
    if (e2 === "bad_email") $("email").focus();
  });

  $("b-resend").addEventListener("click", async () => {
    if (busy || !tsToken) return;
    setError("err-code", "", $("code"));
    const r = await sendCode();
    if (r.status === 200 && r.json.request_id) {
      requestId = r.json.request_id;
      $("code").value = "";
      $("code").focus();
      startCooldown();
      return;
    }
    clearInterval(timer);
    updateResend(0);
    if (r.json.error === "too_many_for_address") { reply = r.json.contact || ""; setError("err-code", reply ? `${START_ERRORS.too_many_for_address} Write to me at ${reply}.` : START_ERRORS.too_many_for_address); }
    else setError("err-code", r.json.error === "mail_failed" ? MAIL : START_ERRORS[r.json.error] || NETWORK);
  });

  $("b-other").addEventListener("click", () => {
    clearInterval(timer);
    show("start");
    $("email").focus();
    $("email").select();
  });

  $("code").addEventListener("input", (e) => {
    e.target.value = e.target.value.replace(/\D/g, "").slice(0, 6);
    setError("err-code", "", e.target);
  });

  function founding(json) {
    // The group the activation put this Mac in, named once on the done step.
    const n = json.founding_no;
    $("ent").textContent = json.ent === "founding" && Number.isInteger(n) ? `You're early\u00a0access\u00a0user ${n} of 50, so Dictate is free for you forever.` : "Dictate is free for you during early access.";
  }

  $("open-app").addEventListener("click", () => {
    // The link itself opens Dictate; this only changes what the page says.
    $("h-done").textContent = "Dictate should be open now.";
    $("closeme").hidden = false;
    $("done-fine").hidden = true;
    $("open-app").classList.remove("primary");
    $("open-app").classList.add("secondary");
    $("open-app").textContent = "Open Dictate again";
    $("h-done").focus();
  });

  function finish(json) {
    const token = json.token;
    founding(json);
    const url = `${scheme}://activate?t=${encodeURIComponent(token)}`;
    $("open-app").href = url;
    show("done");
    // One automatic try. Browsers only allow it to open an app after a click, so the button is the real path.
    location.href = url;
  }

  $("f-code").addEventListener("submit", async (e) => {
    e.preventDefault();
    if (busy) return;
    const code = $("code").value;
    if (!/^\d{6}$/.test(code)) { setError("err-code", "The code is 6 digits.", $("code")); $("code").focus(); return; }
    busy = true;
    $("b-code").disabled = true;
    const r = await api("/api/activate/verify", { request_id: requestId, code });
    busy = false;
    $("b-code").disabled = false;
    if (r.status === 200 && r.json.token) return finish(r.json);
    const err = r.json.error;
    if (err === "wrong_code") {
      const n = r.json.tries_left;
      setError("err-code", n > 0 ? `That code is not right. ${n} ${n === 1 ? "try" : "tries"} left.` : "That code is not right. Send a new code.", $("code"));
    } else if (err === "too_many_tries") setError("err-code", "Too many wrong tries. Send a new code.", $("code"));
    else if (err === "expired") setError("err-code", "That code has expired. Send a new code.", $("code"));
    else setError("err-code", NETWORK);
    $("code").focus();
  });


  // Counts a page view for stats. Failure changes nothing for the person.
  try { fetch(API + "/api/activate/view", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ attribution }) }).catch(() => {}); } catch {}

  // Spots left, shown under the email field. If the request fails the line stays hidden.
  fetch(API + "/api/activate/founding").then((r) => (r.ok ? r.json() : null)).then((j) => {
    if (j && Number.isInteger(j.left) && j.left > 0) { $("founding").textContent = `Free forever for the first 50 early\u00a0access\u00a0users. ${j.left} ${j.left === 1 ? "spot" : "spots"} left.`; $("founding").hidden = false; }
  }).catch(() => {});

  if (!/^[A-Za-z0-9_-]{16,64}$/.test(nonce)) {
    show("open");
  } else {
    show("start");
    initTurnstile();
  }

  // Web Analytics counts dictate.tech only; the CSP allows this script and the beacon's endpoint.
  if (location.hostname === "dictate.tech") {
    const s = document.createElement("script");
    s.defer = true;
    s.src = "https://static.cloudflareinsights.com/beacon.min.js";
    s.dataset.cfBeacon = '{"token": "df4da6da1c404d95824b0a88d2638fda"}';
    document.head.append(s);
  }
})();
