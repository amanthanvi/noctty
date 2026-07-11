//! Pure staged-settings transaction model.
//!
//! Callers provide a field enum, a value type (typically a tagged union), and
//! value equality. The model owns no config parser, allocator, HWND, or I/O.
//! Values are copied into caller-owned entry storage; if values contain slices,
//! their backing storage must outlive the transaction.

const std = @import("std");

pub fn Transaction(
    comptime Field: type,
    comptime Value: type,
    comptime valueEql: fn (Value, Value) bool,
) type {
    switch (@typeInfo(Field)) {
        .@"enum" => {},
        else => @compileError("settings transaction Field must be an enum"),
    }

    return struct {
        const Self = @This();

        pub const FieldValue = struct {
            field: Field,
            value: Value,
        };

        pub const Entry = struct {
            field: Field,
            baseline: Value,
            current: Value,
            draft: Value,
            previewed: bool = false,
            dirty: bool = false,
            conflict: bool = false,
        };

        pub const Resolution = enum {
            keep_mine,
            use_disk,
        };

        pub const ApplyId = u64;

        pub const Intent = union(enum) {
            edit: struct {
                field: Field,
                value: Value,
                live_preview: bool = false,
            },
            external_update: struct {
                revision: u64,
                changes: []const FieldValue,
            },
            resolve_conflict: struct {
                field: Field,
                resolution: Resolution,
            },
            revert,
            apply,
            apply_succeeded: struct {
                apply_id: ApplyId,
                revision: u64,
            },
            apply_failed: struct {
                apply_id: ApplyId,
            },
        };

        pub const Effect = union(enum) {
            /// Set the live application preview to this value. Revert uses the
            /// same idempotent effect with the latest disk value.
            set_preview: FieldValue,
            conflict_detected: Field,
            /// Begins one atomic persistence request. The following
            /// `persist_field` effects form the complete patch.
            apply_requested: struct {
                apply_id: ApplyId,
                expected_current_revision: u64,
                draft_revision: u64,
                field_count: usize,
            },
            persist_field: FieldValue,
        };

        pub const InitError = error{
            StorageTooSmall,
            DuplicateField,
        };

        pub const DispatchError = error{
            UnknownField,
            StaleExternalRevision,
            UnresolvedConflict,
            NoConflict,
            ApplyNotPending,
            ApplyAlreadyPending,
            ApplyIdMismatch,
            ApplyIdExhausted,
            StaleApplyRevision,
            EffectBufferTooSmall,
        };

        entries: []Entry,
        baseline_revision: u64,
        current_revision: u64,
        draft_revision: u64,
        next_apply_id: ApplyId = 1,
        pending_apply_id: ?ApplyId = null,

        pub fn init(
            storage: []Entry,
            initial: []const FieldValue,
            revision: u64,
        ) InitError!Self {
            if (storage.len < initial.len) return error.StorageTooSmall;

            for (initial, 0..) |item, i| {
                for (initial[0..i]) |previous| {
                    if (previous.field == item.field) return error.DuplicateField;
                }
                storage[i] = .{
                    .field = item.field,
                    .baseline = item.value,
                    .current = item.value,
                    .draft = item.value,
                };
            }

            return .{
                .entries = storage[0..initial.len],
                .baseline_revision = revision,
                .current_revision = revision,
                .draft_revision = revision,
            };
        }

        pub fn entry(self: *Self, field: Field) ?*Entry {
            for (self.entries) |*candidate| {
                if (candidate.field == field) return candidate;
            }
            return null;
        }

        pub fn entryConst(self: *const Self, field: Field) ?*const Entry {
            for (self.entries) |*candidate| {
                if (candidate.field == field) return candidate;
            }
            return null;
        }

        pub fn dirtyCount(self: *const Self) usize {
            var count: usize = 0;
            for (self.entries) |candidate| {
                count += @intFromBool(candidate.dirty);
            }
            return count;
        }

        pub fn conflictCount(self: *const Self) usize {
            var count: usize = 0;
            for (self.entries) |candidate| {
                count += @intFromBool(candidate.conflict);
            }
            return count;
        }

        pub fn dispatch(
            self: *Self,
            intent: Intent,
            effects: []Effect,
        ) DispatchError![]Effect {
            return switch (intent) {
                .edit => |change| try self.edit(change, effects),
                .external_update => |update| try self.externalUpdate(update, effects),
                .resolve_conflict => |resolve| try self.resolveConflict(resolve, effects),
                .revert => try self.revert(effects),
                .apply => try self.apply(effects),
                .apply_succeeded => |success| try self.applySucceeded(success),
                .apply_failed => |failure| try self.applyFailed(failure.apply_id),
            };
        }

        fn edit(
            self: *Self,
            change: @FieldType(Intent, "edit"),
            effects: []Effect,
        ) DispatchError![]Effect {
            if (self.pending_apply_id != null) return error.ApplyAlreadyPending;
            const target = self.entry(change.field) orelse return error.UnknownField;
            const needs_preview_effect = if (change.live_preview)
                !target.previewed or !valueEql(target.draft, change.value)
            else
                target.previewed;
            if (needs_preview_effect and effects.len < 1) return error.EffectBufferTooSmall;

            target.draft = change.value;
            target.dirty = !valueEql(target.draft, target.baseline);
            target.conflict = target.dirty and !valueEql(target.current, target.baseline) and
                !valueEql(target.current, target.draft);
            if (!target.dirty) target.conflict = false;
            self.draft_revision +%= 1;

            target.previewed = change.live_preview;
            if (!needs_preview_effect) return effects[0..0];
            effects[0] = .{ .set_preview = .{
                .field = target.field,
                .value = if (change.live_preview) target.draft else target.current,
            } };
            return effects[0..1];
        }

        fn externalUpdate(
            self: *Self,
            update: @FieldType(Intent, "external_update"),
            effects: []Effect,
        ) DispatchError![]Effect {
            if (self.pending_apply_id != null) return error.ApplyAlreadyPending;
            if (update.revision < self.current_revision) return error.StaleExternalRevision;

            var conflict_effect_count: usize = 0;
            for (update.changes) |change| {
                const target = self.entry(change.field) orelse return error.UnknownField;
                const will_conflict = target.dirty and
                    !valueEql(change.value, target.baseline) and
                    !valueEql(change.value, target.draft);
                if (will_conflict and !target.conflict) conflict_effect_count += 1;
            }
            if (effects.len < conflict_effect_count) return error.EffectBufferTooSmall;

            var effect_count: usize = 0;
            for (update.changes) |change| {
                const target = self.entry(change.field).?;
                target.current = change.value;

                if (!target.dirty) {
                    target.baseline = change.value;
                    target.draft = change.value;
                    target.conflict = false;
                    continue;
                }

                if (valueEql(change.value, target.draft)) {
                    target.baseline = change.value;
                    target.draft = change.value;
                    target.dirty = false;
                    target.conflict = false;
                    target.previewed = false;
                    continue;
                }

                const conflict = !valueEql(change.value, target.baseline);
                if (conflict and !target.conflict) {
                    effects[effect_count] = .{ .conflict_detected = target.field };
                    effect_count += 1;
                }
                target.conflict = conflict;
            }
            self.current_revision = update.revision;
            return effects[0..effect_count];
        }

        fn resolveConflict(
            self: *Self,
            resolve: @FieldType(Intent, "resolve_conflict"),
            effects: []Effect,
        ) DispatchError![]Effect {
            if (self.pending_apply_id != null) return error.ApplyAlreadyPending;
            const target = self.entry(resolve.field) orelse return error.UnknownField;
            if (!target.conflict) return error.NoConflict;

            switch (resolve.resolution) {
                .keep_mine => {
                    target.baseline = target.current;
                    target.dirty = !valueEql(target.draft, target.current);
                    target.conflict = false;
                    self.draft_revision +%= 1;
                    return effects[0..0];
                },
                .use_disk => {
                    if (target.previewed and effects.len < 1) return error.EffectBufferTooSmall;
                    const had_preview = target.previewed;
                    target.baseline = target.current;
                    target.draft = target.current;
                    target.dirty = false;
                    target.conflict = false;
                    target.previewed = false;
                    self.draft_revision +%= 1;
                    if (!had_preview) return effects[0..0];
                    effects[0] = .{ .set_preview = .{
                        .field = target.field,
                        .value = target.current,
                    } };
                    return effects[0..1];
                },
            }
        }

        fn revert(self: *Self, effects: []Effect) DispatchError![]Effect {
            if (self.pending_apply_id != null) return error.ApplyAlreadyPending;
            var preview_count: usize = 0;
            for (self.entries) |candidate| {
                preview_count += @intFromBool(candidate.previewed);
            }
            if (effects.len < preview_count) return error.EffectBufferTooSmall;

            var effect_count: usize = 0;
            for (self.entries) |*target| {
                if (target.previewed) {
                    effects[effect_count] = .{ .set_preview = .{
                        .field = target.field,
                        .value = target.current,
                    } };
                    effect_count += 1;
                }
                target.baseline = target.current;
                target.draft = target.current;
                target.previewed = false;
                target.dirty = false;
                target.conflict = false;
            }
            self.baseline_revision = self.current_revision;
            self.draft_revision +%= 1;
            return effects[0..effect_count];
        }

        fn apply(self: *Self, effects: []Effect) DispatchError![]Effect {
            if (self.pending_apply_id != null) return error.ApplyAlreadyPending;
            if (self.conflictCount() != 0) return error.UnresolvedConflict;
            const dirty_count = self.dirtyCount();
            if (dirty_count == 0) return effects[0..0];
            if (effects.len < dirty_count + 1) return error.EffectBufferTooSmall;
            if (self.next_apply_id == std.math.maxInt(ApplyId)) {
                return error.ApplyIdExhausted;
            }

            const apply_id = self.next_apply_id;

            effects[0] = .{ .apply_requested = .{
                .apply_id = apply_id,
                .expected_current_revision = self.current_revision,
                .draft_revision = self.draft_revision,
                .field_count = dirty_count,
            } };
            var effect_count: usize = 1;
            for (self.entries) |target| {
                if (!target.dirty) continue;
                effects[effect_count] = .{ .persist_field = .{
                    .field = target.field,
                    .value = target.draft,
                } };
                effect_count += 1;
            }
            self.pending_apply_id = apply_id;
            self.next_apply_id += 1;
            return effects[0..effect_count];
        }

        fn applySucceeded(
            self: *Self,
            success: @FieldType(Intent, "apply_succeeded"),
        ) DispatchError![]Effect {
            const pending_id = self.pending_apply_id orelse return error.ApplyNotPending;
            if (success.apply_id != pending_id) return error.ApplyIdMismatch;
            if (success.revision < self.current_revision) return error.StaleApplyRevision;
            for (self.entries) |*target| {
                if (target.dirty) target.current = target.draft;
                target.baseline = target.current;
                target.draft = target.current;
                target.previewed = false;
                target.dirty = false;
                target.conflict = false;
            }
            self.baseline_revision = success.revision;
            self.current_revision = success.revision;
            self.draft_revision = success.revision;
            self.pending_apply_id = null;
            return &.{};
        }

        fn applyFailed(self: *Self, apply_id: ApplyId) DispatchError![]Effect {
            const pending_id = self.pending_apply_id orelse return error.ApplyNotPending;
            if (apply_id != pending_id) return error.ApplyIdMismatch;
            self.pending_apply_id = null;
            return &.{};
        }
    };
}

const TestField = enum {
    font_size,
    opacity,
};

const TestValue = union(enum) {
    integer: u32,
    decimal: f64,
};

fn testValueEql(a: TestValue, b: TestValue) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .integer => |value| value == b.integer,
        .decimal => |value| value == b.decimal,
    };
}

const TestTransaction = Transaction(TestField, TestValue, testValueEql);

fn initialTestTransaction(storage: []TestTransaction.Entry) !TestTransaction {
    return TestTransaction.init(storage, &.{
        .{ .field = .font_size, .value = .{ .integer = 12 } },
        .{ .field = .opacity, .value = .{ .decimal = 1.0 } },
    }, 10);
}

test "settings transaction rolls live preview back to current disk value" {
    var storage: [2]TestTransaction.Entry = undefined;
    var transaction = try initialTestTransaction(&storage);
    var effects: [3]TestTransaction.Effect = undefined;

    const preview = try transaction.dispatch(.{ .edit = .{
        .field = .opacity,
        .value = .{ .decimal = 0.8 },
        .live_preview = true,
    } }, &effects);
    try std.testing.expectEqual(@as(usize, 1), preview.len);
    try std.testing.expectEqual(@as(f64, 0.8), preview[0].set_preview.value.decimal);

    const reverted = try transaction.dispatch(.revert, &effects);
    try std.testing.expectEqual(@as(usize, 1), reverted.len);
    try std.testing.expectEqual(@as(f64, 1.0), reverted[0].set_preview.value.decimal);
    try std.testing.expectEqual(@as(usize, 0), transaction.dirtyCount());
}

test "settings transaction adopts disjoint external edits without conflict" {
    var storage: [2]TestTransaction.Entry = undefined;
    var transaction = try initialTestTransaction(&storage);
    var effects: [3]TestTransaction.Effect = undefined;

    _ = try transaction.dispatch(.{ .edit = .{
        .field = .font_size,
        .value = .{ .integer = 14 },
    } }, &effects);
    const external = try transaction.dispatch(.{ .external_update = .{
        .revision = 11,
        .changes = &.{.{ .field = .opacity, .value = .{ .decimal = 0.9 } }},
    } }, &effects);

    try std.testing.expectEqual(@as(usize, 0), external.len);
    try std.testing.expectEqual(@as(usize, 0), transaction.conflictCount());
    try std.testing.expectEqual(@as(f64, 0.9), transaction.entry(.opacity).?.draft.decimal);
    try std.testing.expectEqual(@as(u32, 14), transaction.entry(.font_size).?.draft.integer);
}

test "settings transaction detects and resolves same-field external conflict" {
    var storage: [2]TestTransaction.Entry = undefined;
    var transaction = try initialTestTransaction(&storage);
    var effects: [3]TestTransaction.Effect = undefined;

    _ = try transaction.dispatch(.{ .edit = .{
        .field = .font_size,
        .value = .{ .integer = 14 },
    } }, &effects);
    const external = try transaction.dispatch(.{ .external_update = .{
        .revision = 11,
        .changes = &.{.{ .field = .font_size, .value = .{ .integer = 16 } }},
    } }, &effects);
    try std.testing.expectEqual(@as(usize, 1), external.len);
    try std.testing.expectEqual(TestField.font_size, external[0].conflict_detected);
    try std.testing.expectEqual(@as(usize, 1), transaction.conflictCount());

    _ = try transaction.dispatch(.{ .resolve_conflict = .{
        .field = .font_size,
        .resolution = .keep_mine,
    } }, &effects);
    try std.testing.expectEqual(@as(usize, 0), transaction.conflictCount());
    try std.testing.expectEqual(@as(u32, 14), transaction.entry(.font_size).?.draft.integer);
    try std.testing.expectEqual(@as(u32, 16), transaction.entry(.font_size).?.current.integer);
}

test "settings transaction apply is two phase and commits draft" {
    var storage: [2]TestTransaction.Entry = undefined;
    var transaction = try initialTestTransaction(&storage);
    var effects: [3]TestTransaction.Effect = undefined;

    _ = try transaction.dispatch(.{ .edit = .{
        .field = .font_size,
        .value = .{ .integer = 14 },
    } }, &effects);
    const apply_effects = try transaction.dispatch(.apply, &effects);
    try std.testing.expectEqual(@as(usize, 2), apply_effects.len);
    const apply_id = apply_effects[0].apply_requested.apply_id;
    try std.testing.expectEqual(@as(TestTransaction.ApplyId, 1), apply_id);
    try std.testing.expectEqual(@as(u64, 10), apply_effects[0].apply_requested.expected_current_revision);
    try std.testing.expectEqual(@as(usize, 1), apply_effects[0].apply_requested.field_count);
    try std.testing.expectEqual(TestField.font_size, apply_effects[1].persist_field.field);
    try std.testing.expectEqual(@as(u32, 14), apply_effects[1].persist_field.value.integer);
    try std.testing.expectEqual(@as(?TestTransaction.ApplyId, apply_id), transaction.pending_apply_id);

    _ = try transaction.dispatch(.{ .apply_succeeded = .{
        .apply_id = apply_id,
        .revision = 12,
    } }, &effects);
    try std.testing.expectEqual(@as(?TestTransaction.ApplyId, null), transaction.pending_apply_id);
    try std.testing.expectEqual(@as(usize, 0), transaction.dirtyCount());
    try std.testing.expectEqual(@as(u64, 12), transaction.current_revision);
    try std.testing.expectEqual(@as(u32, 14), transaction.entry(.font_size).?.current.integer);
}

test "settings transaction use disk rolls back active preview" {
    var storage: [2]TestTransaction.Entry = undefined;
    var transaction = try initialTestTransaction(&storage);
    var effects: [3]TestTransaction.Effect = undefined;

    _ = try transaction.dispatch(.{ .edit = .{
        .field = .opacity,
        .value = .{ .decimal = 0.8 },
        .live_preview = true,
    } }, &effects);
    _ = try transaction.dispatch(.{ .external_update = .{
        .revision = 11,
        .changes = &.{.{ .field = .opacity, .value = .{ .decimal = 0.6 } }},
    } }, &effects);

    const resolved = try transaction.dispatch(.{ .resolve_conflict = .{
        .field = .opacity,
        .resolution = .use_disk,
    } }, &effects);
    try std.testing.expectEqual(@as(usize, 1), resolved.len);
    try std.testing.expectEqual(@as(f64, 0.6), resolved[0].set_preview.value.decimal);
    try std.testing.expectEqual(@as(usize, 0), transaction.dirtyCount());
}

test "settings transaction staged edit rolls back an active live preview" {
    var storage: [2]TestTransaction.Entry = undefined;
    var transaction = try initialTestTransaction(&storage);
    var effects: [3]TestTransaction.Effect = undefined;

    _ = try transaction.dispatch(.{ .edit = .{
        .field = .opacity,
        .value = .{ .decimal = 0.8 },
        .live_preview = true,
    } }, &effects);
    const rollback = try transaction.dispatch(.{ .edit = .{
        .field = .opacity,
        .value = .{ .decimal = 0.7 },
        .live_preview = false,
    } }, &effects);

    try std.testing.expectEqual(@as(usize, 1), rollback.len);
    try std.testing.expectEqual(@as(f64, 1.0), rollback[0].set_preview.value.decimal);
    const opacity = transaction.entry(.opacity).?;
    try std.testing.expect(!opacity.previewed);
    try std.testing.expect(opacity.dirty);
    try std.testing.expectEqual(@as(f64, 0.7), opacity.draft.decimal);
    try std.testing.expectEqual(@as(f64, 1.0), opacity.current.decimal);
}

test "settings transaction apply completion requires matching monotonic token" {
    var storage: [2]TestTransaction.Entry = undefined;
    var transaction = try initialTestTransaction(&storage);
    var effects: [3]TestTransaction.Effect = undefined;

    _ = try transaction.dispatch(.{ .edit = .{
        .field = .font_size,
        .value = .{ .integer = 14 },
    } }, &effects);
    const first = try transaction.dispatch(.apply, &effects);
    const first_id = first[0].apply_requested.apply_id;

    try std.testing.expectError(
        error.ApplyIdMismatch,
        transaction.dispatch(.{ .apply_succeeded = .{
            .apply_id = first_id + 1,
            .revision = 11,
        } }, &effects),
    );
    try std.testing.expectEqual(@as(?TestTransaction.ApplyId, first_id), transaction.pending_apply_id);
    _ = try transaction.dispatch(.{ .apply_failed = .{ .apply_id = first_id } }, &effects);
    try std.testing.expectEqual(@as(?TestTransaction.ApplyId, null), transaction.pending_apply_id);

    const second = try transaction.dispatch(.apply, &effects);
    const second_id = second[0].apply_requested.apply_id;
    try std.testing.expect(second_id > first_id);
    try std.testing.expectError(
        error.ApplyIdMismatch,
        transaction.dispatch(.{ .apply_failed = .{ .apply_id = first_id } }, &effects),
    );
    _ = try transaction.dispatch(.{ .apply_succeeded = .{
        .apply_id = second_id,
        .revision = 12,
    } }, &effects);
    try std.testing.expectEqual(@as(usize, 0), transaction.dirtyCount());
}
