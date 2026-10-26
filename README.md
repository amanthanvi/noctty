# Evidence: tab strip without accent (TABLINE, 2026-10-26)

All captures: `PrintWindow(PW_RENDERFULLCONTENT)` of the host on a private desktop
(`CreateDesktopW`, every process started with an explicit `lpDesktop`), 144 DPI, portable
ReleaseFast copies built with the measurement AUMID (`io.github.amanthanvi.noctty.measure`)
and `-Dversion-string=0.0.1`, `LOCALAPPDATA`/`APPDATA` redirected, `--single-instance=false`,
a unique `class`. The terminal (an OpenGL child) captures as white on a hidden desktop, so
only the chrome is evidence.

## t1: the stray blue line in the maintainer's screenshot

`t1-stray-line-crops.png`: the maintainer's screenshot (x 900..1255, y 40..62), then
v1.3.131 with an update notice (the real GitHub feed, which offers 1.3.135), then main
`f4fff162b` in the same state. In both the screenshot and the 1.3.131 capture the line is
a 145 px run of `#8EC5FF` (the dark theme's `info_fg`) on the underline's last row, with
2 px corners on the separator row and `#242428` (`update_open_bg`) between them, followed
18 px later by a 100 px run of `#303030` (the Dismiss button's border). It is the top of
1.3.131's update notice ("Open Release" / "Dismiss"), painted on the host at
`content_top - scaled(2)` and covered by the terminal child, the topmost child, everywhere
else. #336 (BANNER-01, in v1.3.132) moved the notice into a banner child raised above the
terminal: `t1-main-notice-full.png`. The 1.3.131 copy needs the ConPTY pair beside it:
without it a ConPTY-fallback banner message takes the notice's place and nothing shows.

## t3: before (main 54c7633ad) and after (this branch)

`t3-integrated-{dark,light,lightterm}.png` and `t3-win10-row-{dark,light,lightterm}.png`
(the Windows 10 tab row, forced with a measurement-only `App.os_build = 19045`): one tab and
three tabs each. `light` is the light window theme with the default dark terminal;
`lightterm` adds `background = #ffffff`. `accent-counts.txt` counts pixels of the accent
colours found in the before captures (`#5E6CA1`, `#6872A3` and the separate row's strip
`#7A84B5`; this machine's followed Windows accent) in the band above the terminal.

`harness/` holds the driver (`tabline-run.ps1` + `Native.cs`) and the analysis scripts.
