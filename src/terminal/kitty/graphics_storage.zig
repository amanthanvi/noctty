const std = @import("std");
const assert = @import("../../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const terminal = @import("../main.zig");
const point = @import("../point.zig");
const size = @import("../size.zig");
const command = @import("graphics_command.zig");
const PageList = @import("../PageList.zig");
const Screen = @import("../Screen.zig");
const LoadingImage = @import("graphics_image.zig").LoadingImage;
const Image = @import("graphics_image.zig").Image;
const Rect = @import("graphics_image.zig").Rect;
const Command = command.Command;

const log = std.log.scoped(.kitty_gfx);

/// An image storage is associated with a terminal screen (i.e. main
/// screen, alt screen) and contains all the transmitted images and
/// placements.
pub const ImageStorage = struct {
    const ImageMap = std.AutoHashMapUnmanaged(u32, Image);
    const PlacementMap = std.AutoHashMapUnmanaged(PlacementKey, Placement);

    /// Dirty is set to true if placements or images change. This is
    /// purely informational for the renderer and doesn't affect the
    /// correctness of the program. The renderer must set this to false
    /// if it cares about this value.
    dirty: bool = false,

    /// This is the next automatically assigned image ID. We start mid-way
    /// through the u32 range to avoid collisions with buggy programs.
    /// TODO: This isn't good enough, it's perfectly legal for programs
    ///       to use IDs in the latter half of the range and collisions
    ///       are not gracefully handled.
    next_image_id: u32 = 2147483647,

    /// This is the next automatically assigned placement ID. This is never
    /// user-facing so we can start at 0. This is 32-bits because we use
    /// the same space for external placement IDs. We can start at zero
    /// because any number is valid.
    next_internal_placement_id: u32 = 0,

    /// The set of images that are currently known.
    images: ImageMap = .{},

    /// The set of placements for loaded images.
    placements: PlacementMap = .{},

    /// Non-null if there is an in-progress loading image.
    loading: ?*LoadingImage = null,

    /// The total bytes of image data that have been loaded and the limit.
    /// If the limit is reached, the oldest images will be evicted to make
    /// space. Unused images take priority.
    total_bytes: usize = 0,
    total_limit: usize = 320 * 1000 * 1000, // 320MB

    pub fn deinit(
        self: *ImageStorage,
        alloc: Allocator,
        s: *terminal.Screen,
    ) void {
        if (self.loading) |loading| loading.destroy(alloc);

        var it = self.images.iterator();
        while (it.next()) |kv| kv.value_ptr.deinit(alloc);
        self.images.deinit(alloc);

        self.clearPlacements(s);
        self.placements.deinit(alloc);
    }

    /// Kitty image protocol is enabled if we have a non-zero limit.
    pub fn enabled(self: *const ImageStorage) bool {
        return self.total_limit != 0;
    }

    /// Sets the limit in bytes for the total amount of image data that
    /// can be loaded. If this limit is lower, this will do an eviction
    /// if necessary. If the value is zero, then Kitty image protocol will
    /// be disabled.
    pub fn setLimit(
        self: *ImageStorage,
        alloc: Allocator,
        s: *terminal.Screen,
        limit: usize,
    ) !void {
        // Special case disabling by quickly deleting all
        if (limit == 0) {
            self.deinit(alloc, s);
            self.* = .{};
        }

        // If we re lowering our limit, check if we need to evict.
        if (limit < self.total_bytes) {
            const req_bytes = self.total_bytes - limit;
            log.info("evicting images to lower limit, evicting={}", .{req_bytes});
            if (!try self.evictImage(alloc, s, req_bytes, null)) {
                log.warn("failed to evict enough images for required bytes", .{});
            }
        }

        self.total_limit = limit;
    }

    /// Add an already-loaded image to the storage. This will automatically
    /// free any existing image with the same ID. The screen must own the
    /// tracked pins of the placements an eviction may remove.
    pub fn addImage(
        self: *ImageStorage,
        alloc: Allocator,
        s: *terminal.Screen,
        img: Image,
    ) Allocator.Error!void {
        // If the image itself is over the limit, then error immediately
        if (img.data.len > self.total_limit) return error.OutOfMemory;

        // An image that replaces one with the same ID frees that one's
        // bytes, so count them as freed before deciding what to evict, and
        // never evict the image being replaced: its bytes are already
        // counted, and evicting it would leave the total over the limit.
        const old_len = if (self.images.get(img.id)) |old| old.data.len else 0;

        // If this would put us over the limit, then evict.
        const total_bytes = self.total_bytes - old_len + img.data.len;
        if (total_bytes > self.total_limit) {
            const req_bytes = total_bytes - self.total_limit;
            log.info("evicting images to make space for {} bytes", .{req_bytes});
            if (!try self.evictImage(alloc, s, req_bytes, img.id)) {
                log.warn("failed to evict enough images for required bytes", .{});
                return error.OutOfMemory;
            }
        }

        // Do the gop op first so if it fails we don't get a partial state
        const gop = try self.images.getOrPut(alloc, img.id);

        log.debug("addImage image={}", .{img: {
            var copy = img;
            copy.data = "";
            break :img copy;
        }});

        // Retransmitting an image ID replaces the old image and deletes all
        // of its placements, as the Kitty graphics protocol requires.
        if (gop.found_existing) {
            self.deleteById(alloc, s, img.id, 0, false);
            self.total_bytes -= gop.value_ptr.data.len;
            gop.value_ptr.deinit(alloc);
        }

        gop.value_ptr.* = img;
        self.total_bytes += img.data.len;

        self.dirty = true;
    }

    /// Add a placement for a given image. The caller must verify in advance
    /// the image exists to prevent memory corruption. On success, storage
    /// owns `p`; on error, the caller retains ownership. The screen must own
    /// any tracked pin in `p` and in the placement it replaces.
    pub fn addPlacement(
        self: *ImageStorage,
        alloc: Allocator,
        s: *terminal.Screen,
        image_id: u32,
        placement_id: u32,
        p: Placement,
    ) !void {
        assert(self.images.get(image_id) != null);
        log.debug("placement image_id={} placement_id={} placement={}\n", .{
            image_id,
            placement_id,
            p,
        });

        // Tracked pins are marked garbage when their underlying history is
        // pruned. Kitty removes placements once they scroll out of retained
        // history, so reclaim those placements before growing the map for a
        // new one. We don't sweep in the hot path, so do it here.
        if (self.removeGarbagePlacements(s)) self.dirty = true;

        // The important piece here is that the placement ID needs to
        // be marked internal if it is zero. This allows multiple placements
        // to be added for the same image. If it is non-zero, then it is
        // an external placement ID and we can only have one placement
        // per (image id, placement id) pair.
        const key: PlacementKey = .{
            .image_id = image_id,
            .placement_id = if (placement_id == 0) .{
                .tag = .internal,
                .id = id: {
                    defer self.next_internal_placement_id +%= 1;
                    break :id self.next_internal_placement_id;
                },
            } else .{
                .tag = .external,
                .id = placement_id,
            },
        };

        const gop = try self.placements.getOrPut(alloc, key);
        if (gop.found_existing) gop.value_ptr.deinit(s);
        gop.value_ptr.* = p;

        self.dirty = true;
    }

    /// Remove pin-backed placements whose tracked content has been pruned
    /// or erased. Virtual placements have no tracked screen location and
    /// are retained. Returns true if any placement was removed.
    pub fn removeGarbagePlacements(
        self: *ImageStorage,
        s: *terminal.Screen,
    ) bool {
        var removed = false;
        var it = self.placements.iterator();
        while (it.next()) |entry| {
            const pin = switch (entry.value_ptr.location) {
                .pin => |pin| pin,
                .virtual => continue,
            };
            if (!pin.garbage) continue;

            entry.value_ptr.deinit(s);
            self.placements.removeByPtr(entry.key_ptr);
            removed = true;
        }

        return removed;
    }

    fn clearPlacements(self: *ImageStorage, s: *terminal.Screen) void {
        var it = self.placements.iterator();
        while (it.next()) |entry| entry.value_ptr.deinit(s);
        self.placements.clearRetainingCapacity();
    }

    /// Delete the pin placements anchored in the rows from `tl` to `bl`
    /// (the end of the area `tl` names when null), which the caller is about
    /// to erase. PageList moves the tracked pins of erased rows onto rows
    /// that remain, without marking them garbage, so these images would
    /// otherwise be drawn there.
    pub fn deleteInErasedRows(
        self: *ImageStorage,
        s: *terminal.Screen,
        tl: point.Point,
        bl: ?point.Point,
    ) void {
        var top = s.pages.pin(tl) orelse return;
        top.x = 0;
        var bottom = if (bl) |pt|
            s.pages.pin(pt) orelse return
        else
            s.pages.getBottomRight(tl) orelse return;
        bottom.x = s.pages.cols - 1;

        var it = self.placements.iterator();
        while (it.next()) |entry| {
            const pin = switch (entry.value_ptr.location) {
                .pin => |pin| pin,
                .virtual => continue,
            };
            if (!pin.isBetween(top, bottom)) continue;

            entry.value_ptr.deinit(s);
            self.placements.removeByPtr(entry.key_ptr);
            self.dirty = true;
        }
    }

    /// How the row operation behind a scrollMarginsBegin/end pair moves
    /// tracked pins, which decides which placements need repositioning.
    pub const ScrollOp = enum {
        /// The operation shifts the whole active area (it creates
        /// scrollback, or a screen without scrollback discards its top
        /// row), so every placement anchored in the active area can change
        /// its active row and must be restored.
        window_shift,

        /// The operation moves rows in place within the scrolling region,
        /// or moves no pins at all (insertLines, deleteLines): pins anchored
        /// outside the region rows keep their active position, so only the
        /// placements anchored inside need handling.
        in_place,
    };

    /// Adjust placements for a scroll of the terminal's scrolling region by
    /// `delta` rows (negative moves content up), as the Kitty graphics
    /// protocol requires.
    ///
    /// With margins (a region smaller than the screen), placements entirely
    /// inside the region move with the content and are clipped where the
    /// move would take them past a margin (deleted when nothing is left),
    /// while every other placement (straddling a margin, outside the
    /// region, or in the scrollback) does not move at all.
    ///
    /// Without margins, kitty moves every image with the content and clips
    /// nothing: an image can hang off the top or the bottom of the screen.
    /// A pin cannot sit above the top row or below the bottom one, so here
    /// the part that leaves the top of the screen is clipped, and an image
    /// whose anchor row leaves the screen is deleted. Callers skip the
    /// full-screen scroll up on a screen with scrollback, where the pins
    /// already follow their rows into the scrollback.
    ///
    /// This is split into two phases around the row operation because the
    /// scroll implementations move tracked pins in inconsistent ways (some
    /// shift the active area so every pin moves, some rotate rows in place
    /// and adjust only pins inside the region, some move no pins). The
    /// returned state records where every placement must end up, and its
    /// end() repositions the pins once the rows have settled, so the result
    /// does not depend on the path taken. Every call must be paired with
    /// exactly one end().
    pub fn scrollMarginsBegin(
        self: *ImageStorage,
        t: *terminal.Terminal,
        delta: isize,
        op: ScrollOp,
    ) ScrollMargins {
        const s: *terminal.Screen = t.screens.active;
        assert(self == &s.kitty_images);
        var result: ScrollMargins = .{ .screen = s };

        // Placements below may move, be clipped or be deleted.
        self.dirty = true;

        const region = t.scrolling_region;
        const top: i64 = region.top;
        const bottom: i64 = region.bottom;
        const margins = region.top != 0 or
            region.bottom != t.rows - 1 or
            region.left != 0 or
            region.right != t.cols - 1;

        var it = self.placements.iterator();
        while (it.next()) |entry| {
            const p: *Placement = entry.value_ptr;

            // Virtual placements follow their placeholder cells and are
            // never adjusted by scrolls, matching kitty.
            const pin: *PageList.Pin = switch (p.location) {
                .pin => |pin| pin,
                .virtual => continue,
            };

            // Pruned placements are reaped by removeGarbagePlacements.
            if (pin.garbage) continue;

            // Placements anchored outside the active area (scrollback) are
            // never touched by a scroll of the screen.
            const coord = (s.pages.pointFromPin(
                .active,
                pin.*,
            ) orelse continue).coord();
            const y: i64 = coord.y;

            // An in-place operation doesn't touch pins anchored outside the
            // region rows, and a placement anchored there can never be
            // entirely inside the region, so it needs no work at all.
            if (op == .in_place and (y < top or y > bottom)) continue;

            // The final position defaults to unmoved; restoring the pin to
            // this exact spot afterwards is what stops the row operations
            // from dragging the placement around.
            var final_y: i64 = y;

            moved: {
                const image = self.images.get(entry.key_ptr.image_id) orelse break :moved;
                const grid = p.gridSize(image, t);
                const new_y: i64 = y + delta;

                const visible: bool = if (!margins) visible: {
                    // Unknown geometry (no pixel metrics yet) counts as one
                    // row, so such a placement moves until its anchor row
                    // leaves the screen.
                    const rows: i64 = @max(1, grid.rows);
                    if (new_y > bottom or new_y + rows - 1 < top) break :visible false;
                    if (new_y < top) {
                        if (!p.clipTop(image, t, @intCast(top - new_y))) break :visible false;
                        final_y = top;
                        break :visible true;
                    }

                    final_y = new_y;
                    break :visible true;
                } else visible: {
                    // Unknown geometry means we can't know the extent, so
                    // we can't consider the placement contained.
                    if (grid.rows == 0 or grid.cols == 0) break :moved;

                    // Only placements entirely within the scrolling region
                    // move. Kitty only has top/bottom margins so it only
                    // checks rows; the column check is a generalization for
                    // left/right margins and is trivially true for
                    // full-width regions.
                    if (y < top or y + grid.rows - 1 > bottom) break :moved;
                    const x: i64 = coord.x;
                    if (x < region.left or
                        @min(x + grid.cols - 1, @as(i64, t.cols) - 1) > region.right) break :moved;

                    const rows: i64 = grid.rows;
                    const top_clip: i64 = @max(0, top - new_y);
                    const bottom_clip: i64 = @max(0, new_y + rows - 1 - bottom);
                    if (top_clip >= rows or bottom_clip >= rows) break :visible false;

                    if (top_clip > 0) {
                        if (!p.clipTop(image, t, @intCast(top_clip))) break :visible false;
                        final_y = top;
                        break :visible true;
                    }

                    if (bottom_clip > 0) {
                        if (!p.clipBottom(
                            image,
                            t,
                            @intCast(bottom_clip),
                            grid.rows,
                        )) break :visible false;
                    }

                    final_y = new_y;
                    break :visible true;
                };

                // Scrolled or clipped entirely out of the region: the
                // placement is deleted, like kitty. The image itself is
                // retained for future placements.
                if (!visible) {
                    p.deinit(s);
                    self.placements.removeByPtr(entry.key_ptr);
                    continue;
                }
            }

            result.restores.append(s.alloc, .{
                .pin = pin,
                .x = pin.x,
                .y = @intCast(final_y),
            }) catch {
                // OOM: this placement is left to the whims of the generic
                // pin tracking. Degraded, but safe.
                log.warn("OOM adjusting image placement for scroll", .{});
                continue;
            };
        }

        return result;
    }

    /// Get an image by its ID. If the image doesn't exist, null is returned.
    pub fn imageById(self: *const ImageStorage, image_id: u32) ?Image {
        return self.images.get(image_id);
    }

    /// Get an image by its number. If the image doesn't exist, return null.
    pub fn imageByNumber(self: *const ImageStorage, image_number: u32) ?Image {
        var newest: ?Image = null;

        var it = self.images.iterator();
        while (it.next()) |kv| {
            if (kv.value_ptr.number == image_number) {
                if (newest == null or
                    kv.value_ptr.transmit_time.order(newest.?.transmit_time) == .gt)
                {
                    newest = kv.value_ptr.*;
                }
            }
        }

        return newest;
    }

    /// Delete placements, images.
    pub fn delete(
        self: *ImageStorage,
        alloc: Allocator,
        t: *terminal.Terminal,
        cmd: command.Delete.Action,
    ) void {
        switch (cmd) {
            .all => |delete_images| {
                var it = self.placements.iterator();
                while (it.next()) |entry| {
                    // Skip virtual placements
                    switch (entry.value_ptr.location) {
                        .pin => {},
                        .virtual => continue,
                    }

                    // Deinit the placement and remove it
                    const image_id = entry.key_ptr.image_id;
                    entry.value_ptr.deinit(t.screens.active);
                    self.placements.removeByPtr(entry.key_ptr);
                    if (delete_images) self.deleteIfUnused(alloc, image_id);
                }

                if (delete_images) {
                    var image_it = self.images.iterator();
                    while (image_it.next()) |kv| self.deleteIfUnused(alloc, kv.key_ptr.*);
                }

                self.dirty = true;
            },

            .id => |v| self.deleteById(
                alloc,
                t.screens.active,
                v.image_id,
                v.placement_id,
                v.delete,
            ),

            .newest => |v| newest: {
                const img = self.imageByNumber(v.image_number) orelse break :newest;
                self.deleteById(
                    alloc,
                    t.screens.active,
                    img.id,
                    v.placement_id,
                    v.delete,
                );
            },

            .intersect_cursor => |delete_images| {
                self.deleteIntersecting(
                    alloc,
                    t,
                    .{ .active = .{
                        .x = t.screens.active.cursor.x,
                        .y = t.screens.active.cursor.y,
                    } },
                    delete_images,
                    {},
                    null,
                );
            },

            .intersect_cell => |v| intersect_cell: {
                if (v.x <= 0 or v.y <= 0) {
                    log.warn("delete intersect cell coords must be at least 1", .{});
                    break :intersect_cell;
                }

                self.deleteIntersecting(
                    alloc,
                    t,
                    .{ .active = .{
                        .x = std.math.cast(size.CellCountInt, v.x - 1) orelse break :intersect_cell,
                        .y = std.math.cast(size.CellCountInt, v.y - 1) orelse break :intersect_cell,
                    } },
                    v.delete,
                    {},
                    null,
                );
            },

            .intersect_cell_z => |v| intersect_cell_z: {
                if (v.x <= 0 or v.y <= 0) {
                    log.warn("delete intersect cell coords must be at least 1", .{});
                    break :intersect_cell_z;
                }

                self.deleteIntersecting(
                    alloc,
                    t,
                    .{ .active = .{
                        .x = std.math.cast(size.CellCountInt, v.x - 1) orelse break :intersect_cell_z,
                        .y = std.math.cast(size.CellCountInt, v.y - 1) orelse break :intersect_cell_z,
                    } },
                    v.delete,
                    v.z,
                    struct {
                        fn filter(ctx: i32, p: Placement) bool {
                            return p.z == ctx;
                        }
                    }.filter,
                );
            },

            .column => |v| column: {
                if (v.x <= 0) {
                    log.warn("delete column must be greater than zero", .{});
                    break :column;
                }

                const x = v.x - 1;
                var it = self.placements.iterator();
                while (it.next()) |entry| {
                    const img = self.imageById(entry.key_ptr.image_id) orelse continue;
                    const rect = entry.value_ptr.rect(img, t) orelse continue;
                    if (rect.top_left.x <= x and rect.bottom_right.x >= x) {
                        entry.value_ptr.deinit(t.screens.active);
                        self.placements.removeByPtr(entry.key_ptr);
                        if (v.delete) self.deleteIfUnused(alloc, img.id);
                    }
                }

                // Mark dirty to force redraw
                self.dirty = true;
            },

            .row => |v| row: {
                if (v.y <= 0) {
                    log.warn("delete row must be greater than zero", .{});
                    break :row;
                }

                // v.y is in active coords so we want to convert it to a pin
                // so we can compare by page offsets.
                const target_pin = t.screens.active.pages.pin(.{ .active = .{
                    .y = std.math.cast(size.CellCountInt, v.y - 1) orelse break :row,
                } }) orelse break :row;

                var it = self.placements.iterator();
                while (it.next()) |entry| {
                    const img = self.imageById(entry.key_ptr.image_id) orelse continue;
                    const rect = entry.value_ptr.rect(img, t) orelse continue;

                    // We need to copy our pin to ensure we are at least at
                    // the top-left x.
                    var target_pin_copy = target_pin;
                    target_pin_copy.x = rect.top_left.x;
                    if (target_pin_copy.isBetween(rect.top_left, rect.bottom_right)) {
                        entry.value_ptr.deinit(t.screens.active);
                        self.placements.removeByPtr(entry.key_ptr);
                        if (v.delete) self.deleteIfUnused(alloc, img.id);
                    }
                }

                // Mark dirty to force redraw
                self.dirty = true;
            },

            .z => |v| {
                var it = self.placements.iterator();
                while (it.next()) |entry| {
                    switch (entry.value_ptr.location) {
                        .pin => {},

                        // Virtual placeholders cannot delete by z according
                        // to the spec.
                        .virtual => continue,
                    }

                    if (entry.value_ptr.z == v.z) {
                        const image_id = entry.key_ptr.image_id;
                        entry.value_ptr.deinit(t.screens.active);
                        self.placements.removeByPtr(entry.key_ptr);
                        if (v.delete) self.deleteIfUnused(alloc, image_id);
                    }
                }

                // Mark dirty to force redraw
                self.dirty = true;
            },

            .range => |v| range: {
                if (v.first <= 0 or v.last <= 0) {
                    log.warn("delete range values must be greater than zero", .{});
                    break :range;
                }
                if (v.first > v.last) {
                    log.warn("delete range 'x' ({}) must be less than or equal to 'y' ({})", .{ v.first, v.last });
                    break :range;
                }

                var it = self.placements.iterator();
                while (it.next()) |entry| {
                    if (entry.key_ptr.image_id >= v.first and entry.key_ptr.image_id <= v.last) {
                        const image_id = entry.key_ptr.image_id;
                        entry.value_ptr.deinit(t.screens.active);
                        self.placements.removeByPtr(entry.key_ptr);
                        if (v.delete) self.deleteIfUnused(alloc, image_id);
                    }
                }

                // Mark dirty to force redraw
                self.dirty = true;
            },

            // We don't support animation frames yet so they are successfully
            // deleted!
            .animation_frames => {},
        }
    }

    fn deleteById(
        self: *ImageStorage,
        alloc: Allocator,
        s: *terminal.Screen,
        image_id: u32,
        placement_id: u32,
        delete_unused: bool,
    ) void {
        // If no placement, we delete all placements with the ID
        if (placement_id == 0) {
            var it = self.placements.iterator();
            while (it.next()) |entry| {
                if (entry.key_ptr.image_id == image_id) {
                    entry.value_ptr.deinit(s);
                    self.placements.removeByPtr(entry.key_ptr);
                }
            }
        } else {
            if (self.placements.getEntry(.{
                .image_id = image_id,
                .placement_id = .{ .tag = .external, .id = placement_id },
            })) |entry| {
                entry.value_ptr.deinit(s);
                self.placements.removeByPtr(entry.key_ptr);
            }
        }

        // If this is specified, then we also delete the image
        // if it is no longer in use.
        if (delete_unused) self.deleteIfUnused(alloc, image_id);

        // Mark dirty to force redraw
        self.dirty = true;
    }

    /// Delete an image if it is unused.
    fn deleteIfUnused(self: *ImageStorage, alloc: Allocator, image_id: u32) void {
        var it = self.placements.iterator();
        while (it.next()) |kv| {
            if (kv.key_ptr.image_id == image_id) {
                return;
            }
        }

        // If we get here, we can delete the image.
        if (self.images.getEntry(image_id)) |entry| {
            self.total_bytes -= entry.value_ptr.data.len;
            entry.value_ptr.deinit(alloc);
            self.images.removeByPtr(entry.key_ptr);
        }
    }

    /// Deletes all placements intersecting a screen point.
    fn deleteIntersecting(
        self: *ImageStorage,
        alloc: Allocator,
        t: *terminal.Terminal,
        p: point.Point,
        delete_unused: bool,
        filter_ctx: anytype,
        comptime filter: ?fn (@TypeOf(filter_ctx), Placement) bool,
    ) void {
        // Convert our target point to a pin for comparison.
        const target_pin = t.screens.active.pages.pin(p) orelse return;

        var it = self.placements.iterator();
        while (it.next()) |entry| {
            const img = self.imageById(entry.key_ptr.image_id) orelse continue;
            const rect = entry.value_ptr.rect(img, t) orelse continue;
            if (rect.contains(target_pin)) {
                if (filter) |f| if (!f(filter_ctx, entry.value_ptr.*)) continue;
                entry.value_ptr.deinit(t.screens.active);
                self.placements.removeByPtr(entry.key_ptr);
                if (delete_unused) self.deleteIfUnused(alloc, img.id);
            }
        }

        // Mark dirty to force redraw
        self.dirty = true;
    }

    /// Evict image to make space. This will evict the oldest image,
    /// prioritizing transient images and unused images as recommended by the
    /// published Kitty spec.
    ///
    /// This will evict as many images as necessary to make space for
    /// req bytes, never the image `exclude_id` names. The screen must own
    /// the tracked pins of the evicted images' placements.
    fn evictImage(
        self: *ImageStorage,
        alloc: Allocator,
        s: *terminal.Screen,
        req: usize,
        exclude_id: ?u32,
    ) !bool {
        assert(req <= self.total_limit);

        // Ironically we allocate to evict. We should probably redesign the
        // data structures to avoid this but for now allocating a little
        // bit is fine compared to the megabytes we're looking to save.
        const Candidate = struct {
            id: u32,
            time: std.time.Instant,
            // Map images into four distinct blocks:
            // 0: transient, unused
            // 1: not transient, unused
            // 2: transient, used
            // 3: not transient, used
            block: u2,
        };

        var candidates: std.ArrayList(Candidate) = .empty;
        defer candidates.deinit(alloc);

        var it = self.images.iterator();
        while (it.next()) |kv| {
            const img = kv.value_ptr;
            if (exclude_id != null and img.id == exclude_id.?) continue;

            // This is a huge waste. See comment above about redesigning
            // our data structures to avoid this. Eviction should be very
            // rare though and we never have that many images/placements
            // so hopefully this will last a long time.
            const used = used: {
                var p_it = self.placements.iterator();
                while (p_it.next()) |p_kv| {
                    if (p_kv.key_ptr.image_id == img.id) {
                        break :used true;
                    }
                }

                break :used false;
            };

            const transient = img.usage.transient;

            try candidates.append(alloc, .{
                .id = img.id,
                .time = img.transmit_time,
                .block = (if (transient) @as(u2, 0) else @as(u2, 1)) + (if (used) @as(u2, 2) else @as(u2, 0)),
            });
        }

        // Sort
        std.mem.sortUnstable(
            Candidate,
            candidates.items,
            {},
            struct {
                fn lessThan(
                    ctx: void,
                    lhs: Candidate,
                    rhs: Candidate,
                ) bool {
                    _ = ctx;

                    // If images mapped into different blocks, prioritize lower
                    // numbered blocks.
                    if (lhs.block < rhs.block) return true;
                    if (lhs.block > rhs.block) return false;

                    // If images mapped to the same block, the oldest goes
                    // first, then the lowest ID.
                    return switch (lhs.time.order(rhs.time)) {
                        .lt => true,
                        .gt => false,
                        .eq => lhs.id < rhs.id,
                    };
                }
            }.lessThan,
        );

        // They're in order of best to evict.
        var evicted: usize = 0;
        for (candidates.items) |c| {
            // Delete all the placements for this image and the image.
            var p_it = self.placements.iterator();
            while (p_it.next()) |entry| {
                if (entry.key_ptr.image_id == c.id) {
                    entry.value_ptr.deinit(s);
                    self.placements.removeByPtr(entry.key_ptr);
                }
            }

            if (self.images.getEntry(c.id)) |entry| {
                log.info("evicting image id={} bytes={}", .{ c.id, entry.value_ptr.data.len });

                evicted += entry.value_ptr.data.len;
                self.total_bytes -= entry.value_ptr.data.len;

                entry.value_ptr.deinit(alloc);
                self.images.removeByPtr(entry.key_ptr);

                // Freeing exactly the requested bytes is enough: the total
                // is then at the limit, which is allowed.
                if (evicted >= req) return true;
            }
        }

        return false;
    }

    /// State returned by scrollMarginsBegin: the active-area position every
    /// surviving placement pin must be restored to once the scrolled rows
    /// have settled. Every begin must be paired with exactly one end() call
    /// after the scroll's row operations complete.
    pub const ScrollMargins = struct {
        screen: *terminal.Screen,
        restores: std.ArrayList(Restore) = .empty,

        const Restore = struct {
            pin: *PageList.Pin,
            x: size.CellCountInt,
            y: u32,
        };

        /// Reposition every recorded placement pin to its post-scroll
        /// position and release the state. Must be called exactly once,
        /// after the scroll's row operations complete.
        pub fn end(self: *ScrollMargins) void {
            for (self.restores.items) |restore| {
                restore.pin.* = self.screen.pages.pin(.{ .active = .{
                    .x = restore.x,
                    .y = restore.y,
                } }) orelse continue;
            }
            self.restores.deinit(self.screen.alloc);
        }
    };

    /// Every placement is uniquely identified by the image ID and the
    /// placement ID. If an image ID isn't specified it is assumed to be 0.
    /// Likewise, if a placement ID isn't specified it is assumed to be 0.
    pub const PlacementKey = struct {
        image_id: u32,
        placement_id: packed struct {
            tag: enum(u1) { internal, external },
            id: u32,
        },
    };

    pub const Placement = struct {
        /// The location where this placement should be drawn.
        location: Location,

        /// Offset of the x/y from the top-left of the cell.
        x_offset: u32 = 0,
        y_offset: u32 = 0,

        /// Source rectangle for the image to pull from
        source_x: u32 = 0,
        source_y: u32 = 0,
        source_width: u32 = 0,
        source_height: u32 = 0,

        /// The columns/rows this image occupies.
        columns: u32 = 0,
        rows: u32 = 0,

        /// The z-index for this placement.
        z: i32 = 0,

        pub const Location = union(enum) {
            /// Exactly placed on a screen pin.
            pin: *PageList.Pin,

            /// Virtual placement (U=1) for unicode placeholders.
            virtual: void,
        };

        pub fn deinit(
            self: *const Placement,
            s: *terminal.Screen,
        ) void {
            switch (self.location) {
                .pin => |p| s.pages.untrackPin(p),
                .virtual => {},
            }
        }

        /// Multiply two protocol-controlled values without allowing them to
        /// wrap. Placement geometry is exposed as u32, so values larger than
        /// that are represented by the largest possible value.
        fn saturatingMul(lhs: u32, rhs: u32) u32 {
            return std.math.mul(u32, lhs, rhs) catch std.math.maxInt(u32);
        }

        /// Scale a dimension by an aspect ratio and round to the nearest
        /// integer. The u64 intermediate can hold the product of two u32s as
        /// well as the rounding adjustment.
        fn scaleDimension(value: u32, numerator: u32, denominator: u32) u32 {
            if (denominator == 0) return 0;

            const rounded = (@as(u64, value) * @as(u64, numerator) +
                @as(u64, denominator) / 2) / @as(u64, denominator);
            return std.math.cast(u32, rounded) orelse std.math.maxInt(u32);
        }

        pub const SourceRect = struct {
            x: u32,
            y: u32,
            width: u32,
            height: u32,
        };

        /// Returns the requested source rectangle intersected with the image.
        /// A zero width or height requests the full corresponding image
        /// dimension before intersection, as defined by the Kitty protocol.
        pub fn sourceRect(self: Placement, image: Image) SourceRect {
            const x = @min(self.source_x, image.width);
            const y = @min(self.source_y, image.height);
            return .{
                .x = x,
                .y = y,
                .width = @min(
                    if (self.source_width > 0) self.source_width else image.width,
                    image.width - x,
                ),
                .height = @min(
                    if (self.source_height > 0) self.source_height else image.height,
                    image.height - y,
                ),
            };
        }

        /// Returns the placement offset clamped within the first cell. Pixel
        /// geometry may temporarily be unavailable, in which case there is no
        /// valid offset within the cell.
        pub fn cellOffset(
            self: Placement,
            t: *const terminal.Terminal,
        ) struct {
            x: u32,
            y: u32,
        } {
            const cell_width: u32 = t.width_px / t.cols;
            const cell_height: u32 = t.height_px / t.rows;

            return .{
                .x = if (cell_width > 0)
                    @min(self.x_offset, cell_width - 1)
                else
                    0,
                .y = if (cell_height > 0)
                    @min(self.y_offset, cell_height - 1)
                else
                    0,
            };
        }

        /// Calculates the size of this placement's image in pixels,
        /// taking in to account the source rectangle and the specified rows
        /// and columns.
        pub fn calculatedSize(
            self: Placement,
            image: Image,
            t: *const terminal.Terminal,
        ) struct {
            width: u32,
            height: u32,
        } {
            const source = self.sourceRect(image);
            const width = source.width;
            const height = source.height;

            // If we don't have any specified cols or rows then the placement
            // should be the native size of the image, and doesn't need to be
            // re-scaled.
            if (self.columns == 0 and self.rows == 0) return .{
                .width = width,
                .height = height,
            };

            // We calculate the size of a cell so that we can multiply
            // it by the specified cols/rows to get the correct px size.
            //
            // We assume that the width is divided evenly by the column
            // count and the height by the row count, because it should be.
            const cell_width: u32 = t.width_px / t.cols;
            const cell_height: u32 = t.height_px / t.rows;
            const cell_offset = self.cellOffset(t);

            // If we have a specified cols AND rows then we calculate
            // the width and height from them directly, we don't need
            // to adjust for aspect ratio.
            if (self.columns > 0 and self.rows > 0) {
                const calc_width = saturatingMul(cell_width, self.columns);
                const calc_height = saturatingMul(cell_height, self.rows);

                return .{
                    .width = calc_width -| cell_offset.x,
                    .height = calc_height -| cell_offset.y,
                };
            }

            // Either the columns or the rows were specified, but not both,
            // so we need to calculate the other one based on the aspect ratio.

            // If only the columns were specified, we determine
            // the height of the image based on the aspect ratio.
            if (self.columns > 0) {
                const calc_width = saturatingMul(
                    cell_width,
                    self.columns,
                ) -| cell_offset.x;
                const calc_height = scaleDimension(calc_width, height, width);

                return .{
                    .width = calc_width,
                    .height = calc_height,
                };
            }

            // Otherwise, only the rows were specified, so we
            // determine the width based on the aspect ratio.
            {
                const calc_height = saturatingMul(
                    cell_height,
                    self.rows,
                ) -| cell_offset.y;
                const calc_width = scaleDimension(calc_height, width, height);

                return .{
                    .width = calc_width,
                    .height = calc_height,
                };
            }
        }

        /// Returns the size in grid cells that this placement takes up.
        pub fn gridSize(
            self: Placement,
            image: Image,
            t: *const terminal.Terminal,
        ) struct {
            cols: u32,
            rows: u32,
        } {
            // If we have a specified columns and rows then this is trivial.
            if (self.columns > 0 and self.rows > 0) return .{
                .cols = self.columns,
                .rows = self.rows,
            };

            // Otherwise we calculate the pixel size, divide by
            // cell size, and round up to the nearest integer.
            const calc_size = self.calculatedSize(image, t);
            const cell_offset = self.cellOffset(t);
            return .{
                .cols = std.math.divCeil(
                    u32,
                    calc_size.width +| cell_offset.x,
                    t.width_px / t.cols,
                ) catch 0,
                .rows = std.math.divCeil(
                    u32,
                    calc_size.height +| cell_offset.y,
                    t.height_px / t.rows,
                ) catch 0,
            };
            // NOTE: Above `divCeil`s can only fail if the cell size is 0,
            //       in such a case it seems safe to return 0 for this.
        }

        /// Permanently clip `count` grid rows off the top of this placement
        /// by moving the top of its source rectangle down, which sets the
        /// source top and height explicitly. Used when a scroll moves part
        /// of the placement above the top margin, or off the top of a
        /// screen without scrollback. Requires `count` to be less than the
        /// placement's grid rows. Returns false, leaving the placement
        /// unchanged, if no source rows would remain; the caller deletes it
        /// then.
        fn clipTop(
            self: *Placement,
            image: Image,
            t: *const terminal.Terminal,
            count: u32,
        ) bool {
            assert(count > 0);
            const src = self.sourceRect(image);
            const dest_height = self.calculatedSize(image, t).height;
            if (src.height == 0 or dest_height == 0) return false;

            // The clipped rows hold this many pixels of the drawn image: a
            // y offset is blank space above the image in its first row.
            const rows_px = saturatingMul(t.height_px / t.rows, count);
            const image_px = rows_px -| self.cellOffset(t).y;
            const scaled: u64 = @as(u64, src.height) * image_px / dest_height;

            // Without a row count the drawn height follows the source's, so
            // an enlarged image whose crop rounds down to no source rows
            // would stay drawn whole at the top through every scroll. Such
            // an image loses a whole source row instead.
            const crop: u64 = if (self.rows == 0 and image_px > 0) @max(1, scaled) else scaled;
            if (crop >= src.height) return false;

            // Zero rows would mean unscaled.
            if (self.rows > 0 and count >= self.rows) return false;

            self.source_y = src.y + @as(u32, @intCast(crop));
            self.source_height = src.height - @as(u32, @intCast(crop));

            // The offset is less than a cell, so the clipped rows held it.
            self.y_offset = 0;
            if (self.rows > 0) self.rows -= count;
            return true;
        }

        /// clipTop, but clipping `count` of this placement's `span` grid
        /// rows off the bottom by shortening its source rectangle.
        fn clipBottom(
            self: *Placement,
            image: Image,
            t: *const terminal.Terminal,
            count: u32,
            span: u32,
        ) bool {
            assert(count < span);
            const src = self.sourceRect(image);
            const dest_height = self.calculatedSize(image, t).height;
            if (src.height == 0 or dest_height == 0) return false;

            // The rows that remain show this many pixels of the drawn image,
            // the first of them less the y offset above the image.
            const rows_px = saturatingMul(t.height_px / t.rows, span - count);
            const image_px = @min(rows_px -| self.cellOffset(t).y, dest_height);
            const height: u64 = @as(u64, src.height) * image_px / dest_height;

            // A zero source height would read as the full image, so a
            // placement with no source rows left is deleted instead.
            if (height == 0) return false;
            if (self.rows > 0 and count >= self.rows) return false;

            self.source_y = src.y;
            self.source_height = @intCast(height);
            if (self.rows > 0) self.rows -= count;
            return true;
        }

        /// Returns a selection of the entire rectangle this placement
        /// occupies within the screen. This can return null if the placement
        /// doesn't have an associated rect: a virtual placement, one whose
        /// tracked content has been pruned from the scrollback, or one whose
        /// computed grid is empty (missing pixel metrics, or an aspect ratio
        /// that rounds one dimension down to zero).
        pub fn rect(
            self: Placement,
            image: Image,
            t: *const terminal.Terminal,
        ) ?Rect {
            const grid_size = self.gridSize(image, t);
            const pin = switch (self.location) {
                .pin => |p| p,
                .virtual => return null,
            };

            // A garbage pin was moved to the top-left of the oldest page
            // when its rows were pruned. That fallback location is not where
            // the image was, so the placement has no rectangle; the next
            // addPlacement reclaims it.
            if (pin.garbage) return null;

            // An empty grid occupies no rectangle, and subtracting one from
            // a zero count below would underflow.
            if (grid_size.cols == 0 or grid_size.rows == 0) return null;

            var br = switch (pin.downOverflow(grid_size.rows - 1)) {
                .offset => |v| v,
                .overflow => |v| v.end,
            };
            br.x = @intCast(@min(
                // We need to sub one here because the x value is
                // one width already. So if the image is width "1"
                // then we add zero to X because X itself is width 1.
                @as(u32, pin.x) +| (grid_size.cols - 1),
                @as(u32, t.cols) - 1,
            ));

            return .{
                .top_left = pin.*,
                .bottom_right = br,
            };
        }
    };
};

// Our pin for the placement
fn trackPin(
    t: *terminal.Terminal,
    pt: point.Coordinate,
) !*PageList.Pin {
    return try t.screens.active.pages.trackPin(t.screens.active.pages.pin(.{
        .active = pt,
    }).?);
}

test "storage: add placement with zero placement id" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(alloc, .{ .cols = 100, .rows = 100 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 100;

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(alloc, t.screens.active, .{ .id = 1, .width = 50, .height = 50 });
    try s.addImage(alloc, t.screens.active, .{ .id = 2, .width = 25, .height = 25 });
    try s.addPlacement(alloc, t.screens.active, 1, 0, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 25, .y = 25 }) } });
    try s.addPlacement(alloc, t.screens.active, 1, 0, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 25, .y = 25 }) } });

    try testing.expectEqual(@as(usize, 2), s.placements.count());
    try testing.expectEqual(@as(usize, 2), s.images.count());

    // verify the placement is what we expect
    try testing.expect(s.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .internal, .id = 0 },
    }) != null);
    try testing.expect(s.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .internal, .id = 1 },
    }) != null);
}

test "storage: replacing placement releases tracked pin" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(alloc, .{ .cols = 3, .rows = 3 });
    defer t.deinit(alloc);

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(alloc, t.screens.active, .{ .id = 1 });

    const tracked = t.screens.active.pages.countTrackedPins();
    try s.addPlacement(alloc, t.screens.active, 1, 1, .{
        .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) },
    });
    try testing.expectEqual(
        tracked + 1,
        t.screens.active.pages.countTrackedPins(),
    );

    // The same image and placement ID replaces the placement, and the pin
    // of the replaced one is untracked.
    const replacement_pin = try trackPin(&t, .{ .x = 2, .y = 2 });
    try s.addPlacement(alloc, t.screens.active, 1, 1, .{
        .location = .{ .pin = replacement_pin },
    });
    try testing.expectEqual(@as(usize, 1), s.placements.count());
    try testing.expectEqual(
        tracked + 1,
        t.screens.active.pages.countTrackedPins(),
    );
    try testing.expectEqual(
        replacement_pin,
        s.placements.get(.{
            .image_id = 1,
            .placement_id = .{ .tag = .external, .id = 1 },
        }).?.location.pin,
    );
}

test "storage: eviction releases placement pins" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);

    // Room for two 64-byte images but not three. A third image needs 42
    // bytes back, and eviction stops at the first image that frees enough,
    // so only image 1 goes.
    var s: ImageStorage = .{ .total_limit = 150 };
    defer s.deinit(alloc, t.screens.active);

    // Equal transmit times evict in ID order.
    const time = try std.time.Instant.now();
    const tracked = t.screens.active.pages.countTrackedPins();
    try s.addImage(alloc, t.screens.active, .{
        .id = 1,
        .data = try alloc.dupe(u8, "*" ** 64),
        .transmit_time = time,
    });
    try s.addPlacement(alloc, t.screens.active, 1, 1, .{
        .location = .{ .pin = try trackPin(&t, .{ .x = 0, .y = 0 }) },
    });
    try s.addImage(alloc, t.screens.active, .{
        .id = 2,
        .data = try alloc.dupe(u8, "*" ** 64),
        .transmit_time = time,
    });
    try s.addPlacement(alloc, t.screens.active, 2, 1, .{
        .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) },
    });
    try testing.expectEqual(tracked + 2, t.screens.active.pages.countTrackedPins());

    // Adding a third image evicts image 1 and its placement. Image 2's
    // placement and tracked pin remain.
    try s.addImage(alloc, t.screens.active, .{
        .id = 3,
        .data = try alloc.dupe(u8, "*" ** 64),
        .transmit_time = time,
    });
    try testing.expect(!s.images.contains(1));
    try testing.expect(s.images.contains(2));
    try testing.expect(s.images.contains(3));
    try testing.expectEqual(@as(usize, 1), s.placements.count());
    try testing.expect(s.placements.contains(.{
        .image_id = 2,
        .placement_id = .{ .tag = .external, .id = 1 },
    }));
    try testing.expectEqual(tracked + 1, t.screens.active.pages.countTrackedPins());
}

test "storage: adding placement reclaims garbage placements" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(alloc, .{ .cols = 3, .rows = 3 });
    defer t.deinit(alloc);

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(alloc, t.screens.active, .{ .id = 1 });

    const tracked = t.screens.active.pages.countTrackedPins();
    const old_pin = try trackPin(&t, .{ .x = 0, .y = 0 });
    try s.addPlacement(alloc, t.screens.active, 1, 0, .{
        .location = .{ .pin = old_pin },
    });
    try s.addPlacement(alloc, t.screens.active, 1, 0, .{
        .location = .{ .virtual = {} },
    });
    old_pin.garbage = true;

    const new_pin = try trackPin(&t, .{ .x = 1, .y = 1 });
    try s.addPlacement(alloc, t.screens.active, 1, 0, .{
        .location = .{ .pin = new_pin },
    });

    // The garbage placement is gone with its pin; the virtual one stays.
    try testing.expectEqual(@as(usize, 2), s.placements.count());
    try testing.expect(s.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .internal, .id = 1 },
    }).?.location == .virtual);
    try testing.expectEqual(
        tracked + 1,
        t.screens.active.pages.countTrackedPins(),
    );
    try testing.expectEqual(
        new_pin,
        s.placements.get(.{
            .image_id = 1,
            .placement_id = .{ .tag = .internal, .id = 2 },
        }).?.location.pin,
    );
}

test "storage: placement whose rows were pruned has no rect and is reclaimed" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // A one-byte scrollback limit leaves the page list its minimum of one
    // page beyond the active area, so scrolling soon prunes the oldest page.
    var t = try terminal.Terminal.init(alloc, .{
        .cols = 10,
        .rows = 3,
        .max_scrollback = 1,
    });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 60;

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    const img: Image = .{ .id = 1, .width = 10, .height = 20 };
    try s.addImage(alloc, t.screens.active, img);

    const tracked = t.screens.active.pages.countTrackedPins();
    const pin = try trackPin(&t, .{ .x = 0, .y = 0 });
    try s.addPlacement(alloc, t.screens.active, 1, 0, .{
        .location = .{ .pin = pin },
    });
    const placement = s.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .internal, .id = 0 },
    }).?;
    try testing.expect(placement.rect(img, &t) != null);

    // Scroll the placement's row out of the retained history.
    t.screens.active.cursorAbsolute(0, t.rows - 1);
    for (0..100_000) |_| {
        if (pin.garbage) break;
        try t.index();
    } else return error.TestUnexpectedResult;

    // The page list moved the pin to the top-left of the oldest remaining
    // page, so it still resolves to a screen point (the renderer unwraps
    // pointFromPin for placement pins), but the image was never there.
    try testing.expect(t.screens.active.pages.pointFromPin(.screen, pin.*) != null);
    try testing.expect(placement.rect(img, &t) == null);

    // The next placement reclaims it and untracks its pin.
    try s.addPlacement(alloc, t.screens.active, 1, 0, .{
        .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) },
    });
    try testing.expectEqual(@as(usize, 1), s.placements.count());
    try testing.expectEqual(
        tracked + 1,
        t.screens.active.pages.countTrackedPins(),
    );
}

test "storage: delete all placements and images" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);
    const tracked = t.screens.active.pages.countTrackedPins();

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(alloc, t.screens.active, .{ .id = 1 });
    try s.addImage(alloc, t.screens.active, .{ .id = 2 });
    try s.addImage(alloc, t.screens.active, .{ .id = 3 });
    try s.addPlacement(alloc, t.screens.active, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });
    try s.addPlacement(alloc, t.screens.active, 2, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });

    s.dirty = false;
    s.delete(alloc, &t, .{ .all = true });
    try testing.expect(s.dirty);
    try testing.expectEqual(@as(usize, 0), s.images.count());
    try testing.expectEqual(@as(usize, 0), s.placements.count());
    try testing.expectEqual(tracked, t.screens.active.pages.countTrackedPins());
}

test "storage: delete all placements and images preserves limit" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);
    const tracked = t.screens.active.pages.countTrackedPins();

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    s.total_limit = 5000;
    try s.addImage(alloc, t.screens.active, .{ .id = 1 });
    try s.addImage(alloc, t.screens.active, .{ .id = 2 });
    try s.addImage(alloc, t.screens.active, .{ .id = 3 });
    try s.addPlacement(alloc, t.screens.active, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });
    try s.addPlacement(alloc, t.screens.active, 2, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });

    s.dirty = false;
    s.delete(alloc, &t, .{ .all = true });
    try testing.expect(s.dirty);
    try testing.expectEqual(@as(usize, 0), s.images.count());
    try testing.expectEqual(@as(usize, 0), s.placements.count());
    try testing.expectEqual(@as(usize, 5000), s.total_limit);
    try testing.expectEqual(tracked, t.screens.active.pages.countTrackedPins());
}

test "storage: delete all placements" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);
    const tracked = t.screens.active.pages.countTrackedPins();

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(alloc, t.screens.active, .{ .id = 1 });
    try s.addImage(alloc, t.screens.active, .{ .id = 2 });
    try s.addImage(alloc, t.screens.active, .{ .id = 3 });
    try s.addPlacement(alloc, t.screens.active, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });
    try s.addPlacement(alloc, t.screens.active, 2, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });

    s.dirty = false;
    s.delete(alloc, &t, .{ .all = false });
    try testing.expect(s.dirty);
    try testing.expectEqual(@as(usize, 0), s.placements.count());
    try testing.expectEqual(@as(usize, 3), s.images.count());
    try testing.expectEqual(tracked, t.screens.active.pages.countTrackedPins());
}

test "storage: delete all placements by image id" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);
    const tracked = t.screens.active.pages.countTrackedPins();

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(alloc, t.screens.active, .{ .id = 1 });
    try s.addImage(alloc, t.screens.active, .{ .id = 2 });
    try s.addImage(alloc, t.screens.active, .{ .id = 3 });
    try s.addPlacement(alloc, t.screens.active, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });
    try s.addPlacement(alloc, t.screens.active, 2, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });

    s.dirty = false;
    s.delete(alloc, &t, .{ .id = .{ .image_id = 2 } });
    try testing.expect(s.dirty);
    try testing.expectEqual(@as(usize, 1), s.placements.count());
    try testing.expectEqual(@as(usize, 3), s.images.count());
    try testing.expectEqual(tracked + 1, t.screens.active.pages.countTrackedPins());
}

test "storage: delete all placements by image id and unused images" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);
    const tracked = t.screens.active.pages.countTrackedPins();

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(alloc, t.screens.active, .{ .id = 1 });
    try s.addImage(alloc, t.screens.active, .{ .id = 2 });
    try s.addImage(alloc, t.screens.active, .{ .id = 3 });
    try s.addPlacement(alloc, t.screens.active, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });
    try s.addPlacement(alloc, t.screens.active, 2, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });

    s.dirty = false;
    s.delete(alloc, &t, .{ .id = .{ .delete = true, .image_id = 2 } });
    try testing.expect(s.dirty);
    try testing.expectEqual(@as(usize, 1), s.placements.count());
    try testing.expectEqual(@as(usize, 2), s.images.count());
    try testing.expectEqual(tracked + 1, t.screens.active.pages.countTrackedPins());
}

test "storage: delete placement by specific id" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);
    const tracked = t.screens.active.pages.countTrackedPins();

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(alloc, t.screens.active, .{ .id = 1 });
    try s.addImage(alloc, t.screens.active, .{ .id = 2 });
    try s.addImage(alloc, t.screens.active, .{ .id = 3 });
    try s.addPlacement(alloc, t.screens.active, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });
    try s.addPlacement(alloc, t.screens.active, 1, 2, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });
    try s.addPlacement(alloc, t.screens.active, 2, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });

    s.dirty = false;
    s.delete(alloc, &t, .{ .id = .{
        .delete = true,
        .image_id = 1,
        .placement_id = 2,
    } });
    try testing.expect(s.dirty);
    try testing.expectEqual(@as(usize, 2), s.placements.count());
    try testing.expectEqual(@as(usize, 3), s.images.count());
    try testing.expectEqual(tracked + 2, t.screens.active.pages.countTrackedPins());
}

test "storage: delete intersecting cursor" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(alloc, .{ .rows = 100, .cols = 100 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 100;
    const tracked = t.screens.active.pages.countTrackedPins();

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(alloc, t.screens.active, .{ .id = 1, .width = 50, .height = 50 });
    try s.addImage(alloc, t.screens.active, .{ .id = 2, .width = 25, .height = 25 });
    try s.addPlacement(alloc, t.screens.active, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 0, .y = 0 }) } });
    try s.addPlacement(alloc, t.screens.active, 1, 2, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 25, .y = 25 }) } });

    t.screens.active.cursorAbsolute(12, 12);

    s.dirty = false;
    s.delete(alloc, &t, .{ .intersect_cursor = false });
    try testing.expect(s.dirty);
    try testing.expectEqual(@as(usize, 1), s.placements.count());
    try testing.expectEqual(@as(usize, 2), s.images.count());
    try testing.expectEqual(tracked + 1, t.screens.active.pages.countTrackedPins());

    // verify the placement is what we expect
    try testing.expect(s.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 2 },
    }) != null);
}

test "storage: delete intersecting cursor checks interior row column" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(alloc, .{ .rows = 100, .cols = 100 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 100;
    const tracked = t.screens.active.pages.countTrackedPins();

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(alloc, t.screens.active, .{ .id = 1, .width = 10, .height = 10 });
    try s.addPlacement(alloc, t.screens.active, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 0, .y = 0 }) } });
    try s.addPlacement(alloc, t.screens.active, 1, 2, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 20, .y = 0 }) } });

    // This is inside the right placement and on an interior row shared by
    // both placements, but it is outside the left placement's columns.
    t.screens.active.cursorAbsolute(21, 5);
    s.delete(alloc, &t, .{ .intersect_cursor = false });

    try testing.expectEqual(@as(usize, 1), s.placements.count());
    try testing.expect(s.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 1 },
    }) != null);
    try testing.expectEqual(tracked + 1, t.screens.active.pages.countTrackedPins());
}

test "storage: delete intersecting cell checks interior row column" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(alloc, .{ .rows = 100, .cols = 100 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 100;
    const tracked = t.screens.active.pages.countTrackedPins();

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(alloc, t.screens.active, .{ .id = 1, .width = 10, .height = 10 });
    try s.addPlacement(alloc, t.screens.active, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 0, .y = 0 }) } });
    try s.addPlacement(alloc, t.screens.active, 1, 2, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 20, .y = 0 }) } });

    // Protocol coordinates are one-based, so this targets grid cell (21, 5).
    s.delete(alloc, &t, .{ .intersect_cell = .{
        .x = 22,
        .y = 6,
    } });

    try testing.expectEqual(@as(usize, 1), s.placements.count());
    try testing.expect(s.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 1 },
    }) != null);
    try testing.expectEqual(tracked + 1, t.screens.active.pages.countTrackedPins());
}

test "storage: delete intersecting cursor plus unused" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(alloc, .{ .rows = 100, .cols = 100 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 100;
    const tracked = t.screens.active.pages.countTrackedPins();

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(alloc, t.screens.active, .{ .id = 1, .width = 50, .height = 50 });
    try s.addImage(alloc, t.screens.active, .{ .id = 2, .width = 25, .height = 25 });
    try s.addPlacement(alloc, t.screens.active, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 0, .y = 0 }) } });
    try s.addPlacement(alloc, t.screens.active, 1, 2, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 25, .y = 25 }) } });

    t.screens.active.cursorAbsolute(12, 12);

    s.dirty = false;
    s.delete(alloc, &t, .{ .intersect_cursor = true });
    try testing.expect(s.dirty);
    try testing.expectEqual(@as(usize, 1), s.placements.count());
    try testing.expectEqual(@as(usize, 2), s.images.count());
    try testing.expectEqual(tracked + 1, t.screens.active.pages.countTrackedPins());

    // verify the placement is what we expect
    try testing.expect(s.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 2 },
    }) != null);
}

test "storage: delete intersecting cursor hits multiple" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(alloc, .{ .rows = 100, .cols = 100 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 100;
    const tracked = t.screens.active.pages.countTrackedPins();

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(alloc, t.screens.active, .{ .id = 1, .width = 50, .height = 50 });
    try s.addImage(alloc, t.screens.active, .{ .id = 2, .width = 25, .height = 25 });
    try s.addPlacement(alloc, t.screens.active, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 0, .y = 0 }) } });
    try s.addPlacement(alloc, t.screens.active, 1, 2, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 25, .y = 25 }) } });

    t.screens.active.cursorAbsolute(26, 26);

    s.dirty = false;
    s.delete(alloc, &t, .{ .intersect_cursor = true });
    try testing.expect(s.dirty);
    try testing.expectEqual(@as(usize, 0), s.placements.count());
    try testing.expectEqual(@as(usize, 1), s.images.count());
    try testing.expectEqual(tracked, t.screens.active.pages.countTrackedPins());
}

test "storage: delete by column" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(alloc, .{ .rows = 100, .cols = 100 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 100;
    const tracked = t.screens.active.pages.countTrackedPins();

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(alloc, t.screens.active, .{ .id = 1, .width = 50, .height = 50 });
    try s.addImage(alloc, t.screens.active, .{ .id = 2, .width = 25, .height = 25 });
    try s.addPlacement(alloc, t.screens.active, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 0, .y = 0 }) } });
    try s.addPlacement(alloc, t.screens.active, 1, 2, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 25, .y = 25 }) } });

    s.dirty = false;
    s.delete(alloc, &t, .{ .column = .{
        .delete = false,
        .x = 60,
    } });
    try testing.expect(s.dirty);
    try testing.expectEqual(@as(usize, 1), s.placements.count());
    try testing.expectEqual(@as(usize, 2), s.images.count());
    try testing.expectEqual(tracked + 1, t.screens.active.pages.countTrackedPins());

    // verify the placement is what we expect
    try testing.expect(s.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 1 },
    }) != null);
}

test "storage: delete by column 1x1" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(alloc, .{ .rows = 100, .cols = 100 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 100;

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(alloc, t.screens.active, .{ .id = 1, .width = 1, .height = 1 });
    try s.addPlacement(alloc, t.screens.active, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 0, .y = 0 }) } });
    try s.addPlacement(alloc, t.screens.active, 1, 2, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 0 }) } });
    try s.addPlacement(alloc, t.screens.active, 1, 3, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 2, .y = 0 }) } });

    s.delete(alloc, &t, .{ .column = .{
        .delete = false,
        .x = 2,
    } });
    try testing.expectEqual(@as(usize, 2), s.placements.count());
    try testing.expectEqual(@as(usize, 1), s.images.count());

    // verify the placement is what we expect
    try testing.expect(s.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 1 },
    }) != null);
    try testing.expect(s.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 3 },
    }) != null);
}

test "storage: delete by row" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(alloc, .{ .rows = 100, .cols = 100 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 100;
    const tracked = t.screens.active.pages.countTrackedPins();

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(alloc, t.screens.active, .{ .id = 1, .width = 50, .height = 50 });
    try s.addImage(alloc, t.screens.active, .{ .id = 2, .width = 25, .height = 25 });
    try s.addPlacement(alloc, t.screens.active, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 0, .y = 0 }) } });
    try s.addPlacement(alloc, t.screens.active, 1, 2, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 25, .y = 25 }) } });

    s.dirty = false;
    s.delete(alloc, &t, .{ .row = .{
        .delete = false,
        .y = 60,
    } });
    try testing.expect(s.dirty);
    try testing.expectEqual(@as(usize, 1), s.placements.count());
    try testing.expectEqual(@as(usize, 2), s.images.count());
    try testing.expectEqual(tracked + 1, t.screens.active.pages.countTrackedPins());

    // verify the placement is what we expect
    try testing.expect(s.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 1 },
    }) != null);
}

test "storage: delete by row 1x1" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(alloc, .{ .rows = 100, .cols = 100 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 100;

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(alloc, t.screens.active, .{ .id = 1, .width = 1, .height = 1 });
    try s.addPlacement(alloc, t.screens.active, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .y = 0 }) } });
    try s.addPlacement(alloc, t.screens.active, 1, 2, .{ .location = .{ .pin = try trackPin(&t, .{ .y = 1 }) } });
    try s.addPlacement(alloc, t.screens.active, 1, 3, .{ .location = .{ .pin = try trackPin(&t, .{ .y = 2 }) } });

    s.delete(alloc, &t, .{ .row = .{
        .delete = false,
        .y = 2,
    } });
    try testing.expectEqual(@as(usize, 2), s.placements.count());
    try testing.expectEqual(@as(usize, 1), s.images.count());

    // verify the placement is what we expect
    try testing.expect(s.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 1 },
    }) != null);
    try testing.expect(s.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 3 },
    }) != null);
}

test "storage: delete images by range 1" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);
    const tracked = t.screens.active.pages.countTrackedPins();

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(alloc, t.screens.active, .{ .id = 1 });
    try s.addImage(alloc, t.screens.active, .{ .id = 2 });
    try s.addImage(alloc, t.screens.active, .{ .id = 3 });
    try s.addPlacement(alloc, t.screens.active, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });
    try s.addPlacement(alloc, t.screens.active, 2, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });
    try testing.expectEqual(@as(usize, 3), s.images.count());
    try testing.expectEqual(@as(usize, 2), s.placements.count());

    s.dirty = false;
    s.delete(alloc, &t, .{ .range = .{ .delete = false, .first = 1, .last = 2 } });
    try testing.expect(s.dirty);
    try testing.expectEqual(@as(usize, 3), s.images.count());
    try testing.expectEqual(@as(usize, 0), s.placements.count());
    try testing.expectEqual(tracked, t.screens.active.pages.countTrackedPins());
}

test "storage: delete images by range 2" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);
    const tracked = t.screens.active.pages.countTrackedPins();

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(alloc, t.screens.active, .{ .id = 1 });
    try s.addImage(alloc, t.screens.active, .{ .id = 2 });
    try s.addImage(alloc, t.screens.active, .{ .id = 3 });
    try s.addPlacement(alloc, t.screens.active, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });
    try s.addPlacement(alloc, t.screens.active, 2, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });
    try testing.expectEqual(@as(usize, 3), s.images.count());
    try testing.expectEqual(@as(usize, 2), s.placements.count());

    s.dirty = false;
    s.delete(alloc, &t, .{ .range = .{ .delete = true, .first = 1, .last = 2 } });
    try testing.expect(s.dirty);
    try testing.expectEqual(@as(usize, 1), s.images.count());
    try testing.expectEqual(@as(usize, 0), s.placements.count());
    try testing.expectEqual(tracked, t.screens.active.pages.countTrackedPins());
}

test "storage: delete images by range 3" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);
    const tracked = t.screens.active.pages.countTrackedPins();

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(alloc, t.screens.active, .{ .id = 1 });
    try s.addImage(alloc, t.screens.active, .{ .id = 2 });
    try s.addImage(alloc, t.screens.active, .{ .id = 3 });
    try s.addPlacement(alloc, t.screens.active, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });
    try s.addPlacement(alloc, t.screens.active, 2, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });
    try s.addPlacement(alloc, t.screens.active, 3, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });
    try testing.expectEqual(@as(usize, 3), s.images.count());
    try testing.expectEqual(@as(usize, 3), s.placements.count());

    s.dirty = false;
    // Only image 2 is inside the range: the placements below and above it
    // stay, and so do their pins.
    s.delete(alloc, &t, .{ .range = .{ .delete = false, .first = 2, .last = 2 } });
    try testing.expect(s.dirty);
    try testing.expectEqual(@as(usize, 3), s.images.count());
    try testing.expectEqual(@as(usize, 2), s.placements.count());
    try testing.expect(s.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 1 },
    }) != null);
    try testing.expect(s.placements.get(.{
        .image_id = 3,
        .placement_id = .{ .tag = .external, .id = 1 },
    }) != null);
    try testing.expectEqual(tracked + 2, t.screens.active.pages.countTrackedPins());
}

test "storage: delete images by range 4" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);
    const tracked = t.screens.active.pages.countTrackedPins();

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(alloc, t.screens.active, .{ .id = 1 });
    try s.addImage(alloc, t.screens.active, .{ .id = 2 });
    try s.addImage(alloc, t.screens.active, .{ .id = 3 });
    try s.addPlacement(alloc, t.screens.active, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });
    try s.addPlacement(alloc, t.screens.active, 2, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });
    try s.addPlacement(alloc, t.screens.active, 3, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });
    try testing.expectEqual(@as(usize, 3), s.images.count());
    try testing.expectEqual(@as(usize, 3), s.placements.count());

    s.dirty = false;
    // Only image 2 is inside the range: the placements below and above it
    // stay, and so do their pins.
    s.delete(alloc, &t, .{ .range = .{ .delete = true, .first = 2, .last = 2 } });
    try testing.expect(s.dirty);
    try testing.expectEqual(@as(usize, 2), s.images.count());
    try testing.expectEqual(@as(usize, 2), s.placements.count());
    try testing.expect(s.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 1 },
    }) != null);
    try testing.expect(s.placements.get(.{
        .image_id = 3,
        .placement_id = .{ .tag = .external, .id = 1 },
    }) != null);
    try testing.expectEqual(tracked + 2, t.screens.active.pages.countTrackedPins());
}

test "storage: aspect ratio calculation when only columns or rows specified" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t = try terminal.Terminal.init(alloc, .{ .cols = 100, .rows = 100 });
    defer t.deinit(alloc);
    t.width_px = 1000; // 10 px per col
    t.height_px = 2000; // 20 px per row

    // Case 1: Only columns specified
    {
        const image = Image{ .id = 1, .width = 16, .height = 9 };
        var placement = ImageStorage.Placement{
            .location = .{ .virtual = {} },
            .columns = 10,
            .rows = 0,
        };

        // Image is 16x9, set to a width of 10 columns, at 10px per column
        // that's 100px width. 100px * (9 / 16) = 56.25, which should round
        // to a height of 56px.

        const calc_size = placement.calculatedSize(image, &t);
        try testing.expectEqual(@as(u32, 100), calc_size.width);
        try testing.expectEqual(@as(u32, 56), calc_size.height);
    }

    // Case 2: Only rows specified
    {
        const image = Image{ .id = 2, .width = 16, .height = 9 };
        var placement = ImageStorage.Placement{
            .location = .{ .virtual = {} },
            .columns = 0,
            .rows = 5,
        };

        // Image is 16x9, set to a height of 5 rows, at 20px per row that's
        // 100px height. 100px * (16 / 9) = 177.77..., which should round to
        // a width of 178px.

        const calc_size = placement.calculatedSize(image, &t);
        try testing.expectEqual(@as(u32, 178), calc_size.width);
        try testing.expectEqual(@as(u32, 100), calc_size.height);
    }
}

test "storage: cell offsets stay within explicit destination rectangle" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t = try terminal.Terminal.init(alloc, .{ .cols = 5, .rows = 5 });
    defer t.deinit(alloc);
    t.width_px = 50; // 10 px per col
    t.height_px = 100; // 20 px per row

    // Explicit columns and rows describe the far cell boundaries. Offsets
    // move the near edge inward without moving those far edges.
    const placement: ImageStorage.Placement = .{
        .location = .{ .virtual = {} },
        .x_offset = 3,
        .y_offset = 4,
        .columns = 2,
        .rows = 1,
    };
    const actual = placement.calculatedSize(.{ .width = 4, .height = 3 }, &t);
    try testing.expectEqual(@as(u32, 17), actual.width);
    try testing.expectEqual(@as(u32, 16), actual.height);
    try testing.expectEqual(@as(u32, 2), placement.gridSize(.{ .width = 4, .height = 3 }, &t).cols);
    try testing.expectEqual(@as(u32, 1), placement.gridSize(.{ .width = 4, .height = 3 }, &t).rows);
}

test "storage: cell offsets clamp to cell bounds" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t = try terminal.Terminal.init(alloc, .{ .cols = 5, .rows = 5 });
    defer t.deinit(alloc);
    t.width_px = 50; // 10 px per col
    t.height_px = 100; // 20 px per row

    const placement: ImageStorage.Placement = .{
        .location = .{ .virtual = {} },
        .x_offset = std.math.maxInt(u32),
        .y_offset = std.math.maxInt(u32),
        .columns = 1,
        .rows = 1,
    };
    const offset = placement.cellOffset(&t);
    try testing.expectEqual(@as(u32, 9), offset.x);
    try testing.expectEqual(@as(u32, 19), offset.y);

    // Even hostile offsets leave one pixel inside the requested cell.
    const actual = placement.calculatedSize(.{ .width = 1, .height = 1 }, &t);
    try testing.expectEqual(@as(u32, 1), actual.width);
    try testing.expectEqual(@as(u32, 1), actual.height);
}

test "storage: default source rectangle is intersected before sizing" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t = try terminal.Terminal.init(alloc, .{ .cols = 5, .rows = 5 });
    defer t.deinit(alloc);

    const placement: ImageStorage.Placement = .{
        .location = .{ .virtual = {} },
        .source_x = 3,
        .source_y = 1,
    };
    const actual = placement.calculatedSize(.{ .width = 4, .height = 3 }, &t);
    try testing.expectEqual(@as(u32, 1), actual.width);
    try testing.expectEqual(@as(u32, 2), actual.height);
}

test "storage: explicit source rectangle is intersected before sizing" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t = try terminal.Terminal.init(alloc, .{ .cols = 10, .rows = 10 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 100;

    // The requested 8x8 rectangle intersects this 10x10 image as 2x3.
    // With a two-column destination, the clipped 2:3 aspect ratio produces
    // a 20x30 pixel destination.
    const placement: ImageStorage.Placement = .{
        .location = .{ .virtual = {} },
        .source_x = 8,
        .source_y = 7,
        .source_width = 8,
        .source_height = 8,
        .columns = 2,
    };
    const actual = placement.calculatedSize(.{ .width = 10, .height = 10 }, &t);
    try testing.expectEqual(@as(u32, 20), actual.width);
    try testing.expectEqual(@as(u32, 30), actual.height);
}

test "storage: placement geometry handles untrusted dimensions" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const max = std.math.maxInt(u32);

    var t = try terminal.Terminal.init(alloc, .{ .cols = 2, .rows = 2 });
    defer t.deinit(alloc);
    t.width_px = max;
    t.height_px = max;

    // Cell dimensions multiplied by protocol-controlled row and column
    // counts saturate instead of panicking or wrapping.
    {
        const placement: ImageStorage.Placement = .{
            .location = .{ .virtual = {} },
            .columns = 3,
            .rows = 3,
        };
        const actual = placement.calculatedSize(.{ .width = 1, .height = 1 }, &t);
        try testing.expectEqual(max, actual.width);
        try testing.expectEqual(max, actual.height);
    }

    // Aspect-ratio scaling also saturates when the derived dimension does
    // not fit in the u32 geometry type.
    {
        const placement: ImageStorage.Placement = .{
            .location = .{ .virtual = {} },
            .columns = 3,
            .source_height = max,
        };
        const actual = placement.calculatedSize(.{ .width = 1, .height = 1 }, &t);
        try testing.expectEqual(max, actual.width);
        try testing.expectEqual(max, actual.height);
    }
    {
        const placement: ImageStorage.Placement = .{
            .location = .{ .virtual = {} },
            .rows = 3,
            .source_width = max,
        };
        const actual = placement.calculatedSize(.{ .width = 1, .height = 1 }, &t);
        try testing.expectEqual(max, actual.width);
        try testing.expectEqual(max, actual.height);
    }

    // Pixel offsets are protocol-controlled too. Clamp them to the cell
    // before including them in grid geometry.
    t.width_px = 2;
    t.height_px = 2;
    {
        const placement: ImageStorage.Placement = .{
            .location = .{ .virtual = {} },
            .x_offset = max,
            .y_offset = max,
        };
        const actual = placement.gridSize(.{ .width = 1, .height = 1 }, &t);
        try testing.expectEqual(@as(u32, 1), actual.cols);
        try testing.expectEqual(@as(u32, 1), actual.rows);
    }

    const pin = try trackPin(&t, .{ .x = 0, .y = 0 });
    defer t.screens.active.pages.untrackPin(pin);

    // Explicit maximum dimensions must clamp the rectangle to the terminal
    // without overflowing its horizontal extent.
    {
        const placement: ImageStorage.Placement = .{
            .location = .{ .pin = pin },
            .columns = max,
            .rows = 1,
        };
        const rect = placement.rect(.{ .width = 1, .height = 1 }, &t).?;
        try testing.expectEqual(@as(size.CellCountInt, 1), rect.bottom_right.x);
    }

    // Terminals can temporarily have no pixel geometry. A placement whose
    // computed grid is empty has no rectangle, so rect must not subtract one
    // from a zero row count.
    t.width_px = 0;
    t.height_px = 0;
    {
        const placement: ImageStorage.Placement = .{
            .location = .{ .pin = pin },
            .columns = 1,
        };
        const actual = placement.gridSize(.{ .width = 1, .height = 1 }, &t);
        try testing.expectEqual(@as(u32, 0), actual.cols);
        try testing.expectEqual(@as(u32, 0), actual.rows);
        try testing.expect(placement.rect(.{ .width = 1, .height = 1 }, &t) == null);
    }
}

test "storage: aspect scaling of an untrusted source size with ordinary cells" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const max = std.math.maxInt(u32);

    var t = try terminal.Terminal.init(alloc, .{ .cols = 2, .rows = 2 });
    defer t.deinit(alloc);
    t.width_px = 20; // 10 px per col
    t.height_px = 40; // 20 px per row

    // The cell size times one column or row fits, but the side scaled by
    // the aspect ratio of a 4294967295 px dimension does not. The source
    // rectangle is intersected with the image, so the dimension is the
    // image's.
    {
        const placement: ImageStorage.Placement = .{
            .location = .{ .virtual = {} },
            .columns = 1,
            .source_height = max,
        };
        const actual = placement.calculatedSize(.{ .width = 1, .height = max }, &t);
        try testing.expectEqual(@as(u32, 10), actual.width);
        try testing.expectEqual(max, actual.height);
    }
    {
        const placement: ImageStorage.Placement = .{
            .location = .{ .virtual = {} },
            .rows = 1,
            .source_width = max,
        };
        const actual = placement.calculatedSize(.{ .width = max, .height = 1 }, &t);
        try testing.expectEqual(max, actual.width);
        try testing.expectEqual(@as(u32, 20), actual.height);
    }
}

test "storage: placement rect with an empty or maximum grid" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t = try terminal.Terminal.init(alloc, .{ .cols = 10, .rows = 10 });
    defer t.deinit(alloc);
    t.width_px = 100; // 10 px per col
    t.height_px = 200; // 20 px per row

    const pin = try trackPin(&t, .{ .x = 5, .y = 0 });
    defer t.screens.active.pages.untrackPin(pin);

    // With ordinary cell metrics, scaling a very wide, one-pixel-tall
    // image to one column rounds its height to zero pixels: no row.
    {
        const image: Image = .{ .id = 1, .width = 10000, .height = 1 };
        const placement: ImageStorage.Placement = .{
            .location = .{ .pin = pin },
            .columns = 1,
        };
        const grid = placement.gridSize(image, &t);
        try testing.expectEqual(@as(u32, 1), grid.cols);
        try testing.expectEqual(@as(u32, 0), grid.rows);
        try testing.expect(placement.rect(image, &t) == null);
    }

    // The same for a very tall, one-pixel-wide image scaled to one row:
    // no column.
    {
        const image: Image = .{ .id = 1, .width = 1, .height = 10000 };
        const placement: ImageStorage.Placement = .{
            .location = .{ .pin = pin },
            .rows = 1,
        };
        const grid = placement.gridSize(image, &t);
        try testing.expectEqual(@as(u32, 0), grid.cols);
        try testing.expectEqual(@as(u32, 1), grid.rows);
        try testing.expect(placement.rect(image, &t) == null);
    }

    // The maximum column count from a pin past the second column clamps to
    // the last column instead of overflowing.
    {
        const image: Image = .{ .id = 1, .width = 1, .height = 1 };
        const placement: ImageStorage.Placement = .{
            .location = .{ .pin = pin },
            .columns = std.math.maxInt(u32),
            .rows = 1,
        };
        const rect = placement.rect(image, &t).?;
        try testing.expectEqual(@as(size.CellCountInt, 5), rect.top_left.x);
        try testing.expectEqual(@as(size.CellCountInt, 9), rect.bottom_right.x);
    }
}

/// Test helper: the placement stored under an external placement ID.
fn testPlacement(
    t: *terminal.Terminal,
    image_id: u32,
    placement_id: u32,
) ?ImageStorage.Placement {
    return t.screens.active.kitty_images.placements.get(.{
        .image_id = image_id,
        .placement_id = .{ .tag = .external, .id = placement_id },
    });
}

/// Test helper: where a pin placement is anchored in the active area, or
/// null when it is gone or anchored outside the active area.
fn testActiveCoord(
    t: *terminal.Terminal,
    image_id: u32,
    placement_id: u32,
) ?point.Coordinate {
    const p = testPlacement(t, image_id, placement_id) orelse return null;
    const pin = switch (p.location) {
        .pin => |pin| pin,
        .virtual => return null,
    };
    const pt = t.screens.active.pages.pointFromPin(.active, pin.*) orelse return null;
    return pt.coord();
}

test "storage: scroll margins placement inside region scrolls and clips at top" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(alloc, .{ .cols = 10, .rows = 6 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 60;

    // 2-row image (10x10px cells) inside the region (rows 1-4).
    const storage: *ImageStorage = &t.screens.active.kitty_images;
    try storage.addImage(alloc, t.screens.active, .{
        .id = 1,
        .width = 10,
        .height = 20,
    });
    const tracked = t.screens.active.pages.countTrackedPins();
    try storage.addPlacement(alloc, t.screens.active, 1, 1, .{
        .location = .{ .pin = try trackPin(&t, .{ .x = 0, .y = 2 }) },
    });
    t.setTopAndBottomMargin(2, 5);
    t.setCursorPos(5, 1);

    // Entirely inside: moves up with the content.
    try t.index();
    try testing.expectEqual(
        @as(?point.Coordinate, .{ .x = 0, .y = 1 }),
        testActiveCoord(&t, 1, 1),
    );

    // Would extend above the top margin: anchored at the top margin
    // with the top cell row clipped off the source.
    try t.index();
    try testing.expectEqual(
        @as(?point.Coordinate, .{ .x = 0, .y = 1 }),
        testActiveCoord(&t, 1, 1),
    );
    {
        const p = testPlacement(&t, 1, 1) orelse return error.TestUnexpectedResult;
        try testing.expectEqual(@as(u32, 10), p.source_y);
        try testing.expectEqual(@as(u32, 10), p.source_height);
    }

    // Fully clipped: deleted, and its tracked pin released.
    try t.index();
    try testing.expectEqual(@as(usize, 0), storage.placements.count());
    try testing.expectEqual(tracked, t.screens.active.pages.countTrackedPins());
    // The image itself is retained.
    try testing.expectEqual(@as(usize, 1), storage.images.count());
}

test "storage: scroll margins placement straddling region does not move" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(alloc, .{ .cols = 10, .rows = 6 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 60;

    // 3-row image anchored at the top of a 2-row region: not entirely
    // within the region, so region scrolls must not move it. This
    // exercises the scrollback-creating path (region top at row 0).
    const storage: *ImageStorage = &t.screens.active.kitty_images;
    try storage.addImage(alloc, t.screens.active, .{
        .id = 1,
        .width = 10,
        .height = 30,
    });
    try storage.addPlacement(alloc, t.screens.active, 1, 1, .{
        .location = .{ .pin = try trackPin(&t, .{ .x = 0, .y = 0 }) },
    });
    t.setTopAndBottomMargin(1, 2);
    t.setCursorPos(2, 1);

    try t.index();
    try testing.expectEqual(
        @as(?point.Coordinate, .{ .x = 0, .y = 0 }),
        testActiveCoord(&t, 1, 1),
    );
    const p = testPlacement(&t, 1, 1) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u32, 0), p.source_y);
    try testing.expectEqual(@as(u32, 0), p.source_height);
}

test "storage: scroll margins placement below region does not move" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(alloc, .{ .cols = 10, .rows = 6 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 60;

    // A "status bar" image below the bottom margin must stay put while
    // the region above it scrolls (scrollback-creating path).
    const storage: *ImageStorage = &t.screens.active.kitty_images;
    try storage.addImage(alloc, t.screens.active, .{
        .id = 1,
        .width = 10,
        .height = 10,
    });
    try storage.addPlacement(alloc, t.screens.active, 1, 1, .{
        .location = .{ .pin = try trackPin(&t, .{ .x = 0, .y = 5 }) },
    });
    t.setTopAndBottomMargin(1, 4);
    t.setCursorPos(4, 1);

    try t.index();
    try t.index();
    try testing.expectEqual(
        @as(?point.Coordinate, .{ .x = 0, .y = 5 }),
        testActiveCoord(&t, 1, 1),
    );
}

test "storage: scroll margins reverse index clips at bottom" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(alloc, .{ .cols = 10, .rows = 6 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 60;

    // 2-row image at the bottom of the region (rows 1-4).
    const storage: *ImageStorage = &t.screens.active.kitty_images;
    try storage.addImage(alloc, t.screens.active, .{
        .id = 1,
        .width = 10,
        .height = 20,
    });
    const tracked = t.screens.active.pages.countTrackedPins();
    try storage.addPlacement(alloc, t.screens.active, 1, 1, .{
        .location = .{ .pin = try trackPin(&t, .{ .x = 0, .y = 3 }) },
    });
    t.setTopAndBottomMargin(2, 5);
    t.setCursorPos(2, 1);

    // Moves down, with the bottom cell row clipped off the source.
    t.reverseIndex();
    try testing.expectEqual(
        @as(?point.Coordinate, .{ .x = 0, .y = 4 }),
        testActiveCoord(&t, 1, 1),
    );
    {
        const p = testPlacement(&t, 1, 1) orelse return error.TestUnexpectedResult;
        try testing.expectEqual(@as(u32, 0), p.source_y);
        try testing.expectEqual(@as(u32, 10), p.source_height);
    }

    // Fully clipped: deleted.
    t.reverseIndex();
    try testing.expectEqual(@as(usize, 0), storage.placements.count());
    try testing.expectEqual(tracked, t.screens.active.pages.countTrackedPins());
}

test "storage: scroll margins scaled placement clips proportionally" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(alloc, .{ .cols = 10, .rows = 6 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 60;

    // A 40px-tall image scaled into 2 rows, inside a 2-row region.
    const storage: *ImageStorage = &t.screens.active.kitty_images;
    try storage.addImage(alloc, t.screens.active, .{
        .id = 1,
        .width = 10,
        .height = 40,
    });
    try storage.addPlacement(alloc, t.screens.active, 1, 1, .{
        .location = .{ .pin = try trackPin(&t, .{ .x = 0, .y = 1 }) },
        .columns = 1,
        .rows = 2,
    });
    t.setTopAndBottomMargin(2, 3);
    t.setCursorPos(3, 1);

    try t.index();
    try testing.expectEqual(
        @as(?point.Coordinate, .{ .x = 0, .y = 1 }),
        testActiveCoord(&t, 1, 1),
    );
    const p = testPlacement(&t, 1, 1) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u32, 20), p.source_y);
    try testing.expectEqual(@as(u32, 20), p.source_height);
    try testing.expectEqual(@as(u32, 1), p.rows);
    try testing.expectEqual(@as(u32, 1), p.columns);
}

test "storage: scroll margins left/right margins respect columns" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(alloc, .{ .cols = 10, .rows = 6 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 60;

    // One placement outside the left/right margin columns, one inside.
    const storage: *ImageStorage = &t.screens.active.kitty_images;
    try storage.addImage(alloc, t.screens.active, .{
        .id = 1,
        .width = 10,
        .height = 10,
    });
    try storage.addPlacement(alloc, t.screens.active, 1, 1, .{
        .location = .{ .pin = try trackPin(&t, .{ .x = 0, .y = 2 }) },
    });
    try storage.addPlacement(alloc, t.screens.active, 1, 2, .{
        .location = .{ .pin = try trackPin(&t, .{ .x = 2, .y = 2 }) },
    });

    t.modes.set(.enable_left_and_right_margin, true);
    t.setLeftAndRightMargin(2, 8);

    try t.scrollUp(1);

    // Outside the margin columns: stays.
    try testing.expectEqual(
        @as(?point.Coordinate, .{ .x = 0, .y = 2 }),
        testActiveCoord(&t, 1, 1),
    );

    // Inside: moves up.
    try testing.expectEqual(
        @as(?point.Coordinate, .{ .x = 2, .y = 1 }),
        testActiveCoord(&t, 1, 2),
    );
}

test "storage: scroll margins insert/delete lines do not move placements" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(alloc, .{ .cols = 10, .rows = 6 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 60;

    // Kitty does not scroll images for IL/DL, only for IND/RI/SU/SD.
    const storage: *ImageStorage = &t.screens.active.kitty_images;
    try storage.addImage(alloc, t.screens.active, .{
        .id = 1,
        .width = 10,
        .height = 10,
    });
    try storage.addPlacement(alloc, t.screens.active, 1, 1, .{
        .location = .{ .pin = try trackPin(&t, .{ .x = 0, .y = 2 }) },
    });
    t.setTopAndBottomMargin(2, 5);
    t.setCursorPos(2, 1);

    t.deleteLines(1);
    try testing.expectEqual(
        @as(?point.Coordinate, .{ .x = 0, .y = 2 }),
        testActiveCoord(&t, 1, 1),
    );

    t.insertLines(1);
    try testing.expectEqual(
        @as(?point.Coordinate, .{ .x = 0, .y = 2 }),
        testActiveCoord(&t, 1, 1),
    );
}

test "storage: scroll without margins moves placement into scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(alloc, .{ .cols = 10, .rows = 6 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 60;

    // No margins: the placement follows its anchored row into the
    // scrollback via pin tracking (kitty's marginless behavior).
    const storage: *ImageStorage = &t.screens.active.kitty_images;
    try storage.addImage(alloc, t.screens.active, .{
        .id = 1,
        .width = 10,
        .height = 20,
    });
    try storage.addPlacement(alloc, t.screens.active, 1, 1, .{
        .location = .{ .pin = try trackPin(&t, .{ .x = 0, .y = 0 }) },
    });
    t.setCursorPos(6, 1);

    try t.index();
    const p = testPlacement(&t, 1, 1) orelse return error.TestUnexpectedResult;
    try testing.expect(t.screens.active.pages.pointFromPin(
        .active,
        p.location.pin.*,
    ) == null);
    const pt = t.screens.active.pages.pointFromPin(.screen, p.location.pin.*) orelse
        return error.TestUnexpectedResult;
    try testing.expectEqual(point.Coordinate{ .x = 0, .y = 0 }, pt.coord());
    try testing.expectEqual(@as(u32, 0), p.source_height);
}

test "storage: scroll margins large scroll deletes inside placement" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(alloc, .{ .cols = 10, .rows = 6 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 60;

    const storage: *ImageStorage = &t.screens.active.kitty_images;
    try storage.addImage(alloc, t.screens.active, .{
        .id = 1,
        .width = 10,
        .height = 10,
    });
    const tracked = t.screens.active.pages.countTrackedPins();
    try storage.addPlacement(alloc, t.screens.active, 1, 1, .{
        .location = .{ .pin = try trackPin(&t, .{ .x = 0, .y = 2 }) },
    });
    t.setTopAndBottomMargin(2, 5);

    try t.scrollUp(10);
    try testing.expectEqual(@as(usize, 0), storage.placements.count());
    try testing.expectEqual(tracked, t.screens.active.pages.countTrackedPins());
}

test "storage: scroll margins straddling placement pin inside region restored" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(alloc, .{ .cols = 10, .rows = 6 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 60;

    // 2-row image anchored on the bottom margin row, extending below
    // the region: not entirely inside, so it must not move even though
    // the region scroll moves every tracked pin within the region rows.
    const storage: *ImageStorage = &t.screens.active.kitty_images;
    try storage.addImage(alloc, t.screens.active, .{
        .id = 1,
        .width = 10,
        .height = 20,
    });
    try storage.addPlacement(alloc, t.screens.active, 1, 1, .{
        .location = .{ .pin = try trackPin(&t, .{ .x = 0, .y = 4 }) },
    });
    t.setTopAndBottomMargin(2, 5);
    t.setCursorPos(5, 1);

    try t.index();
    try testing.expectEqual(
        @as(?point.Coordinate, .{ .x = 0, .y = 4 }),
        testActiveCoord(&t, 1, 1),
    );
    const p = testPlacement(&t, 1, 1) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u32, 0), p.source_y);
    try testing.expectEqual(@as(u32, 0), p.source_height);
}

test "storage: scroll margins multi-line scroll up with scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(alloc, .{ .cols = 10, .rows = 6 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 60;

    // 1-row image inside a region whose top is the screen top, so the
    // scroll pushes text into the scrollback (window shift) while the
    // image moves within the region.
    const storage: *ImageStorage = &t.screens.active.kitty_images;
    try storage.addImage(alloc, t.screens.active, .{
        .id = 1,
        .width = 10,
        .height = 10,
    });
    const tracked = t.screens.active.pages.countTrackedPins();
    try storage.addPlacement(alloc, t.screens.active, 1, 1, .{
        .location = .{ .pin = try trackPin(&t, .{ .x = 0, .y = 2 }) },
    });
    t.setTopAndBottomMargin(1, 4);

    try t.scrollUp(2);
    try testing.expectEqual(
        @as(?point.Coordinate, .{ .x = 0, .y = 0 }),
        testActiveCoord(&t, 1, 1),
    );

    // Another two rows scrolls it out of the region: deleted.
    try t.scrollUp(2);
    try testing.expectEqual(@as(usize, 0), storage.placements.count());
    try testing.expectEqual(tracked, t.screens.active.pages.countTrackedPins());
}

test "storage: scroll without scrollback moves placements off the top" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(alloc, .{ .cols = 10, .rows = 6 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 60;

    // The alternate screen keeps no scrollback, so a full-screen scroll
    // discards the top row instead of moving it into history.
    try t.switchScreenMode(.@"1049", true);
    try testing.expect(t.screens.active.no_scrollback);

    // A 2-row image on the top row and a 1-row image on row 3.
    const storage: *ImageStorage = &t.screens.active.kitty_images;
    try storage.addImage(alloc, t.screens.active, .{
        .id = 1,
        .width = 10,
        .height = 20,
    });
    try storage.addImage(alloc, t.screens.active, .{
        .id = 2,
        .width = 10,
        .height = 10,
    });
    const tracked = t.screens.active.pages.countTrackedPins();
    try storage.addPlacement(alloc, t.screens.active, 1, 1, .{
        .location = .{ .pin = try trackPin(&t, .{ .x = 0, .y = 0 }) },
    });
    try storage.addPlacement(alloc, t.screens.active, 2, 1, .{
        .location = .{ .pin = try trackPin(&t, .{ .x = 0, .y = 3 }) },
    });
    t.setCursorPos(6, 1);

    // The top row of the 2-row image scrolls off the screen: what is left
    // stays on the top row with that row clipped off the source.
    try t.index();
    try testing.expectEqual(
        @as(?point.Coordinate, .{ .x = 0, .y = 0 }),
        testActiveCoord(&t, 1, 1),
    );
    {
        const p = testPlacement(&t, 1, 1) orelse return error.TestUnexpectedResult;
        try testing.expectEqual(@as(u32, 10), p.source_y);
        try testing.expectEqual(@as(u32, 10), p.source_height);
    }
    try testing.expectEqual(
        @as(?point.Coordinate, .{ .x = 0, .y = 2 }),
        testActiveCoord(&t, 2, 1),
    );

    // Scrolling up two rows (SU) takes the rest of the first image off
    // the screen, so it is deleted, and moves the second one up two rows.
    try t.scrollUp(2);
    try testing.expect(testPlacement(&t, 1, 1) == null);
    try testing.expectEqual(
        @as(?point.Coordinate, .{ .x = 0, .y = 0 }),
        testActiveCoord(&t, 2, 1),
    );
    try testing.expectEqual(@as(usize, 1), storage.placements.count());
    try testing.expectEqual(tracked + 1, t.screens.active.pages.countTrackedPins());
}

test "storage: reverse index at the top of the screen moves placements down" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(alloc, .{ .cols = 10, .rows = 6 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 60;

    // A 1-row image on row 2 and a 2-row image on row 4.
    const storage: *ImageStorage = &t.screens.active.kitty_images;
    try storage.addImage(alloc, t.screens.active, .{
        .id = 1,
        .width = 10,
        .height = 10,
    });
    try storage.addImage(alloc, t.screens.active, .{
        .id = 2,
        .width = 10,
        .height = 20,
    });
    const tracked = t.screens.active.pages.countTrackedPins();
    try storage.addPlacement(alloc, t.screens.active, 1, 1, .{
        .location = .{ .pin = try trackPin(&t, .{ .x = 0, .y = 2 }) },
    });
    try storage.addPlacement(alloc, t.screens.active, 2, 1, .{
        .location = .{ .pin = try trackPin(&t, .{ .x = 0, .y = 4 }) },
    });
    t.setCursorPos(1, 1);

    // The text moves down one row, and the images with it. The 2-row
    // image now reaches past the bottom row and is drawn cut off there,
    // as kitty draws it.
    t.reverseIndex();
    try testing.expectEqual(
        @as(?point.Coordinate, .{ .x = 0, .y = 3 }),
        testActiveCoord(&t, 1, 1),
    );
    try testing.expectEqual(
        @as(?point.Coordinate, .{ .x = 0, .y = 5 }),
        testActiveCoord(&t, 2, 1),
    );
    {
        const p = testPlacement(&t, 2, 1) orelse return error.TestUnexpectedResult;
        try testing.expectEqual(@as(u32, 0), p.source_height);
    }

    // SD moves them on; the 2-row image leaves the screen and is deleted.
    t.scrollDown(1);
    try testing.expectEqual(
        @as(?point.Coordinate, .{ .x = 0, .y = 4 }),
        testActiveCoord(&t, 1, 1),
    );
    try testing.expect(testPlacement(&t, 2, 1) == null);
    try testing.expectEqual(@as(usize, 1), storage.placements.count());
    try testing.expectEqual(tracked + 1, t.screens.active.pages.countTrackedPins());
}

test "storage: erasing the scrollback removes placements anchored in it" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(alloc, .{ .cols = 10, .rows = 6 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 60;

    const storage: *ImageStorage = &t.screens.active.kitty_images;
    try storage.addImage(alloc, t.screens.active, .{
        .id = 1,
        .width = 10,
        .height = 10,
    });
    const tracked = t.screens.active.pages.countTrackedPins();
    try storage.addPlacement(alloc, t.screens.active, 1, 1, .{
        .location = .{ .pin = try trackPin(&t, .{ .x = 3, .y = 0 }) },
    });
    try storage.addPlacement(alloc, t.screens.active, 1, 2, .{
        .location = .{ .pin = try trackPin(&t, .{ .x = 3, .y = 4 }) },
    });

    // With no scrollback yet, ED 3 erases nothing and deletes nothing.
    t.eraseDisplay(.scrollback, false);
    try testing.expectEqual(@as(usize, 2), storage.placements.count());

    // Scroll the first placement into the scrollback.
    t.setCursorPos(6, 1);
    try t.index();
    try t.index();
    try testing.expect(testActiveCoord(&t, 1, 1) == null);
    try testing.expectEqual(
        @as(?point.Coordinate, .{ .x = 3, .y = 2 }),
        testActiveCoord(&t, 1, 2),
    );

    // ED 3 erases the scrollback. The placement anchored there has no row
    // left, so it goes with it, and the one on the screen stays.
    t.eraseDisplay(.scrollback, false);
    try testing.expect(testPlacement(&t, 1, 1) == null);
    try testing.expectEqual(
        @as(?point.Coordinate, .{ .x = 3, .y = 2 }),
        testActiveCoord(&t, 1, 2),
    );
    try testing.expectEqual(tracked + 1, t.screens.active.pages.countTrackedPins());
}

test "storage: shrinking a screen without scrollback removes placements on removed rows" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(alloc, .{ .cols = 10, .rows = 6 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 60;

    try t.switchScreenMode(.@"1049", true);
    try testing.expect(t.screens.active.no_scrollback);

    const storage: *ImageStorage = &t.screens.active.kitty_images;
    try storage.addImage(alloc, t.screens.active, .{
        .id = 1,
        .width = 10,
        .height = 10,
    });
    const tracked = t.screens.active.pages.countTrackedPins();
    try storage.addPlacement(alloc, t.screens.active, 1, 1, .{
        .location = .{ .pin = try trackPin(&t, .{ .x = 3, .y = 0 }) },
    });
    try storage.addPlacement(alloc, t.screens.active, 1, 2, .{
        .location = .{ .pin = try trackPin(&t, .{ .x = 3, .y = 4 }) },
    });

    // With the cursor on the bottom row, shrinking to 3 rows removes the
    // top three rows, and the screen keeps no history for them.
    t.setCursorPos(6, 1);
    try t.resize(alloc, 10, 3);
    try testing.expect(testPlacement(&t, 1, 1) == null);
    try testing.expectEqual(
        @as(?point.Coordinate, .{ .x = 3, .y = 1 }),
        testActiveCoord(&t, 1, 2),
    );
    try testing.expectEqual(tracked + 1, t.screens.active.pages.countTrackedPins());
}

test "storage: shrinking without pulling scrollback removes placements on erased rows" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(alloc, .{ .cols = 10, .rows = 6 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 60;

    // termio turns this off for every Windows pty, a pseudo console that
    // keeps no scrollback.
    t.flags.resize_pull_scrollback = false;

    const storage: *ImageStorage = &t.screens.active.kitty_images;
    try storage.addImage(alloc, t.screens.active, .{
        .id = 1,
        .width = 10,
        .height = 10,
    });
    const tracked = t.screens.active.pages.countTrackedPins();
    try storage.addPlacement(alloc, t.screens.active, 1, 1, .{
        .location = .{ .pin = try trackPin(&t, .{ .x = 3, .y = 0 }) },
    });
    try storage.addPlacement(alloc, t.screens.active, 1, 2, .{
        .location = .{ .pin = try trackPin(&t, .{ .x = 3, .y = 5 }) },
    });
    try t.printString("top");
    t.setCursorPos(1, 1);

    // Shrinking to 3 rows would push the cursor's row into the scrollback,
    // so the screen keeps that row and erases the three rows below the new
    // bottom instead, as ConPTY does. The image anchored on the bottom row
    // goes with its row; the one on the cursor's row stays.
    try t.resize(alloc, 10, 3);
    try testing.expectEqual(@as(size.CellCountInt, 0), t.screens.active.cursor.y);
    {
        const str = try t.plainString(alloc);
        defer alloc.free(str);
        try testing.expectEqualStrings("top", str);
    }
    try testing.expectEqual(
        @as(?point.Coordinate, .{ .x = 3, .y = 0 }),
        testActiveCoord(&t, 1, 1),
    );
    try testing.expect(testPlacement(&t, 1, 2) == null);
    try testing.expectEqual(tracked + 1, t.screens.active.pages.countTrackedPins());
}

test "storage: clipping a placement off the top accounts for its y offset" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(alloc, .{ .cols = 10, .rows = 6 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 60;

    try t.switchScreenMode(.@"1049", true);
    const storage: *ImageStorage = &t.screens.active.kitty_images;
    try storage.addImage(alloc, t.screens.active, .{
        .id = 1,
        .width = 10,
        .height = 20,
    });

    // A 20px-tall image 5px down its first row spans three rows. The
    // first row holds 5px of it, so scrolling that row off clips 5px off
    // the source, and the rest starts at the top of the screen.
    try storage.addPlacement(alloc, t.screens.active, 1, 1, .{
        .location = .{ .pin = try trackPin(&t, .{ .x = 0, .y = 0 }) },
        .y_offset = 5,
    });

    // An offset stays inside the first cell, so 15px on a 10px cell is
    // 9px, and the first row holds 1px of the image: scrolling it off clips
    // 1px and leaves no offset.
    try storage.addPlacement(alloc, t.screens.active, 1, 2, .{
        .location = .{ .pin = try trackPin(&t, .{ .x = 5, .y = 0 }) },
        .y_offset = 15,
    });

    t.setCursorPos(6, 1);
    try t.index();
    {
        const p = testPlacement(&t, 1, 1) orelse return error.TestUnexpectedResult;
        try testing.expectEqual(@as(u32, 5), p.source_y);
        try testing.expectEqual(@as(u32, 15), p.source_height);
        try testing.expectEqual(@as(u32, 0), p.y_offset);
        try testing.expectEqual(@as(u32, 2), p.gridSize(storage.imageById(1).?, &t).rows);
    }
    {
        const p = testPlacement(&t, 1, 2) orelse return error.TestUnexpectedResult;
        try testing.expectEqual(@as(u32, 1), p.source_y);
        try testing.expectEqual(@as(u32, 19), p.source_height);
        try testing.expectEqual(@as(u32, 0), p.y_offset);
        try testing.expectEqual(@as(u32, 2), p.gridSize(storage.imageById(1).?, &t).rows);
    }
    try testing.expectEqual(
        @as(?point.Coordinate, .{ .x = 0, .y = 0 }),
        testActiveCoord(&t, 1, 1),
    );
    try testing.expectEqual(
        @as(?point.Coordinate, .{ .x = 5, .y = 0 }),
        testActiveCoord(&t, 1, 2),
    );
}

test "storage: clipping an enlarged placement off the top always crops its source" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(alloc, .{ .cols = 10, .rows = 6 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 60;

    try t.switchScreenMode(.@"1049", true);
    const storage: *ImageStorage = &t.screens.active.kitty_images;
    try storage.addImage(alloc, t.screens.active, .{
        .id = 1,
        .width = 1,
        .height = 2,
    });

    // Scaled by its columns alone, the 1x2 image is drawn 20x40 px, four
    // rows, so each source row is two rows tall and one row is half of a
    // source row.
    const tracked = t.screens.active.pages.countTrackedPins();
    try storage.addPlacement(alloc, t.screens.active, 1, 1, .{
        .location = .{ .pin = try trackPin(&t, .{ .x = 0, .y = 0 }) },
        .columns = 2,
    });
    try testing.expectEqual(
        @as(u32, 4),
        testPlacement(&t, 1, 1).?.gridSize(storage.imageById(1).?, &t).rows,
    );

    // A crop that rounded down to no source rows would leave the image drawn
    // whole at the top through every scroll. A whole source row goes.
    t.setCursorPos(6, 1);
    try t.index();
    {
        const p = testPlacement(&t, 1, 1) orelse return error.TestUnexpectedResult;
        try testing.expectEqual(@as(u32, 1), p.source_y);
        try testing.expectEqual(@as(u32, 1), p.source_height);
    }
    try testing.expectEqual(
        @as(?point.Coordinate, .{ .x = 0, .y = 0 }),
        testActiveCoord(&t, 1, 1),
    );

    // The next row takes the last source row.
    try t.index();
    try testing.expect(testPlacement(&t, 1, 1) == null);
    try testing.expectEqual(tracked, t.screens.active.pages.countTrackedPins());
}

test "storage: replacing an image counts its old bytes before evicting" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);

    // Equal transmit times evict in ID order.
    const time = try std.time.Instant.now();

    // Replacing image 2 with as many bytes keeps the total at the limit,
    // so nothing has to be evicted, image 1 included.
    {
        var s: ImageStorage = .{ .total_limit = 12 };
        defer s.deinit(alloc, t.screens.active);
        try s.addImage(alloc, t.screens.active, .{
            .id = 1,
            .data = try alloc.dupe(u8, "1234"),
            .transmit_time = time,
        });
        try s.addImage(alloc, t.screens.active, .{
            .id = 2,
            .data = try alloc.dupe(u8, "12345678"),
            .transmit_time = time,
        });
        try s.addImage(alloc, t.screens.active, .{
            .id = 2,
            .data = try alloc.dupe(u8, "abcdefgh"),
            .transmit_time = time,
        });
        try testing.expect(s.images.contains(1));
        try testing.expect(s.images.contains(2));
        try testing.expectEqual(@as(usize, 12), s.total_bytes);
    }

    // A larger replacement must evict. The image it replaces, here the
    // first candidate, is not one to evict: its bytes are already counted
    // as freed, and evicting it too would leave the total over the limit.
    {
        var s: ImageStorage = .{ .total_limit = 12 };
        defer s.deinit(alloc, t.screens.active);
        try s.addImage(alloc, t.screens.active, .{
            .id = 1,
            .data = try alloc.dupe(u8, "12345678"),
            .transmit_time = time,
        });
        try s.addImage(alloc, t.screens.active, .{
            .id = 2,
            .data = try alloc.dupe(u8, "1234"),
            .transmit_time = time,
        });
        try s.addImage(alloc, t.screens.active, .{
            .id = 1,
            .data = try alloc.dupe(u8, "abcdefghij"),
            .transmit_time = time,
        });
        try testing.expect(s.images.contains(1));
        try testing.expect(!s.images.contains(2));
        try testing.expectEqual(@as(usize, 10), s.total_bytes);
    }
}

test "storage: eviction stops once it has freed enough bytes" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);

    var s: ImageStorage = .{ .total_limit = 10 };
    defer s.deinit(alloc, t.screens.active);

    // Two 5-byte images fill the limit exactly. A third needs exactly
    // 5 bytes back, which evicting image 1 alone provides.
    const time = try std.time.Instant.now();
    inline for (.{ 1, 2, 3 }) |id| {
        try s.addImage(alloc, t.screens.active, .{
            .id = id,
            .data = try alloc.dupe(u8, "12345"),
            .transmit_time = time,
        });
    }
    try testing.expect(!s.images.contains(1));
    try testing.expect(s.images.contains(2));
    try testing.expect(s.images.contains(3));
    try testing.expectEqual(@as(usize, 10), s.total_bytes);
}

test "storage: evict unused transient image" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);

    var s: ImageStorage = .{ .total_limit = 192 };
    defer s.deinit(alloc, t.screens.active);

    // Equal transmit times would evict unused images in ID order, image 1
    // first, without the hint.
    const time = try std.time.Instant.now();
    try s.addImage(alloc, t.screens.active, .{
        .id = 1,
        .data = try alloc.dupe(u8, "*" ** 64),
        .usage = .{ .transient = false },
        .transmit_time = time,
    });
    try s.addImage(alloc, t.screens.active, .{
        .id = 2,
        .data = try alloc.dupe(u8, "*" ** 64),
        .usage = .{ .transient = true },
        .transmit_time = time,
    });
    try s.addImage(alloc, t.screens.active, .{
        .id = 3,
        .data = try alloc.dupe(u8, "*" ** 64),
        .usage = .{ .transient = true },
        .transmit_time = time,
    });
    try s.addPlacement(
        alloc,
        t.screens.active,
        2,
        1,
        .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } },
    );

    const result = try s.evictImage(alloc, t.screens.active, 32, null);
    try testing.expectEqual(true, result);
    try testing.expectEqual(2, s.images.count());
    try testing.expect(s.images.contains(1));
    try testing.expect(s.images.contains(2));
    try testing.expect(!s.images.contains(3));
}
