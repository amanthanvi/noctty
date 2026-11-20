"""Require an allowlisted Zig invocation before building oracle artifacts."""

import ctypes as ct
import os
import re
import sys
from ctypes import wintypes as win

BUILD_OPTIONS = frozenset(
    {
        "-Dvt-api",
        "-Doracle-corpus",
        "-Doracle-scrollback",
        "-Dsimd",
        "-Doptimize",
        "-Dcpu",
        "-Dcustom-shaders",
    }
)
VALUE_OPTIONS = frozenset({"-p", "--prefix", "--summary"})
ALLOWED_ZIG_ENVIRONMENT = frozenset(
    {"ZIG_GLOBAL_CACHE_DIR", "ZIG_HOME", "ZIG_LOCAL_CACHE_DIR", "ZIG_VERSION"}
)
UNSAFE_ENVIRONMENT = frozenset(
    {
        "CPATH",
        "C_INCLUDE_PATH",
        "CPLUS_INCLUDE_PATH",
        "OBJC_INCLUDE_PATH",
        "LIBRARY_PATH",
        "LINK",
        "_LINK_",
    }
)


def check_environment():
    for name in sorted(os.environ):
        namespace = name.partition("_")[0] + "_"
        if (
            name in UNSAFE_ENVIRONMENT
            or name.startswith("CCC_")
            or (name.startswith("ZIG_") and name not in ALLOWED_ZIG_ENVIRONMENT)
        ):
            if re.fullmatch(r"[A-Z0-9_]{1,64}", name) is None:
                name = namespace + "*"
            raise ValueError(f"disallowed environment variable: {name}")


def check_arguments(args):
    if len(args) < 3 or args[1] != "build":
        raise ValueError("cannot establish the original Zig build invocation")
    rest = iter(args[2:])
    selected = False
    for arg in rest:
        if arg == "oracle" and not selected:
            selected = True
            continue
        name, equals, value = arg.partition("=")
        if name in BUILD_OPTIONS and equals and value:
            continue
        # The installed Zig shim can supply a job limit before launching Zig.
        if re.fullmatch(r"-j[1-9][0-9]*", arg):
            continue
        if (
            arg in VALUE_OPTIONS
            and (value := next(rest, ""))
            and not value.startswith("-")
        ):
            continue
        # Diagnose option names without disclosing paths or argument values.
        if re.fullmatch(r"-{1,2}[A-Za-z0-9][A-Za-z0-9-]{0,63}", name):
            raise ValueError(f"disallowed or malformed option: {name}")
        raise ValueError(
            "only the oracle build step and its allowlisted options are permitted"
        )
    if not selected:
        raise ValueError("the original Zig invocation did not select oracle")


def parent_build_arguments(zig_exe):
    """Read original driver argv, including options consumed by Zig's Maker."""
    kernel = ct.WinDLL("kernel32", use_last_error=True)
    ntdll = ct.WinDLL("ntdll")
    shell = ct.WinDLL("shell32", use_last_error=True)

    def bind(lib, name, result, *types):
        fn = getattr(lib, name)
        fn.restype = result
        fn.argtypes = types
        return fn

    open_process = bind(
        kernel, "OpenProcess", win.HANDLE, win.DWORD, win.BOOL, win.DWORD
    )
    close = bind(kernel, "CloseHandle", win.BOOL, win.HANDLE)
    image_name = bind(
        kernel,
        "QueryFullProcessImageNameW",
        win.BOOL,
        win.HANDLE,
        win.DWORD,
        win.LPWSTR,
        ct.POINTER(win.DWORD),
    )
    filetime = ct.POINTER(win.FILETIME)
    times = bind(kernel, "GetProcessTimes", win.BOOL, win.HANDLE, *([filetime] * 4))
    query = bind(
        ntdll,
        "NtQueryInformationProcess",
        win.LONG,
        win.HANDLE,
        win.ULONG,
        win.LPVOID,
        win.ULONG,
        ct.POINTER(win.ULONG),
    )
    split = bind(
        shell,
        "CommandLineToArgvW",
        ct.POINTER(win.LPWSTR),
        win.LPCWSTR,
        ct.POINTER(ct.c_int),
    )
    free = bind(kernel, "LocalFree", win.HLOCAL, win.HLOCAL)

    class BasicInfo(ct.Structure):
        _fields_ = [
            ("exit_status", win.LONG),
            ("peb", ct.c_void_p),
            ("affinity", ct.c_size_t),
            ("priority", win.LONG),
            ("pid", ct.c_size_t),
            ("parent", ct.c_size_t),
        ]

    class UnicodeString(ct.Structure):
        _fields_ = [
            ("length", win.USHORT),
            ("capacity", win.USHORT),
            ("buffer", ct.c_void_p),
        ]

    def command_line(handle):
        needed = win.ULONG()
        # ProcessCommandLineInformation returns a UNICODE_STRING and its data.
        query(handle, 60, None, 0, ct.byref(needed))
        if not ct.sizeof(UnicodeString) <= needed.value <= 131072:
            raise OSError("cannot size the Zig driver command line")
        buffer = ct.create_string_buffer(needed.value)
        if query(handle, 60, buffer, len(buffer), None) != 0:
            raise OSError("cannot read the Zig driver command line")
        string = UnicodeString.from_buffer(buffer)
        start = ct.addressof(buffer)
        if (
            not string.buffer
            or string.length % 2
            or string.length > string.capacity
            or not start + ct.sizeof(string) <= string.buffer
            or string.buffer + string.length > start + len(buffer)
        ):
            raise OSError("invalid Zig driver command line")
        argc = ct.c_int()
        argv = split(ct.wstring_at(string.buffer, string.length // 2), ct.byref(argc))
        if not argv:
            raise OSError("cannot split the Zig driver command line")
        try:
            return [argv[i] for i in range(argc.value)]
        finally:
            free(argv)

    # 0.15 runs this step from its build runner. 0.17 runs it from Maker.
    # Follow only the immediate ancestry and bind the driver to Zig's image.
    pid = os.getpid()
    younger = None
    for _ in range(4):
        handle = open_process(0x1000, False, pid)  # PROCESS_QUERY_LIMITED_INFORMATION
        if not handle:
            break
        try:
            created, exited, kernel_time, user_time = (win.FILETIME() for _ in range(4))
            if not times(
                handle,
                ct.byref(created),
                ct.byref(exited),
                ct.byref(kernel_time),
                ct.byref(user_time),
            ):
                break
            stamp = (created.dwHighDateTime << 32) | created.dwLowDateTime
            if younger is not None and stamp > younger:
                break  # A parent PID was reused after the child started.
            younger = stamp
            path = ct.create_unicode_buffer(32768)
            length = win.DWORD(len(path))
            if not image_name(handle, 0, path, ct.byref(length)):
                break
            if os.path.samefile(path.value, zig_exe):
                return command_line(handle)
            info = BasicInfo()
            if (
                query(handle, 0, ct.byref(info), ct.sizeof(info), None) != 0
                or info.pid != pid
            ):
                break
            pid = info.parent
        finally:
            close(handle)
    raise OSError("cannot identify the original Zig build driver")


if __name__ == "__main__":
    try:
        if os.name != "nt":
            raise ValueError("the oracle build argument guard requires Windows")
        check_environment()
        check_arguments(parent_build_arguments(sys.argv[1]))
    except ValueError as exc:
        sys.exit(f"oracle build arguments: {exc}")
    except OSError:
        sys.exit(
            "oracle build arguments: unable to verify the original Zig build invocation"
        )
