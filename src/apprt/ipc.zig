//! Inter-process Communication to a running Ghostty instance from a separate
//! process.
const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = @import("../quirks.zig").inlineAssert;
const lib = @import("../lib/main.zig");

pub const Errors = error{
    /// The IPC failed. If a function returns this error, it's expected that
    /// an a more specific error message will have been written to stderr (or
    /// otherwise shown to the user in an appropriate way).
    IPCFailed,
};

pub const Target = union(Key) {
    /// Open up a new window in a custom instance of Ghostty.
    class: [:0]const u8,

    /// Detect which instance to open a new window in.
    detect,

    // Sync with: ghostty_ipc_target_tag_e
    pub const Key = enum(c_int) {
        class,
        detect,

        test "ghostty.h Target.Key" {
            try lib.checkGhosttyHEnum(Key, "GHOSTTY_IPC_TARGET_");
        }
    };

    // Sync with: ghostty_ipc_target_u
    pub const CValue = extern union {
        class: [*:0]const u8,
        detect: void,
    };

    // Sync with: ghostty_ipc_target_s
    pub const C = extern struct {
        key: Key,
        value: CValue,
    };

    /// Convert to ghostty_ipc_target_s.
    pub fn cval(self: Target) C {
        return .{
            .key = @as(Key, self),
            .value = switch (self) {
                .class => |class| .{ .class = class.ptr },
                .detect => .{ .detect = {} },
            },
        };
    }
};

pub const automation_window_list_schema = "noctty.windows.v3";
pub const automation_window_list_api_version: u32 = 3;

comptime {
    const version_suffix = std.fmt.comptimePrint(".v{d}", .{automation_window_list_api_version});
    if (!std.mem.endsWith(u8, automation_window_list_schema, version_suffix)) {
        @compileError("automation window-list schema suffix must match api version");
    }
}

pub const AutomationWindowList = struct {
    schema: []const u8 = automation_window_list_schema,
    api_version: u32 = automation_window_list_api_version,
    instance: AutomationInstance,
    windows: []AutomationWindow,

    pub fn deinit(self: *AutomationWindowList, alloc: Allocator) void {
        self.instance.deinit(alloc);
        for (self.windows) |*window| window.deinit(alloc);
        alloc.free(self.windows);
        self.* = undefined;
    }
};

pub const AutomationInstance = struct {
    pid: u32,
    version: []const u8,
    class: []const u8,

    pub fn deinit(self: *AutomationInstance, alloc: Allocator) void {
        alloc.free(self.version);
        alloc.free(self.class);
        self.* = undefined;
    }
};

pub const AutomationWindow = struct {
    window_id: u32,
    title: []const u8,
    focused: bool,
    active_tab_id: ?u32,
    tab_count: u64,
    pane_count: u64,
    tabs: []AutomationTab,

    pub fn deinit(self: *AutomationWindow, alloc: Allocator) void {
        alloc.free(self.title);
        for (self.tabs) |*tab| tab.deinit(alloc);
        alloc.free(self.tabs);
        self.* = undefined;
    }
};

pub const AutomationTab = struct {
    tab_id: u32,
    active: bool,
    focused_surface_id: ?u64,
    pane_count: u64,
    panes: []AutomationPane,

    pub fn deinit(self: *AutomationTab, alloc: Allocator) void {
        for (self.panes) |*pane| pane.deinit(alloc);
        alloc.free(self.panes);
        self.* = undefined;
    }
};

pub const AutomationPane = struct {
    surface_id: u64,
    title: ?[]const u8,
    working_directory: ?[]const u8,
    focused: bool,
    active: bool,

    pub fn deinit(self: *AutomationPane, alloc: Allocator) void {
        if (self.title) |title| alloc.free(title);
        if (self.working_directory) |working_directory| alloc.free(working_directory);
        self.* = undefined;
    }
};

pub const AutomationActionTarget = union(enum) {
    focused,
    surface_id: u64,
};

pub const Action = union(enum) {
    // A GUIDE TO ADDING NEW ACTIONS:
    //
    // 1. Add the action to the `Key` enum. Preserve enum ordering so the
    //    retained compatibility checks keep passing for the Windows-only fork.
    //
    // 2. Add the action and optional value to the Action union.
    //
    // 3. If the value type is not void, ensure the value is C ABI
    //    compatible (extern). If it is not, add a `C` decl to the value
    //    and a `cval` function to convert to the C ABI compatible value.
    //
    // 4. If a compatibility surface still mirrors this action, update it
    //    alongside the Zig definition and keep the ordering aligned.

    /// The arguments to pass to Ghostty as the command.
    new_window: NewWindow,

    pub const NewWindow = struct {
        /// A list of command arguments to launch in the new window. If this is
        /// `null` the command configured in the config or the user's default
        /// shell should be launched.
        ///
        /// It is an error for this to be non-`null`, but zero length.
        arguments: ?[][:0]const u8,

        pub const C = extern struct {
            /// null terminated list of arguments
            /// it will be null itself if there are no arguments
            arguments: ?[*]?[*:0]const u8,

            pub fn deinit(self: *NewWindow.C, alloc: Allocator) void {
                if (self.arguments) |arguments| alloc.free(arguments);
            }
        };

        pub fn cval(self: *NewWindow, alloc: Allocator) Allocator.Error!NewWindow.C {
            var result: NewWindow.C = undefined;

            if (self.arguments) |arguments| {
                result.arguments = try alloc.alloc([*:0]const u8, arguments.len + 1);

                for (arguments, 0..) |argument, i|
                    result.arguments[i] = argument.ptr;

                // add null terminator
                result.arguments[arguments.len] = null;
            } else {
                result.arguments = null;
            }

            return result;
        }
    };

    /// Sync with: ghostty_ipc_action_tag_e
    pub const Key = enum(c_int) {
        new_window,

        test "ghostty.h Action.Key" {
            try lib.checkGhosttyHEnum(Key, "GHOSTTY_IPC_ACTION_");
        }
    };

    /// Sync with: ghostty_ipc_action_u
    pub const CValue = cvalue: {
        const key_fields = @typeInfo(Key).@"enum".fields;
        var union_fields: [key_fields.len]std.builtin.Type.UnionField = undefined;
        for (key_fields, 0..) |field, i| {
            const action = @unionInit(Action, field.name, undefined);
            const Type = t: {
                const Type = @TypeOf(@field(action, field.name));
                // Types can provide custom types for their CValue.
                if (Type != void and @hasDecl(Type, "C")) break :t Type.C;
                break :t Type;
            };

            union_fields[i] = .{
                .name = field.name,
                .type = Type,
                .alignment = @alignOf(Type),
            };
        }

        break :cvalue @Type(.{ .@"union" = .{
            .layout = .@"extern",
            .tag_type = null,
            .fields = &union_fields,
            .decls = &.{},
        } });
    };

    /// Sync with: ghostty_ipc_action_s
    pub const C = extern struct {
        key: Key,
        value: CValue,
    };

    comptime {
        // For ABI compatibility, we expect that this is our union size.
        // At the time of writing, we don't promise ABI compatibility
        // so we can change this but I want to be aware of it.
        assert(@sizeOf(CValue) == switch (@sizeOf(usize)) {
            4 => 4,
            8 => 8,
            else => unreachable,
        });
    }

    /// Returns the value type for the given key.
    pub fn Value(comptime key: Key) type {
        inline for (@typeInfo(Action).@"union".fields) |field| {
            const field_key = @field(Key, field.name);
            if (field_key == key) return field.type;
        }

        unreachable;
    }

    /// Convert to ghostty_ipc_action_s.
    pub fn cval(self: Action, alloc: Allocator) C {
        const value: CValue = switch (self) {
            inline else => |v, tag| @unionInit(
                CValue,
                @tagName(tag),
                if (@TypeOf(v) != void and @hasDecl(@TypeOf(v), "cval")) v.cval(alloc) else v,
            ),
        };

        return .{
            .key = @as(Key, self),
            .value = value,
        };
    }
};
