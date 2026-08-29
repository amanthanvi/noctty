//! UIA event raisers.
//!
//! Every widget provider routes through here so the
//! `UiaClientsAreListening` short-circuit and the failed-event
//! logging policy stay in one place. Raising events directly via
//! `uiautomationcore` from widget code is a bug.

const std = @import("std");
const com = @import("com.zig");
const constants = @import("constants.zig");

pub fn clientsAreListening() bool {
    return com.UiaClientsAreListening() != 0;
}

pub fn raiseFocusChanged(provider: *com.IRawElementProviderSimple) void {
    if (!clientsAreListening()) return;
    const hr = com.UiaRaiseAutomationEvent(
        provider,
        constants.UIA_AutomationFocusChangedEventId,
    );
    logIfFailed("UIA_AutomationFocusChangedEventId", hr);
}

pub fn raiseSelectionInvalidated(provider: *com.IRawElementProviderSimple) void {
    if (!clientsAreListening()) return;
    const hr = com.UiaRaiseAutomationEvent(
        provider,
        constants.UIA_Selection_InvalidatedEventId,
    );
    logIfFailed("UIA_Selection_InvalidatedEventId", hr);
}

pub fn raiseSelectionItemSelected(provider: *com.IRawElementProviderSimple) void {
    if (!clientsAreListening()) return;
    const hr = com.UiaRaiseAutomationEvent(
        provider,
        constants.UIA_SelectionItem_ElementSelectedEventId,
    );
    logIfFailed("UIA_SelectionItem_ElementSelectedEventId", hr);
}

/// Notify text clients that a document's content changed. Callers must
/// coalesce byte-level terminal updates before raising this event.
pub fn raiseTextChanged(provider: *com.IRawElementProviderSimple) void {
    if (!clientsAreListening()) return;
    const hr = com.UiaRaiseAutomationEvent(
        provider,
        constants.UIA_Text_TextChangedEventId,
    );
    logIfFailed("UIA_Text_TextChangedEventId", hr);
}

/// Notify text clients that the terminal insertion caret moved. Callers must
/// coalesce cursor motion with the same snapshot cadence as text changes.
pub fn raiseTextSelectionChanged(provider: *com.IRawElementProviderSimple) void {
    if (!clientsAreListening()) return;
    const hr = com.UiaRaiseAutomationEvent(
        provider,
        constants.UIA_Text_TextSelectionChangedEventId,
    );
    logIfFailed("UIA_Text_TextSelectionChangedEventId", hr);
}

pub fn raiseLiveRegionChanged(provider: *com.IRawElementProviderSimple) void {
    if (!clientsAreListening()) return;
    const hr = com.UiaRaiseAutomationEvent(
        provider,
        constants.UIA_LiveRegionChangedEventId,
    );
    logIfFailed("UIA_LiveRegionChangedEventId", hr);
}

pub const Notification = enum {
    other,
    action_completed,
    action_aborted,

    fn toInt(self: Notification) i32 {
        return switch (self) {
            .other => com.NotificationKind_Other,
            .action_completed => com.NotificationKind_ActionCompleted,
            .action_aborted => com.NotificationKind_ActionAborted,
        };
    }
};

/// Announce sparse palette states/outcomes. Selection movement uses only
/// SelectionItem events; MostRecent prevents rapid failures from queueing.
pub fn raiseNotification(
    provider: *com.IRawElementProviderSimple,
    kind: Notification,
    message: []const u8,
) void {
    if (!clientsAreListening() or message.len == 0) return;
    const message_bstr = allocNotificationBstr(std.heap.page_allocator, message) catch return;
    defer com.SysFreeString(message_bstr);
    const activity_id = com.SysAllocString(
        std.unicode.utf8ToUtf16LeStringLiteral("noctty.command-palette"),
    ) orelse return;
    defer com.SysFreeString(activity_id);
    const hr = com.UiaRaiseNotificationEvent(
        provider,
        kind.toInt(),
        com.NotificationProcessing_MostRecent,
        message_bstr,
        activity_id,
    );
    logIfFailed("UiaRaiseNotificationEvent", hr);
}

/// Announce only newly appended, already-sanitized terminal output. TextChanged
/// remains the semantic document-change signal; this notification is the
/// Windows Terminal-compatible speech path for screen readers.
pub fn raiseTerminalOutputNotification(
    provider: *com.IRawElementProviderSimple,
    message: []const u8,
) void {
    if (!clientsAreListening() or message.len == 0) return;
    const message_bstr = allocNotificationBstr(std.heap.page_allocator, message) catch return;
    defer com.SysFreeString(message_bstr);
    const activity_id = com.SysAllocString(
        std.unicode.utf8ToUtf16LeStringLiteral("TerminalTextOutput"),
    ) orelse return;
    defer com.SysFreeString(activity_id);
    const hr = com.UiaRaiseNotificationEvent(
        provider,
        com.NotificationKind_ActionCompleted,
        com.NotificationProcessing_All,
        message_bstr,
        activity_id,
    );
    logIfFailed("UiaRaiseNotificationEvent(TerminalTextOutput)", hr);
}

fn allocNotificationBstr(
    allocator: std.mem.Allocator,
    message: []const u8,
) ![*:0]u16 {
    const message_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, message);
    defer allocator.free(message_w);
    const len = std.math.cast(u32, message_w.len) orelse return error.OutOfMemory;
    return com.SysAllocStringLen(message_w.ptr, len) orelse error.OutOfMemory;
}

pub fn raiseNameChanged(provider: *com.IRawElementProviderSimple) void {
    raiseCurrentStringPropertyChanged(provider, constants.UIA_NamePropertyId);
}

/// Query and publish the current BSTR for a string-valued property. UIA
/// property-change handlers receive `newValue` directly; VT_EMPTY is not a
/// request to re-query. The old value may be unavailable, so it remains empty.
pub fn raiseCurrentStringPropertyChanged(
    provider: *com.IRawElementProviderSimple,
    property_id: i32,
) void {
    if (!clientsAreListening()) return;

    var new_value = com.VARIANT.empty();
    const query_hr = provider.vtbl.GetPropertyValue(provider, property_id, &new_value);
    if (query_hr != com.S_OK) {
        logIfFailed("UIA property value query", query_hr);
        return;
    }
    defer logIfFailed("VariantClear(event property value)", com.VariantClear(&new_value));
    if (new_value.vt != com.VT_BSTR or new_value.value.bstr == null) {
        std.log.warn("uia: string property event has invalid new value property_id={d} vt={d}", .{
            property_id,
            new_value.vt,
        });
        return;
    }

    raisePropertyChanged(
        provider,
        property_id,
        com.VARIANT.empty(),
        new_value,
    );
}

pub const StructureChange = enum {
    child_added,
    child_removed,
    children_invalidated,
    children_bulk_added,
    children_bulk_removed,
    children_reordered,

    fn toInt(self: StructureChange) i32 {
        return switch (self) {
            .child_added => com.StructureChangeType_ChildAdded,
            .child_removed => com.StructureChangeType_ChildRemoved,
            .children_invalidated => com.StructureChangeType_ChildrenInvalidated,
            .children_bulk_added => com.StructureChangeType_ChildrenBulkAdded,
            .children_bulk_removed => com.StructureChangeType_ChildrenBulkRemoved,
            .children_reordered => com.StructureChangeType_ChildrenReordered,
        };
    }
};

/// Pass `runtime_id = null` for the bulk / invalidated forms. Empty
/// slices are also coerced to null so callers can't accidentally raise
/// a miscoped event with a zero-length runtime id.
pub fn raiseStructureChanged(
    provider: *com.IRawElementProviderSimple,
    change: StructureChange,
    runtime_id: ?[]i32,
) void {
    if (!clientsAreListening()) return;
    const effective: ?[]i32 = if (runtime_id) |slice|
        (if (slice.len == 0) null else slice)
    else
        null;
    const rid_ptr: ?[*]i32 = if (effective) |slice| slice.ptr else null;
    const rid_len: i32 = if (effective) |slice| @intCast(slice.len) else 0;
    const hr = com.UiaRaiseStructureChangedEvent(
        provider,
        change.toInt(),
        rid_ptr,
        rid_len,
    );
    logIfFailed("UIA_StructureChangedEventId", hr);
}

/// VARIANTs are shallow; caller owns any BSTR storage.
pub fn raisePropertyChanged(
    provider: *com.IRawElementProviderSimple,
    property_id: i32,
    old_value: com.VARIANT,
    new_value: com.VARIANT,
) void {
    if (!clientsAreListening()) return;
    const hr = com.UiaRaiseAutomationPropertyChangedEvent(
        provider,
        property_id,
        old_value,
        new_value,
    );
    logIfFailed("UIA_AutomationPropertyChangedEvent", hr);
}

fn logIfFailed(tag: []const u8, hr: com.HRESULT) void {
    if (hr != com.S_OK) {
        std.log.warn("uia: {s} raise failed hr=0x{x:0>8}", .{
            tag,
            @as(u32, @bitCast(hr)),
        });
    }
}

test "StructureChange maps to the right SDK integer" {
    try std.testing.expectEqual(
        @as(i32, com.StructureChangeType_ChildAdded),
        StructureChange.child_added.toInt(),
    );
    try std.testing.expectEqual(
        @as(i32, com.StructureChangeType_ChildRemoved),
        StructureChange.child_removed.toInt(),
    );
    try std.testing.expectEqual(
        @as(i32, com.StructureChangeType_ChildrenInvalidated),
        StructureChange.children_invalidated.toInt(),
    );
    try std.testing.expectEqual(
        @as(i32, com.StructureChangeType_ChildrenBulkAdded),
        StructureChange.children_bulk_added.toInt(),
    );
    try std.testing.expectEqual(
        @as(i32, com.StructureChangeType_ChildrenBulkRemoved),
        StructureChange.children_bulk_removed.toInt(),
    );
    try std.testing.expectEqual(
        @as(i32, com.StructureChangeType_ChildrenReordered),
        StructureChange.children_reordered.toInt(),
    );
}

test "Notification maps sparse palette outcomes to SDK values" {
    try std.testing.expectEqual(@as(i32, com.NotificationKind_Other), Notification.other.toInt());
    try std.testing.expectEqual(@as(i32, com.NotificationKind_ActionCompleted), Notification.action_completed.toInt());
    try std.testing.expectEqual(@as(i32, com.NotificationKind_ActionAborted), Notification.action_aborted.toInt());
}

test "notification message conversion preserves long messages" {
    const message = "a" ** 300;
    const message_w = try allocNotificationBstr(std.testing.allocator, message);
    defer com.SysFreeString(message_w);

    try std.testing.expectEqual(@as(u32, 300), com.SysStringLen(message_w));
    for (message_w[0..300]) |unit| try std.testing.expectEqual(@as(u16, 'a'), unit);
    try std.testing.expectEqual(@as(u16, 0), message_w[300]);
}

test "notification message conversion preserves supplementary scalars" {
    const message_w = try allocNotificationBstr(std.testing.allocator, "status: 🚀");
    defer com.SysFreeString(message_w);
    const expected = std.unicode.utf8ToUtf16LeStringLiteral("status: 🚀");

    try std.testing.expectEqual(@as(u32, @intCast(expected.len)), com.SysStringLen(message_w));
    try std.testing.expectEqualSlices(u16, expected, message_w[0..expected.len]);
}

test "notification message conversion rejects invalid UTF-8" {
    try std.testing.expectError(
        error.InvalidUtf8,
        allocNotificationBstr(std.testing.allocator, "valid\xFFinvalid"),
    );
}
