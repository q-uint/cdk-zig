//! Checks `ic0.zig` against the vendored `ic0.spec`, in both directions, at
//! compile time. Every spec entry must be bound, every binding must be in the
//! spec, and the signatures must agree.
//!
//! The spec gives addresses and lengths the same type, so types alone cannot
//! tell them apart. It does name them consistently though, `dst` and `*_src`
//! for addresses, so a parameter named that way may be bound as a pointer
//! whatever width the spec states. Everything else must match exactly.
//!
//! That keeps ic0.spec a verbatim copy of the specification, so refreshing it
//! stays a clean diff rather than a merge against our own annotations.

const std = @import("std");
const ic0 = @import("ic0.zig");

pub const entries = parseAll();

comptime {
    @setEvalBranchQuota(2_000_000);
    checkSpecIsBound();
    checkBindingsAreSpecified();
}

/// Whether the spec permits calling `ic0.<name>` from `context`. An unknown
/// name is a compile error rather than a false.
pub fn allows(comptime name: []const u8, comptime context: ic0.Context) bool {
    @setEvalBranchQuota(2_000_000);
    for (entries) |entry| {
        if (!std.mem.eql(u8, entry.name, name)) continue;
        for (entry.contexts) |allowed| {
            if (allowed == context) return true;
        }
        return false;
    }
    @compileError("ic0." ++ name ++ " is not in ic0.spec");
}

// Counted first so the result can be filled into a fixed array. Growing with
// `++` would recopy the whole slice on every line.
fn parseAll() []const Entry {
    @setEvalBranchQuota(2_000_000);
    var out: [countEntryLines()]Entry = undefined;
    var i: usize = 0;
    var it = std.mem.splitScalar(u8, @embedFile("ic0.spec"), '\n');
    while (it.next()) |line| {
        if (!isEntryLine(line)) continue;
        out[i] = parse(line);
        i += 1;
    }
    const final = out;
    return &final;
}

fn countEntryLines() usize {
    @setEvalBranchQuota(2_000_000);
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, @embedFile("ic0.spec"), '\n');
    while (it.next()) |line| {
        if (isEntryLine(line)) count += 1;
    }
    return count;
}

fn isEntryLine(comptime line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    return trimmed.len != 0 and trimmed[0] != '#';
}

fn checkSpecIsBound() void {
    for (entries) |entry| {
        if (!@hasDecl(ic0, entry.name))
            @compileError("ic0." ++ entry.name ++ " is in ic0.spec but not bound in ic0.zig");

        const info = @typeInfo(@TypeOf(@field(ic0, entry.name)));
        if (info != .@"fn")
            @compileError("ic0." ++ entry.name ++ " is in ic0.spec but is not a function");
        checkSignature(entry, info.@"fn");
    }
}

fn checkBindingsAreSpecified() void {
    for (@typeInfo(ic0).@"struct".decl_names) |name| {
        if (@TypeOf(@field(ic0, name)) == type) continue;
        if (@typeInfo(@TypeOf(@field(ic0, name))) != .@"fn") continue;
        if (!inSpec(name))
            @compileError("ic0." ++ name ++ " is bound in ic0.zig but not in ic0.spec");
    }
}

fn inSpec(comptime name: []const u8) bool {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return true;
    }
    return false;
}

const Param = struct {
    name: []const u8,
    type_text: []const u8,

    // The spec types addresses the same as lengths, but names them
    // consistently, so the name is what tells them apart.
    fn isAddress(self: Param) bool {
        return std.mem.eql(u8, self.name, "dst") or
            std.mem.endsWith(u8, self.name, "src");
    }
};

const Entry = struct {
    name: []const u8,
    params: []const Param,
    returns: []const u8,
    contexts: []const ic0.Context,
};

// What the spec's `*` stands for. Deliberately excludes `s`.
const every_context: []const ic0.Context = &.{
    .I, .G, .U, .RQ, .NRQ, .TQ, .CQ, .Ry, .Rt, .CRy, .CRt, .C, .CC, .F, .T,
};

// The legend does not list a bare Q, but msg_deadline is annotated with one.
// Its prose puts the call in "all calls to query and composite query methods,
// including calls in replicated mode", and CQ appears separately on that same
// line, so Q is the query methods.
const query_contexts: []const ic0.Context = &.{ .RQ, .NRQ, .TQ };

fn splitContexts(comptime text: []const u8) []const ic0.Context {
    var out: [countContexts(text)]ic0.Context = undefined;
    var i: usize = 0;
    var it = std.mem.tokenizeAny(u8, text, " \t");
    while (it.next()) |token| {
        for (expand(token)) |context| {
            out[i] = context;
            i += 1;
        }
    }
    const final = out;
    return &final;
}

fn countContexts(comptime text: []const u8) usize {
    var count: usize = 0;
    var it = std.mem.tokenizeAny(u8, text, " \t");
    while (it.next()) |token| {
        count += expand(token).len;
    }
    return count;
}

fn expand(comptime token: []const u8) []const ic0.Context {
    if (std.mem.eql(u8, token, "*")) return every_context;
    if (std.mem.eql(u8, token, "Q")) return query_contexts;
    return &.{toContext(token)};
}

fn toContext(comptime token: []const u8) ic0.Context {
    inline for (@typeInfo(ic0.Context).@"enum".field_names) |name| {
        if (std.mem.eql(u8, name, token)) return @field(ic0.Context, name);
    }
    @compileError("ic0.spec has an unknown context code: " ++ token);
}

fn parse(comptime line: []const u8) Entry {
    const whole = std.mem.trim(u8, line, " \t\r");

    const comment = std.mem.indexOf(u8, whole, "//") orelse
        @compileError("ic0.spec line has no context annotation: " ++ line);
    const contexts = splitContexts(whole[comment + 2 ..]);
    const trimmed = std.mem.trim(u8, whole[0..comment], " \t");

    if (!std.mem.startsWith(u8, trimmed, "ic0."))
        @compileError("ic0.spec line does not start with \"ic0.\": " ++ line);
    const rest = std.mem.trimEnd(u8, trimmed["ic0.".len..], ";");

    const colon = std.mem.indexOfScalar(u8, rest, ':') orelse
        @compileError("ic0.spec line has no colon: " ++ line);
    const name = std.mem.trim(u8, rest[0..colon], " ");

    const open = std.mem.indexOfScalar(u8, rest, '(') orelse
        @compileError("ic0.spec line has no parameter list: " ++ line);
    const arrow = std.mem.indexOf(u8, rest, "->") orelse
        @compileError("ic0.spec line has no return arrow: " ++ line);
    const close = std.mem.lastIndexOfScalar(u8, rest[0..arrow], ')') orelse
        @compileError("ic0.spec line has no closing parenthesis: " ++ line);

    return .{
        .name = name,
        .params = splitParams(rest[open + 1 .. close]),
        .returns = normalizeType(rest[arrow + 2 ..]),
        .contexts = contexts,
    };
}

fn splitParams(comptime text: []const u8) []const Param {
    const trimmed = std.mem.trim(u8, text, " ");
    if (trimmed.len == 0) return &.{};

    var out: [std.mem.count(u8, trimmed, ",") + 1]Param = undefined;
    var i: usize = 0;
    var it = std.mem.splitScalar(u8, trimmed, ',');
    while (it.next()) |param| {
        const colon = std.mem.indexOfScalar(u8, param, ':') orelse
            @compileError("ic0.spec parameter has no type: " ++ param);
        out[i] = .{
            .name = std.mem.trim(u8, param[0..colon], " \t"),
            .type_text = std.mem.trim(u8, param[colon + 1 ..], " \t"),
        };
        i += 1;
    }
    const final = out;
    return &final;
}

// Takes the type out of `name : Type`, `( name : Type )`, `Type` or `()`.
fn normalizeType(comptime text: []const u8) []const u8 {
    var t = std.mem.trim(u8, text, " \t");
    if (std.mem.startsWith(u8, t, "(") and std.mem.endsWith(u8, t, ")"))
        t = std.mem.trim(u8, t[1 .. t.len - 1], " ");
    if (std.mem.lastIndexOfScalar(u8, t, ':')) |colon|
        t = std.mem.trim(u8, t[colon + 1 ..], " ");
    return t;
}

fn checkSignature(comptime entry: Entry, comptime f: std.lang.Type.Fn) void {
    const where = "ic0." ++ entry.name;

    if (f.param_types.len != entry.params.len)
        @compileError(std.fmt.comptimePrint(
            "{s}: spec has {d} parameters, ic0.zig has {d}",
            .{ where, entry.params.len, f.param_types.len },
        ));

    for (entry.params, f.param_types, 0..) |param, bound, index| {
        const B = bound orelse
            @compileError(where ++ ": parameter may not be generic");
        // An address may be bound as a pointer whatever width the spec gives
        // it, since callers pass pointers rather than integers.
        if (param.isAddress() and @typeInfo(B) == .pointer) continue;
        if (!matches(param.type_text, B))
            @compileError(std.fmt.comptimePrint(
                "{s}: parameter {d} ({s}) is {s} in the spec but {s} in ic0.zig",
                .{ where, index, param.name, param.type_text, @typeName(B) },
            ));
    }

    const R = f.return_type orelse
        @compileError(where ++ ": return type may not be generic");
    if (!matches(entry.returns, R))
        @compileError(std.fmt.comptimePrint(
            "{s}: returns {s} in the spec but {s} in ic0.zig",
            .{ where, entry.returns, @typeName(R) },
        ));
}

fn matches(comptime spec_type: []const u8, comptime Bound: type) bool {
    if (std.mem.eql(u8, spec_type, "")) return Bound == void;
    if (std.mem.eql(u8, spec_type, "i32")) return Bound == i32;
    if (std.mem.eql(u8, spec_type, "i64")) return Bound == i64;
    if (std.mem.eql(u8, spec_type, "I")) return Bound == ic0.I;
    @compileError("ic0.spec uses a type this check does not know: " ++ spec_type);
}
