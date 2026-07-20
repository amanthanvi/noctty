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
    var message_w: [256]u16 = undefined;
    const written = std.unicode.utf8ToUtf16Le(message_w[0 .. message_w.len - 1], message) catch return;
    message_w[written] = 0;
    const activity_id = std.unicode.utf8ToUtf16LeStringLiteral("winghostty.command-palette");
    const hr = com.UiaRaiseNotificationEvent(
        provider,
        kind.toInt(),
        com.NotificationProcessing_MostRecent,
        @ptrCast(&message_w),
        activity_id,
    );
    logIfFailed("UiaRaiseNotificationEvent", hr);
}

/// Notify clients that a widget's live accessible name changed. Empty
/// VARIANTs intentionally ask clients to re-query the provider; this avoids
/// allocating duplicate BSTRs solely for an event whose value is already
/// available through `GetPropertyValue`.
pub fn raiseNameChanged(provider: *com.IRawElementProviderSimple) void {
    raisePropertyChanged(
        provider,
        constants.UIA_NamePropertyId,
        com.VARIANT.empty(),
        com.VARIANT.empty(),
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
