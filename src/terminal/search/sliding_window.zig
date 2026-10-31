const std = @import("std");
const assert = @import("../../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const CircBuf = @import("../../datastruct/main.zig").CircBuf;
const build_options = @import("terminal_options");
const point = @import("../point.zig");
const size = @import("../size.zig");
const PageList = @import("../PageList.zig");
const Page = @import("../page.zig").Page;
const Screen = @import("../Screen.zig");
const Terminal = @import("../Terminal.zig");
const PageFormatter = @import("../formatter.zig").PageFormatter;
const FlattenedHighlight = @import("../highlight.zig").Flattened;
const Pattern = @import("pattern.zig").Pattern;

/// Searches page nodes via a sliding window. The sliding window maintains
/// the invariant that data isn't pruned until (1) we've searched it and
/// (2) we've accounted for overlaps across pages to fit the needle.
///
/// The sliding window is first initialized empty. Pages are then appended
/// in the order to search them. The sliding window supports both a forward
/// and reverse order specified via `init`. The pages should be appended
/// in the correct order matching the search direction.
///
/// All appends grow the window. The window is only pruned when a search
/// is done (positive or negative match) via `next()`.
///
/// To avoid unnecessary memory growth, the recommended usage is to
/// call `next()` until it returns null and then `append` the next page
/// and repeat the process. This will always maintain the minimum
/// required memory to search for the needle.
///
/// The caller is responsible for providing the pages and ensuring they're
/// in the proper order. The SlidingWindow itself doesn't own the pages, but
/// it will contain pointers to them in order to return selections. If any
/// pages become invalid, the caller should clear the sliding window and
/// start over.
pub const SlidingWindow = struct {
    /// The allocator to use for all the data within this window. We
    /// store this rather than passing it around because its already
    /// part of multiple elements (eg. Meta's CellMap) and we want to
    /// ensure we always use a consistent allocator. Additionally, only
    /// a small amount of sliding windows are expected to be in use
    /// at any one time so the memory overhead isn't that large.
    alloc: Allocator,

    /// The data buffer is a circular buffer of u8 that contains the
    /// encoded page text that we can use to search for the needle.
    data: DataBuf,

    /// The meta buffer is a circular buffer that contains the metadata
    /// about the pages we're searching. This usually isn't that large
    /// so callers must iterate through it to find the offset to map
    /// data to meta.
    meta: MetaBuf,

    /// Buffer that can fit any amount of chunks necessary for next
    /// to never fail allocation.
    chunk_buf: std.MultiArrayList(FlattenedHighlight.Chunk),

    /// Offset into data for our current state. This handles the
    /// situation where our search moved through meta[0] but didn't
    /// do enough to prune it.
    data_offset: usize = 0,

    /// The needle we're searching for. Does own the memory.
    needle: []const u8,

    /// The search direction. If the direction is forward then pages should
    /// be appended in forward linked list order from the PageList. If the
    /// direction is reverse then pages should be appended in reverse order.
    ///
    /// This is important because in most cases, a reverse search is going
    /// to be more desirable to search from the end of the active area
    /// backwards so more recent data is found first.
    direction: Direction,

    /// A buffer to store the overlap search data. This is used to search
    /// overlaps between pages where the match starts on one page and
    /// ends on another. The length is always `needle.len * 2`.
    overlap_buf: []u8,

    /// A linear copy of the unsearched data for `Pattern.find`, which
    /// needs one contiguous haystack. `append` reserves it.
    haystack_buf: std.ArrayListUnmanaged(u8) = .empty,

    /// The matcher for non-default query options, borrowed. Null runs the
    /// literal scan.
    pattern: ?*Pattern,

    const Direction = enum { forward, reverse };
    const DataBuf = CircBuf(u8, 0);
    const MetaBuf = CircBuf(Meta, undefined);

    /// Information copied from a page while appending it to the window.
    ///
    /// Callers use `last_row_wrapped` to decide whether an adjacent page can
    /// contribute to a cross-page match without reading the node again.
    pub const AppendResult = struct {
        content_len: usize,
        last_row_wrapped: bool,
    };

    const Meta = struct {
        node: *PageList.List.Node,
        serial: u64,
        rows: size.CellCountInt,
        cell_map: std.ArrayList(point.Coordinate),

        /// What preceded the node's text in screen order when it was
        /// appended: the previous node's hard newline, text whose byte the
        /// window does not have (a soft wrap), or nothing.
        before: Pattern.Edge,

        /// Whether another node followed it when it was appended.
        has_next: bool,

        pub fn deinit(self: *Meta, alloc: Allocator) void {
            self.cell_map.deinit(alloc);
        }
    };

    pub fn init(
        alloc: Allocator,
        direction: Direction,
        needle_unowned: []const u8,
    ) Allocator.Error!SlidingWindow {
        return SlidingWindow.initPattern(alloc, direction, needle_unowned, null);
    }

    /// A window that matches with `pattern`, the query's compiled
    /// `Pattern`, or with the literal scan when it is null. The pattern is
    /// borrowed: it must outlive the window, and every window that shares
    /// it runs on one thread.
    pub fn initPattern(
        alloc: Allocator,
        direction: Direction,
        needle_unowned: []const u8,
        pattern: ?*Pattern,
    ) Allocator.Error!SlidingWindow {
        var data = try DataBuf.init(alloc, 0);
        errdefer data.deinit(alloc);

        var meta = try MetaBuf.init(alloc, 0);
        errdefer meta.deinit(alloc);

        const needle = try alloc.dupe(u8, needle_unowned);
        errdefer alloc.free(needle);
        switch (direction) {
            .forward => {},
            .reverse => std.mem.reverse(u8, needle),
        }

        const overlap_buf = try alloc.alloc(u8, needle.len * 2);
        errdefer alloc.free(overlap_buf);

        return .{
            .alloc = alloc,
            .data = data,
            .meta = meta,
            .chunk_buf = .empty,
            .needle = needle,
            .direction = direction,
            .overlap_buf = overlap_buf,
            .pattern = pattern,
        };
    }

    pub fn deinit(self: *SlidingWindow) void {
        self.haystack_buf.deinit(self.alloc);
        self.alloc.free(self.overlap_buf);
        self.alloc.free(self.needle);
        self.chunk_buf.deinit(self.alloc);
        self.data.deinit(self.alloc);

        var meta_it = self.meta.iterator(.forward);
        while (meta_it.next()) |meta| meta.deinit(self.alloc);
        self.meta.deinit(self.alloc);
    }

    /// Clear all data but retain allocated capacity.
    pub fn clearAndRetainCapacity(self: *SlidingWindow) void {
        var meta_it = self.meta.iterator(.forward);
        while (meta_it.next()) |meta| meta.deinit(self.alloc);
        self.meta.clear();
        self.data.clear();
        self.data_offset = 0;
    }

    /// Search the window for the next occurrence of the needle. As
    /// the window moves, the window will prune itself while maintaining
    /// the invariant that the window is always big enough to contain
    /// the needle.
    ///
    /// This returns a flattened highlight on a match. The
    /// flattened highlight requires allocation and is therefore more expensive
    /// than a normal selection, but it is more efficient to render since it
    /// has all the information without having to dereference pointers into
    /// the terminal state.
    ///
    /// The flattened highlight chunks reference internal memory for this
    /// sliding window and are only valid until the next call to `next()`
    /// or `append()`. If the caller wants to retain the flattened highlight
    /// then they should clone it.
    ///
    /// This reads only memory the window owns and never allocates: `append`
    /// reserves what a scan needs. A pattern that fails at run time finds
    /// nothing (see `Pattern.failure`).
    pub fn next(self: *SlidingWindow) ?FlattenedHighlight {
        // An empty needle represents an inactive search. Searching for it
        // would otherwise produce a zero-length match, which highlight()
        // cannot represent because its end offset is inclusive.
        if (self.needle.len == 0) return null;

        if (self.pattern) |pattern| return self.nextPattern(pattern);

        const slices = slices: {
            // If we have less data then the needle then we can't possibly match
            const data_len = self.data.len();
            if (data_len < self.needle.len) return null;

            break :slices self.data.getPtrSlice(
                self.data_offset,
                data_len - self.data_offset,
            );
        };

        // Search the first slice for the needle.
        if (std.ascii.indexOfIgnoreCase(slices[0], self.needle)) |idx| {
            return self.highlight(
                idx,
                self.needle.len,
            );
        }

        // Search the overlap buffer for the needle.
        if (slices[0].len > 0 and slices[1].len > 0) overlap: {
            // Get up to needle.len - 1 bytes from each side (as much as
            // we can) and store it in the overlap buffer.
            const prefix: []const u8 = prefix: {
                const len = @min(slices[0].len, self.needle.len - 1);
                const idx = slices[0].len - len;
                break :prefix slices[0][idx..];
            };
            const suffix: []const u8 = suffix: {
                const len = @min(slices[1].len, self.needle.len - 1);
                break :suffix slices[1][0..len];
            };
            const overlap_len = prefix.len + suffix.len;
            assert(overlap_len <= self.overlap_buf.len);
            @memcpy(self.overlap_buf[0..prefix.len], prefix);
            @memcpy(self.overlap_buf[prefix.len..overlap_len], suffix);

            // Search the overlap
            const idx = std.ascii.indexOfIgnoreCase(
                self.overlap_buf[0..overlap_len],
                self.needle,
            ) orelse break :overlap;

            // We found a match in the overlap buffer. We need to map the
            // index back to the data buffer in order to get our selection.
            return self.highlight(
                slices[0].len - prefix.len + idx,
                self.needle.len,
            );
        }

        // Search the last slice for the needle.
        if (std.ascii.indexOfIgnoreCase(slices[1], self.needle)) |idx| {
            return self.highlight(
                slices[0].len + idx,
                self.needle.len,
            );
        }

        // Special case 1-lengthed needles to delete the entire buffer.
        if (self.needle.len == 1) {
            self.clearAndRetainCapacity();
            self.assertIntegrity();
            return null;
        }

        // No match. We keep `needle.len - 1` bytes available to
        // handle the future overlap case.
        prune: {
            var meta_it = self.meta.iterator(.reverse);
            var saved: usize = 0;
            while (meta_it.next()) |meta| {
                const needed = self.needle.len - 1 - saved;
                if (meta.cell_map.items.len >= needed) {
                    // We save up to this meta. We set our data offset
                    // to exactly where it needs to be to continue
                    // searching.
                    self.data_offset = meta.cell_map.items.len - needed;
                    break;
                }

                saved += meta.cell_map.items.len;
            } else {
                // If we exited the while loop naturally then we
                // never got the amount we needed and so there is
                // nothing to prune.
                assert(saved < self.needle.len - 1);
                break :prune;
            }

            const prune_count = self.meta.len() - meta_it.idx;
            if (prune_count == 0) {
                // This can happen if we need to save up to the first
                // meta value to retain our window.
                break :prune;
            }

            // We can now delete all the metas up to but NOT including
            // the meta we found through meta_it.
            meta_it = self.meta.iterator(.forward);
            var prune_data_len: usize = 0;
            for (0..prune_count) |_| {
                const meta = meta_it.next().?;
                prune_data_len += meta.cell_map.items.len;
                meta.deinit(self.alloc);
            }
            self.meta.deleteOldest(prune_count);
            self.data.deleteOldest(prune_data_len);
        }

        // Our data offset now moves to needle.len - 1 from the end so
        // that we can handle the overlap case.
        self.data_offset = self.data.len() - (self.needle.len - 1);

        self.assertIntegrity();
        return null;
    }

    /// `next` for a window with a pattern. A regex can match fewer bytes
    /// than its source, so it has no fast fail on short data, and a scan
    /// that finds nothing keeps the suffix `Pattern.retainLen` asks for.
    fn nextPattern(self: *SlidingWindow, pattern: *Pattern) ?FlattenedHighlight {
        const data_len = self.data.len();
        if (data_len == 0) return null;

        const slices = self.data.getPtrSlice(
            self.data_offset,
            data_len - self.data_offset,
        );
        if (self.patternMatch(pattern, slices[0], slices[1])) |match| {
            return self.highlight(match.start, match.len);
        }

        // Special case zero-overlap searches to delete the entire buffer.
        const retain_len = pattern.retainLen();
        if (retain_len == 0) {
            self.clearAndRetainCapacity();
            self.assertIntegrity();
            return null;
        }

        self.pruneRetainingSuffix(retain_len);

        self.assertIntegrity();
        return null;
    }

    fn pruneRetainingSuffix(self: *SlidingWindow, retain_len: usize) void {
        if (self.data.len() <= retain_len) {
            self.data_offset = 0;
            return;
        }

        var drop = self.data.len() - retain_len;
        while (drop > 0) {
            var meta_it = self.meta.iterator(.forward);
            const meta = meta_it.next().?;
            const meta_len = meta.cell_map.items.len;
            assert(meta_len > 0);

            if (drop >= meta_len) {
                meta.deinit(self.alloc);
                self.meta.deleteOldest(1);
                self.data.deleteOldest(meta_len);
                drop -= meta_len;
                continue;
            }

            const keep_len = meta_len - drop;
            std.mem.copyForwards(
                point.Coordinate,
                meta.cell_map.items[0..keep_len],
                meta.cell_map.items[drop..],
            );
            meta.cell_map.shrinkRetainingCapacity(keep_len);
            self.data.deleteOldest(drop);
            drop = 0;
        }

        self.data_offset = 0;
    }

    /// The pattern's match in the unsearched data, as an offset from
    /// `data_offset` in search order.
    fn patternMatch(
        self: *SlidingWindow,
        pattern: *Pattern,
        first: []const u8,
        second: []const u8,
    ) ?Pattern.Span {
        const text = self.buildHaystack(first, second);
        const around = self.edges();
        const span = pattern.find(.{
            .text = text,
            .before = around.before,
            .after = around.after,
            .pick = switch (self.direction) {
                .forward => .first,
                .reverse => .last,
            },
        }) orelse return null;
        return switch (self.direction) {
            .forward => span,
            .reverse => .{ .start = text.len - span.start - span.len, .len = span.len },
        };
    }

    /// The unsearched data in screen order, in the buffer `append`
    /// reserved.
    fn buildHaystack(
        self: *SlidingWindow,
        first: []const u8,
        second: []const u8,
    ) []const u8 {
        self.haystack_buf.clearRetainingCapacity();

        switch (self.direction) {
            .forward => {
                self.haystack_buf.appendSliceAssumeCapacity(first);
                self.haystack_buf.appendSliceAssumeCapacity(second);
            },
            .reverse => {
                // `first` and `second` are logical search-order slices after
                // data_offset. Reverse the whole range across the circular
                // split: reverse(first ++ second) == reverse(second) ++ reverse(first).
                self.appendReversed(second);
                self.appendReversed(first);
            },
        }

        return self.haystack_buf.items;
    }

    fn appendReversed(self: *SlidingWindow, bytes: []const u8) void {
        var i = bytes.len;
        while (i > 0) {
            i -= 1;
            self.haystack_buf.appendAssumeCapacity(bytes[i]);
        }
    }

    /// What lies before and after the unsearched data in screen order.
    fn edges(self: *const SlidingWindow) struct { before: Pattern.Edge, after: Pattern.Edge } {
        return switch (self.direction) {
            .forward => .{ .before = self.searchStartEdge(), .after = self.searchEndEdge() },
            .reverse => .{ .before = self.searchEndEdge(), .after = self.searchStartEdge() },
        };
    }

    /// What lies before `data_offset` in search order.
    fn searchStartEdge(self: *const SlidingWindow) Pattern.Edge {
        if (self.data_offset > 0) {
            const prior_byte = self.dataByteAt(self.data_offset - 1) orelse return .unknown;
            return .{ .byte = prior_byte };
        }

        var it = self.meta.iterator(.forward);
        const meta = it.next() orelse return .none;
        return switch (self.direction) {
            .forward => meta.before,
            .reverse => if (meta.has_next) .unknown else .none,
        };
    }

    /// What lies after the window's data in search order.
    fn searchEndEdge(self: *const SlidingWindow) Pattern.Edge {
        var it = self.meta.iterator(.reverse);
        const meta = it.next() orelse return .none;
        return switch (self.direction) {
            .forward => if (meta.has_next) .unknown else .none,
            .reverse => meta.before,
        };
    }

    fn dataByteAt(self: *const SlidingWindow, offset: usize) ?u8 {
        if (offset >= self.data.len()) return null;

        const cap = self.data.capacity();
        if (cap == 0) return null;

        const idx = self.data.tail + offset;
        const storage_idx = if (idx < cap) idx else idx - cap;
        return self.data.storage[storage_idx];
    }

    /// Return a flattened highlight for the given start and length.
    ///
    /// The flattened highlight can be used to render the highlight
    /// in the most efficient way because it doesn't require a terminal
    /// lock to access terminal data to compare whether some viewport
    /// matches the highlight (because it doesn't need to traverse
    /// the page nodes).
    ///
    /// The start index is assumed to be relative to the offset. i.e.
    /// index zero is actually at `self.data[self.data_offset]`. The
    /// selection will account for the offset.
    fn highlight(
        self: *SlidingWindow,
        start_offset: usize,
        len: usize,
    ) FlattenedHighlight {
        const start = start_offset + self.data_offset;
        const end = start + len - 1;
        if (comptime std.debug.runtime_safety) {
            assert(start < self.data.len());
            assert(start + len <= self.data.len());
        }

        self.chunk_buf.clearRetainingCapacity();
        var result: FlattenedHighlight = .empty;

        // A reverse cross-page match needs the row count of the last meta in
        // search order after the chunks themselves are reversed. Snapshot it
        // while traversing Meta rather than dereferencing a PageList node after
        // the terminal lock has been released.
        var cross_page_end_rows: ?size.CellCountInt = null;

        // Go through the meta nodes to find our start.
        const tl: struct {
            /// If non-null, we need to continue searching for the bottom-right.
            br: ?struct {
                it: MetaBuf.Iterator,
                consumed: usize,
            },

            /// Data to prune, both are lengths.
            prune: struct {
                meta: usize,
                data: usize,
            },
        } = tl: {
            var meta_it = self.meta.iterator(.forward);
            var meta_consumed: usize = 0;
            while (meta_it.next()) |meta| {
                // Always increment our consumed count so that our index
                // is right for the end search if we do it.
                const prior_meta_consumed = meta_consumed;
                meta_consumed += meta.cell_map.items.len;

                // meta_i is the index we expect to find the match in the
                // cell map within this meta if it contains it.
                const meta_i = start - prior_meta_consumed;

                // This meta doesn't contain the match. This means we
                // can also prune this set of data because we only look
                // forward.
                if (meta_i >= meta.cell_map.items.len) continue;

                // Now we look for the end. In MOST cases it is the same as
                // our starting chunk because highlights are usually small and
                // not on a boundary, so let's optimize for that.
                const end_i = end - prior_meta_consumed;
                if (end_i < meta.cell_map.items.len) {
                    @branchHint(.likely);

                    // The entire highlight is within this meta.
                    const start_map = meta.cell_map.items[meta_i];
                    const end_map = meta.cell_map.items[end_i];
                    result.top_x = start_map.x;
                    result.bot_x = end_map.x;
                    self.chunk_buf.appendAssumeCapacity(.{
                        .node = meta.node,
                        .serial = meta.serial,
                        .start = @intCast(start_map.y),
                        .end = @intCast(end_map.y + 1),
                    });

                    break :tl .{
                        .br = null,
                        .prune = .{
                            .meta = meta_it.idx - 1,
                            .data = prior_meta_consumed,
                        },
                    };
                } else {
                    // We found the meta that contains the start of the match
                    // only. Consume this entire node from our start offset.
                    const map = meta.cell_map.items[meta_i];
                    result.top_x = map.x;
                    self.chunk_buf.appendAssumeCapacity(.{
                        .node = meta.node,
                        .serial = meta.serial,
                        .start = @intCast(map.y),
                        .end = meta.rows,
                    });

                    break :tl .{
                        .br = .{
                            .it = meta_it,
                            .consumed = meta_consumed,
                        },
                        .prune = .{
                            .meta = meta_it.idx - 1,
                            .data = prior_meta_consumed,
                        },
                    };
                }
            } else {
                // Precondition that the start index is within the data buffer.
                unreachable;
            }
        };

        // Search for our end.
        if (tl.br) |br| {
            var meta_it = br.it;
            var meta_consumed: usize = br.consumed;
            while (meta_it.next()) |meta| {
                // meta_i is the index we expect to find the match in the
                // cell map within this meta if it contains it.
                const meta_i = end - meta_consumed;
                if (meta_i >= meta.cell_map.items.len) {
                    // This meta doesn't contain the match. We still add it
                    // to our results because we want the full flattened list.
                    self.chunk_buf.appendAssumeCapacity(.{
                        .node = meta.node,
                        .serial = meta.serial,
                        .start = 0,
                        .end = meta.rows,
                    });

                    meta_consumed += meta.cell_map.items.len;
                    continue;
                }

                // We found it
                const map = meta.cell_map.items[meta_i];
                result.bot_x = map.x;
                cross_page_end_rows = meta.rows;
                self.chunk_buf.appendAssumeCapacity(.{
                    .node = meta.node,
                    .serial = meta.serial,
                    .start = 0,
                    .end = @intCast(map.y + 1),
                });
                break;
            } else {
                // Precondition that the end index is within the data buffer.
                unreachable;
            }
        }

        // Our offset into the current meta block is the start index
        // minus the amount of data fully consumed. We then add one
        // to move one past the match so we don't repeat it.
        self.data_offset = start - tl.prune.data + 1;

        // If we went beyond our initial meta node we can prune.
        if (tl.prune.meta > 0) {
            // Deinit all our memory in the meta blocks prior to our
            // match.
            var meta_it = self.meta.iterator(.forward);
            var meta_consumed: usize = 0;
            for (0..tl.prune.meta) |_| {
                const meta: *Meta = meta_it.next().?;
                meta_consumed += meta.cell_map.items.len;
                meta.deinit(self.alloc);
            }
            if (comptime std.debug.runtime_safety) {
                assert(meta_it.idx == tl.prune.meta);
                assert(meta_it.next().?.node == self.chunk_buf.items(.node)[0]);
            }
            self.meta.deleteOldest(tl.prune.meta);

            // Delete all the data up to our current index.
            assert(tl.prune.data > 0);
            self.data.deleteOldest(tl.prune.data);
        }

        switch (self.direction) {
            .forward => {},
            .reverse => {
                const slice = self.chunk_buf.slice();
                const nodes = slice.items(.node);
                const serials = slice.items(.serial);
                const starts = slice.items(.start);
                const ends = slice.items(.end);

                if (self.chunk_buf.len > 1) {
                    // Reverse all our chunks. This should be pretty obvious why.
                    std.mem.reverse(*PageList.List.Node, nodes);
                    std.mem.reverse(u64, serials);
                    std.mem.reverse(size.CellCountInt, starts);
                    std.mem.reverse(size.CellCountInt, ends);

                    // Now normally with forward traversal with multiple pages,
                    // the suffix of the first page and the prefix of the last
                    // page are used.
                    //
                    // For a reverse traversal, this is inverted (since the
                    // pages are in reverse order we get the suffix of the last
                    // page and the prefix of the first page). So we need to
                    // invert this.
                    //
                    // We DON'T need to do this for any middle pages because
                    // they always use the full page.
                    //
                    // This is a fixup that makes our start/end match the
                    // same logic as the loops above if they were in forward
                    // order.
                    assert(nodes.len >= 2);
                    starts[0] = ends[0] - 1;
                    ends[0] = cross_page_end_rows.?;
                    ends[nodes.len - 1] = starts[nodes.len - 1] + 1;
                    starts[nodes.len - 1] = 0;
                } else {
                    // For a single chunk, the y values are in reverse order
                    // (start is the screen-end, end is the screen-start).
                    // Swap them to get proper top-to-bottom order.
                    const start_y = starts[0];
                    starts[0] = ends[0] - 1;
                    ends[0] = start_y + 1;
                }

                // X values also need to be reversed since the top/bottom
                // are swapped for the nodes.
                const top_x = result.top_x;
                result.top_x = result.bot_x;
                result.bot_x = top_x;
            },
        }

        // Copy over our MultiArrayList so it points to the proper memory.
        result.chunks = self.chunk_buf;
        return result;
    }

    /// Add a new node to the sliding window. This will always grow
    /// the sliding window; data isn't pruned until it is consumed
    /// via a search (via next()).
    ///
    /// The content length is the number of bytes of content added to the
    /// sliding window. The total bytes will be larger since this omits
    /// metadata, but it is an accurate measure of the text content size
    /// added.
    ///
    /// This reads the node and its neighbours, so the caller must hold the
    /// necessary locks. `next()` then reads only what the window copied.
    pub fn append(
        self: *SlidingWindow,
        node: *PageList.List.Node,
    ) Allocator.Error!AppendResult {
        const page = node.page();
        const last_row_wrapped = page.getRow(page.size.rows - 1).wrap;
        return self.appendPage(node, page, last_row_wrapped);
    }

    /// Append a node only when its last row is soft wrapped.
    ///
    /// It is used when loading the overlap around an otherwise complete
    /// search region.
    pub fn appendIfWrapped(
        self: *SlidingWindow,
        node: *PageList.List.Node,
    ) Allocator.Error!?AppendResult {
        const page = node.page();
        const last_row_wrapped = page.getRow(page.size.rows - 1).wrap;
        if (!last_row_wrapped) return null;
        return try self.appendPage(node, page, last_row_wrapped);
    }

    /// Copy one page into the window's owned search buffers.
    fn appendPage(
        self: *SlidingWindow,
        node: *PageList.List.Node,
        page: *const Page,
        last_row_wrapped: bool,
    ) Allocator.Error!AppendResult {
        // Initialize our metadata for the node.
        var meta: Meta = .{
            .node = node,
            .serial = node.serial,
            .rows = page.size.rows,
            .cell_map = .empty,
            .before = before: {
                const prev = node.prev orelse break :before .none;
                const prev_page = prev.page();
                if (prev_page.getRow(prev_page.size.rows - 1).wrap) break :before .unknown;
                break :before .{ .byte = '\n' };
            },
            .has_next = node.next != null,
        };
        errdefer meta.deinit(self.alloc);

        // PageFormatter writes to a linear writer; copy that encoded
        // page into the circular search window below.
        var encoded: std.Io.Writer.Allocating = .init(self.alloc);
        defer encoded.deinit();

        // Encode the page into the buffer.
        const formatter: PageFormatter = formatter: {
            var formatter: PageFormatter = .init(page, .{
                .emit = .plain,
                .unwrap = true,
            });
            formatter.point_map = .{
                .alloc = self.alloc,
                .map = &meta.cell_map,
            };
            break :formatter formatter;
        };
        formatter.format(&encoded.writer) catch {
            // The ArrayList-backed writer can only fail by exhausting memory.
            return error.OutOfMemory;
        };
        assert(meta.cell_map.items.len == encoded.written().len);

        // If the node we're adding isn't soft-wrapped, we add the
        // trailing newline.
        if (!last_row_wrapped) {
            encoded.writer.writeByte('\n') catch return error.OutOfMemory;
            try meta.cell_map.append(
                self.alloc,
                meta.cell_map.getLastOrNull() orelse .{
                    .x = 0,
                    .y = 0,
                },
            );
        }

        // If our written data is empty, then there is nothing to
        // add to our data set.
        const written = encoded.written();
        if (written.len == 0) {
            self.assertIntegrity();
            return .{
                .content_len = 0,
                .last_row_wrapped = last_row_wrapped,
            };
        }

        // Get our written data. If we're doing a reverse search then we
        // need to reverse all our encodings.
        switch (self.direction) {
            .forward => {},
            .reverse => {
                std.mem.reverse(u8, written);
                std.mem.reverse(point.Coordinate, meta.cell_map.items);
            },
        }

        // Ensure our buffers are big enough to store what we need, and
        // reserve what next() needs so it never allocates.
        try self.data.ensureUnusedCapacity(self.alloc, written.len);
        try self.meta.ensureUnusedCapacity(self.alloc, 1);
        try self.chunk_buf.ensureTotalCapacity(self.alloc, self.meta.capacity());
        if (self.pattern != null) {
            try self.haystack_buf.ensureTotalCapacity(self.alloc, self.data.len() + written.len);
        }

        // Append our new node to the circular buffer.
        self.data.appendSliceAssumeCapacity(written);
        self.meta.appendAssumeCapacity(meta);

        self.assertIntegrity();
        return .{
            .content_len = written.len,
            .last_row_wrapped = last_row_wrapped,
        };
    }

    /// Only for tests!
    fn testChangeNeedle(self: *SlidingWindow, new: []const u8) void {
        assert(new.len == self.needle.len);
        self.alloc.free(self.needle);
        self.needle = self.alloc.dupe(u8, new) catch unreachable;
    }

    fn assertIntegrity(self: *const SlidingWindow) void {
        if (comptime !std.debug.runtime_safety) return;

        // We don't run integrity checks on Valgrind because its soooooo slow,
        // Valgrind is our integrity checker, and we run these during unit
        // tests (non-Valgrind) anyways so we're verifying anyways.
        if (std.valgrind.runningOnValgrind() > 0) return;

        // Integrity check: verify our data matches our metadata exactly.
        var meta_it = self.meta.iterator(.forward);
        var data_len: usize = 0;
        while (meta_it.next()) |m| data_len += m.cell_map.items.len;
        assert(data_len == self.data.len());

        // Integrity check: verify our data offset is within bounds.
        assert(self.data.len() == 0 or self.data_offset < self.data.len());
    }
};

const testPattern = @import("pattern.zig").testPattern;

test "SlidingWindow empty on init" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var w: SlidingWindow = try .init(alloc, .forward, "boo!");
    defer w.deinit();
    try testing.expectEqual(0, w.data.len());
    try testing.expectEqual(0, w.meta.len());
}

test "SlidingWindow empty needle has no matches" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var w: SlidingWindow = try .init(alloc, .forward, "");
    defer w.deinit();

    var s = try Screen.init(alloc, .{
        .cols = 80,
        .rows = 24,
        .max_scrollback = 0,
    });
    defer s.deinit();
    try s.testWriteString("hello");

    _ = try w.append(s.pages.pages.first.?);
    try testing.expectEqual(null, w.next());
}

test "SlidingWindow single append" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var w: SlidingWindow = try .init(alloc, .forward, "boo!");
    defer w.deinit();

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 0 });
    defer s.deinit();
    try s.testWriteString("hello. boo! hello. boo!");

    // We want to test single-page cases.
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    const node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(node);

    // We should be able to find two matches.
    {
        const h = w.next().?;
        const sel = h.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 7,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.start));
        try testing.expectEqual(point.Point{ .active = .{
            .x = 10,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.end));
    }
    {
        const h = w.next().?;
        const sel = h.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 19,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.start));
        try testing.expectEqual(point.Point{ .active = .{
            .x = 22,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.end));
    }
    try testing.expect(w.next() == null);
    try testing.expect(w.next() == null);
}

test "SlidingWindow single append case insensitive ASCII" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var w: SlidingWindow = try .init(alloc, .forward, "Boo!");
    defer w.deinit();

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 0 });
    defer s.deinit();
    try s.testWriteString("hello. boo! hello. boo!");

    // We want to test single-page cases.
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    const node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(node);

    // We should be able to find two matches.
    {
        const h = w.next().?;
        const sel = h.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 7,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.start));
        try testing.expectEqual(point.Point{ .active = .{
            .x = 10,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.end));
    }
    {
        const h = w.next().?;
        const sel = h.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 19,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.start));
        try testing.expectEqual(point.Point{ .active = .{
            .x = 22,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.end));
    }
    try testing.expect(w.next() == null);
    try testing.expect(w.next() == null);
}

test "SlidingWindow single append case sensitive" {
    if (comptime !build_options.oniguruma) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;
    const p = try testPattern(.{ .needle = "Boo!", .options = .{ .case_sensitive = true } });
    defer p.destroy(alloc);
    var w: SlidingWindow = try .initPattern(alloc, .forward, "Boo!", p);
    defer w.deinit();

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 0 });
    defer s.deinit();
    try s.testWriteString("hello. boo! hello. boo!");

    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    const node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(node);

    try testing.expect(w.next() == null);
}

test "SlidingWindow non-regex regex engine prunes no-match pages" {
    if (comptime !build_options.oniguruma) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;
    const p = try testPattern(.{ .needle = "Needle", .options = .{ .case_sensitive = true } });
    defer p.destroy(alloc);
    var w: SlidingWindow = try .initPattern(alloc, .forward, "Needle", p);
    defer w.deinit();

    var s = try Screen.init(alloc, .{ .cols = 20, .rows = 4, .max_scrollback = 1000 });
    defer s.deinit();

    const first_page_cells = s.pages.cols * s.pages.pages.first.?.capacity().rows;
    for (0..first_page_cells + w.needle.len + 1) |_| try s.testWriteString("x");
    try testing.expect(s.pages.pages.first != s.pages.pages.last);

    const first_node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(first_node);
    try testing.expect(w.next() == null);

    _ = try w.append(first_node.next.?);
    try testing.expect(w.next() == null);
    try testing.expectEqual(@as(usize, 1), w.meta.len());
    try testing.expectEqual(w.needle.len - 1, w.data.len() - w.data_offset);
}

test "SlidingWindow single append whole word" {
    if (comptime !build_options.oniguruma) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;
    const p = try testPattern(.{ .needle = "boo", .options = .{ .whole_word = true } });
    defer p.destroy(alloc);
    var w: SlidingWindow = try .initPattern(alloc, .forward, "boo", p);
    defer w.deinit();

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 0 });
    defer s.deinit();
    try s.testWriteString("booo boo barbar");

    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    const node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(node);

    const h = w.next().?;
    const sel = h.untracked();
    try testing.expectEqual(point.Point{ .active = .{
        .x = 5,
        .y = 0,
    } }, s.pages.pointFromPin(.active, sel.start));
    try testing.expectEqual(point.Point{ .active = .{
        .x = 7,
        .y = 0,
    } }, s.pages.pointFromPin(.active, sel.end));
    try testing.expect(w.next() == null);
}

test "SlidingWindow whole word matches true page edge" {
    if (comptime !build_options.oniguruma) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;
    const p = try testPattern(.{ .needle = "boo", .options = .{ .whole_word = true } });
    defer p.destroy(alloc);
    var w: SlidingWindow = try .initPattern(alloc, .forward, "boo", p);
    defer w.deinit();

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 1000 });
    defer s.deinit();

    const first_page_rows = s.pages.pages.first.?.capacity().rows;
    for (0..first_page_rows - 1) |_| try s.testWriteString("\n");
    for (0..s.pages.cols - 4) |_| try s.testWriteString("x");
    try s.testWriteString(" boo");
    try testing.expect(s.pages.pages.first == s.pages.pages.last);

    const first_node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(first_node);

    const h = w.next().?;
    const sel = h.untracked();
    try testing.expectEqual(point.Point{ .active = .{
        .x = 77,
        .y = 23,
    } }, s.pages.pointFromPin(.active, sel.start));
    try testing.expectEqual(point.Point{ .active = .{
        .x = 79,
        .y = 23,
    } }, s.pages.pointFromPin(.active, sel.end));
    try testing.expect(w.next() == null);
}

test "SlidingWindow whole word does not match synthetic page edge" {
    if (comptime !build_options.oniguruma) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;
    const p = try testPattern(.{ .needle = "boo", .options = .{ .whole_word = true } });
    defer p.destroy(alloc);
    var w: SlidingWindow = try .initPattern(alloc, .forward, "boo", p);
    defer w.deinit();

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 1000 });
    defer s.deinit();

    const first_page_rows = s.pages.pages.first.?.capacity().rows;
    for (0..first_page_rows - 1) |_| try s.testWriteString("\n");
    for (0..s.pages.cols - 4) |_| try s.testWriteString("x");
    try s.testWriteString(" boo");
    try s.testWriteString("x");
    try testing.expect(s.pages.pages.first != s.pages.pages.last);

    const first_node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(first_node);
    try testing.expect(w.next() == null);

    _ = try w.append(first_node.next.?);
    try testing.expect(w.next() == null);
}

test "SlidingWindow whole-word literal retains full synthetic edge match" {
    if (comptime !build_options.oniguruma) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;
    const p = try testPattern(.{ .needle = "boo", .options = .{ .whole_word = true } });
    defer p.destroy(alloc);
    var w: SlidingWindow = try .initPattern(alloc, .forward, "boo", p);
    defer w.deinit();

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 1000 });
    defer s.deinit();

    const first_page_rows = s.pages.pages.first.?.capacity().rows;
    for (0..first_page_rows - 1) |_| try s.testWriteString("\n");
    for (0..s.pages.cols - 4) |_| try s.testWriteString("x");
    try s.testWriteString(" boo");
    try s.testWriteString(" ");
    try testing.expect(s.pages.pages.first != s.pages.pages.last);

    const first_node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(first_node);
    try testing.expect(w.next() == null);

    _ = try w.append(first_node.next.?);
    const h = w.next().?;
    const sel = h.untracked();
    try testing.expectEqual(first_node, sel.start.node);
    try testing.expectEqual(first_node, sel.end.node);
}

test "SlidingWindow single append regex" {
    if (comptime !build_options.oniguruma) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;
    const p = try testPattern(.{ .needle = "b[o]{2}!", .options = .{ .regex = true } });
    defer p.destroy(alloc);
    var w: SlidingWindow = try .initPattern(alloc, .forward, "b[o]{2}!", p);
    defer w.deinit();

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 0 });
    defer s.deinit();
    try s.testWriteString("hello. baa! hello. boo!");

    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    const node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(node);

    const h = w.next().?;
    const sel = h.untracked();
    try testing.expectEqual(point.Point{ .active = .{
        .x = 19,
        .y = 0,
    } }, s.pages.pointFromPin(.active, sel.start));
    try testing.expectEqual(point.Point{ .active = .{
        .x = 22,
        .y = 0,
    } }, s.pages.pointFromPin(.active, sel.end));
    try testing.expect(w.next() == null);
}

test "SlidingWindow regex no match preserves window state" {
    if (comptime !build_options.oniguruma) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;
    const p = try testPattern(.{ .needle = "boo!", .options = .{ .regex = true } });
    defer p.destroy(alloc);
    var w: SlidingWindow = try .initPattern(alloc, .forward, "boo!", p);
    defer w.deinit();

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 0 });
    defer s.deinit();
    try s.testWriteString("hello. bo");

    const node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(node);

    const data_len = w.data.len();
    const meta_len = w.meta.len();
    try testing.expect(w.next() == null);
    try testing.expectEqual(data_len, w.data.len());
    try testing.expectEqual(meta_len, w.meta.len());
}

test "SlidingWindow regex no match defers pruning" {
    if (comptime !build_options.oniguruma) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;
    const p = try testPattern(.{ .needle = "b[o]{2}!", .options = .{ .regex = true } });
    defer p.destroy(alloc);
    var w: SlidingWindow = try .initPattern(alloc, .forward, "b[o]{2}!", p);
    defer w.deinit();

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 1000 });
    defer s.deinit();

    const first_page_rows = s.pages.pages.first.?.capacity().rows;
    for (0..first_page_rows - 1) |_| try s.testWriteString("\n");
    for (0..s.pages.cols) |_| try s.testWriteString("x");
    try s.testWriteString("yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy");
    try testing.expect(s.pages.pages.first != s.pages.pages.last);

    const first_node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(first_node);
    _ = try w.append(first_node.next.?);
    const data_len = w.data.len();

    try testing.expect(w.next() == null);
    try testing.expectEqual(@as(usize, 2), w.meta.len());
    try testing.expectEqual(data_len, w.data.len());
    try testing.expectEqual(@as(usize, 0), w.data_offset);
}

test "SlidingWindow regex no match keeps bounded suffix" {
    if (comptime !build_options.oniguruma) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;
    const p = try testPattern(.{ .needle = "y+z", .options = .{ .regex = true } });
    defer p.destroy(alloc);
    var w: SlidingWindow = try .initPattern(alloc, .forward, "y+z", p);
    defer w.deinit();

    var s = try Screen.init(alloc, .{ .cols = 120, .rows = 24, .max_scrollback = 1000 });
    defer s.deinit();

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(alloc);
    try text.appendNTimes(alloc, 'x', Pattern.regex_no_match_retain_len + 8192);
    try s.testWriteString(text.items);

    var node: ?*PageList.List.Node = s.pages.pages.first.?;
    while (node) |n| : (node = n.next) {
        _ = try w.append(n);
    }
    const meta_len = w.meta.len();
    try testing.expect(meta_len > 1);

    try testing.expect(w.next() == null);
    try testing.expectEqual(@as(usize, 0), w.data_offset);
    try testing.expectEqual(Pattern.regex_no_match_retain_len, w.data.len());
}

test "SlidingWindow regex match can span more than literal overlap" {
    if (comptime !build_options.oniguruma) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;
    const p = try testPattern(.{ .needle = "startx+end", .options = .{ .regex = true } });
    defer p.destroy(alloc);
    var w: SlidingWindow = try .initPattern(alloc, .forward, "startx+end", p);
    defer w.deinit();

    var s = try Screen.init(alloc, .{ .cols = 20, .rows = 4, .max_scrollback = 1000 });
    defer s.deinit();

    const first_page_cells = s.pages.cols * s.pages.pages.first.?.capacity().rows;
    try s.testWriteString("start");
    for (0..first_page_cells - "start".len) |_| try s.testWriteString("x");
    try s.testWriteString("end");
    try testing.expect(s.pages.pages.first != s.pages.pages.last);

    const first_node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(first_node);
    try testing.expect(w.next() == null);
    try testing.expectEqual(@as(usize, 1), w.meta.len());
    try testing.expectEqual(@as(usize, 0), w.data_offset);

    _ = try w.append(first_node.next.?);
    const h = w.next().?;
    const sel = h.untracked();
    try testing.expectEqual(first_node, sel.start.node);
    try testing.expectEqual(first_node.next.?, sel.end.node);
}

test "SlidingWindow reverse pattern haystack preserves offset across circular split" {
    if (comptime !build_options.oniguruma) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;
    const p = try testPattern(.{ .needle = "abc", .options = .{ .regex = true } });
    defer p.destroy(alloc);
    var w: SlidingWindow = try .initPattern(alloc, .reverse, "abc", p);
    defer w.deinit();

    try w.data.ensureUnusedCapacity(alloc, 8);
    w.data.appendSliceAssumeCapacity("123456");
    w.data.deleteOldest(4);
    w.data.appendSliceAssumeCapacity("abcdef");
    w.data_offset = 2;

    const slices = w.data.getPtrSlice(w.data_offset, w.data.len() - w.data_offset);
    try testing.expect(slices[0].len > 0);
    try testing.expect(slices[1].len > 0);

    // append reserves this; the data here was written directly.
    try w.haystack_buf.ensureTotalCapacity(alloc, w.data.len());
    const haystack = w.buildHaystack(slices[0], slices[1]);
    try testing.expectEqualStrings("fedcba", haystack);
}

test "SlidingWindow edge decision uses the page state captured at append" {
    if (comptime !build_options.oniguruma) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;
    const p = try testPattern(.{ .needle = "boo", .options = .{ .whole_word = true } });
    defer p.destroy(alloc);

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 1000 });
    defer s.deinit();

    const first_page_rows = s.pages.pages.first.?.capacity().rows;
    for (0..first_page_rows - 1) |_| try s.testWriteString("\n");
    try s.testWriteString("tail");
    try s.testWriteString("\n");
    try testing.expect(s.pages.pages.first != s.pages.pages.last);
    try s.testWriteString("boo ok");

    const first_node: *PageList.List.Node = s.pages.pages.first.?;
    const second_node = first_node.next.?;

    // The positive control: a word at the start of a page whose previous
    // line ends in a hard newline is a whole word.
    {
        var control: SlidingWindow = try .initPattern(alloc, .forward, "boo", p);
        defer control.deinit();
        _ = try control.append(second_node);
        const h = control.next() orelse return error.TestExpectedMatch;
        try testing.expectEqual(second_node, h.untracked().start.node);
    }

    var w: SlidingWindow = try .initPattern(alloc, .forward, "boo", p);
    defer w.deinit();
    _ = try w.append(second_node);

    // The previous page ended its last line with a hard newline when the
    // window took this one. The window is scanned without the terminal lock,
    // so the scan decides with that state even after a writer wraps the line.
    const last_row = first_node.page().getRow(first_node.rows() - 1);
    try testing.expect(!last_row.wrap);
    last_row.wrap = true;
    defer last_row.wrap = false;

    const h = w.next() orelse return error.TestExpectedMatch;
    const sel = h.untracked();
    try testing.expectEqual(second_node, sel.start.node);
    try testing.expectEqual(second_node, sel.end.node);
    try testing.expectEqual(@as(size.CellCountInt, 0), sel.start.x);
    try testing.expectEqual(@as(size.CellCountInt, 2), sel.end.x);
}

test "SlidingWindow reverse search works with non-default query options" {
    if (comptime !build_options.oniguruma) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;

    const p = try testPattern(.{ .needle = "boo!", .options = .{ .case_sensitive = true } });
    defer p.destroy(alloc);
    var w: SlidingWindow = try .initPattern(alloc, .reverse, "boo!", p);
    defer w.deinit();

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 0 });
    defer s.deinit();
    try s.testWriteString("hello. boo! hello. boo!");

    const node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(node);

    const h = w.next().?;
    const sel = h.untracked();
    try testing.expectEqual(point.Point{ .active = .{
        .x = 19,
        .y = 0,
    } }, s.pages.pointFromPin(.active, sel.start).?);
    try testing.expectEqual(point.Point{ .active = .{
        .x = 22,
        .y = 0,
    } }, s.pages.pointFromPin(.active, sel.end).?);
}

test "SlidingWindow reverse regex searches UTF-8 haystack in forward order" {
    if (comptime !build_options.oniguruma) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;
    const p = try testPattern(.{ .needle = "caf.", .options = .{ .regex = true } });
    defer p.destroy(alloc);
    var w: SlidingWindow = try .initPattern(alloc, .reverse, "caf.", p);
    defer w.deinit();

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 0 });
    defer s.deinit();
    try s.testWriteString("caf\xc3\xa9 one caf\xc3\xa9");

    const node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(node);

    const h = w.next().?;
    const sel = h.untracked();
    try testing.expectEqual(point.Point{ .active = .{
        .x = 9,
        .y = 0,
    } }, s.pages.pointFromPin(.active, sel.start).?);
    try testing.expectEqual(point.Point{ .active = .{
        .x = 12,
        .y = 0,
    } }, s.pages.pointFromPin(.active, sel.end).?);
}

test "SlidingWindow next does not allocate once pages are appended" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try Screen.init(alloc, .{
        .cols = 20,
        .rows = 4,
        .max_scrollback = std.math.maxInt(usize),
    });
    defer s.deinit();
    const first_page_cells = s.pages.cols * s.pages.pages.first.?.capacity().rows;
    const words = first_page_cells / 8 + 4;

    // Not "boo! x  ": the formatter trims the spaces that end the first
    // page, which glues its last word to the next page's first "boo" for
    // a whole-word match.
    for (0..words) |_| try s.testWriteString("boo! x..");
    try testing.expect(s.pages.pages.first != s.pages.pages.last);

    const p: ?*Pattern = if (comptime build_options.oniguruma)
        try testPattern(.{ .needle = "boo", .options = .{ .whole_word = true } })
    else
        null;
    defer if (p) |pattern| pattern.destroy(alloc);

    for ([_]?*Pattern{ null, p }) |pattern| {
        var w: SlidingWindow = try .initPattern(alloc, .forward, "boo", pattern);
        defer w.deinit();
        var node = s.pages.pages.first;
        while (node) |n| : (node = n.next) _ = try w.append(n);

        // Every allocation from here on fails, and the scan still finds
        // every match without one.
        var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
        w.alloc = failing.allocator();
        defer w.alloc = alloc;
        var matches: usize = 0;
        while (w.next()) |_| matches += 1;
        try testing.expectEqual(words, matches);
        try testing.expect(!failing.has_induced_failure);
    }
}

test "SlidingWindow single append single char" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var w: SlidingWindow = try .init(alloc, .forward, "b");
    defer w.deinit();

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 0 });
    defer s.deinit();
    try s.testWriteString("hello. boo! hello. boo!");

    // We want to test single-page cases.
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    const node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(node);

    // We should be able to find two matches.
    {
        const h = w.next().?;
        const sel = h.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 7,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.start));
        try testing.expectEqual(point.Point{ .active = .{
            .x = 7,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.end));
    }
    {
        const h = w.next().?;
        const sel = h.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 19,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.start));
        try testing.expectEqual(point.Point{ .active = .{
            .x = 19,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.end));
    }
    try testing.expect(w.next() == null);
    try testing.expect(w.next() == null);
}

test "SlidingWindow literal no match keeps whole pages and moves the offset" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var w: SlidingWindow = try .init(alloc, .forward, "nope!");
    defer w.deinit();

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 0 });
    defer s.deinit();
    try s.testWriteString("hello. boo! hello. boo!");
    _ = try w.append(s.pages.pages.first.?);
    const data_len = w.data.len();

    // Upstream's prune drops whole pages only, and the offset keeps the
    // `needle.len - 1` bytes a match that continues into the next page
    // needs.
    try testing.expect(w.next() == null);
    try testing.expectEqual(data_len, w.data.len());
    try testing.expectEqual(data_len - w.needle.len + 1, w.data_offset);
}

test "SlidingWindow literal no match keeps exactly needle.len - 1 bytes" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var w: SlidingWindow = try .init(alloc, .forward, "nope!");
    defer w.deinit();

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 1000 });
    defer s.deinit();

    // A full first page with no match, then a page holding only "zzz".
    const first_page_rows = s.pages.pages.first.?.capacity().rows;
    for (0..first_page_rows - 1) |_| try s.testWriteString("\n");
    for (0..s.pages.cols) |_| try s.testWriteString("x");
    try s.testWriteString("\n");
    try testing.expect(s.pages.pages.first != s.pages.pages.last);
    try s.testWriteString("zzz");

    const node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(node);
    _ = try w.append(node.next.?);
    {
        var it = w.meta.iterator(.reverse);
        try testing.expectEqual(w.needle.len - 1, it.next().?.cell_map.items.len);
    }

    // The prune drops the first page and keeps the last page's bytes,
    // exactly the `needle.len - 1` an overlap needs.
    try testing.expect(w.next() == null);
    try testing.expectEqual(1, w.meta.len());
    try testing.expectEqual(w.needle.len - 1, w.data.len());
    try testing.expectEqual(0, w.data_offset);
}

test "SlidingWindow single append no match" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var w: SlidingWindow = try .init(alloc, .forward, "nope!");
    defer w.deinit();

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 0 });
    defer s.deinit();
    try s.testWriteString("hello. boo! hello. boo!");

    // We want to test single-page cases.
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    const node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(node);

    // No matches
    try testing.expect(w.next() == null);
    try testing.expect(w.next() == null);

    // Should still keep the page
    try testing.expectEqual(1, w.meta.len());
}

test "SlidingWindow two pages" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var w: SlidingWindow = try .init(alloc, .forward, "boo!");
    defer w.deinit();

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 1000 });
    defer s.deinit();

    // Fill up the first page. The final bytes in the first page
    // are "boo!"
    const first_page_rows = s.pages.pages.first.?.capacity().rows;
    for (0..first_page_rows - 1) |_| try s.testWriteString("\n");
    for (0..s.pages.cols - 4) |_| try s.testWriteString("x");
    try s.testWriteString("boo!");
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    try s.testWriteString("\n");
    try testing.expect(s.pages.pages.first != s.pages.pages.last);
    try s.testWriteString("hello. boo!");

    // Add both pages
    const node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(node);
    _ = try w.append(node.next.?);

    // Search should find two matches
    {
        const h = w.next().?;
        const sel = h.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 76,
            .y = 22,
        } }, s.pages.pointFromPin(.active, sel.start).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 79,
            .y = 22,
        } }, s.pages.pointFromPin(.active, sel.end).?);
    }
    {
        const h = w.next().?;
        const sel = h.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 7,
            .y = 23,
        } }, s.pages.pointFromPin(.active, sel.start).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 10,
            .y = 23,
        } }, s.pages.pointFromPin(.active, sel.end).?);
    }
    try testing.expect(w.next() == null);
    try testing.expect(w.next() == null);
}

test "SlidingWindow two pages single char" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var w: SlidingWindow = try .init(alloc, .forward, "b");
    defer w.deinit();

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 1000 });
    defer s.deinit();

    // Fill up the first page. The final bytes in the first page
    // are "boo!"
    const first_page_rows = s.pages.pages.first.?.capacity().rows;
    for (0..first_page_rows - 1) |_| try s.testWriteString("\n");
    for (0..s.pages.cols - 4) |_| try s.testWriteString("x");
    try s.testWriteString("boo!");
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    try s.testWriteString("\n");
    try testing.expect(s.pages.pages.first != s.pages.pages.last);
    try s.testWriteString("hello. boo!");

    // Add both pages
    const node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(node);
    _ = try w.append(node.next.?);

    // Search should find two matches
    {
        const h = w.next().?;
        const sel = h.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 76,
            .y = 22,
        } }, s.pages.pointFromPin(.active, sel.start).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 76,
            .y = 22,
        } }, s.pages.pointFromPin(.active, sel.end).?);
    }
    {
        const h = w.next().?;
        const sel = h.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 7,
            .y = 23,
        } }, s.pages.pointFromPin(.active, sel.start).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 7,
            .y = 23,
        } }, s.pages.pointFromPin(.active, sel.end).?);
    }
    try testing.expect(w.next() == null);
    try testing.expect(w.next() == null);
}

test "SlidingWindow two pages match across boundary" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var w: SlidingWindow = try .init(alloc, .forward, "hello, world");
    defer w.deinit();

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 1000 });
    defer s.deinit();

    // Fill up the first page. The final bytes in the first page
    // are "boo!"
    const first_page_rows = s.pages.pages.first.?.capacity().rows;
    for (0..first_page_rows - 1) |_| try s.testWriteString("\n");
    for (0..s.pages.cols - 4) |_| try s.testWriteString("x");
    try s.testWriteString("hell");
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    try s.testWriteString("o, world!");
    try testing.expect(s.pages.pages.first != s.pages.pages.last);

    // Add both pages
    const node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(node);
    _ = try w.append(node.next.?);

    // Search should find a match
    {
        const h = w.next().?;
        const sel = h.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 76,
            .y = 22,
        } }, s.pages.pointFromPin(.active, sel.start).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 7,
            .y = 23,
        } }, s.pages.pointFromPin(.active, sel.end).?);
    }
    try testing.expect(w.next() == null);
    try testing.expect(w.next() == null);

    // We shouldn't prune because we don't have enough space
    try testing.expectEqual(2, w.meta.len());
}

test "SlidingWindow two pages no match across boundary with newline" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var w: SlidingWindow = try .init(alloc, .forward, "hello, world");
    defer w.deinit();

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 1000 });
    defer s.deinit();

    // Fill up the first page. The final bytes in the first page
    // are "boo!"
    const first_page_rows = s.pages.pages.first.?.capacity().rows;
    for (0..first_page_rows - 1) |_| try s.testWriteString("\n");
    for (0..s.pages.cols - 4) |_| try s.testWriteString("x");
    try s.testWriteString("hell");
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    try s.testWriteString("\no, world!");
    try testing.expect(s.pages.pages.first != s.pages.pages.last);

    // Add both pages
    const node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(node);
    _ = try w.append(node.next.?);

    // Search should NOT find a match
    try testing.expect(w.next() == null);
    try testing.expect(w.next() == null);

    // We shouldn't prune because we don't have enough space
    try testing.expectEqual(2, w.meta.len());
}

test "SlidingWindow two pages no match across boundary with newline reverse" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var w: SlidingWindow = try .init(alloc, .reverse, "hello, world");
    defer w.deinit();

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 1000 });
    defer s.deinit();

    // Fill up the first page. The final bytes in the first page
    // are "boo!"
    const first_page_rows = s.pages.pages.first.?.capacity().rows;
    for (0..first_page_rows - 1) |_| try s.testWriteString("\n");
    for (0..s.pages.cols - 4) |_| try s.testWriteString("x");
    try s.testWriteString("hell");
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    try s.testWriteString("\no, world!");
    try testing.expect(s.pages.pages.first != s.pages.pages.last);

    // Add both pages in reverse order
    const node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(node.next.?);
    _ = try w.append(node);

    // Search should NOT find a match
    try testing.expect(w.next() == null);
    try testing.expect(w.next() == null);
}

test "SlidingWindow two pages no match prunes first page" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var w: SlidingWindow = try .init(alloc, .forward, "nope!");
    defer w.deinit();

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 1000 });
    defer s.deinit();

    // Fill up the first page. The final bytes in the first page
    // are "boo!"
    const first_page_rows = s.pages.pages.first.?.capacity().rows;
    for (0..first_page_rows - 1) |_| try s.testWriteString("\n");
    for (0..s.pages.cols - 4) |_| try s.testWriteString("x");
    try s.testWriteString("boo!");
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    try s.testWriteString("\n");
    try testing.expect(s.pages.pages.first != s.pages.pages.last);
    try s.testWriteString("hello. boo!");

    // Add both pages
    const node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(node);
    _ = try w.append(node.next.?);

    // Search should find nothing
    try testing.expect(w.next() == null);
    try testing.expect(w.next() == null);

    // We should've pruned our page because the second page
    // has enough text to contain our needle.
    try testing.expectEqual(1, w.meta.len());
}

test "SlidingWindow two pages no match keeps both pages" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 1000 });
    defer s.deinit();

    // Fill up the first page. The final bytes in the first page
    // are "boo!"
    const first_page_rows = s.pages.pages.first.?.capacity().rows;
    for (0..first_page_rows - 1) |_| try s.testWriteString("\n");
    for (0..s.pages.cols - 4) |_| try s.testWriteString("x");
    try s.testWriteString("boo!");
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    try s.testWriteString("\n");
    try testing.expect(s.pages.pages.first != s.pages.pages.last);
    try s.testWriteString("hello. boo!");

    // Imaginary needle for search. Doesn't match!
    var needle_list: std.ArrayList(u8) = .empty;
    defer needle_list.deinit(alloc);
    try needle_list.appendNTimes(alloc, 'x', first_page_rows * s.pages.cols);
    const needle: []const u8 = needle_list.items;

    var w: SlidingWindow = try .init(alloc, .forward, needle);
    defer w.deinit();

    // Add both pages
    const node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(node);
    _ = try w.append(node.next.?);

    // Search should find nothing
    try testing.expect(w.next() == null);
    try testing.expect(w.next() == null);

    // No pruning because both pages are needed to fit needle.
    try testing.expectEqual(2, w.meta.len());
}

test "SlidingWindow single append across circular buffer boundary" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var w: SlidingWindow = try .init(alloc, .forward, "abc");
    defer w.deinit();

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 0 });
    defer s.deinit();
    try s.testWriteString("XXXXXXXXXXXXXXXXXXXboo!XXXXX");

    // We are trying to break a circular buffer boundary so the way we
    // do this is to duplicate the data then do a failing search. This
    // will cause the first page to be pruned. The next time we append we'll
    // put it in the middle of the circ buffer. We assert this so that if
    // our implementation changes our test will fail.
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    const node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(node);
    _ = try w.append(node);
    {
        // No wrap around yet
        const slices = w.data.getPtrSlice(0, w.data.len());
        try testing.expect(slices[0].len > 0);
        try testing.expect(slices[1].len == 0);
    }

    // Search non-match, prunes page
    try testing.expect(w.next() == null);
    try testing.expectEqual(1, w.meta.len());

    // Change the needle, just needs to be the same length (not a real API)
    w.testChangeNeedle("boo");

    // Add new page, now wraps
    _ = try w.append(node);
    {
        const slices = w.data.getPtrSlice(0, w.data.len());
        try testing.expect(slices[0].len > 0);
        try testing.expect(slices[1].len > 0);
    }
    {
        const h = w.next().?;
        const sel = h.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 19,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.start).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 21,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.end).?);
    }
    try testing.expect(w.next() == null);
}

test "SlidingWindow single append match on boundary" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var w: SlidingWindow = try .init(alloc, .forward, "abcd");
    defer w.deinit();

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 0 });
    defer s.deinit();
    try s.testWriteString("o!XXXXXXXXXXXXXXXXXXXbo");

    // We need to surgically modify the last row to be soft-wrapped
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    const node: *PageList.List.Node = s.pages.pages.first.?;
    node.page().getRow(node.rows() - 1).wrap = true;

    // We are trying to break a circular buffer boundary so the way we
    // do this is to duplicate the data then do a failing search. This
    // will cause the first page to be pruned. The next time we append we'll
    // put it in the middle of the circ buffer. We assert this so that if
    // our implementation changes our test will fail.
    _ = try w.append(node);
    _ = try w.append(node);
    {
        // No wrap around yet
        const slices = w.data.getPtrSlice(0, w.data.len());
        try testing.expect(slices[0].len > 0);
        try testing.expect(slices[1].len == 0);
    }

    // Search non-match, prunes page
    try testing.expect(w.next() == null);
    try testing.expectEqual(1, w.meta.len());

    // Change the needle, just needs to be the same length (not a real API)
    w.testChangeNeedle("boo!");

    // Add new page, now wraps
    _ = try w.append(node);
    {
        const slices = w.data.getPtrSlice(0, w.data.len());
        try testing.expect(slices[0].len > 0);
        try testing.expect(slices[1].len > 0);
    }
    {
        const h = w.next().?;
        const sel = h.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 21,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.start).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 1,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.end).?);
    }
    try testing.expect(w.next() == null);
}

test "SlidingWindow single append reversed" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var w: SlidingWindow = try .init(alloc, .reverse, "boo!");
    defer w.deinit();

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 0 });
    defer s.deinit();
    try s.testWriteString("hello. boo! hello. boo!");

    // We want to test single-page cases.
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    const node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(node);

    // We should be able to find two matches.
    {
        const h = w.next().?;
        const sel = h.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 19,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.start).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 22,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.end).?);
    }
    {
        const h = w.next().?;
        const sel = h.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 7,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.start).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 10,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.end).?);
    }
    try testing.expect(w.next() == null);
    try testing.expect(w.next() == null);
}

test "SlidingWindow single append no match reversed" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var w: SlidingWindow = try .init(alloc, .reverse, "nope!");
    defer w.deinit();

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 0 });
    defer s.deinit();
    try s.testWriteString("hello. boo! hello. boo!");

    // We want to test single-page cases.
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    const node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(node);

    // No matches
    try testing.expect(w.next() == null);
    try testing.expect(w.next() == null);

    // Should still keep the page
    try testing.expectEqual(1, w.meta.len());
}

test "SlidingWindow two pages reversed" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var w: SlidingWindow = try .init(alloc, .reverse, "boo!");
    defer w.deinit();

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 1000 });
    defer s.deinit();

    // Fill up the first page. The final bytes in the first page
    // are "boo!"
    const first_page_rows = s.pages.pages.first.?.capacity().rows;
    for (0..first_page_rows - 1) |_| try s.testWriteString("\n");
    for (0..s.pages.cols - 4) |_| try s.testWriteString("x");
    try s.testWriteString("boo!");
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    try s.testWriteString("\n");
    try testing.expect(s.pages.pages.first != s.pages.pages.last);
    try s.testWriteString("hello. boo!");

    // Add both pages in reverse order
    const node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(node.next.?);
    _ = try w.append(node);

    // Search should find two matches (in reverse order)
    {
        const h = w.next().?;
        const sel = h.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 7,
            .y = 23,
        } }, s.pages.pointFromPin(.active, sel.start).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 10,
            .y = 23,
        } }, s.pages.pointFromPin(.active, sel.end).?);
    }
    {
        const h = w.next().?;
        const sel = h.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 76,
            .y = 22,
        } }, s.pages.pointFromPin(.active, sel.start).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 79,
            .y = 22,
        } }, s.pages.pointFromPin(.active, sel.end).?);
    }
    try testing.expect(w.next() == null);
    try testing.expect(w.next() == null);
}

test "SlidingWindow two pages match across boundary reversed" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var w: SlidingWindow = try .init(alloc, .reverse, "hello, world");
    defer w.deinit();

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 1000 });
    defer s.deinit();

    // Fill up the first page. The final bytes in the first page
    // are "hell"
    const first_page_rows = s.pages.pages.first.?.capacity().rows;
    for (0..first_page_rows - 1) |_| try s.testWriteString("\n");
    for (0..s.pages.cols - 4) |_| try s.testWriteString("x");
    try s.testWriteString("hell");
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    try s.testWriteString("o, world!");
    try testing.expect(s.pages.pages.first != s.pages.pages.last);

    // Add both pages in reverse order
    const node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(node.next.?);
    _ = try w.append(node);

    // Search should find a match
    {
        const h = w.next().?;
        const chunks = h.chunks.slice();
        const nodes = chunks.items(.node);
        const serials = chunks.items(.serial);
        try testing.expectEqual(2, chunks.len);
        try testing.expectEqual(node, nodes[0]);
        try testing.expectEqual(node.serial, serials[0]);
        try testing.expectEqual(node.next.?, nodes[1]);
        try testing.expectEqual(node.next.?.serial, serials[1]);

        const sel = h.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 76,
            .y = 22,
        } }, s.pages.pointFromPin(.active, sel.start).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 7,
            .y = 23,
        } }, s.pages.pointFromPin(.active, sel.end).?);
    }
    try testing.expect(w.next() == null);
    try testing.expect(w.next() == null);

    // In reverse mode, the last appended meta (first original page) is large
    // enough to contain needle.len - 1 bytes, so pruning occurs
    try testing.expectEqual(1, w.meta.len());
}

test "SlidingWindow two pages no match prunes first page reversed" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var w: SlidingWindow = try .init(alloc, .reverse, "nope!");
    defer w.deinit();

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 1000 });
    defer s.deinit();

    // Fill up the first page. The final bytes in the first page
    // are "boo!"
    const first_page_rows = s.pages.pages.first.?.capacity().rows;
    for (0..first_page_rows - 1) |_| try s.testWriteString("\n");
    for (0..s.pages.cols - 4) |_| try s.testWriteString("x");
    try s.testWriteString("boo!");
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    try s.testWriteString("\n");
    try testing.expect(s.pages.pages.first != s.pages.pages.last);
    try s.testWriteString("hello. boo!");

    // Add both pages in reverse order
    const node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(node.next.?);
    _ = try w.append(node);

    // Search should find nothing
    try testing.expect(w.next() == null);
    try testing.expect(w.next() == null);

    // We should've pruned our page because the second page
    // has enough text to contain our needle.
    try testing.expectEqual(1, w.meta.len());
}

test "SlidingWindow two pages no match keeps both pages reversed" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 1000 });
    defer s.deinit();

    // Fill up the first page. The final bytes in the first page
    // are "boo!"
    const first_page_rows = s.pages.pages.first.?.capacity().rows;
    for (0..first_page_rows - 1) |_| try s.testWriteString("\n");
    for (0..s.pages.cols - 4) |_| try s.testWriteString("x");
    try s.testWriteString("boo!");
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    try s.testWriteString("\n");
    try testing.expect(s.pages.pages.first != s.pages.pages.last);
    try s.testWriteString("hello. boo!");

    // Imaginary needle for search. Doesn't match!
    var needle_list: std.ArrayList(u8) = .empty;
    defer needle_list.deinit(alloc);
    try needle_list.appendNTimes(alloc, 'x', first_page_rows * s.pages.cols);
    const needle: []const u8 = needle_list.items;

    var w: SlidingWindow = try .init(alloc, .reverse, needle);
    defer w.deinit();

    // Add both pages in reverse order
    const node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(node.next.?);
    _ = try w.append(node);

    // Search should find nothing
    try testing.expect(w.next() == null);
    try testing.expect(w.next() == null);

    // No pruning because both pages are needed to fit needle.
    try testing.expectEqual(2, w.meta.len());
}

test "SlidingWindow single append across circular buffer boundary reversed" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var w: SlidingWindow = try .init(alloc, .reverse, "abc");
    defer w.deinit();

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 0 });
    defer s.deinit();
    try s.testWriteString("XXXXXXXXXXXXXXXXXXXboo!XXXXX");

    // We are trying to break a circular buffer boundary so the way we
    // do this is to duplicate the data then do a failing search. This
    // will cause the first page to be pruned. The next time we append we'll
    // put it in the middle of the circ buffer. We assert this so that if
    // our implementation changes our test will fail.
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    const node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(node);
    _ = try w.append(node);
    {
        // No wrap around yet
        const slices = w.data.getPtrSlice(0, w.data.len());
        try testing.expect(slices[0].len > 0);
        try testing.expect(slices[1].len == 0);
    }

    // Search non-match, prunes page
    try testing.expect(w.next() == null);
    try testing.expectEqual(1, w.meta.len());

    // Change the needle, just needs to be the same length (not a real API)
    // testChangeNeedle doesn't reverse, so pass reversed needle for reverse mode
    w.testChangeNeedle("oob");

    // Add new page, now wraps
    _ = try w.append(node);
    {
        const slices = w.data.getPtrSlice(0, w.data.len());
        try testing.expect(slices[0].len > 0);
        try testing.expect(slices[1].len > 0);
    }
    {
        const h = w.next().?;
        const sel = h.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 19,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.start).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 21,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.end).?);
    }
    try testing.expect(w.next() == null);
}

test "SlidingWindow single append match on boundary reversed" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var w: SlidingWindow = try .init(alloc, .reverse, "abcd");
    defer w.deinit();

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 0 });
    defer s.deinit();
    try s.testWriteString("o!XXXXXXXXXXXXXXXXXXXbo");

    // We need to surgically modify the last row to be soft-wrapped
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    const node: *PageList.List.Node = s.pages.pages.first.?;
    node.page().getRow(node.rows() - 1).wrap = true;

    // We are trying to break a circular buffer boundary so the way we
    // do this is to duplicate the data then do a failing search. This
    // will cause the first page to be pruned. The next time we append we'll
    // put it in the middle of the circ buffer. We assert this so that if
    // our implementation changes our test will fail.
    _ = try w.append(node);
    _ = try w.append(node);
    {
        // No wrap around yet
        const slices = w.data.getPtrSlice(0, w.data.len());
        try testing.expect(slices[0].len > 0);
        try testing.expect(slices[1].len == 0);
    }

    // Search non-match, prunes page
    try testing.expect(w.next() == null);
    try testing.expectEqual(1, w.meta.len());

    // Change the needle, just needs to be the same length (not a real API)
    // testChangeNeedle doesn't reverse, so pass reversed needle for reverse mode
    w.testChangeNeedle("!oob");

    // Add new page, now wraps
    _ = try w.append(node);
    {
        const slices = w.data.getPtrSlice(0, w.data.len());
        try testing.expect(slices[0].len > 0);
        try testing.expect(slices[1].len > 0);
    }
    {
        const h = w.next().?;
        const sel = h.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 21,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.start).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 1,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.end).?);
    }
    try testing.expect(w.next() == null);
}

test "SlidingWindow single append soft wrapped" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var w: SlidingWindow = try .init(alloc, .forward, "boo!");
    defer w.deinit();

    var t: Terminal = try .init(alloc, .{ .cols = 4, .rows = 5 });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("A\r\nxxboo!\r\nC");

    // We want to test single-page cases.
    const screen = t.screens.active;
    try testing.expect(screen.pages.pages.first == screen.pages.pages.last);
    const node: *PageList.List.Node = screen.pages.pages.first.?;
    _ = try w.append(node);

    // We should be able to find two matches.
    {
        const h = w.next().?;
        const sel = h.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 2,
            .y = 1,
        } }, screen.pages.pointFromPin(.active, sel.start));
        try testing.expectEqual(point.Point{ .active = .{
            .x = 1,
            .y = 2,
        } }, screen.pages.pointFromPin(.active, sel.end));
    }
    try testing.expect(w.next() == null);
    try testing.expect(w.next() == null);
}

test "SlidingWindow single append reversed soft wrapped" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var w: SlidingWindow = try .init(alloc, .reverse, "boo!");
    defer w.deinit();

    var t: Terminal = try .init(alloc, .{ .cols = 4, .rows = 5 });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("A\r\nxxboo!\r\nC");

    // We want to test single-page cases.
    const screen = t.screens.active;
    try testing.expect(screen.pages.pages.first == screen.pages.pages.last);
    const node: *PageList.List.Node = screen.pages.pages.first.?;
    _ = try w.append(node);

    // We should be able to find two matches.
    {
        const h = w.next().?;
        const sel = h.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 2,
            .y = 1,
        } }, screen.pages.pointFromPin(.active, sel.start));
        try testing.expectEqual(point.Point{ .active = .{
            .x = 1,
            .y = 2,
        } }, screen.pages.pointFromPin(.active, sel.end));
    }
    try testing.expect(w.next() == null);
    try testing.expect(w.next() == null);
}

// This tests a real bug that occurred where a whitespace-only page
// that encodes to zero bytes would crash.
test "SlidingWindow append whitespace only node" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var w: SlidingWindow = try .init(alloc, .forward, "x");
    defer w.deinit();

    var s = try Screen.init(alloc, .{
        .cols = 80,
        .rows = 24,
        .max_scrollback = 0,
    });
    defer s.deinit();

    // By setting the empty page to wrap we get a zero-byte page.
    // This is invasive but its otherwise hard to reproduce naturally
    // without creating a slow test.
    const node: *PageList.List.Node = s.pages.pages.first.?;
    const last_row = node.page().getRow(node.rows() - 1);
    last_row.wrap = true;

    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    _ = try w.append(node);

    // No matches expected
    try testing.expect(w.next() == null);
}
