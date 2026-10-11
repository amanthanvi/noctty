param([switch]$Stream, [int]$IntervalMs=10)
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$e=[char]27
[Console]::Write("$e[2J$e[H$e[?12l")
$lines=@(
 'D3D11 beta parity: same VT, shaping, rasterization and atlas',
 "$e[31mRED $e[32mGREEN $e[34mBLUE $e[33mYELLOW $e[35mMAGENTA $e[36mCYAN$e[0m",
 "$e[41;37m red background $e[42;30m green background $e[44;97m blue background $e[0m",
 '┌──────────────┬──────────────┐',
 '│ Box drawing  │ ╔══════╗     │',
 '└──────────────┴─╚══════╝─────┘',
 'CJK: 日本語 中文 한글 全角１２３',
 'Emoji: 😀 🚀 🌈 ❤️ 🍕 🐱',
 "$e[1mBold$e[22m normal $e[3mItalic$e[23m $e[4mUnderline$e[24m",
 "$e[38;2;30;50;70mLow contrast correction test$e[0m",
 'ASCII: ABCDEFGHIJKLMNOPQRSTUVWXYZ abcdefghijklmnopqrstuvwxyz 0123456789',
 'Cursor below: block, steady, left edge.'
)
foreach($line in $lines) { [Console]::Write($line+"`r`n") }
# The existing parsed-grid benchmark hook observes the beginning of the top row.
# Write its token only after the complete fixture, then restore the steady cursor.
[Console]::Write("$e[1;1HRENDERER_FIXTURE_READY: D3D11 beta parity, shared terminal core$e[K$e[14;1H")
if ($env:NOCTTY_RENDERER_TEST_KITTY -eq '1') { [Console]::Write("$e`_Ga=T,f=24,s=1,v=1,c=1,r=1,i=1; /wAA$e\".Replace('; ', ';')) }; if ($env:NOCTTY_RENDERER_READY_PATH) { [IO.File]::WriteAllText($env:NOCTTY_RENDERER_READY_PATH,'fixture-written') }; if ($Stream) {
 Start-Sleep -Seconds 2
 $clock=[Diagnostics.Stopwatch]::StartNew()
 $frame=0
 while($clock.Elapsed.TotalSeconds -lt 45) {
  [Console]::Write("$e[?2026h$e[14;1H$e[38;2;100;200;250mSTREAM frame=$frame$e[0m " + ('abcdef 日本語 😀 '*5) + "$e[K$e[15;1H" + ('─'*70) + "$e[?2026l")
  $frame++
  if ($env:NOCTTY_RENDERER_TEST_IMAGE_CHURN -eq '1' -and $frame % 5 -eq 0) {
   $imageId = 1000 + [int]($frame / 5)
   # Distinct visible IDs exercise renderer-owned copies before each deletion.
   if ($imageId -gt 1001) { [Console]::Write("$e`_Ga=d,d=I,i=$($imageId-1),q=2$e\") }
   [Console]::Write("$e`_Ga=T,f=24,s=1,v=1,c=1,r=1,i=$imageId,q=2;/wAA$e\")
  }
  if($frame % 30 -eq 0 -and $env:NOCTTY_RENDERER_STREAM_PROGRESS_FILE){
   $checkpoint=$frame.ToString()+','+$clock.ElapsedMilliseconds.ToString()+','+[Environment]::TickCount64.ToString()
   try {
    [IO.File]::WriteAllText($env:NOCTTY_RENDERER_STREAM_PROGRESS_FILE+'.tmp', $checkpoint)
    [IO.File]::Move($env:NOCTTY_RENDERER_STREAM_PROGRESS_FILE+'.tmp', $env:NOCTTY_RENDERER_STREAM_PROGRESS_FILE, $true)
   } catch [IO.IOException] { } # Retry at the next checkpoint if a reader holds the file.
  }
  Start-Sleep -Milliseconds $IntervalMs
 }
}
Start-Sleep -Seconds 90
