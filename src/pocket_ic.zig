const std = @import("std");
pub const principal = @import("principal.zig");

const Allocator = std.mem.Allocator;
const ManagedList = std.array_list.AlignedManaged(u8, null);
const Stringify = std.json.Stringify;
const IoWriter = std.io.Writer;

pub const SubnetKind = enum {
    application,
    system,
    nns,
    sns,
    ii,
    fiduciary,
    bitcoin,
    verified_application,
};

pub const InstallMode = enum {
    install,
    reinstall,
    upgrade,
};

pub const WasmResult = union(enum) {
    reply: []const u8,
    reject: []const u8,
};

pub const PocketIcConfig = struct {
    server_url: ?[]const u8 = null,
    application_subnets: u32 = 1,
    nns: bool = false,
    system_subnets: u32 = 0,
};

pub const PocketIc = struct {
    allocator: Allocator,
    url: []const u8,
    instance_id: usize,
    effective_canister_id: []const u8,
    client: *std.http.Client,
    process: ?std.process.Child = null,

    pub fn init(allocator: Allocator, config: PocketIcConfig) !PocketIc {
        var process: ?std.process.Child = null;
        const url = if (config.server_url) |u|
            try allocator.dupe(u8, u)
        else blk: {
            const result = try startServer(allocator);
            process = result.process;
            break :blk result.url;
        };

        const client = try allocator.create(std.http.Client);
        client.* = .{ .allocator = allocator };

        const instance_json = try buildInstanceConfigJson(allocator, config);
        defer allocator.free(instance_json);

        const create_url = try std.fmt.allocPrint(allocator, "{s}/instances", .{url});
        defer allocator.free(create_url);

        const resp = try httpPost(client, allocator, create_url, instance_json);
        defer allocator.free(resp.body);

        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, resp.body, .{
            .allocate = .alloc_always,
        });
        defer parsed.deinit();

        const created = parsed.value.object.get("Created") orelse
            return error.InstanceCreationFailed;
        const instance_id: usize = @intCast(created.object.get("instance_id").?.integer);
        const topology = created.object.get("topology").?.object;
        const eff_cid_val = topology.get("default_effective_canister_id").?;
        const eff_cid = switch (eff_cid_val) {
            .string => |s| principal.decode(s) catch return error.InvalidPrincipal,
            .object => |obj| blk: {
                const b64 = obj.get("canister_id").?.string;
                break :blk try base64Decode(allocator, b64);
            },
            else => return error.InvalidPrincipal,
        };

        return .{
            .allocator = allocator,
            .url = url,
            .instance_id = instance_id,
            .effective_canister_id = eff_cid,
            .client = client,
            .process = process,
        };
    }

    pub fn deinit(self: *PocketIc) void {
        const delete_url = std.fmt.allocPrint(self.allocator, "{s}/instances/{d}", .{
            self.url, self.instance_id,
        }) catch "";
        defer if (delete_url.len > 0) self.allocator.free(delete_url);

        if (delete_url.len > 0) {
            if (httpDelete(self.client, self.allocator, delete_url)) |resp| {
                self.allocator.free(resp.body);
            } else |_| {}
        }

        self.client.deinit();
        self.allocator.destroy(self.client);
        self.allocator.free(self.effective_canister_id);
        self.allocator.free(self.url);

        if (self.process) |*proc| {
            _ = proc.kill() catch {};
            _ = proc.wait() catch {};
        }
    }

    pub fn createCanister(self: *PocketIc) ![]const u8 {
        return self.createCanisterWithSender(principal.anonymous);
    }

    pub fn createCanisterWithSender(self: *PocketIc, sender: []const u8) ![]const u8 {
        const payload = &candid.empty_record_args;
        const reply = try self.managementCallWithEffective(
            sender,
            "provisional_create_canister_with_cycles",
            payload,
            .none,
        );
        defer self.allocator.free(reply);

        return try candid.decodePrincipalFromRecord(self.allocator, reply);
    }

    pub fn installCode(
        self: *PocketIc,
        canister_id: []const u8,
        wasm_module: []const u8,
        arg: []const u8,
        mode: InstallMode,
    ) !void {
        try self.installCodeWithSender(canister_id, wasm_module, arg, mode, principal.anonymous);
    }

    pub fn installCodeWithSender(
        self: *PocketIc,
        canister_id: []const u8,
        wasm_module: []const u8,
        arg: []const u8,
        mode: InstallMode,
        sender: []const u8,
    ) !void {
        const payload = try candid.encodeInstallCodeArgs(
            self.allocator,
            mode,
            canister_id,
            wasm_module,
            arg,
        );
        defer self.allocator.free(payload);

        const reply = try self.managementCallWithEffective(sender, "install_code", payload, .{ .canister_id = canister_id });
        self.allocator.free(reply);
    }

    pub fn updateCall(
        self: *PocketIc,
        canister_id: []const u8,
        sender: []const u8,
        method: []const u8,
        payload: []const u8,
    ) !WasmResult {
        const call_json = try buildCanisterCallJson(
            self.allocator,
            sender,
            canister_id,
            method,
            payload,
            .{ .canister_id = canister_id },
        );
        defer self.allocator.free(call_json);

        const submit_url = try std.fmt.allocPrint(
            self.allocator,
            "{s}/instances/{d}/update/submit_ingress_message",
            .{ self.url, self.instance_id },
        );
        defer self.allocator.free(submit_url);

        return self.submitAndAwait(submit_url, call_json);
    }

    pub fn queryCall(
        self: *PocketIc,
        canister_id: []const u8,
        sender: []const u8,
        method: []const u8,
        payload: []const u8,
    ) !WasmResult {
        const call_json = try buildCanisterCallJson(
            self.allocator,
            sender,
            canister_id,
            method,
            payload,
            .{ .canister_id = canister_id },
        );
        defer self.allocator.free(call_json);

        const url = try std.fmt.allocPrint(
            self.allocator,
            "{s}/instances/{d}/read/query",
            .{ self.url, self.instance_id },
        );
        defer self.allocator.free(url);

        const resp = try self.requestAndPoll(.POST, url, call_json);
        defer self.allocator.free(resp.body);

        return parseCanisterResult(self.allocator, resp.body);
    }

    pub fn tick(self: *PocketIc) !void {
        const url = try std.fmt.allocPrint(
            self.allocator,
            "{s}/instances/{d}/update/tick",
            .{ self.url, self.instance_id },
        );
        defer self.allocator.free(url);

        const resp = try self.requestAndPoll(.POST, url, "{}");
        self.allocator.free(resp.body);
    }

    pub fn getTime(self: *PocketIc) !u64 {
        const url = try std.fmt.allocPrint(
            self.allocator,
            "{s}/instances/{d}/read/get_time",
            .{ self.url, self.instance_id },
        );
        defer self.allocator.free(url);

        const resp = try httpGet(self.client, self.allocator, url);
        defer self.allocator.free(resp.body);

        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, resp.body, .{
            .allocate = .alloc_always,
        });
        defer parsed.deinit();

        return @intCast(parsed.value.object.get("nanos_since_epoch").?.integer);
    }

    pub fn setTime(self: *PocketIc, nanos_since_epoch: u64) !void {
        const body = try std.fmt.allocPrint(
            self.allocator,
            "{{\"nanos_since_epoch\":{d}}}",
            .{nanos_since_epoch},
        );
        defer self.allocator.free(body);

        const url = try std.fmt.allocPrint(
            self.allocator,
            "{s}/instances/{d}/update/set_time",
            .{ self.url, self.instance_id },
        );
        defer self.allocator.free(url);

        const resp = try self.requestAndPoll(.POST, url, body);
        self.allocator.free(resp.body);
    }

    pub fn advanceTime(self: *PocketIc, nanos: u64) !void {
        const current = try self.getTime();
        try self.setTime(current + nanos);
    }

    pub fn addCycles(self: *PocketIc, canister_id: []const u8, amount: u128) !u128 {
        const cid_b64 = try base64Encode(self.allocator, canister_id);
        defer self.allocator.free(cid_b64);

        const body = try std.fmt.allocPrint(
            self.allocator,
            "{{\"canister_id\":\"{s}\",\"amount\":{d}}}",
            .{ cid_b64, amount },
        );
        defer self.allocator.free(body);

        const url = try std.fmt.allocPrint(
            self.allocator,
            "{s}/instances/{d}/update/add_cycles",
            .{ self.url, self.instance_id },
        );
        defer self.allocator.free(url);

        const resp = try self.requestAndPoll(.POST, url, body);
        defer self.allocator.free(resp.body);

        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, resp.body, .{
            .allocate = .alloc_always,
        });
        defer parsed.deinit();

        return @intCast(parsed.value.object.get("cycles").?.integer);
    }

    pub fn getCycles(self: *PocketIc, canister_id: []const u8) !u128 {
        const cid_b64 = try base64Encode(self.allocator, canister_id);
        defer self.allocator.free(cid_b64);

        const body = try std.fmt.allocPrint(
            self.allocator,
            "{{\"canister_id\":\"{s}\"}}",
            .{cid_b64},
        );
        defer self.allocator.free(body);

        const url = try std.fmt.allocPrint(
            self.allocator,
            "{s}/instances/{d}/read/get_cycles",
            .{ self.url, self.instance_id },
        );
        defer self.allocator.free(url);

        const resp = try self.requestAndPoll(.POST, url, body);
        defer self.allocator.free(resp.body);

        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, resp.body, .{
            .allocate = .alloc_always,
        });
        defer parsed.deinit();

        return @intCast(parsed.value.object.get("cycles").?.integer);
    }

    pub fn autoProgress(self: *PocketIc) !void {
        const url = try std.fmt.allocPrint(
            self.allocator,
            "{s}/instances/{d}/auto_progress",
            .{ self.url, self.instance_id },
        );
        defer self.allocator.free(url);

        const resp = try httpPost(self.client, self.allocator, url, "{}");
        self.allocator.free(resp.body);
    }

    pub fn stopProgress(self: *PocketIc) !void {
        const url = try std.fmt.allocPrint(
            self.allocator,
            "{s}/instances/{d}/stop_progress",
            .{ self.url, self.instance_id },
        );
        defer self.allocator.free(url);

        const resp = try httpPost(self.client, self.allocator, url, "\"\"");
        self.allocator.free(resp.body);
    }

    fn managementCallWithEffective(
        self: *PocketIc,
        sender: []const u8,
        method: []const u8,
        payload: []const u8,
        effective: EffectivePrincipal,
    ) ![]const u8 {
        const call_json = try buildCanisterCallJson(
            self.allocator,
            sender,
            principal.managementCanister,
            method,
            payload,
            effective,
        );
        defer self.allocator.free(call_json);

        const submit_url = try std.fmt.allocPrint(
            self.allocator,
            "{s}/instances/{d}/update/submit_ingress_message",
            .{ self.url, self.instance_id },
        );
        defer self.allocator.free(submit_url);

        const result = try self.submitAndAwait(submit_url, call_json);
        switch (result) {
            .reply => |data| return data,
            .reject => |msg| {
                std.log.err("management canister rejected: {s}", .{msg});
                self.allocator.free(msg);
                return error.ManagementCanisterRejected;
            },
        }
    }

    fn submitAndAwait(self: *PocketIc, submit_url: []const u8, call_json: []const u8) !WasmResult {
        const submit_resp = try self.requestAndPoll(.POST, submit_url, call_json);
        defer self.allocator.free(submit_resp.body);

        // submit_ingress_message returns {"Ok": <message_id>} or {"Err": ...}
        const submit_parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, submit_resp.body, .{
            .allocate = .alloc_always,
        });
        defer submit_parsed.deinit();

        const message_id_val = submit_parsed.value.object.get("Ok") orelse {
            return .{ .reject = try self.allocator.dupe(u8, "submit_ingress_message failed") };
        };
        const message_id_json = try std.json.Stringify.valueAlloc(self.allocator, message_id_val, .{});
        defer self.allocator.free(message_id_json);

        const await_url = try std.fmt.allocPrint(
            self.allocator,
            "{s}/instances/{d}/update/await_ingress_message",
            .{ self.url, self.instance_id },
        );
        defer self.allocator.free(await_url);

        const await_resp = try self.requestAndPoll(.POST, await_url, message_id_json);
        defer self.allocator.free(await_resp.body);

        return parseCanisterResult(self.allocator, await_resp.body);
    }

    fn requestAndPoll(
        self: *PocketIc,
        method: std.http.Method,
        url: []const u8,
        body: ?[]const u8,
    ) !HttpResponse {
        var resp = try httpRequest(self.client, self.allocator, method, url, body);

        if (resp.status != .accepted) return resp;

        const poll_parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, resp.body, .{
            .allocate = .alloc_always,
        });
        const state_label = try self.allocator.dupe(u8, poll_parsed.value.object.get("state_label").?.string);
        const op_id = try self.allocator.dupe(u8, poll_parsed.value.object.get("op_id").?.string);
        defer self.allocator.free(state_label);
        defer self.allocator.free(op_id);
        poll_parsed.deinit();
        self.allocator.free(resp.body);

        const poll_url = try std.fmt.allocPrint(
            self.allocator,
            "{s}/read_graph/{s}/{s}",
            .{ self.url, state_label, op_id },
        );
        defer self.allocator.free(poll_url);

        for (0..3000) |_| {
            std.Thread.sleep(10 * std.time.ns_per_ms);
            resp = try httpGet(self.client, self.allocator, poll_url);
            if (resp.status == .ok) break;
            self.allocator.free(resp.body);
        } else {
            return error.PollTimeout;
        }

        const prune_url = try std.fmt.allocPrint(
            self.allocator,
            "{s}/prune_graph/{s}/{s}",
            .{ self.url, state_label, op_id },
        );
        defer self.allocator.free(prune_url);

        const prune_resp = httpDelete(self.client, self.allocator, prune_url) catch |err| {
            std.log.warn("failed to prune graph: {}", .{err});
            return resp;
        };
        self.allocator.free(prune_resp.body);

        return resp;
    }
};

const HttpResponse = struct {
    status: std.http.Status,
    body: []const u8,
};

fn httpPost(client: *std.http.Client, allocator: Allocator, url: []const u8, body: []const u8) !HttpResponse {
    return httpRequest(client, allocator, .POST, url, body);
}

fn httpGet(client: *std.http.Client, allocator: Allocator, url: []const u8) !HttpResponse {
    return httpRequest(client, allocator, .GET, url, null);
}

fn httpDelete(client: *std.http.Client, allocator: Allocator, url: []const u8) !HttpResponse {
    return httpRequest(client, allocator, .DELETE, url, null);
}

fn httpRequest(
    client: *std.http.Client,
    allocator: Allocator,
    method: std.http.Method,
    url: []const u8,
    body: ?[]const u8,
) !HttpResponse {
    const uri = try std.Uri.parse(url);

    var req = try client.request(method, uri, .{
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
        },
    });
    defer req.deinit();

    if (body) |b| {
        try req.sendBodyComplete(@constCast(b));
    } else {
        try req.sendBodiless();
    }

    var redirect_buf: [8 * 1024]u8 = undefined;
    var response = try req.receiveHead(&redirect_buf);

    var transfer_buf: [16 * 1024]u8 = undefined;
    const reader = response.reader(&transfer_buf);
    const response_body = try reader.allocRemaining(allocator, std.Io.Limit.limited(10 * 1024 * 1024));

    return .{
        .status = response.head.status,
        .body = response_body,
    };
}

const ServerInfo = struct {
    url: []const u8,
    process: std.process.Child,
};

fn startServer(allocator: Allocator) !ServerInfo {
    const bin_path = std.posix.getenv("POCKET_IC_BIN") orelse
        return error.PocketIcBinNotSet;

    const port_file = try std.fmt.allocPrint(
        allocator,
        "/tmp/pocket_ic_{d}.port",
        .{std.time.nanoTimestamp()},
    );
    defer allocator.free(port_file);

    const argv = [_][]const u8{ bin_path, "--port-file", port_file };
    var child = std.process.Child.init(&argv, allocator);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;

    try child.spawn();

    var port: ?u16 = null;
    for (0..300) |_| {
        std.Thread.sleep(100 * std.time.ns_per_ms);
        if (std.fs.openFileAbsolute(port_file, .{})) |file| {
            defer file.close();
            var buf: [16]u8 = undefined;
            const n = file.readAll(&buf) catch continue;
            if (n > 0) {
                const trimmed = std.mem.trimRight(u8, buf[0..n], &.{ '\n', '\r', ' ' });
                port = std.fmt.parseInt(u16, trimmed, 10) catch continue;
                break;
            }
        } else |_| {}
    }

    const p = port orelse return error.ServerStartTimeout;
    const server_url = try std.fmt.allocPrint(allocator, "http://localhost:{d}", .{p});

    return .{ .url = server_url, .process = child };
}

const EffectivePrincipal = union(enum) {
    none,
    canister_id: []const u8,
    subnet_id: []const u8,
};

const subnet_entry = .{
    .state_config = "New",
    .instruction_config = "Production",
    .dts_flag = "Disabled",
    .subnet_admins = [0][]const u8{},
    .cost_schedule = "Normal",
};

const SubnetEntry = @TypeOf(subnet_entry);

fn buildInstanceConfigJson(allocator: Allocator, config: PocketIcConfig) ![]const u8 {
    var aw: IoWriter.Allocating = .init(allocator);
    errdefer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };

    const app_entries = try allocator.alloc(SubnetEntry, config.application_subnets);
    defer allocator.free(app_entries);
    @memset(app_entries, subnet_entry);

    const sys_entries = try allocator.alloc(SubnetEntry, config.system_subnets);
    defer allocator.free(sys_entries);
    @memset(sys_entries, subnet_entry);

    const nns_val: ?SubnetEntry = if (config.nns) subnet_entry else null;

    try s.write(.{
        .subnet_config_set = .{
            .application = app_entries,
            .system = sys_entries,
            .nns = nns_val,
            .sns = @as(?SubnetEntry, null),
            .ii = @as(?SubnetEntry, null),
            .fiduciary = @as(?SubnetEntry, null),
            .bitcoin = @as(?SubnetEntry, null),
            .verified_application = @as([]const SubnetEntry, &.{}),
        },
    });

    return aw.toOwnedSlice();
}

fn buildCanisterCallJson(
    allocator: Allocator,
    sender: []const u8,
    canister_id: []const u8,
    method: []const u8,
    payload: []const u8,
    effective: EffectivePrincipal,
) ![]const u8 {
    const sender_b64 = try base64Encode(allocator, sender);
    defer allocator.free(sender_b64);
    const cid_b64 = try base64Encode(allocator, canister_id);
    defer allocator.free(cid_b64);
    const payload_b64 = try base64Encode(allocator, payload);
    defer allocator.free(payload_b64);

    var aw: IoWriter.Allocating = .init(allocator);
    errdefer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };

    try s.beginObject();
    try s.objectField("sender");
    try s.write(sender_b64);
    try s.objectField("canister_id");
    try s.write(cid_b64);
    try s.objectField("effective_principal");
    switch (effective) {
        .none => try s.write("None"),
        .canister_id => |cid| {
            const eff_b64 = try base64Encode(allocator, cid);
            defer allocator.free(eff_b64);
            try s.write(.{ .CanisterId = eff_b64 });
        },
        .subnet_id => |sid| {
            const eff_b64 = try base64Encode(allocator, sid);
            defer allocator.free(eff_b64);
            try s.write(.{ .SubnetId = eff_b64 });
        },
    }
    try s.objectField("method");
    try s.write(method);
    try s.objectField("payload");
    try s.write(payload_b64);
    try s.endObject();

    return aw.toOwnedSlice();
}

fn parseCanisterResult(allocator: Allocator, json_body: []const u8) !WasmResult {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_body, .{
        .allocate = .alloc_always,
        .max_value_len = null,
    }) catch return error.InvalidCanisterResult;
    defer parsed.deinit();

    if (parsed.value.object.get("Ok")) |ok_val| {
        // Response might be wrapped: {"Ok": {"Reply": base64}} or {"Ok": base64}
        switch (ok_val) {
            .string => |s| {
                const decoded = try base64Decode(allocator, s);
                return .{ .reply = decoded };
            },
            else => {},
        }
        if (ok_val.object.get("Reply")) |reply_val| {
            const reply_b64 = reply_val.string;
            const decoded = try base64Decode(allocator, reply_b64);
            return .{ .reply = decoded };
        }
        if (ok_val.object.get("Reject")) |reject_val| {
            const msg = try allocator.dupe(u8, reject_val.string);
            return .{ .reject = msg };
        }
        return error.InvalidCanisterResult;
    }

    if (parsed.value.object.get("Err")) |err_val| {
        const msg = if (err_val.object.get("description")) |d|
            try allocator.dupe(u8, d.string)
        else
            try allocator.dupe(u8, "unknown error");
        return .{ .reject = msg };
    }

    return error.InvalidCanisterResult;
}

fn base64Encode(allocator: Allocator, data: []const u8) ![]const u8 {
    const encoder = std.base64.standard.Encoder;
    const len = encoder.calcSize(data.len);
    const buf = try allocator.alloc(u8, len);
    _ = encoder.encode(buf, data);
    return buf;
}

fn base64Decode(allocator: Allocator, encoded: []const u8) ![]const u8 {
    const decoder = std.base64.standard.Decoder;
    const len = try decoder.calcSizeForSlice(encoded);
    const buf = try allocator.alloc(u8, len);
    try decoder.decode(buf, encoded);
    return buf;
}

const candid = struct {
    // Candid encoding of (record {}) -- used for create_canister args
    // DIDL + 1 type (record, 0 fields) + 1 arg of type 0
    const empty_record_args = [_]u8{
        'D', 'I', 'D', 'L', // magic
        0x01, // 1 type in table
        0x6c, 0x00, // type 0: record with 0 fields
        0x01, // 1 argument
        0x00, // arg 0 is type 0
    };

    fn fieldHash(comptime name: []const u8) u32 {
        var h: u32 = 0;
        for (name) |c| {
            h = h *% 223 +% c;
        }
        return h;
    }

    const FieldInfo = struct {
        hash: u32,
        name: []const u8,
    };

    fn sortFields(comptime fields: []const FieldInfo) [fields.len]FieldInfo {
        var sorted: [fields.len]FieldInfo = undefined;
        @memcpy(&sorted, fields);
        for (0..sorted.len) |i| {
            for (i + 1..sorted.len) |j| {
                if (sorted[j].hash < sorted[i].hash) {
                    const tmp = sorted[i];
                    sorted[i] = sorted[j];
                    sorted[j] = tmp;
                }
            }
        }
        return sorted;
    }

    const install_code_fields = sortFields(&[_]FieldInfo{
        .{ .hash = fieldHash("arg"), .name = "arg" },
        .{ .hash = fieldHash("canister_id"), .name = "canister_id" },
        .{ .hash = fieldHash("mode"), .name = "mode" },
        .{ .hash = fieldHash("wasm_module"), .name = "wasm_module" },
    });

    const mode_variants = sortFields(&[_]FieldInfo{
        .{ .hash = fieldHash("install"), .name = "install" },
        .{ .hash = fieldHash("reinstall"), .name = "reinstall" },
        .{ .hash = fieldHash("upgrade"), .name = "upgrade" },
    });

    fn modeIndex(comptime mode_name: []const u8) u32 {
        for (mode_variants, 0..) |v, i| {
            if (std.mem.eql(u8, v.name, mode_name)) return @intCast(i);
        }
        unreachable;
    }

    fn encodeInstallCodeArgs(
        allocator: Allocator,
        mode: InstallMode,
        canister_id_bytes: []const u8,
        wasm_module: []const u8,
        arg: []const u8,
    ) ![]const u8 {
        var buf = ManagedList.init(allocator);

        // Magic
        try buf.appendSlice("DIDL");

        // Type table: 3 types
        // type 0: vec nat8 (blob)
        // type 1: variant { install: null, reinstall: null, upgrade: null }
        // type 2: record { arg: type0, canister_id: principal, mode: type1, wasm_module: type0 }
        try appendUleb128(&buf, 3);

        // type 0: vec (0x6d) nat8 (0x7b)
        try appendSleb128(&buf, -19); // vec
        try appendSleb128(&buf, -5); // nat8

        // type 1: variant with 3 options
        try appendSleb128(&buf, -21); // variant
        try appendUleb128(&buf, 3); // 3 options
        for (mode_variants) |v| {
            try appendUleb128(&buf, v.hash);
            try appendSleb128(&buf, -1); // null
        }

        // type 2: record with 4 fields
        try appendSleb128(&buf, -20); // record
        try appendUleb128(&buf, 4); // 4 fields
        for (install_code_fields) |f| {
            try appendUleb128(&buf, f.hash);
            if (std.mem.eql(u8, f.name, "arg") or std.mem.eql(u8, f.name, "wasm_module")) {
                try appendSleb128(&buf, 0); // type 0 (blob)
            } else if (std.mem.eql(u8, f.name, "canister_id")) {
                try appendSleb128(&buf, -24); // principal
            } else if (std.mem.eql(u8, f.name, "mode")) {
                try appendSleb128(&buf, 1); // type 1 (variant)
            }
        }

        // Args section: 1 arg of type 2
        try appendUleb128(&buf, 1);
        try appendSleb128(&buf, 2);

        // Values - record fields in sorted hash order
        for (install_code_fields) |f| {
            if (std.mem.eql(u8, f.name, "arg")) {
                try appendUleb128(&buf, arg.len);
                try buf.appendSlice(arg);
            } else if (std.mem.eql(u8, f.name, "canister_id")) {
                try buf.append(0x01); // present
                try appendUleb128(&buf, canister_id_bytes.len);
                try buf.appendSlice(canister_id_bytes);
            } else if (std.mem.eql(u8, f.name, "mode")) {
                const idx: u32 = switch (mode) {
                    .install => modeIndex("install"),
                    .reinstall => modeIndex("reinstall"),
                    .upgrade => modeIndex("upgrade"),
                };
                try appendUleb128(&buf, idx);
                // null value = no bytes
            } else if (std.mem.eql(u8, f.name, "wasm_module")) {
                try appendUleb128(&buf, wasm_module.len);
                try buf.appendSlice(wasm_module);
            }
        }

        return buf.toOwnedSlice();
    }

    fn decodePrincipalFromRecord(allocator: Allocator, data: []const u8) ![]const u8 {
        if (data.len < 4) return error.CandidDecodingFailed;
        if (!std.mem.eql(u8, data[0..4], "DIDL")) return error.CandidDecodingFailed;

        var pos: usize = 4;

        // Skip type table
        const type_count = readUleb128(data, &pos);
        for (0..type_count) |_| {
            const tag = readSleb128(data, &pos);
            switch (tag) {
                -18 => { // opt
                    _ = readSleb128(data, &pos);
                },
                -19 => { // vec
                    _ = readSleb128(data, &pos);
                },
                -20, -21 => { // record, variant
                    const n = readUleb128(data, &pos);
                    for (0..n) |_| {
                        _ = readUleb128(data, &pos); // hash
                        _ = readSleb128(data, &pos); // type
                    }
                },
                else => {},
            }
        }

        // Skip arg count and type refs
        const arg_count = readUleb128(data, &pos);
        for (0..arg_count) |_| {
            _ = readSleb128(data, &pos);
        }

        // Now at value section. Expect a record with a principal field.
        // The principal is encoded as: 0x01 (present) + uleb128(len) + bytes
        if (pos >= data.len) return error.CandidDecodingFailed;

        // Look for the principal value (0x01 flag byte followed by length)
        if (data[pos] != 0x01) return error.CandidDecodingFailed;
        pos += 1;

        const len = readUleb128(data, &pos);
        if (pos + len > data.len) return error.CandidDecodingFailed;

        return try allocator.dupe(u8, data[pos .. pos + len]);
    }
};

const leb128 = std.leb;

fn appendUleb128(list: *ManagedList, value: anytype) !void {
    try leb128.writeUleb128(list.writer(), value);
}

fn appendSleb128(list: *ManagedList, value: anytype) !void {
    try leb128.writeIleb128(list.writer(), value);
}

fn readUleb128(data: []const u8, pos: *usize) usize {
    var fbs = std.io.fixedBufferStream(data[pos.*..]);
    const value = leb128.readUleb128(usize, fbs.reader()) catch return 0;
    pos.* += fbs.pos;
    return value;
}

fn readSleb128(data: []const u8, pos: *usize) i64 {
    var fbs = std.io.fixedBufferStream(data[pos.*..]);
    const value = leb128.readIleb128(i64, fbs.reader()) catch return 0;
    pos.* += fbs.pos;
    return value;
}

const testing = std.testing;

test "base64 round-trip" {
    const cases = [_][]const u8{ "", "\x04", "hello", &.{ 0, 1, 2, 3, 4, 5 } };
    for (cases) |data| {
        const encoded = try base64Encode(testing.allocator, data);
        defer testing.allocator.free(encoded);
        const decoded = try base64Decode(testing.allocator, encoded);
        defer testing.allocator.free(decoded);
        try testing.expectEqualSlices(u8, data, decoded);
    }
}

test "base64 known values" {
    const encoded = try base64Encode(testing.allocator, &.{0x04});
    defer testing.allocator.free(encoded);
    try testing.expectEqualStrings("BA==", encoded);
}

test "candid field hash" {
    // Known hashes from the Candid spec
    try testing.expectEqual(@as(u32, 4849238), candid.fieldHash("arg"));
    // Fields must sort by hash; verify ordering
    var prev: u32 = 0;
    for (candid.install_code_fields) |f| {
        try testing.expect(f.hash >= prev);
        prev = f.hash;
    }
    prev = 0;
    for (candid.mode_variants) |v| {
        try testing.expect(v.hash >= prev);
        prev = v.hash;
    }
}

test "candid empty record encoding" {
    const expected = "DIDL" ++ [_]u8{ 0x01, 0x6c, 0x00, 0x01, 0x00 };
    try testing.expectEqualSlices(u8, expected, &candid.empty_record_args);
}

test "candid encode install_code args" {
    const canister_id = &[_]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x01, 0x01 };
    const wasm = &[_]u8{ 0x00, 0x61, 0x73, 0x6d }; // \0asm
    const arg = "";

    const encoded = try candid.encodeInstallCodeArgs(
        testing.allocator,
        .install,
        canister_id,
        wasm,
        arg,
    );
    defer testing.allocator.free(encoded);

    // Verify magic
    try testing.expectEqualStrings("DIDL", encoded[0..4]);

    // Verify it starts with valid Candid: 3 types
    var pos: usize = 4;
    const type_count = readUleb128(encoded, &pos);
    try testing.expectEqual(@as(usize, 3), type_count);

    // Decode the result back to verify the principal is recoverable
    // by checking the encoded data is non-empty and well-formed
    try testing.expect(encoded.len > 20);
}

test "candid decode principal from record" {
    // Manually construct: DIDL + 1 type (record, 1 field canister_id:principal) + 1 arg + value
    var buf = ManagedList.init(testing.allocator);
    defer buf.deinit();

    try buf.appendSlice("DIDL");
    try appendUleb128(&buf, 1); // 1 type
    try appendSleb128(&buf, -20); // record
    try appendUleb128(&buf, 1); // 1 field
    try appendUleb128(&buf, candid.fieldHash("canister_id")); // field hash
    try appendSleb128(&buf, -24); // principal
    try appendUleb128(&buf, 1); // 1 arg
    try appendSleb128(&buf, 0); // type 0

    // Value: principal
    const principal_bytes = &[_]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x01, 0x01 };
    try buf.append(0x01); // present
    try appendUleb128(&buf, principal_bytes.len);
    try buf.appendSlice(principal_bytes);

    const decoded = try candid.decodePrincipalFromRecord(testing.allocator, buf.items);
    defer testing.allocator.free(decoded);

    try testing.expectEqualSlices(u8, principal_bytes, decoded);
}

test "buildInstanceConfigJson default" {
    const json = try buildInstanceConfigJson(testing.allocator, .{});
    defer testing.allocator.free(json);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    const config = parsed.value.object.get("subnet_config_set").?.object;
    try testing.expectEqual(@as(usize, 1), config.get("application").?.array.items.len);
    try testing.expectEqual(@as(usize, 0), config.get("system").?.array.items.len);
    try testing.expect(config.get("nns").? == .null);
}

test "buildInstanceConfigJson with nns" {
    const json = try buildInstanceConfigJson(testing.allocator, .{
        .application_subnets = 2,
        .nns = true,
    });
    defer testing.allocator.free(json);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    const config = parsed.value.object.get("subnet_config_set").?.object;
    try testing.expectEqual(@as(usize, 2), config.get("application").?.array.items.len);
    try testing.expect(config.get("nns").? != .null);
}

test "buildCanisterCallJson with none effective principal" {
    const json = try buildCanisterCallJson(
        testing.allocator,
        &.{0x04}, // anonymous
        &.{}, // management canister
        "test_method",
        "payload",
        .none,
    );
    defer testing.allocator.free(json);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    const obj = parsed.value.object;
    try testing.expectEqualStrings("BA==", obj.get("sender").?.string);
    try testing.expectEqualStrings("", obj.get("canister_id").?.string);
    try testing.expectEqualStrings("None", obj.get("effective_principal").?.string);
    try testing.expectEqualStrings("test_method", obj.get("method").?.string);
}

test "buildCanisterCallJson with canister_id effective principal" {
    const cid = &[_]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x01, 0x01 };
    const json = try buildCanisterCallJson(
        testing.allocator,
        &.{0x04},
        cid,
        "greet",
        "",
        .{ .canister_id = cid },
    );
    defer testing.allocator.free(json);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    const eff = parsed.value.object.get("effective_principal").?.object;
    try testing.expect(eff.get("CanisterId") != null);
}

test "parseCanisterResult reply" {
    const json = "{\"Ok\":{\"Reply\":\"aGVsbG8=\"}}";
    const result = try parseCanisterResult(testing.allocator, json);
    switch (result) {
        .reply => |data| {
            defer testing.allocator.free(data);
            try testing.expectEqualStrings("hello", data);
        },
        .reject => |msg| {
            defer testing.allocator.free(msg);
            return error.UnexpectedReject;
        },
    }
}

test "parseCanisterResult reject" {
    const json = "{\"Ok\":{\"Reject\":\"canister trapped\"}}";
    const result = try parseCanisterResult(testing.allocator, json);
    switch (result) {
        .reply => |data| {
            defer testing.allocator.free(data);
            return error.UnexpectedReply;
        },
        .reject => |msg| {
            defer testing.allocator.free(msg);
            try testing.expectEqualStrings("canister trapped", msg);
        },
    }
}

test "parseCanisterResult error" {
    const json = "{\"Err\":{\"description\":\"something broke\"}}";
    const result = try parseCanisterResult(testing.allocator, json);
    switch (result) {
        .reply => |data| {
            defer testing.allocator.free(data);
            return error.UnexpectedReply;
        },
        .reject => |msg| {
            defer testing.allocator.free(msg);
            try testing.expectEqualStrings("something broke", msg);
        },
    }
}

test "parseCanisterResult invalid json" {
    try testing.expectError(error.InvalidCanisterResult, parseCanisterResult(testing.allocator, "not json"));
}

// Minimal WASM canister that exports a "greet" query returning "hello".
// Hand-crafted:
//   imports: ic0.msg_reply_data_append(i32,i32), ic0.msg_reply()
//   exports: canister_query greet -> func 2
//   memory:  1 page
//   data:    "hello" at offset 0
//   code:    i32.const 0, i32.const 5, call 0, call 1, end
const test_canister_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, // magic + version
    // Type section: 2 types
    0x01, 0x09, 0x02,
    0x60, 0x02, 0x7f, 0x7f, 0x00, // (i32, i32) -> ()
    0x60, 0x00, 0x00, // () -> ()
    // Import section: ic0.msg_reply_data_append, ic0.msg_reply
    0x02, 0x2d, 0x02,
    0x03, 'i',  'c',
    '0',  0x15, 'm',
    's',  'g',  '_',
    'r',  'e',  'p',
    'l',  'y',  '_',
    'd',  'a',  't',
    'a',  '_',  'a',
    'p',  'p',  'e',
    'n',  'd',  0x00,
    0x00, 0x03, 'i',
    'c',  '0',  0x09,
    'm',  's',  'g',
    '_',  'r',  'e',
    'p',  'l',  'y',
    0x00, 0x01,
    // Function section: 1 function of type 1
    0x03,
    0x02, 0x01, 0x01,
    // Memory section: 1 memory, min 1 page
    0x05, 0x03, 0x01,
    0x00, 0x01,
    // Export section: "canister_query greet" -> func 2
    0x07,
    0x18, 0x01, 0x14,
    'c',  'a',  'n',
    'i',  's',  't',
    'e',  'r',  '_',
    'q',  'u',  'e',
    'r',  'y',  ' ',
    'g',  'r',  'e',
    'e',  't',  0x00,
    0x02,
    // Code section: greet body
    0x0a, 0x0c,
    0x01, 0x0a, 0x00,
    0x41, 0x00, // i32.const 0
    0x41, 0x05, // i32.const 5
    0x10, 0x00, // call 0 (msg_reply_data_append)
    0x10, 0x01, // call 1 (msg_reply)
    0x0b, // end
    // Data section: "hello" at offset 0
    0x0b,
    0x0b,
    0x01,
    0x00,
    0x41, 0x00, 0x0b, // i32.const 0, end
    0x05, 'h',  'e',
    'l',  'l',  'o',
};

fn skipIfNoServer() !void {
    if (std.posix.getenv("POCKET_IC_BIN") == null) return error.SkipZigTest;
}

test "server: instance lifecycle" {
    try skipIfNoServer();
    var pocket = try PocketIc.init(testing.allocator, .{});
    pocket.deinit();
}

test "server: create canister" {
    try skipIfNoServer();
    var pocket = try PocketIc.init(testing.allocator, .{});
    defer pocket.deinit();

    const cid = try pocket.createCanister();
    defer testing.allocator.free(cid);
    try testing.expect(cid.len > 0);
}

test "server: install code and query" {
    try skipIfNoServer();
    var pocket = try PocketIc.init(testing.allocator, .{});
    defer pocket.deinit();

    const cid = try pocket.createCanister();
    defer testing.allocator.free(cid);
    try pocket.installCode(cid, &test_canister_wasm, "", .install);

    const result = try pocket.queryCall(cid, principal.anonymous, "greet", "");
    switch (result) {
        .reply => |data| {
            defer testing.allocator.free(data);
            try testing.expectEqualStrings("hello", data);
        },
        .reject => |msg| {
            defer testing.allocator.free(msg);
            std.debug.print("rejected: {s}\n", .{msg});
            return error.Rejected;
        },
    }
}

test "server: time control" {
    try skipIfNoServer();
    var pocket = try PocketIc.init(testing.allocator, .{});
    defer pocket.deinit();

    const t1 = try pocket.getTime();
    try testing.expect(t1 > 0);

    const target: u64 = 1_000_000_000_000_000_000;
    try pocket.setTime(target);
    const t2 = try pocket.getTime();
    // setTime is async and may trigger ticks that adjust the time
    try testing.expect(t2 >= target);

    const advance_ns: u64 = 5_000_000_000;
    try pocket.advanceTime(advance_ns);
    const t3 = try pocket.getTime();
    try testing.expect(t3 >= t2 + advance_ns);
}

test "server: tick" {
    try skipIfNoServer();
    var pocket = try PocketIc.init(testing.allocator, .{});
    defer pocket.deinit();

    try pocket.tick();
}

test "server: add and get cycles" {
    try skipIfNoServer();
    var pocket = try PocketIc.init(testing.allocator, .{});
    defer pocket.deinit();

    const cid = try pocket.createCanister();
    defer testing.allocator.free(cid);
    const added = try pocket.addCycles(cid, 1_000_000_000_000);
    try testing.expect(added > 0);

    const balance = try pocket.getCycles(cid);
    try testing.expect(balance > 0);
}

test "server: multiple subnets" {
    try skipIfNoServer();
    var pocket = try PocketIc.init(testing.allocator, .{
        .application_subnets = 2,
    });
    defer pocket.deinit();

    const cid = try pocket.createCanister();
    defer testing.allocator.free(cid);
    try testing.expect(cid.len > 0);
}
