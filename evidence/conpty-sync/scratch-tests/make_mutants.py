import sys

src = open(sys.argv[1], encoding='utf-8').read()
out = sys.argv[2]


def write(name, text):
    open(out + '/mutant-' + name + '.ps1', 'w', encoding='utf-8', newline='\n').write(text)


def swap(old, new):
    assert src.count(old) == 1, old
    return src.replace(old, new)


retry_old = "$proc.ExitCode -ne 7 -or $attempt -ge 4"
write('noretry', swap(retry_old, "$proc.ExitCode -ne 7 -or $attempt -ge 1"))
write('retry6', swap(retry_old, "$proc.ExitCode -notin 6, 7 -or $attempt -ge 4"))
write('norequireall', swap("    elseif ($RequireAll -and $r.Status -eq 'SKIP') {", "    elseif ($false -and $r.Status -eq 'SKIP') {"))

age_old = "if ($null -ne $childStart -and $null -ne $parentStart -and $childStart.ToUniversalTime() -lt $parentStart.ToUniversalTime()) { continue }\n                if (-not $seen.Add"
assert src.count(age_old) == 1
write('nodategate', src.replace(age_old, "if ($false) { continue }\n                if (-not $seen.Add"))
write('noseen', swap("if (-not $seen.Add([int]$child.ProcessId)) { continue }", ""))
# Unknown start times dropped instead of kept
needle = "if ($null -ne $childStart -and $null -ne $parentStart -and $childStart.ToUniversalTime()"
assert src.count(needle) == 2  # the diagnostics walk and Get-SyncDescendants (the later one)
head, sep, tail = src.rpartition(needle)
write('dropunknown', head + "if ($childStart -lt $parentStart -or $childStart.ToUniversalTime()" + tail)
print('ok')
