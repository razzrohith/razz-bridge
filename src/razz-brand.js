/**
 * Razz Bridge brand overlay — injected into every page via nginx sub_filter.
 * Replaces vendor text in the operator UI with neutral branding.
 */
(function () {
  'use strict';

  var TITLE  = 'Remote Access';
  var OLD_RE = /TinyPilot|Tinypilot|tinypilot|TINYPILOT/g;

  /* ── force document.title ─────────────────────────────── */
  try {
    Object.defineProperty(document, 'title', {
      configurable: true,
      get: function () { return TITLE; },
      set: function () {}          // silently ignore writes from the app
    });
  } catch (e) {
    /* fallback if defineProperty blocked */
    document.title = TITLE;
  }

  /* ── replace text in a DOM node ──────────────────────── */
  function patchNode(node) {
    if (!node) return;
    if (node.nodeType === 3) {                    // TEXT_NODE
      var v = node.nodeValue;
      if (OLD_RE.test(v)) {
        node.nodeValue = v.replace(OLD_RE, TITLE);
        OLD_RE.lastIndex = 0;
      }
    } else if (node.nodeType === 1) {             // ELEMENT_NODE
      if (node.tagName === 'SCRIPT' || node.tagName === 'STYLE') return;
      /* patch attribute values that show vendor text */
      ['title', 'alt', 'placeholder', 'aria-label'].forEach(function (attr) {
        var val = node.getAttribute(attr);
        if (val && OLD_RE.test(val)) {
          node.setAttribute(attr, val.replace(OLD_RE, TITLE));
          OLD_RE.lastIndex = 0;
        }
      });
      for (var i = 0; i < node.childNodes.length; i++) {
        patchNode(node.childNodes[i]);
      }
      /* pierce shadow DOM if present */
      if (node.shadowRoot) patchNode(node.shadowRoot);
    }
  }

  /* ── run on current body ─────────────────────────────── */
  function run() {
    document.title = TITLE;          // belt-and-suspenders
    patchNode(document.body);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', run);
  } else {
    run();
  }

  /* ── watch for dynamic content (SPAs / web components) ── */
  document.addEventListener('DOMContentLoaded', function () {
    var obs = new MutationObserver(function (muts) {
      muts.forEach(function (m) {
        m.addedNodes.forEach(function (n) { patchNode(n); });
        if (m.type === 'characterData') patchNode(m.target);
      });
    });
    obs.observe(document.body, {
      childList: true,
      subtree: true,
      characterData: true
    });
    run();
  });
})();
