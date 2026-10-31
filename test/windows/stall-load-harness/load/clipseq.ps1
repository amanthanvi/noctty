Add-Type -Namespace W14 -Name Clip -MemberDefinition '[DllImport("user32.dll")] public static extern uint GetClipboardSequenceNumber();'
"{0:o} clipboard_seq={1}" -f (Get-Date), [W14.Clip]::GetClipboardSequenceNumber()
