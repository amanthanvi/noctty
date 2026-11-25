//! astdump (r39, round 38's lead direction, item 1): every token and every node of each Zig source file exactly as
//! the compiler's own parser (std.zig.Ast) reads it, for the residue gate and the binding check, which take every
//! structure from it instead of reading Zig by hand.
//!
//! Usage: astdump <out file> <list file>, the list one source path per line; a path written `?<path>` gets its parse
//! result alone (the P line). The dump's first line is `astdump 3 legacy <version>` (the 1A compiler's Ast, whose tokenizer has
//! a `**` operator) or `astdump 3 current <version>`, <version> the building compiler's (r40). For each file it writes
//!   F <path>
//!   P <parse errors> [<first error's tag> <its token's byte offset>]   (any error: UNPARSEABLE; no N section then)
//!   K <token count>             then one line per token: <tag> <start byte> <end byte>
//!   N <node count> <reached>    then one line per reached node: <index> <tag> <main token> <first token>
//!                               <last token> <parent index, -1 for the root> <role in the parent> [<key>=<value>]...
//!   X <problem> <node>          a node reached twice, a tag this tool does not walk, or an unreached node
//!   E
//! A role names the child's place in its parent's data (lhs, rhs, operand, cond, then, else, init, type, value, arg,
//! callee, elem, field, ...). The extra keys are token indices (-1: none): `pay` and `err` (a capture list's first
//! token, `|x|` and `else |e|`), `lbl` (a label), `name` (a function's name), `p` (a parameter, <name token>/<type
//! node>), `mut` and `ct` (a declaration's `const` or `var`, and its `comptime`), and for a container field `tuple`
//! (1 when it is tuple-like) and `ct`.
//! Parent links are exact: each node's children are the nodes its own data names (the full-node accessors and the
//! node data fields the Ast documents), walked from the root; every node must be reached once, which the tiling check
//! (zigast.py) then verifies against each node's token span. A file that cannot be read is written as `F <path>`,
//! `R` (unreadable) and `E`.
//!
//! Built with the compiler that matches the tree it reads and run through scripts\dev-windows.cmd. It links libc and
//! does its file I/O through it, the one interface both supported compilers' standard libraries share unchanged; the
//! two compilers' Ast differ only where named below (`legacy_ast`).
const std = @import("std");
const Ast = std.zig.Ast;
const Node = Ast.Node;
const c = std.c;

/// The older Ast still has the `**` array-multiplication node, legacy assembly and an `errdefer` payload token.
const legacy_ast = @hasDecl(Node, "AsmLegacy");

const gpa = std.heap.c_allocator;

var out_file: ?*c.FILE = null;
var obuf: [1 << 16]u8 = undefined;
var olen: usize = 0;

fn flush() void {
    if (olen > 0) {
        _ = c.fwrite(&obuf, 1, olen, out_file.?);
        olen = 0;
    }
}

fn put(s: []const u8) void {
    if (olen + s.len > obuf.len) flush();
    if (s.len > obuf.len) {
        _ = c.fwrite(s.ptr, 1, s.len, out_file.?);
        return;
    }
    @memcpy(obuf[olen..][0..s.len], s);
    olen += s.len;
}

fn putInt(v: i64) void {
    var b: [24]u8 = undefined;
    var i: usize = b.len;
    var x: u64 = if (v < 0) @intCast(-v) else @intCast(v);
    while (true) {
        i -= 1;
        b[i] = @intCast('0' + x % 10);
        x /= 10;
        if (x == 0) break;
    }
    if (v < 0) {
        i -= 1;
        b[i] = '-';
    }
    put(b[i..]);
}

fn putKey(key: []const u8, v: i64) void {
    put(" ");
    put(key);
    put("=");
    putInt(v);
}

fn optTok(t: ?Ast.TokenIndex) i64 {
    return if (t) |x| @intCast(x) else -1;
}

/// A node index as its integer, read from its bytes (the two compilers name the enum-to-integer builtin differently).
fn nodeInt(n: Node.Index) u32 {
    return std.mem.bytesToValue(u32, std.mem.asBytes(&n));
}

fn readFile(path: [*:0]const u8) ?[:0]u8 {
    const f = c.fopen(path, "rb") orelse return null;
    defer _ = c.fclose(f);
    var cap: usize = 1 << 16;
    var buf = gpa.alloc(u8, cap + 1) catch return null;
    var len: usize = 0;
    while (true) {
        if (len == cap) {
            const nb = gpa.realloc(buf, cap * 2 + 1) catch return null;
            buf = nb;
            cap *= 2;
        }
        const got = c.fread(buf.ptr + len, 1, cap - len, f);
        if (got == 0) break;
        len += got;
    }
    buf[len] = 0;
    return buf[0..len :0];
}

const Walk = struct {
    tree: *const Ast,
    parent: []i64, // -2: not reached
    role: [][]const u8,
    stack: []Node.Index,
    sp: usize = 0,
    problems: usize = 0,

    fn problem(w: *Walk, what: []const u8, n: Node.Index) void {
        put("X ");
        put(what);
        put(" ");
        putInt(nodeInt(n));
        put("\n");
        w.problems += 1;
    }

    fn add(w: *Walk, p: Node.Index, ch: Node.Index, role: []const u8) void {
        const i = nodeInt(ch);
        if (i >= w.parent.len) return w.problem("out-of-range", ch);
        if (w.parent[i] != -2) return w.problem("reached-twice", ch);
        w.parent[i] = nodeInt(p);
        w.role[i] = role;
        w.stack[w.sp] = ch;
        w.sp += 1;
    }

    fn opt(w: *Walk, p: Node.Index, ch: Node.OptionalIndex, role: []const u8) void {
        if (ch.unwrap()) |x| w.add(p, x, role);
    }

    fn all(w: *Walk, p: Node.Index, xs: []const Node.Index, role: []const u8) void {
        for (xs) |x| w.add(p, x, role);
    }

    /// Every child of `n`: the nodes its data names, per tag, each with its role.
    fn children(w: *Walk, n: Node.Index) void {
        const t = w.tree;
        var buf2: [2]Node.Index = undefined;
        var buf1: [1]Node.Index = undefined;
        switch (t.nodeTag(n)) {
            .root => w.all(n, t.rootDecls(), "member"),
            .identifier, .number_literal, .char_literal, .string_literal, .multiline_string_literal, .enum_literal,
            .error_value, .unreachable_literal, .error_set_decl,
            => {},
            .@"defer", .bool_not, .negation, .bit_not, .negation_wrap, .address_of, .@"try", .optional_type, .deref,
            .@"suspend", .@"resume", .@"comptime", .@"nosuspend",
            => w.add(n, t.nodeData(n).node, "operand"),
            .@"errdefer" => if (legacy_ast) w.add(n, t.nodeData(n).opt_token_and_node[1], "operand") else w.add(n, t.nodeData(n).node, "operand"),
            .@"catch", .equal_equal, .bang_equal, .less_than, .greater_than, .less_or_equal, .greater_or_equal,
            .assign_mul, .assign_div, .assign_mod, .assign_add, .assign_sub, .assign_shl, .assign_shl_sat,
            .assign_shr, .assign_bit_and, .assign_bit_xor, .assign_bit_or, .assign_mul_wrap, .assign_add_wrap,
            .assign_sub_wrap, .assign_mul_sat, .assign_add_sat, .assign_sub_sat, .assign, .merge_error_sets, .mul,
            .div, .mod, .mul_wrap, .mul_sat, .add, .sub, .array_cat, .add_wrap, .sub_wrap, .add_sat, .sub_sat, .shl,
            .shl_sat, .shr, .bit_and, .bit_xor, .bit_or, .@"orelse", .bool_and, .bool_or, .switch_range, .error_union,
            => {
                const d = t.nodeData(n).node_and_node;
                w.add(n, d[0], "lhs");
                w.add(n, d[1], "rhs");
            },
            .array_type => {
                const d = t.nodeData(n).node_and_node;
                w.add(n, d[0], "len");
                w.add(n, d[1], "elem_type");
            },
            .array_access => {
                const d = t.nodeData(n).node_and_node;
                w.add(n, d[0], "object");
                w.add(n, d[1], "index");
            },
            .fn_decl => {
                const d = t.nodeData(n).node_and_node;
                w.add(n, d[0], "proto");
                w.add(n, d[1], "body");
            },
            .field_access, .unwrap_optional => w.add(n, t.nodeData(n).node_and_token[0], "object"),
            .grouped_expression => w.add(n, t.nodeData(n).node_and_token[0], "operand"),
            .@"return" => w.opt(n, t.nodeData(n).opt_node, "operand"),
            .@"break", .@"continue" => w.opt(n, t.nodeData(n).opt_token_and_opt_node[1], "operand"),
            .test_decl => w.add(n, t.nodeData(n).opt_token_and_node[1], "body"),
            .anyframe_type => w.add(n, t.nodeData(n).token_and_node[1], "type"),
            .for_range => {
                const d = t.nodeData(n).node_and_opt_node;
                w.add(n, d[0], "start");
                w.opt(n, d[1], "end");
            },
            .global_var_decl, .local_var_decl, .simple_var_decl, .aligned_var_decl => {
                const v = t.fullVarDecl(n).?;
                w.opt(n, v.ast.type_node, "type");
                w.opt(n, v.ast.align_node, "align");
                w.opt(n, v.ast.addrspace_node, "addrspace");
                w.opt(n, v.ast.section_node, "section");
                w.opt(n, v.ast.init_node, "init");
            },
            .assign_destructure => {
                const a = t.assignDestructure(n);
                w.all(n, a.ast.variables, "target");
                w.add(n, a.ast.value_expr, "value");
            },
            .array_type_sentinel => {
                const a = t.fullArrayType(n).?;
                w.add(n, a.ast.elem_count, "len");
                w.opt(n, a.ast.sentinel, "sentinel");
                w.add(n, a.ast.elem_type, "elem_type");
            },
            .ptr_type_aligned, .ptr_type_sentinel, .ptr_type, .ptr_type_bit_range => {
                const p = t.fullPtrType(n).?;
                w.opt(n, p.ast.sentinel, "sentinel");
                w.opt(n, p.ast.align_node, "align");
                w.opt(n, p.ast.bit_range_start, "bit_start");
                w.opt(n, p.ast.bit_range_end, "bit_end");
                w.opt(n, p.ast.addrspace_node, "addrspace");
                w.add(n, p.ast.child_type, "elem_type");
            },
            .slice_open, .slice, .slice_sentinel => {
                const s = t.fullSlice(n).?;
                w.add(n, s.ast.sliced, "object");
                w.add(n, s.ast.start, "start");
                w.opt(n, s.ast.end, "end");
                w.opt(n, s.ast.sentinel, "sentinel");
            },
            .array_init_one, .array_init_one_comma, .array_init_dot_two, .array_init_dot_two_comma, .array_init_dot,
            .array_init_dot_comma, .array_init, .array_init_comma,
            => {
                const a = t.fullArrayInit(&buf2, n).?;
                w.opt(n, a.ast.type_expr, "type");
                w.all(n, a.ast.elements, "elem");
            },
            .struct_init_one, .struct_init_one_comma, .struct_init_dot_two, .struct_init_dot_two_comma,
            .struct_init_dot, .struct_init_dot_comma, .struct_init, .struct_init_comma,
            => {
                const s = t.fullStructInit(&buf2, n).?;
                w.opt(n, s.ast.type_expr, "type");
                w.all(n, s.ast.fields, "field");
            },
            .call_one, .call_one_comma, .call, .call_comma => {
                const k = t.fullCall(&buf1, n).?;
                w.add(n, k.ast.fn_expr, "callee");
                w.all(n, k.ast.params, "arg");
            },
            .@"switch", .switch_comma => {
                const s = t.fullSwitch(n).?;
                w.add(n, s.ast.condition, "cond");
                w.all(n, s.ast.cases, "case");
            },
            .switch_case_one, .switch_case_inline_one, .switch_case, .switch_case_inline => {
                const s = t.fullSwitchCase(n).?;
                w.all(n, s.ast.values, "item");
                w.add(n, s.ast.target_expr, "target");
            },
            .while_simple, .while_cont, .@"while" => {
                const l = t.fullWhile(n).?;
                w.add(n, l.ast.cond_expr, "cond");
                w.opt(n, l.ast.cont_expr, "cont");
                w.add(n, l.ast.then_expr, "then");
                w.opt(n, l.ast.else_expr, "else");
            },
            .for_simple, .@"for" => {
                const l = t.fullFor(n).?;
                w.all(n, l.ast.inputs, "input");
                w.add(n, l.ast.then_expr, "then");
                w.opt(n, l.ast.else_expr, "else");
            },
            .if_simple, .@"if" => {
                const i = t.fullIf(n).?;
                w.add(n, i.ast.cond_expr, "cond");
                w.add(n, i.ast.then_expr, "then");
                w.opt(n, i.ast.else_expr, "else");
            },
            .fn_proto_simple, .fn_proto_multi, .fn_proto_one, .fn_proto => {
                const f = t.fullFnProto(&buf1, n).?;
                w.all(n, f.ast.params, "param");
                w.opt(n, f.ast.align_expr, "align");
                w.opt(n, f.ast.addrspace_expr, "addrspace");
                w.opt(n, f.ast.section_expr, "section");
                w.opt(n, f.ast.callconv_expr, "callconv");
                w.opt(n, f.ast.return_type, "ret");
            },
            .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => {
                w.all(n, t.builtinCallParams(&buf2, n).?, "arg");
            },
            .container_decl, .container_decl_trailing, .container_decl_two, .container_decl_two_trailing,
            .container_decl_arg, .container_decl_arg_trailing, .tagged_union, .tagged_union_trailing,
            .tagged_union_two, .tagged_union_two_trailing, .tagged_union_enum_tag, .tagged_union_enum_tag_trailing,
            => {
                const k = t.fullContainerDecl(&buf2, n).?;
                w.opt(n, k.ast.arg, "arg");
                w.all(n, k.ast.members, "member");
            },
            .container_field_init, .container_field_align, .container_field => {
                const f = t.fullContainerField(n).?;
                w.opt(n, f.ast.type_expr, "type");
                w.opt(n, f.ast.align_expr, "align");
                w.opt(n, f.ast.value_expr, "value");
            },
            .block_two, .block_two_semicolon, .block, .block_semicolon => w.all(n, t.blockStatements(&buf2, n).?, "stmt"),
            .asm_simple, .@"asm" => {
                const a = t.fullAsm(n).?;
                w.add(n, a.ast.template, "template");
                w.all(n, a.ast.items, "asm_item");
                if (@hasField(@TypeOf(a.ast), "clobbers")) w.opt(n, a.ast.clobbers, "clobbers");
            },
            .asm_output => w.opt(n, t.nodeData(n).opt_node_and_token[0], "type"),
            .asm_input => w.add(n, t.nodeData(n).node_and_token[0], "operand"),
            // the tags only one compiler has, by name, and `anyframe_literal` (no children), which keeps this prong
            // reachable on the compiler that has none of the others
            else => |tg| {
                const name = @tagName(tg);
                if (std.mem.eql(u8, name, "anyframe_literal")) {
                    // no children
                } else if (legacy_ast and std.mem.eql(u8, name, "array_mult")) {
                    const d = t.nodeData(n).node_and_node;
                    w.add(n, d[0], "lhs");
                    w.add(n, d[1], "rhs");
                } else if (legacy_ast and std.mem.eql(u8, name, "asm_legacy")) {
                    if (comptime @hasDecl(Ast, "legacyAsm")) {
                        const a = t.legacyAsm(n).?;
                        w.add(n, a.ast.template, "template");
                        w.all(n, a.ast.items, "asm_item");
                    }
                } else {
                    w.problem("unwalked-tag", n);
                }
            },
        }
    }
};

/// The extra keys of a node's line (see the file's documentation).
fn extras(t: *const Ast, n: Node.Index) void {
    var buf1: [1]Node.Index = undefined;
    switch (t.nodeTag(n)) {
        .if_simple, .@"if" => {
            const i = t.fullIf(n).?;
            putKey("pay", optTok(i.payload_token));
            putKey("err", optTok(i.error_token));
        },
        .while_simple, .while_cont, .@"while" => {
            const l = t.fullWhile(n).?;
            putKey("pay", optTok(l.payload_token));
            putKey("err", optTok(l.error_token));
            putKey("lbl", optTok(l.label_token));
        },
        .for_simple, .@"for" => {
            const l = t.fullFor(n).?;
            putKey("pay", @intCast(l.payload_token));
            putKey("lbl", optTok(l.label_token));
        },
        .@"switch", .switch_comma => putKey("lbl", optTok(t.fullSwitch(n).?.label_token)),
        .switch_case_one, .switch_case_inline_one, .switch_case, .switch_case_inline => {
            putKey("pay", optTok(t.fullSwitchCase(n).?.payload_token));
        },
        .@"break", .@"continue" => putKey("lbl", optTok(t.nodeData(n).opt_token_and_opt_node[0].unwrap())),
        .fn_proto_simple, .fn_proto_multi, .fn_proto_one, .fn_proto => {
            const f = t.fullFnProto(&buf1, n).?;
            putKey("name", optTok(f.name_token));
            var it = f.iterate(t);
            while (it.next()) |p| {
                put(" p=");
                putInt(optTok(p.name_token));
                put("/");
                putInt(if (p.type_expr) |te| @intCast(nodeInt(te)) else -1);
            }
        },
        .global_var_decl, .local_var_decl, .simple_var_decl, .aligned_var_decl => {
            const v = t.fullVarDecl(n).?;
            putKey("mut", @intCast(v.ast.mut_token));
            putKey("ct", optTok(v.comptime_token));
        },
        .container_field_init, .container_field_align, .container_field => {
            const f = t.fullContainerField(n).?;
            putKey("tuple", if (f.ast.tuple_like) 1 else 0);
            putKey("ct", optTok(f.comptime_token));
        },
        else => {},
    }
}

fn dumpFile(path: []const u8, pathz: [*:0]const u8, status_only: bool) void {
    put("F ");
    put(path);
    put("\n");
    const src = readFile(pathz) orelse {
        put("R\nE\n");
        return;
    };
    defer gpa.free(src.ptr[0 .. src.len + 1]);
    var tree = (if (comptime @hasDecl(Ast, "ParseOptions")) Ast.parse(gpa, src, .{}) else Ast.parse(gpa, src, .zig)) catch {
        put("R\nE\n");
        return;
    };
    defer tree.deinit(gpa);
    put("P ");
    putInt(@intCast(tree.errors.len));
    if (tree.errors.len > 0) { // the first error: its tag and the byte offset of the token it names
        const e0 = tree.errors[0];
        put(" ");
        put(@tagName(e0.tag));
        put(" ");
        putInt(tree.tokenStart(e0.token));
    }
    put("\n");
    if (status_only) {
        put("E\n");
        return;
    }
    put("K ");
    putInt(@intCast(tree.tokens.len));
    put("\n");
    var ti: u32 = 0;
    while (ti < tree.tokens.len) : (ti += 1) {
        put(@tagName(tree.tokenTag(ti)));
        put(" ");
        const st = tree.tokenStart(ti);
        putInt(st);
        put(" ");
        putInt(@intCast(st + tree.tokenSlice(ti).len));
        put("\n");
    }
    if (tree.errors.len == 0) {
        const nn = tree.nodes.len;
        const parent = gpa.alloc(i64, nn) catch return;
        defer gpa.free(parent);
        const roles = gpa.alloc([]const u8, nn) catch return;
        defer gpa.free(roles);
        const stack = gpa.alloc(Node.Index, nn + 1) catch return;
        defer gpa.free(stack);
        const byint = gpa.alloc(Node.Index, nn) catch return;
        defer gpa.free(byint);
        @memset(parent, -2);
        var w = Walk{ .tree = &tree, .parent = parent, .role = roles, .stack = stack };
        parent[0] = -1;
        roles[0] = "file";
        stack[0] = .root;
        w.sp = 1;
        var reached: usize = 0;
        while (w.sp > 0) {
            w.sp -= 1;
            const n = w.stack[w.sp];
            byint[nodeInt(n)] = n;
            reached += 1;
            w.children(n);
        }
        put("N ");
        putInt(@intCast(nn));
        put(" ");
        putInt(@intCast(reached));
        put("\n");
        var k: usize = 0;
        while (k < nn) : (k += 1) {
            if (parent[k] == -2) {
                put("X unreached ");
                putInt(@intCast(k));
                put("\n");
                continue;
            }
            const n = byint[k];
            putInt(@intCast(k));
            put(" ");
            put(@tagName(tree.nodeTag(n)));
            put(" ");
            putInt(tree.nodeMainToken(n));
            put(" ");
            putInt(tree.firstToken(n));
            put(" ");
            putInt(tree.lastToken(n));
            put(" ");
            putInt(parent[k]);
            put(" ");
            put(roles[k]);
            extras(&tree, n);
            put("\n");
        }
    }
    put("E\n");
}

pub export fn main(argc: c_int, argv: [*][*:0]u8) c_int {
    if (argc != 3) return 2;
    out_file = c.fopen(argv[1], "wb") orelse return 3;
    const list = readFile(argv[2]) orelse return 4;
    // the format, which Ast this is (`legacy`, the 1A compiler's, with the `**` operator, or `current`), and from
    // r40 the version of the compiler that built this program, which the residue gate and the binding check compare
    // with the tree's pin (round 39's Opus L1)
    put(if (legacy_ast) "astdump 3 legacy " else "astdump 3 current ");
    put(@import("builtin").zig_version_string);
    put("\n");
    var pbuf: [4096]u8 = undefined;
    var a: usize = 0;
    while (a < list.len) {
        var b = a;
        while (b < list.len and list[b] != '\n') b += 1;
        var e = b;
        if (e > a and list[e - 1] == '\r') e -= 1;
        var line = list[a..e];
        a = b + 1;
        if (line.len == 0) continue;
        const status_only = line[0] == '?';
        if (status_only) line = line[1..];
        if (line.len >= pbuf.len) {
            put("F ");
            put(line);
            put("\nR\nE\n");
            continue;
        }
        @memcpy(pbuf[0..line.len], line);
        pbuf[line.len] = 0;
        dumpFile(line, pbuf[0..line.len :0], status_only);
    }
    flush();
    _ = c.fclose(out_file.?);
    return 0;
}
