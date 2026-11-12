(function () {
  var root = document.documentElement;
  var toggle = document.getElementById("theme-toggle");
  var storageKey = "nc-theme";
  var media = window.matchMedia ? window.matchMedia("(prefers-color-scheme: light)") : null;
  // A choice made with the toggle, kept here too so it holds when storage
  // is blocked.
  var chosenThisVisit = false;

  function chosenTheme() {
    try {
      var stored = localStorage.getItem(storageKey);
      return stored === "light" || stored === "dark" ? stored : null;
    } catch (error) {
      return null;
    }
  }

  function applyTheme(theme) {
    root.setAttribute("data-theme", theme);

    if (toggle) {
      var nextTheme = theme === "dark" ? "light" : "dark";
      var label = "Switch to " + nextTheme + " mode";
      toggle.setAttribute("aria-label", label);
      toggle.setAttribute("title", label);
    }
  }

  applyTheme(root.getAttribute("data-theme") || "dark");

  // The 404 page's terminal names the path that was asked for. It is set as
  // text, stripped of control, format and line-separator characters so a
  // crafted URL cannot draw extra lines or reorder text, and capped by code
  // point so a long URL cannot stretch the page.
  var lostPaths = document.querySelectorAll("[data-nc-lost-path]");
  if (lostPaths.length > 0) {
    var requested = window.location.pathname;
    try {
      requested = decodeURIComponent(requested);
    } catch (error) {
      // Keep the encoded form when it does not decode.
    }
    requested = requested
      .replace(/[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/gu, "")
      .replace(/\s+/g, " ")
      .replace(/\//g, "\\");
    var points = Array.from(requested);
    if (points.length > 64) requested = points.slice(0, 63).join("") + "…";
    for (var i = 0; i < lostPaths.length; i += 1) lostPaths[i].textContent = requested;
  }

  // Anything that scrolls sideways (a capture wider than its frame, a
  // command block on a phone) gets a track under it whose thumb is the part
  // in view. A capture also starts on its subject (data-nc-pan:
  // "left:<fraction>" puts that point of the image at the frame's left edge,
  // "center:<fraction>" in its middle). Either is a tab stop only while it
  // scrolls (the markup keeps a command block's tabindex for pages without
  // JavaScript).
  var panFrames = document.querySelectorAll("[data-nc-pan]");
  for (var p = 0; p < panFrames.length; p += 1) setUpPan(panFrames[p]);

  function setUpPan(frame) {
    var isCapture = frame.tagName !== "PRE";
    var spec = (frame.getAttribute("data-nc-pan") || "left:0").split(":");
    var mode = spec[0];
    var at = Number(spec[1]) || 0;
    var track = document.createElement("div");
    var thumb = document.createElement("span");
    var started = false;
    track.className = "nc-track";
    track.setAttribute("aria-hidden", "true");
    track.appendChild(thumb);
    frame.insertAdjacentElement("afterend", track);

    function update() {
      var range = frame.scrollWidth - frame.clientWidth;
      var panning = range > 1;
      track.classList.toggle("is-panning", panning);
      if (panning) {
        frame.setAttribute("tabindex", "0");
        if (isCapture) {
          frame.setAttribute("role", "region");
          // Each capture is named by its own caption.
          var labelledBy = frame.getAttribute("data-nc-labelledby");
          if (labelledBy) frame.setAttribute("aria-labelledby", labelledBy);
          else frame.setAttribute("aria-label", "Screenshot, scrolls sideways");
        }
        if (!started) {
          started = true;
          var x = at * frame.scrollWidth - (mode === "center" ? frame.clientWidth / 2 : 0);
          frame.scrollLeft = Math.max(0, Math.min(range, x));
        }
        thumb.style.left = (frame.scrollLeft / frame.scrollWidth) * 100 + "%";
        thumb.style.width = (frame.clientWidth / frame.scrollWidth) * 100 + "%";
      } else if (isCapture) {
        started = false;
        frame.removeAttribute("tabindex");
        frame.removeAttribute("role");
        frame.removeAttribute("aria-label");
        frame.removeAttribute("aria-labelledby");
      } else {
        // A command block that fits has nothing to scroll to.
        frame.removeAttribute("tabindex");
      }
    }

    frame.addEventListener("scroll", update, { passive: true });
    if (typeof ResizeObserver === "function") new ResizeObserver(update).observe(frame);
    else window.addEventListener("resize", update);
    // A web font that loads late changes a command's width without resizing
    // its frame, which the observer would miss.
    if (document.fonts && document.fonts.ready) document.fonts.ready.then(update);
    update();
  }

  // Until the visitor picks a theme, follow the system when it changes.
  if (media) {
    var followSystem = function (event) {
      if (!chosenThisVisit && !chosenTheme()) applyTheme(event.matches ? "light" : "dark");
    };
    if (typeof media.addEventListener === "function") {
      media.addEventListener("change", followSystem);
    } else if (typeof media.addListener === "function") {
      media.addListener(followSystem);
    }
  }

  if (!toggle) return;

  toggle.addEventListener("click", function () {
    var nextTheme = root.getAttribute("data-theme") === "dark" ? "light" : "dark";
    chosenThisVisit = true;
    applyTheme(nextTheme);

    try {
      localStorage.setItem(storageKey, nextTheme);
    } catch (error) {
      // Keep the theme change even if storage is unavailable.
    }
  });
})();
