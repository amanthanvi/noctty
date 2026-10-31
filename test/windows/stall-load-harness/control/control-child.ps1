# MEASUREMENT ONLY (pacing-stall2 positive control): a WinForms window on the
# private desktop it was started on. Pumps until -Ready exists (the watchdog has
# seen 10 replies), pumps 1 s more, then its UI thread sleeps -SleepMs without
# pumping, then pumps 2 s, closes and exits. No clipboard, no input.
param([Parameter(Mandatory)][string]$Ready, [Parameter(Mandatory)][string]$Out, [int]$SleepMs = 3000)
Add-Type -AssemblyName System.Windows.Forms
function Say($m) { Add-Content -LiteralPath $Out -Value ("{0:HH:mm:ss.fff} qpc={1} {2}" -f (Get-Date), [Diagnostics.Stopwatch]::GetTimestamp(), $m) }
$f = New-Object System.Windows.Forms.Form
$f.Width = 220; $f.Height = 120; $f.Text = 'w14 stall2 control'; $f.ShowInTaskbar = $false; $f.StartPosition = 'Manual'; $f.Left = 50; $f.Top = 50
$f.Show(); Say ("shown pid={0} tid={1}" -f $PID, [AppDomain]::GetCurrentThreadId())
$deadline = (Get-Date).AddSeconds(60)
while (-not (Test-Path -LiteralPath $Ready) -and (Get-Date) -lt $deadline) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 20 }
Say ("ready file seen={0}" -f (Test-Path -LiteralPath $Ready))
for ($i = 0; $i -lt 50; $i++) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 20 }
Say ("blocking UI thread {0} ms (Thread.Sleep)" -f $SleepMs)
[System.Threading.Thread]::Sleep($SleepMs)
Say 'pumping again'
for ($i = 0; $i -lt 100; $i++) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 20 }
$f.Close(); $f.Dispose(); Say 'closed'
