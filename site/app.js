(function () {
  var root = document.documentElement;
  var toggle = document.getElementById("theme-toggle");
  var storageKey = "nc-theme";
  var blinkTimer = null;

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

  if (!toggle) return;

  toggle.addEventListener("click", function () {
    var nextTheme = root.getAttribute("data-theme") === "dark" ? "light" : "dark";
    applyTheme(nextTheme);

    if (blinkTimer === null) {
      toggle.classList.add("is-blinking");
      blinkTimer = setTimeout(function () {
        toggle.classList.remove("is-blinking");
        blinkTimer = null;
      }, 220);
    }

    try {
      localStorage.setItem(storageKey, nextTheme);
    } catch (error) {
      // Keep the theme change even if storage is unavailable.
    }
  });
})();
