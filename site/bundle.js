(() => {
  // site/components/install/install-copied-icon.jsx
  function InstallCopiedIcon() {
    return /* @__PURE__ */ React.createElement("svg", { className: "wg-install__copy-icon", width: "14", height: "14", viewBox: "0 0 16 16", fill: "none", "aria-hidden": "true" }, /* @__PURE__ */ React.createElement("path", { d: "M3.5 8.5 6.5 11.5 12.5 4.5", stroke: "currentColor", strokeWidth: "1.5", strokeLinecap: "round", strokeLinejoin: "round" }));
  }

  // site/components/install/install-copy-icon.jsx
  function InstallCopyIcon() {
    return /* @__PURE__ */ React.createElement("svg", { className: "wg-install__copy-icon", width: "14", height: "14", viewBox: "0 0 16 16", fill: "none", "aria-hidden": "true" }, /* @__PURE__ */ React.createElement("rect", { x: "5.5", y: "5.5", width: "8", height: "9", rx: "1", stroke: "currentColor", strokeWidth: "1.25" }), /* @__PURE__ */ React.createElement("path", { d: "M5 10.5H4a1.5 1.5 0 0 1-1.5-1.5V3.5A1.5 1.5 0 0 1 4 2h6a1.5 1.5 0 0 1 1.5 1.5V5", stroke: "currentColor", strokeWidth: "1.25" }));
  }

  // site/components/install/install-block.jsx
  var { useState } = React;
  var INSTALL_METHODS = {
    scoop: {
      label: "Scoop",
      cmd: "scoop install winghostty/winghostty",
      copy: "scoop bucket add winghostty https://github.com/amanthanvi/scoop-winghostty\r\nscoop install winghostty/winghostty"
    },
    winget: {
      label: "WinGet",
      cmd: "winget install AmanThanvi.winghostty",
      copy: "winget install AmanThanvi.winghostty"
    }
  };
  function InstallBlock() {
    const [method, setMethod] = useState("winget");
    const [copied, setCopied] = useState(false);
    const active = INSTALL_METHODS[method];
    const onCopy = () => {
      navigator.clipboard?.writeText(active.copy).then(() => {
        setCopied(true);
        setTimeout(() => setCopied(false), 1400);
      });
    };
    const longestCmd = INSTALL_METHODS.winget.cmd;
    return /* @__PURE__ */ React.createElement("div", { className: "wg-install-lane" }, /* @__PURE__ */ React.createElement("div", { className: "wg-install-panel" }, /* @__PURE__ */ React.createElement("div", { className: "wg-install-frame" }, /* @__PURE__ */ React.createElement(
      "svg",
      {
        className: "wg-install-defs",
        "aria-hidden": "true",
        focusable: "false",
        width: "0",
        height: "0"
      },
      /* @__PURE__ */ React.createElement("defs", null, /* @__PURE__ */ React.createElement(
        "filter",
        {
          id: "wg-goo",
          x: "-15%",
          y: "-15%",
          width: "130%",
          height: "130%",
          colorInterpolationFilters: "sRGB"
        },
        /* @__PURE__ */ React.createElement("feGaussianBlur", { in: "SourceGraphic", stdDeviation: "4", result: "blur" }),
        /* @__PURE__ */ React.createElement(
          "feColorMatrix",
          {
            in: "blur",
            values: "1 0 0 0 0  0 1 0 0 0  0 0 1 0 0  0 0 0 22 -10"
          }
        )
      ))
    ), /* @__PURE__ */ React.createElement("div", { className: "wg-install-fluid", "aria-hidden": "true" }, /* @__PURE__ */ React.createElement("div", { className: "wg-install-fluid__pill" }), /* @__PURE__ */ React.createElement("div", { className: "wg-install-fluid__tab" })), /* @__PURE__ */ React.createElement("div", { className: "wg-install" }, /* @__PURE__ */ React.createElement("span", { className: "wg-install__sizer", "aria-hidden": "true" }, longestCmd), /* @__PURE__ */ React.createElement("span", { className: "wg-install__sigil" }, String.fromCharCode(36)), /* @__PURE__ */ React.createElement("code", { className: "wg-install__command" }, active.cmd), /* @__PURE__ */ React.createElement(
      "button",
      {
        type: "button",
        className: `wg-install__copy${copied ? " is-copied" : ""}`,
        onClick: onCopy,
        "aria-label": copied ? "Copied" : "Copy install command"
      },
      copied ? /* @__PURE__ */ React.createElement(InstallCopiedIcon, null) : /* @__PURE__ */ React.createElement(InstallCopyIcon, null)
    )), /* @__PURE__ */ React.createElement("div", { className: "wg-install-tabs", role: "tablist", "aria-label": "Install method" }, Object.entries(INSTALL_METHODS).map(([key, item]) => /* @__PURE__ */ React.createElement(
      "button",
      {
        key,
        type: "button",
        role: "tab",
        "aria-selected": method === key,
        className: method === key ? "is-active" : void 0,
        onClick: () => {
          setMethod(key);
          setCopied(false);
        }
      },
      item.label
    ))))));
  }

  // site/components/hero/color-dots.jsx
  var COLOR_DOT_KEYS = ["red", "green", "blue", "yellow"];
  function ColorDots() {
    return /* @__PURE__ */ React.createElement("span", { className: "wg-color-dots", "aria-hidden": "true" }, COLOR_DOT_KEYS.map((key) => /* @__PURE__ */ React.createElement("span", { key, className: `wg-color-dot wg-color-dot--${key}` }, /* @__PURE__ */ React.createElement("span", { className: "wg-color-dot__bob" }, /* @__PURE__ */ React.createElement("span", { className: "wg-color-dot__chip" })))));
  }

  // site/components/hero/version-chip-color.jsx
  var { useEffect, useState: useState2 } = React;
  function useLiveVersion() {
    const [v, setV] = useState2(() => typeof window !== "undefined" && window.WG_VERSION || "1.3.106");
    useEffect(() => {
      const onUpdate = (e) => {
        const newV = e?.detail?.version || window.WG_VERSION || "1.3.106";
        setV(newV);
      };
      window.addEventListener("wg-version-updated", onUpdate);
      return () => window.removeEventListener("wg-version-updated", onUpdate);
    }, []);
    return v;
  }
  function VersionChipColor() {
    const v = useLiveVersion();
    return /* @__PURE__ */ React.createElement("span", { className: "wg-hero__badge" }, /* @__PURE__ */ React.createElement(ColorDots, null), /* @__PURE__ */ React.createElement("span", { className: "wg-hero__badge-version" }, `v${v}`), /* @__PURE__ */ React.createElement("span", { className: "wg-hero__badge-latest" }, "latest"), /* @__PURE__ */ React.createElement("span", { className: "wg-hero__badge-sep", "aria-hidden": "true" }), /* @__PURE__ */ React.createElement("span", { className: "wg-hero__badge-meta" }, "Win 10/11 \xB7 x64 \xB7 ARM64"), /* @__PURE__ */ React.createElement("span", { className: "wg-hero__badge-sep", "aria-hidden": "true" }), /* @__PURE__ */ React.createElement("span", { className: "wg-hero__badge-stack" }, "MIT \xB7 OpenGL 4.3"));
  }

  // site/components/heroes.jsx
  function HeroColorPop() {
    return /* @__PURE__ */ React.createElement("section", { className: "wg-hero", id: "download", "aria-labelledby": "hero-title" }, /* @__PURE__ */ React.createElement("div", { className: "wg-hero-copy" }, /* @__PURE__ */ React.createElement(VersionChipColor, null), /* @__PURE__ */ React.createElement("div", { className: "wg-hero__intro" }, /* @__PURE__ */ React.createElement("h1", { className: "wg-hero__title", id: "hero-title" }, "Ghostty", /* @__PURE__ */ React.createElement("span", { className: "wg-accent-red" }, ","), /* @__PURE__ */ React.createElement("br", { className: "wg-hero__mobile-break" }), " finally", /* @__PURE__ */ React.createElement("br", null), "on Windows", /* @__PURE__ */ React.createElement("span", { className: "wg-accent-blue" }, ".")), /* @__PURE__ */ React.createElement("p", { className: "wg-hero__caption" }, "The Ghostty you know and love, now on Windows. Winghostty is a Windows-native fork that brings Ghostty's terminal core into a real Windows app, with tabs, splits, profiles, and plain-text configuration.")), /* @__PURE__ */ React.createElement("div", { className: "wg-hero__actions" }, /* @__PURE__ */ React.createElement(
      "a",
      {
        className: "wg-button wg-button--primary",
        href: "https://github.com/amanthanvi/winghostty/releases/latest",
        target: "_blank",
        rel: "noreferrer"
      },
      "Download latest \u2197"
    ), /* @__PURE__ */ React.createElement(InstallBlock, null))));
  }

  // site/components/layout/section-label.jsx
  function SectionLabel({ num, title }) {
    return /* @__PURE__ */ React.createElement("div", { className: "wg-section-label" }, /* @__PURE__ */ React.createElement("span", null, num), /* @__PURE__ */ React.createElement("span", null, title));
  }

  // site/components/mark/winghostty-toggle.jsx
  var { useState: useState3 } = React;
  function WinghosttyToggle({ theme, onToggle, size = 22 }) {
    const [blinking, setBlinking] = useState3(false);
    const [hover, setHover] = useState3(false);
    const triggerBlink = () => {
      if (blinking) return;
      setBlinking(true);
      onToggle();
      setTimeout(() => setBlinking(false), 220);
    };
    return /* @__PURE__ */ React.createElement(
      "button",
      {
        type: "button",
        className: `wg-theme-toggle${blinking ? " is-blinking" : ""}`,
        onMouseEnter: () => setHover(true),
        onMouseLeave: () => setHover(false),
        onClick: triggerBlink,
        "aria-label": `Switch to ${theme === "dark" ? "light" : "dark"} mode`,
        title: `Switch to ${theme === "dark" ? "light" : "dark"} mode`,
        style: hover ? { background: "var(--surface-strong)" } : void 0
      },
      /* @__PURE__ */ React.createElement("svg", { width: size, height: size * 32 / 27, viewBox: "0 0 27 32", fill: "none", "aria-hidden": "true" }, /* @__PURE__ */ React.createElement(
        "path",
        {
          className: "wg-theme-toggle__ghost",
          d: "M20.4 30.59C19.28 30.59 18.18 30.21 17.32 29.51C17.16 29.39 17 29.36 16.9 29.36C16.72 29.36 16.55 29.43 16.41 29.54C15.55 30.22 14.46 30.6 13.36 30.6C12.26 30.6 11.18 30.22 10.32 29.54C10.18 29.43 10.01 29.37 9.85 29.37C9.68 29.37 9.51 29.43 9.37 29.54C8.51 30.22 7.47 30.59 6.36 30.6H6.33C5.02 30.6 3.78 30.07 2.84 29.11C1.92 28.17 1.41 26.93 1.41 25.62V13.37C1.41 6.77 6.77 1.41 13.36 1.41C19.95 1.41 25.32 6.77 25.32 13.36V25.62C25.32 28.26 23.28 30.44 20.67 30.59C20.58 30.59 20.49 30.59 20.4 30.59Z",
          fill: "currentColor"
        }
      ), /* @__PURE__ */ React.createElement("g", { className: "wg-theme-toggle__glyphs" }, /* @__PURE__ */ React.createElement(
        "path",
        {
          className: "wg-theme-toggle__glyph",
          d: "M11.28 12.44L7.35 10.17C6.84 9.87 6.18 10.05 5.89 10.56C5.59 11.07 5.77 11.73 6.28 12.02L8.6 13.37L6.28 14.71C5.77 15 5.59 15.66 5.89 16.17C6.18 16.68 6.84 16.86 7.35 16.56L11.28 14.29C11.99 13.88 11.99 12.85 11.28 12.44V12.44Z",
          fill: "var(--bg)"
        }
      ), /* @__PURE__ */ React.createElement(
        "path",
        {
          className: "wg-theme-toggle__glyph",
          d: "M20.18 12.29H15.02C14.43 12.29 13.95 12.77 13.95 13.36C13.95 13.96 14.42 14.43 15.02 14.43H20.18C20.77 14.43 21.25 13.96 21.25 13.36C21.25 12.77 20.78 12.29 20.18 12.29Z",
          fill: "var(--bg)"
        }
      )))
    );
  }

  // site/components/mark.jsx
  function WinghosttyMark({ size = 28, theme = "dark", animated = false }) {
    const ghostFill = theme === "dark" ? "#ffffff" : "#0a0a0a";
    const outline = theme === "dark" ? "#0a0a0a" : "#ffffff";
    const glyph = theme === "dark" ? "#0a0a0a" : "#ffffff";
    const transition = animated ? "fill 0.5s cubic-bezier(0.45, 0, 0.15, 1)" : void 0;
    return /* @__PURE__ */ React.createElement("svg", { width: size, height: size * 32 / 27, viewBox: "0 0 27 32", fill: "none", "aria-hidden": "true" }, /* @__PURE__ */ React.createElement("defs", null, /* @__PURE__ */ React.createElement("clipPath", { id: `wg-tl-${size}` }, /* @__PURE__ */ React.createElement("rect", { x: "0", y: "0", width: "13.36", height: "16" })), /* @__PURE__ */ React.createElement("clipPath", { id: `wg-tr-${size}` }, /* @__PURE__ */ React.createElement("rect", { x: "13.36", y: "0", width: "13.64", height: "16" })), /* @__PURE__ */ React.createElement("clipPath", { id: `wg-bl-${size}` }, /* @__PURE__ */ React.createElement("rect", { x: "0", y: "16", width: "13.36", height: "16" })), /* @__PURE__ */ React.createElement("clipPath", { id: `wg-br-${size}` }, /* @__PURE__ */ React.createElement("rect", { x: "13.36", y: "16", width: "13.64", height: "16" }))), /* @__PURE__ */ React.createElement("path", { d: "M20.4 32C19.14 32 17.92 31.62 16.88 30.93C15.84 31.62 14.61 32 13.36 32C12.11 32 10.88 31.62 9.85 30.93C8.82 31.62 7.63 31.99 6.37 32H6.33C4.63 32 3.04 31.32 1.83 30.09C0.65 28.88 -0 27.29 -0 25.61V13.36C-9.71e-05 5.99 5.99 0 13.36 0C20.73 0 26.73 5.99 26.73 13.36V25.62C26.73 29.01 24.1 31.81 20.75 31.99C20.63 32 20.51 32 20.4 32Z", fill: "#F25022", clipPath: `url(#wg-tl-${size})` }), /* @__PURE__ */ React.createElement("path", { d: "M20.4 32C19.14 32 17.92 31.62 16.88 30.93C15.84 31.62 14.61 32 13.36 32C12.11 32 10.88 31.62 9.85 30.93C8.82 31.62 7.63 31.99 6.37 32H6.33C4.63 32 3.04 31.32 1.83 30.09C0.65 28.88 -0 27.29 -0 25.61V13.36C-9.71e-05 5.99 5.99 0 13.36 0C20.73 0 26.73 5.99 26.73 13.36V25.62C26.73 29.01 24.1 31.81 20.75 31.99C20.63 32 20.51 32 20.4 32Z", fill: "#7FBA00", clipPath: `url(#wg-tr-${size})` }), /* @__PURE__ */ React.createElement("path", { d: "M20.4 32C19.14 32 17.92 31.62 16.88 30.93C15.84 31.62 14.61 32 13.36 32C12.11 32 10.88 31.62 9.85 30.93C8.82 31.62 7.63 31.99 6.37 32H6.33C4.63 32 3.04 31.32 1.83 30.09C0.65 28.88 -0 27.29 -0 25.61V13.36C-9.71e-05 5.99 5.99 0 13.36 0C20.73 0 26.73 5.99 26.73 13.36V25.62C26.73 29.01 24.1 31.81 20.75 31.99C20.63 32 20.51 32 20.4 32Z", fill: "#00A4EF", clipPath: `url(#wg-bl-${size})` }), /* @__PURE__ */ React.createElement("path", { d: "M20.4 32C19.14 32 17.92 31.62 16.88 30.93C15.84 31.62 14.61 32 13.36 32C12.11 32 10.88 31.62 9.85 30.93C8.82 31.62 7.63 31.99 6.37 32H6.33C4.63 32 3.04 31.32 1.83 30.09C0.65 28.88 -0 27.29 -0 25.61V13.36C-9.71e-05 5.99 5.99 0 13.36 0C20.73 0 26.73 5.99 26.73 13.36V25.62C26.73 29.01 24.1 31.81 20.75 31.99C20.63 32 20.51 32 20.4 32Z", fill: "#FFB900", clipPath: `url(#wg-br-${size})` }), /* @__PURE__ */ React.createElement("path", { style: { transition }, d: "M20.4 30.59C19.28 30.59 18.18 30.21 17.32 29.51C17.16 29.39 17 29.36 16.9 29.36C16.72 29.36 16.55 29.43 16.41 29.54C15.55 30.22 14.46 30.6 13.36 30.6C12.26 30.6 11.18 30.22 10.32 29.54C10.18 29.43 10.01 29.37 9.85 29.37C9.68 29.37 9.51 29.43 9.37 29.54C8.51 30.22 7.47 30.59 6.36 30.6H6.33C5.02 30.6 3.78 30.07 2.84 29.11C1.92 28.17 1.41 26.93 1.41 25.62V13.37C1.41 6.77 6.77 1.41 13.36 1.41C19.95 1.41 25.32 6.77 25.32 13.36V25.62C25.32 28.26 23.28 30.44 20.67 30.59C20.58 30.59 20.49 30.59 20.4 30.59Z", fill: outline }), /* @__PURE__ */ React.createElement("path", { style: { transition }, d: "M23.91 13.36V25.62C23.91 27.49 22.47 29.08 20.59 29.18C19.68 29.23 18.84 28.94 18.19 28.41C17.42 27.79 16.32 27.82 15.54 28.43C14.94 28.91 14.18 29.19 13.36 29.19C12.54 29.19 11.78 28.91 11.19 28.43C10.39 27.81 9.3 27.81 8.5 28.43C7.91 28.9 7.16 29.18 6.35 29.19C4.4 29.2 2.81 27.56 2.81 25.61V13.36C2.81 7.54 7.54 2.81 13.36 2.81C19.19 2.81 23.91 7.54 23.91 13.36Z", fill: ghostFill }), /* @__PURE__ */ React.createElement("path", { style: { transition }, d: "M11.28 12.44L7.35 10.17C6.84 9.87 6.18 10.05 5.89 10.56C5.59 11.07 5.77 11.73 6.28 12.02L8.6 13.37L6.28 14.71C5.77 15 5.59 15.66 5.89 16.17C6.18 16.68 6.84 16.86 7.35 16.56L11.28 14.29C11.99 13.88 11.99 12.85 11.28 12.44V12.44Z", fill: glyph }), /* @__PURE__ */ React.createElement("path", { style: { transition }, d: "M20.18 12.29H15.02C14.43 12.29 13.95 12.77 13.95 13.36C13.95 13.96 14.42 14.43 15.02 14.43H20.18C20.77 14.43 21.25 13.96 21.25 13.36C21.25 12.77 20.78 12.29 20.18 12.29Z", fill: glyph }));
  }

  // site/components/mark/winghostty-wordmark.jsx
  function WinghosttyWordmark({ size = 28, theme = "dark" }) {
    return /* @__PURE__ */ React.createElement("span", { className: "wg-wordmark" }, /* @__PURE__ */ React.createElement(WinghosttyMark, { size, theme }), /* @__PURE__ */ React.createElement("span", { className: "wg-wordmark__text", style: { fontSize: size * 0.78 } }, "Winghostty"));
  }

  // site/components/layout/top-bar.jsx
  function TopBar({ theme, setTheme }) {
    return /* @__PURE__ */ React.createElement("header", { className: "wg-topbar" }, /* @__PURE__ */ React.createElement("div", { className: "wg-container wg-topbar__inner" }, /* @__PURE__ */ React.createElement("a", { href: "/", className: "wg-wordmark-link", "aria-label": "Winghostty home" }, /* @__PURE__ */ React.createElement(WinghosttyWordmark, { size: 24, theme })), /* @__PURE__ */ React.createElement(WinghosttyToggle, { theme, onToggle: () => setTheme(theme === "dark" ? "light" : "dark") })));
  }

  // site/components/features/feature-glyphs.jsx
  var FEATURE_GLYPHS = {
    gpu: /* @__PURE__ */ React.createElement("svg", { viewBox: "0 0 32 32", width: "32", height: "32", fill: "none", stroke: "currentColor", strokeWidth: "1.25", strokeLinecap: "round", strokeLinejoin: "round", "aria-hidden": "true" }, /* @__PURE__ */ React.createElement("rect", { x: "2.5", y: "8", width: "27", height: "16", rx: "1.5" }), /* @__PURE__ */ React.createElement("path", { d: "M2.5 12H1.5v8h1" }), /* @__PURE__ */ React.createElement("circle", { cx: "11", cy: "16", r: "4" }), /* @__PURE__ */ React.createElement("circle", { cx: "21", cy: "16", r: "4" }), /* @__PURE__ */ React.createElement("path", { d: "M8.25 13.25 13.75 18.75M13.75 13.25 8.25 18.75", strokeOpacity: "0.55" }), /* @__PURE__ */ React.createElement("path", { d: "M18.25 13.25 23.75 18.75M23.75 13.25 18.25 18.75", strokeOpacity: "0.55" }), /* @__PURE__ */ React.createElement("path", { d: "M7 24v3h18v-3" }), /* @__PURE__ */ React.createElement("path", { d: "M10 24.5v2M13 24.5v2M19 24.5v2M22 24.5v2", strokeOpacity: "0.55" })),
    native: /* @__PURE__ */ React.createElement("svg", { viewBox: "0 0 32 32", width: "32", height: "32", shapeRendering: "crispEdges", "aria-hidden": "true" }, /* @__PURE__ */ React.createElement("rect", { x: "2", y: "2", width: "13", height: "13", fill: "var(--wg-red)" }), /* @__PURE__ */ React.createElement("rect", { x: "17", y: "2", width: "13", height: "13", fill: "var(--wg-green)" }), /* @__PURE__ */ React.createElement("rect", { x: "2", y: "17", width: "13", height: "13", fill: "var(--wg-blue)" }), /* @__PURE__ */ React.createElement("rect", { x: "17", y: "17", width: "13", height: "13", fill: "var(--wg-yellow)" })),
    compat: /* @__PURE__ */ React.createElement("svg", { viewBox: "0 0 32 32", width: "32", height: "32", shapeRendering: "geometricPrecision", "aria-hidden": "true" }, /* @__PURE__ */ React.createElement(
      "image",
      {
        href: "icons/ghostty-official.png?v=2026-05-25-18",
        width: "32",
        height: "32",
        preserveAspectRatio: "xMidYMid meet"
      }
    )),
    config: /* @__PURE__ */ React.createElement("svg", { viewBox: "0 0 32 32", width: "32", height: "32", fill: "none", stroke: "currentColor", strokeWidth: "1.25", strokeLinecap: "round", strokeLinejoin: "round", "aria-hidden": "true" }, /* @__PURE__ */ React.createElement("path", { d: "M20.35 4.5a6.5 6.5 0 0 0-6.2 8.5L4.9 22.25a3 3 0 1 0 4.25 4.25l9.25-9.25a6.5 6.5 0 0 0 8.5-8.2l-4.05 4.05-3.85-.7-.7-3.85 4.05-4.05c-.64-.17-1.31-.25-2-.25Z" }), /* @__PURE__ */ React.createElement("circle", { cx: "7.03", cy: "24.38", r: "1.05" })),
    libghostty: /* @__PURE__ */ React.createElement("svg", { viewBox: "0 0 32 32", width: "32", height: "32", fill: "none", stroke: "currentColor", strokeWidth: "1.5", strokeLinecap: "round", strokeLinejoin: "round", shapeRendering: "geometricPrecision", "aria-hidden": "true" }, /* @__PURE__ */ React.createElement("rect", { x: "4.75", y: "7.75", width: "22.5", height: "16.5", rx: "2.25" }), /* @__PURE__ */ React.createElement("path", { d: "M9 13 12.25 16 9 19" }), /* @__PURE__ */ React.createElement("path", { d: "M15.25 19.25H22" })),
    oss: /* @__PURE__ */ React.createElement("svg", { viewBox: "0 0 590 590", width: "32", height: "32", shapeRendering: "geometricPrecision", "aria-hidden": "true" }, /* @__PURE__ */ React.createElement(
      "path",
      {
        fill: "#3FA648",
        stroke: "#23552A",
        strokeWidth: "19.2122",
        strokeLinecap: "round",
        strokeLinejoin: "round",
        d: "M328.7,395.8c40.3-15,61.4-43.8,61.4-93.4S348.3,209,296,208.9c-55.1-0.1-96.8,43.6-96.1,93.5s24.4,83,62.4,94.9L195,563C104.8,539.7,13.2,433.3,13.2,302.4C13.2,147.3,137.8,21.5,294,21.5s282.8,125.7,282.8,280.8c0,133-90.8,237.9-182.9,261.1L328.7,395.8z"
      }
    ))
  };

  // site/components/features/feature-card.jsx
  function FeatureCard({ feature }) {
    return /* @__PURE__ */ React.createElement("article", { className: "wg-feature-card" }, /* @__PURE__ */ React.createElement("div", { className: "wg-feature-card__glyph" }, FEATURE_GLYPHS[feature.k]), /* @__PURE__ */ React.createElement("h2", null, feature.title), /* @__PURE__ */ React.createElement("p", null, feature.body));
  }

  // site/components/features/feature-grid.jsx
  var FEATURES = [
    { k: "gpu", title: "Smooth and GPU-accelerated", body: "Fast, crisp terminal rendering in the Windows app shipping today." },
    { k: "native", title: "Feels native on Windows", body: "Tabs, splits, IME, drag-and-drop, and the details that make it feel like a real Windows app." },
    { k: "compat", title: "Built on Ghostty", body: "Winghostty keeps Ghostty's terminal core, then adds the Windows-native app layer around it." },
    { k: "config", title: "Easy to make your own", body: "Edit %LOCALAPPDATA%\\winghostty\\config.ghostty, reload changes live, and make Winghostty feel like yours." },
    { k: "libghostty", title: "Your shells, ready to go", body: "PowerShell, cmd, Git Bash, and opt-in WSL are easy to launch from the built-in profile picker." },
    { k: "oss", title: "Open source, local-first", body: "MIT-licensed, no telemetry, and updates stay notify-only instead of replacing binaries in the background." }
  ];
  function FeatureGrid() {
    return /* @__PURE__ */ React.createElement("div", { className: "wg-feature-grid" }, FEATURES.map((feature) => /* @__PURE__ */ React.createElement(FeatureCard, { key: feature.k, feature })));
  }

  // site/components/footer/footer.jsx
  function Footer({ theme }) {
    return /* @__PURE__ */ React.createElement("footer", { className: "wg-footer" }, /* @__PURE__ */ React.createElement("div", { className: "wg-footer__top" }, /* @__PURE__ */ React.createElement(WinghosttyWordmark, { size: 20, theme }), /* @__PURE__ */ React.createElement("div", { className: "wg-footer__links" }, /* @__PURE__ */ React.createElement("a", { href: "https://github.com/amanthanvi/winghostty", target: "_blank", rel: "noreferrer" }, "GitHub"), /* @__PURE__ */ React.createElement("a", { href: "https://github.com/amanthanvi/winghostty/releases", target: "_blank", rel: "noreferrer" }, "Releases"), /* @__PURE__ */ React.createElement("a", { href: "https://github.com/amanthanvi/winghostty/issues", target: "_blank", rel: "noreferrer" }, "Issues"), /* @__PURE__ */ React.createElement("a", { href: "https://ghostty.org", target: "_blank", rel: "noreferrer" }, "Upstream \u2197"))), /* @__PURE__ */ React.createElement("div", { className: "wg-footer__bottom" }, /* @__PURE__ */ React.createElement("span", null, "Built on Ghostty's terminal core by Mitchell Hashimoto & contributors. Win32 runtime by", " ", /* @__PURE__ */ React.createElement("a", { href: "https://github.com/amanthanvi" }, "@amanthanvi"), "."), /* @__PURE__ */ React.createElement("span", null, "MIT \xB7 Not affiliated with upstream Ghostty")));
  }

  // site/components/why/why-fork.jsx
  var WHY_ITEMS = [
    {
      q: "Why a fork instead of upstream?",
      a: "Ghostty does not ship a Windows app today. Winghostty keeps the Ghostty core and builds the Windows-native experience around it."
    },
    {
      q: "How close is it to Ghostty?",
      a: "Close where it matters: the terminal core is shared, while the app layer around it is purpose-built for Windows."
    },
    {
      q: "Is it ready to use?",
      a: "Winghostty is young, with first public releases on April 16, 2026, but it is already usable if you are comfortable running a fast-moving project."
    },
    {
      q: "What platforms is this for?",
      a: "Windows 10 and Windows 11 on x64 and ARM64. This fork is focused on shipping a native Windows app."
    },
    {
      q: "Anything to know before installing?",
      a: "Yes. Installers are self-signed, not signed by a public CA, so SmartScreen may still warn on first run. Click More info, then Run anyway."
    },
    {
      q: "Does it phone home?",
      a: "No telemetry or analytics. The updater only checks GitHub for new releases and stays notify-only."
    }
  ];
  function WhyFork() {
    return /* @__PURE__ */ React.createElement("div", { className: "wg-why-grid" }, WHY_ITEMS.map((item, idx) => /* @__PURE__ */ React.createElement("div", { key: item.q, className: "wg-why-item" }, /* @__PURE__ */ React.createElement("span", { className: "wg-why-item__index" }, String(idx + 1).padStart(2, "0")), /* @__PURE__ */ React.createElement("div", null, /* @__PURE__ */ React.createElement("h2", null, item.q), /* @__PURE__ */ React.createElement("p", null, item.a)))));
  }

  // site/components/app.jsx
  var { useEffect: useAppEffect, useState: useAppState } = React;
  function App() {
    const [theme, setTheme] = useAppState(() => localStorage.getItem("wg-theme") || "dark");
    useAppEffect(() => {
      localStorage.setItem("wg-theme", theme);
    }, [theme]);
    useAppEffect(() => {
      document.documentElement.setAttribute("data-theme", theme);
      document.body.dataset.theme = theme;
    }, [theme]);
    useAppEffect(() => {
      const onMessage = (e) => {
        const d = e.data || {};
        if (d.type === "__activate_edit_mode") document.body.dataset.editMode = "on";
        if (d.type === "__deactivate_edit_mode") document.body.dataset.editMode = "off";
      };
      window.addEventListener("message", onMessage);
      window.parent?.postMessage({ type: "__edit_mode_available" }, "*");
      return () => window.removeEventListener("message", onMessage);
    }, []);
    return /* @__PURE__ */ React.createElement(React.Fragment, null, /* @__PURE__ */ React.createElement("a", { className: "wg-skip-link", href: "#main-content" }, "Skip to content"), /* @__PURE__ */ React.createElement(TopBar, { theme, setTheme }), /* @__PURE__ */ React.createElement("main", { id: "main-content" }, /* @__PURE__ */ React.createElement("div", { className: "wg-container wg-section wg-section--lead" }, /* @__PURE__ */ React.createElement(HeroColorPop, null)), /* @__PURE__ */ React.createElement(
      "div",
      {
        className: "wg-container wg-section wg-section--follow",
        "data-accent": "blue",
        style: { contentVisibility: "auto", containIntrinsicSize: "640px" }
      },
      /* @__PURE__ */ React.createElement(SectionLabel, { num: "01", title: "What you get" }),
      /* @__PURE__ */ React.createElement(FeatureGrid, null)
    ), /* @__PURE__ */ React.createElement(
      "div",
      {
        className: "wg-container wg-section",
        "data-accent": "yellow",
        style: { paddingTop: 32, paddingBottom: 48, contentVisibility: "auto", containIntrinsicSize: "540px" }
      },
      /* @__PURE__ */ React.createElement(SectionLabel, { num: "02", title: "Why a fork?" }),
      /* @__PURE__ */ React.createElement(WhyFork, null)
    ), /* @__PURE__ */ React.createElement("div", { className: "wg-container", style: { contentVisibility: "auto", containIntrinsicSize: "220px" } }, /* @__PURE__ */ React.createElement(Footer, { theme }))));
  }

  // site/main.jsx
  ReactDOM.createRoot(document.getElementById("root")).render(/* @__PURE__ */ React.createElement(App, null));
})();
