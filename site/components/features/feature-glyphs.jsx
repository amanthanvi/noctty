export const FEATURE_GLYPHS = {
  gpu: (
    <svg viewBox="0 0 32 32" width="32" height="32" fill="none" stroke="currentColor" strokeWidth="1.25" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <rect x="2.5" y="8" width="27" height="16" rx="1.5" />
      <path d="M2.5 12H1.5v8h1" />
      <circle cx="11" cy="16" r="4" />
      <circle cx="21" cy="16" r="4" />
      <path d="M8.25 13.25 13.75 18.75M13.75 13.25 8.25 18.75" strokeOpacity="0.55" />
      <path d="M18.25 13.25 23.75 18.75M23.75 13.25 18.25 18.75" strokeOpacity="0.55" />
      <path d="M7 24v3h18v-3" />
      <path d="M10 24.5v2M13 24.5v2M19 24.5v2M22 24.5v2" strokeOpacity="0.55" />
    </svg>
  ),
  native: (
    <svg viewBox="0 0 32 32" width="32" height="32" shapeRendering="crispEdges" aria-hidden="true">
      <rect x="2" y="2" width="13" height="13" fill="var(--wg-red)" />
      <rect x="17" y="2" width="13" height="13" fill="var(--wg-green)" />
      <rect x="2" y="17" width="13" height="13" fill="var(--wg-blue)" />
      <rect x="17" y="17" width="13" height="13" fill="var(--wg-yellow)" />
    </svg>
  ),
  compat: (
    <svg viewBox="0 0 32 32" width="32" height="32" shapeRendering="geometricPrecision" aria-hidden="true">
      <image
        href="icons/ghostty-official.png?v=2026-05-25-18"
        width="32"
        height="32"
        preserveAspectRatio="xMidYMid meet"
      />
    </svg>
  ),
  config: (
    <svg viewBox="0 0 32 32" width="32" height="32" fill="none" stroke="currentColor" strokeWidth="1.25" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <path d="M20.35 4.5a6.5 6.5 0 0 0-6.2 8.5L4.9 22.25a3 3 0 1 0 4.25 4.25l9.25-9.25a6.5 6.5 0 0 0 8.5-8.2l-4.05 4.05-3.85-.7-.7-3.85 4.05-4.05c-.64-.17-1.31-.25-2-.25Z" />
      <circle cx="7.03" cy="24.38" r="1.05" />
    </svg>
  ),
  libghostty: (
    <svg viewBox="0 0 32 32" width="32" height="32" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" shapeRendering="geometricPrecision" aria-hidden="true">
      <rect x="4.75" y="7.75" width="22.5" height="16.5" rx="2.25" />
      <path d="M9 13 12.25 16 9 19" />
      <path d="M15.25 19.25H22" />
    </svg>
  ),
  oss: (
    <svg viewBox="0 0 590 590" width="32" height="32" shapeRendering="geometricPrecision" aria-hidden="true">
      <path
        fill="#3FA648"
        stroke="#23552A"
        strokeWidth="19.2122"
        strokeLinecap="round"
        strokeLinejoin="round"
        d="M328.7,395.8c40.3-15,61.4-43.8,61.4-93.4S348.3,209,296,208.9c-55.1-0.1-96.8,43.6-96.1,93.5s24.4,83,62.4,94.9L195,563C104.8,539.7,13.2,433.3,13.2,302.4C13.2,147.3,137.8,21.5,294,21.5s282.8,125.7,282.8,280.8c0,133-90.8,237.9-182.9,261.1L328.7,395.8z"
      />
    </svg>
  ),
};
