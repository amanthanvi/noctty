# The harnesses' real-input and foreground calls: SendInput, keybd_event,
# SetForegroundWindow, BringWindowToTop and ForceForeground, moved verbatim from
# InteractiveWin11WindowNative (scripts/interactive-win11-window-lib.ps1), which
# loads this file only outside hosted mode. A hosted (private-desktop) run has no
# foreground and must not inject input (AGENTS.md "Running noctty"), so this file
# refuses to load there. It defines no PowerShell function. Callers name
# [InteractiveWin11RealInput] directly.
if ($env:NOCTTY_GUI_HIDDEN_DESKTOP) { throw 'interactive-win11-realinput.ps1 must not load in a hosted (private-desktop) run: it holds the real-input and foreground calls.' }

if (-not ('InteractiveWin11RealInput' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Threading;

public static class InteractiveWin11RealInput {
    private static int lastSendInputRequested;
    private static int lastSendInputReturned;

    public static int LastSendInputRequested {
        get { return Volatile.Read(ref lastSendInputRequested); }
    }

    public static int LastSendInputReturned {
        get { return Volatile.Read(ref lastSendInputReturned); }
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct MOUSEINPUT {
        public int dx;
        public int dy;
        public uint mouseData;
        public uint dwFlags;
        public uint time;
        public UIntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct KEYBDINPUT {
        public ushort wVk;
        public ushort wScan;
        public uint dwFlags;
        public uint time;
        public UIntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct HARDWAREINPUT {
        public uint uMsg;
        public ushort wParamL;
        public ushort wParamH;
    }

    [StructLayout(LayoutKind.Explicit)]
    public struct INPUTUNION {
        [FieldOffset(0)]
        public MOUSEINPUT mi;

        [FieldOffset(0)]
        public KEYBDINPUT ki;

        [FieldOffset(0)]
        public HARDWAREINPUT hi;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct INPUT {
        public uint type;
        public INPUTUNION value;

        public INPUTUNION U {
            get { return value; }
            set { this.value = value; }
        }
    }

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool BringWindowToTop(IntPtr hWnd);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern uint SendInput(uint cInputs, INPUT[] pInputs, int cbSize);

    [DllImport("user32.dll")]
    public static extern void keybd_event(
        byte bVk,
        byte bScan,
        uint dwFlags,
        UIntPtr dwExtraInfo
    );

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);

    [DllImport("kernel32.dll")]
    private static extern uint GetCurrentThreadId();

    private const uint INPUT_KEYBOARD = 1;
    private const uint KEYEVENTF_KEYUP = 0x0002;

    private static INPUT Key(ushort virtualKey, uint flags) {
        INPUT input = new INPUT();
        input.type = INPUT_KEYBOARD;
        input.value.ki.wVk = virtualKey;
        input.value.ki.dwFlags = flags;
        return input;
    }

    public static bool SubmitInputs(INPUT[] inputs) {
        int requested = inputs.Length;
        int returned = unchecked((int)SendInput(
            (uint)requested,
            inputs,
            Marshal.SizeOf(typeof(INPUT))
        ));
        Volatile.Write(ref lastSendInputRequested, requested);
        Volatile.Write(ref lastSendInputReturned, returned);
        return returned == requested;
    }

    public static bool ForceForeground(
        IntPtr hWnd,
        bool altTap,
        bool useSendInputForAltTap
    ) {
        if (altTap) {
            if (useSendInputForAltTap) {
                SubmitInputs(new INPUT[] {
                    Key(0x12, 0),
                    Key(0x12, KEYEVENTF_KEYUP)
                });
            }
            else {
                keybd_event(0x12, 0, 0, UIntPtr.Zero);
                keybd_event(0x12, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);
            }
        }

        uint ignored;
        uint targetThread = GetWindowThreadProcessId(hWnd, out ignored);
        IntPtr foreground = GetForegroundWindow();
        uint foregroundThread = foreground == IntPtr.Zero
            ? 0
            : GetWindowThreadProcessId(foreground, out ignored);
        uint currentThread = GetCurrentThreadId();
        bool attachedForeground = foregroundThread != 0 &&
            foregroundThread != currentThread &&
            AttachThreadInput(currentThread, foregroundThread, true);
        bool attachedTarget = targetThread != 0 &&
            targetThread != currentThread &&
            AttachThreadInput(currentThread, targetThread, true);
        try {
            BringWindowToTop(hWnd);
            SetForegroundWindow(hWnd);
            return GetForegroundWindow() == hWnd;
        }
        finally {
            if (attachedTarget) {
                AttachThreadInput(currentThread, targetThread, false);
            }
            if (attachedForeground) {
                AttachThreadInput(currentThread, foregroundThread, false);
            }
        }
    }
}
'@
}
