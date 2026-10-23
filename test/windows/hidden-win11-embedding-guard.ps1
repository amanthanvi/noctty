# The one copy of the -Embedding delegation guard. Both hidden-desktop libraries
# dot-source it (hidden-win11-lib.ps1 for the hosted-runner harnesses,
# hidden-win11-local-lib.ps1 for the developer-machine ones), and every harness
# that starts `noctty.exe -Embedding` calls it before it starts anything and
# again right before that launch. Contracts.96 pins the function and its calls.
#
# The measurement AUMID does not isolate Server.register's real COM CLSID: an
# -Embedding copy publishes the real handoff class object in the session's live
# class table, which a private desktop does not isolate either. An idle server
# could then receive the user's live console handoff while noctty is their
# delegated terminal. Read only that one selection and fail closed on an
# unreadable key; there is no bypass.
function Assert-EmbeddingDelegationSafe {
    try { $selection = Get-ItemProperty -LiteralPath 'HKCU:\Console\%%Startup' -ErrorAction Stop }
    catch [Management.Automation.ItemNotFoundException] { return }
    $terminal = [guid]::Empty
    if ([guid]::TryParse([string]$selection.DelegationTerminal, [ref]$terminal) -and
        $terminal -eq [guid]'33368C6F-D328-410C-B225-26DC9F12C728') {
        throw 'Embedding launch blocked: noctty is the selected delegated terminal. The measurement AUMID does not isolate the real COM handoff CLSID; use a sandbox with independent console delegation.'
    }
}
