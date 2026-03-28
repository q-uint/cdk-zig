const std = @import("std");
const cdk = @import("cdk");
pub const bls = @import("bls");
pub const principal = cdk.principal;
pub const flamegraph = @import("flamegraph.zig");
const candid = cdk.candid;
const cbor = cdk.cbor;
const hash_tree = cdk.hash_tree;

const Allocator = std.mem.Allocator;
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
        const EmptyRecord = struct {};
        const payload = candid.encode(self.allocator, .{EmptyRecord{}}) catch
            return error.CandidEncodingFailed;
        defer self.allocator.free(payload);
        const reply = try self.managementCallWithEffective(
            sender,
            "provisional_create_canister_with_cycles",
            payload,
            .none,
        );
        defer self.allocator.free(reply);

        const CreateResult = struct { canister_id: candid.Principal };
        const result = candid.decode(CreateResult, self.allocator, reply) catch
            return error.CandidDecodingFailed;
        return result.canister_id.bytes;
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
        const InstallCodeMode = union(enum) { install: void, reinstall: void, upgrade: void };
        const InstallCodeArgs = struct {
            arg: candid.Blob,
            canister_id: candid.Principal,
            mode: InstallCodeMode,
            wasm_module: candid.Blob,
        };
        const mode_val: InstallCodeMode = switch (mode) {
            .install => .{ .install = {} },
            .reinstall => .{ .reinstall = {} },
            .upgrade => .{ .upgrade = {} },
        };
        const payload = candid.encode(self.allocator, .{InstallCodeArgs{
            .arg = candid.Blob.from(arg),
            .canister_id = candid.Principal.from(canister_id),
            .mode = mode_val,
            .wasm_module = candid.Blob.from(wasm_module),
        }}) catch return error.CandidEncodingFailed;
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

    pub const Certificate = struct {
        allocator: Allocator,
        tree: hash_tree.CborTree,
        signature: []const u8,
        // Owns the backing bytes that tree nodes and signature point into.
        backing: []const u8,

        pub fn deinit(self: *Certificate) void {
            self.tree.deinit();
            self.allocator.free(self.backing);
        }
    };

    pub fn readStateCertificate(
        self: *PocketIc,
        canister_id: []const u8,
        paths: []const []const []const u8,
    ) !Certificate {
        // Build the CBOR read_state request envelope.
        const time_ns = try self.getTime();
        const ingress_expiry = time_ns + 240_000_000_000;

        // Encode each path as CBOR: array of byte strings.
        // Then wrap in an outer array.
        var path_bufs: [8][]const u8 = undefined;
        if (paths.len > 8) return error.TooManyPaths;
        for (paths, 0..) |path, i| {
            path_bufs[i] = try encodePathCbor(self.allocator, path);
        }
        defer for (path_bufs[0..paths.len]) |buf| self.allocator.free(buf);

        // Compute content size for dynamic allocation.
        var paths_size: usize = 0;
        for (path_bufs[0..paths.len]) |encoded_path| {
            paths_size += encoded_path.len;
        }
        const content_size = 1 // map(4) header
            + cbor.headSize("request_type".len) + "request_type".len + cbor.headSize("read_state".len) + "read_state".len + cbor.headSize("ingress_expiry".len) + "ingress_expiry".len + cbor.headSize(ingress_expiry) + cbor.headSize("paths".len) + "paths".len + cbor.headSize(paths.len) + paths_size + cbor.headSize("sender".len) + "sender".len + cbor.headSize(1) + 1; // bytes(0x04)

        // envelope: map(1) + "content" header + content
        const envelope_size = 1 + cbor.headSize("content".len) + "content".len + content_size;
        // tagged: 3-byte self-describe tag + envelope
        const tagged_size = 3 + envelope_size;

        const tagged_buf = try self.allocator.alloc(u8, tagged_size);
        defer self.allocator.free(tagged_buf);

        // Write self-describe tag.
        tagged_buf[0] = 0xd9;
        tagged_buf[1] = 0xd9;
        tagged_buf[2] = 0xf7;

        // Write envelope: { "content": <content> }
        var pos: usize = 3;
        tagged_buf[pos] = 0xa1; // map(1)
        pos += 1;
        pos += writeTextToBuf(tagged_buf[pos..], "content");

        // Write content map.
        tagged_buf[pos] = 0xa4; // map(4)
        pos += 1;
        pos += writeTextToBuf(tagged_buf[pos..], "request_type");
        pos += writeTextToBuf(tagged_buf[pos..], "read_state");
        pos += writeTextToBuf(tagged_buf[pos..], "ingress_expiry");
        pos += writeUintToBuf(tagged_buf[pos..], ingress_expiry);
        pos += writeTextToBuf(tagged_buf[pos..], "paths");
        pos += writeArrayHeaderToBuf(tagged_buf[pos..], paths.len);
        for (path_bufs[0..paths.len]) |encoded_path| {
            @memcpy(tagged_buf[pos..][0..encoded_path.len], encoded_path);
            pos += encoded_path.len;
        }
        pos += writeTextToBuf(tagged_buf[pos..], "sender");
        pos += writeBytesToBuf(tagged_buf[pos..], &.{0x04});

        const tagged = tagged_buf[0..pos];

        // POST to read_state endpoint.
        const cid_text = principal.encode(canister_id);
        const url = try std.fmt.allocPrint(
            self.allocator,
            "{s}/instances/{d}/api/v2/canister/{s}/read_state",
            .{ self.url, self.instance_id, cid_text },
        );
        defer self.allocator.free(url);

        const resp = try httpRequestCbor(self.client, self.allocator, url, tagged);
        errdefer self.allocator.free(resp.body);

        if (resp.status != .ok) {
            self.allocator.free(resp.body);
            return error.InvalidReadStateResponse;
        }

        // Parse response: CBOR { "certificate": <bytes> }
        var resp_data = resp.body;
        if (resp_data.len >= 3 and resp_data[0] == 0xd9 and resp_data[1] == 0xd9 and resp_data[2] == 0xf7) {
            resp_data = resp_data[3..];
        }
        const resp_decoded = try cbor.decodeValue(resp_data);
        const resp_map = switch (resp_decoded.value) {
            .map => |m| m,
            else => return error.InvalidReadStateResponse,
        };
        const cert_val = try cbor.mapLookup(resp_map, "certificate") orelse
            return error.InvalidReadStateResponse;
        const cert_bytes = switch (cert_val) {
            .bytes => |b| b,
            else => return error.InvalidReadStateResponse,
        };

        // Parse certificate: CBOR { "tree": <tree>, "signature": <bytes> }
        var cert_data = cert_bytes;
        if (cert_data.len >= 3 and cert_data[0] == 0xd9 and cert_data[1] == 0xd9 and cert_data[2] == 0xf7) {
            cert_data = cert_data[3..];
        }
        const cert_decoded = try cbor.decodeValue(cert_data);
        const cert_map = switch (cert_decoded.value) {
            .map => |m| m,
            else => return error.InvalidReadStateResponse,
        };

        const sig_val = try cbor.mapLookup(cert_map, "signature") orelse
            return error.InvalidReadStateResponse;
        const signature = switch (sig_val) {
            .bytes => |b| b,
            else => return error.InvalidReadStateResponse,
        };

        const tree_raw = try findRawTreeBytes(cert_map);
        var tree = try hash_tree.HashTree.decodeCbor(self.allocator, tree_raw);
        errdefer tree.deinit();

        return .{
            .allocator = self.allocator,
            .tree = tree,
            .signature = signature,
            .backing = resp.body,
        };
    }

    fn findRawTreeBytes(map_content: []const u8) ![]const u8 {
        return try cbor.mapLookupRaw(map_content, "tree") orelse error.InvalidCbor;
    }

    // Get the root public key for this IC instance.
    // Returns the raw BLS12-381 G2 public key (96 bytes) without DER prefix.
    pub fn rootKey(self: *PocketIc) ![]const u8 {
        // Look up the subnet for the effective_canister_id, then fetch
        // that subnet's public key via read/pub_key.

        const subnet_b64 = try base64Encode(self.allocator, self.effective_canister_id);
        defer self.allocator.free(subnet_b64);

        // First get the subnet_id for our effective canister.
        const get_subnet_body = try std.fmt.allocPrint(
            self.allocator,
            "{{\"canister_id\":\"{s}\"}}",
            .{subnet_b64},
        );
        defer self.allocator.free(get_subnet_body);

        const get_subnet_url = try std.fmt.allocPrint(
            self.allocator,
            "{s}/instances/{d}/read/get_subnet",
            .{ self.url, self.instance_id },
        );
        defer self.allocator.free(get_subnet_url);

        const subnet_resp = try httpPost(self.client, self.allocator, get_subnet_url, get_subnet_body);
        defer self.allocator.free(subnet_resp.body);

        const subnet_parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, subnet_resp.body, .{
            .allocate = .alloc_always,
        });
        defer subnet_parsed.deinit();

        const subnet_id_b64 = subnet_parsed.value.object.get("subnet_id").?.string;
        const subnet_id = try base64Decode(self.allocator, subnet_id_b64);
        defer self.allocator.free(subnet_id);

        // Now get the public key.
        const sid_b64 = try base64Encode(self.allocator, subnet_id);
        defer self.allocator.free(sid_b64);

        const pk_body = try std.fmt.allocPrint(
            self.allocator,
            "{{\"subnet_id\":\"{s}\"}}",
            .{sid_b64},
        );
        defer self.allocator.free(pk_body);

        const pk_url = try std.fmt.allocPrint(
            self.allocator,
            "{s}/instances/{d}/read/pub_key",
            .{ self.url, self.instance_id },
        );
        defer self.allocator.free(pk_url);

        const pk_resp = try httpPost(self.client, self.allocator, pk_url, pk_body);
        defer self.allocator.free(pk_resp.body);

        // Response is a JSON-encoded byte array (base64 or raw JSON array).
        const pk_parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, pk_resp.body, .{
            .allocate = .alloc_always,
        });
        defer pk_parsed.deinit();

        // The response is a DER-encoded public key as a JSON array of bytes.
        const arr = pk_parsed.value.array;
        const der_key = try self.allocator.alloc(u8, arr.items.len);
        for (arr.items, 0..) |item, i| {
            der_key[i] = @intCast(item.integer);
        }

        // Strip DER prefix to get raw 96-byte BLS key.
        const raw_key = bls.extractDerKey(der_key) catch {
            // If DER extraction fails, return as-is (might already be raw).
            return der_key;
        };
        const result = try self.allocator.dupe(u8, raw_key);
        self.allocator.free(der_key);
        return result;
    }

    // Verify a certificate's BLS signature against the IC root key.
    pub fn verifyCertificate(self: *PocketIc, cert: *const Certificate) !void {
        const root_key = try self.rootKey();
        defer self.allocator.free(root_key);

        const root_hash = cert.tree.root.?.reconstruct();
        bls.verifyIcCertificate(cert.signature, &root_hash, root_key) catch
            return error.CertificateVerificationFailed;
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

fn httpRequestCbor(
    client: *std.http.Client,
    allocator: Allocator,
    url: []const u8,
    body: []const u8,
) !HttpResponse {
    const uri = try std.Uri.parse(url);
    var req = try client.request(.POST, uri, .{
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/cbor" },
        },
    });
    defer req.deinit();
    // std.http.Client.sendBodyComplete takes []u8 but does not mutate;
    // @constCast is safe here.
    try req.sendBodyComplete(@constCast(body));
    var redirect_buf: [8 * 1024]u8 = undefined;
    var response = try req.receiveHead(&redirect_buf);
    var transfer_buf: [16 * 1024]u8 = undefined;
    const reader = response.reader(&transfer_buf);
    const response_body = try reader.allocRemaining(allocator, std.Io.Limit.limited(10 * 1024 * 1024));
    return .{ .status = response.head.status, .body = response_body };
}

fn encodePathCbor(allocator: Allocator, path: []const []const u8) ![]const u8 {
    // Calculate size: array header + each element as a CBOR byte string.
    var size: usize = cbor.headSize(path.len);
    for (path) |elem| {
        size += cbor.headSize(elem.len) + elem.len;
    }
    const buf = try allocator.alloc(u8, size);
    var pos: usize = 0;
    cbor.writeHead(buf, &pos, 4, path.len); // CBOR array
    for (path) |elem| {
        cbor.writeHead(buf, &pos, 2, elem.len); // CBOR byte string
        @memcpy(buf[pos..][0..elem.len], elem);
        pos += elem.len;
    }
    return buf;
}

fn writeTextToBuf(buf: []u8, text: []const u8) usize {
    var pos: usize = 0;
    cbor.writeHead(buf, &pos, 3, text.len);
    @memcpy(buf[pos..][0..text.len], text);
    return pos + text.len;
}

fn writeBytesToBuf(buf: []u8, data: []const u8) usize {
    var pos: usize = 0;
    cbor.writeHead(buf, &pos, 2, data.len);
    @memcpy(buf[pos..][0..data.len], data);
    return pos + data.len;
}

fn writeUintToBuf(buf: []u8, val: u64) usize {
    var pos: usize = 0;
    cbor.writeHead(buf, &pos, 0, val);
    return pos;
}

fn writeArrayHeaderToBuf(buf: []u8, len: usize) usize {
    var pos: usize = 0;
    cbor.writeHead(buf, &pos, 4, len);
    return pos;
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

test "candid encode empty record" {
    const EmptyRecord = struct {};
    const bytes = try candid.encode(testing.allocator, .{EmptyRecord{}});
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("DIDL", bytes[0..4]);
}

test "candid encode install_code round-trip" {
    const InstallCodeMode = union(enum) { install: void, reinstall: void, upgrade: void };
    const InstallCodeArgs = struct {
        arg: candid.Blob,
        canister_id: candid.Principal,
        mode: InstallCodeMode,
        wasm_module: candid.Blob,
    };
    const canister_id = &[_]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x01, 0x01 };
    const wasm = &[_]u8{ 0x00, 0x61, 0x73, 0x6d };
    const encoded = try candid.encode(testing.allocator, .{InstallCodeArgs{
        .arg = candid.Blob.from(""),
        .canister_id = candid.Principal.from(canister_id),
        .mode = .{ .install = {} },
        .wasm_module = candid.Blob.from(wasm),
    }});
    defer testing.allocator.free(encoded);
    try testing.expectEqualStrings("DIDL", encoded[0..4]);
    try testing.expect(encoded.len > 20);

    const decoded = try candid.decode(InstallCodeArgs, testing.allocator, encoded);
    defer testing.allocator.free(decoded.arg.data);
    defer testing.allocator.free(decoded.canister_id.bytes);
    defer testing.allocator.free(decoded.wasm_module.data);
    try testing.expectEqualSlices(u8, canister_id, decoded.canister_id.bytes);
    try testing.expectEqualSlices(u8, wasm, decoded.wasm_module.data);
}

test "candid decode principal from record" {
    const CreateResult = struct { canister_id: candid.Principal };
    const principal_bytes = &[_]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x01, 0x01 };
    const encoded = try candid.encode(testing.allocator, .{CreateResult{
        .canister_id = candid.Principal.from(principal_bytes),
    }});
    defer testing.allocator.free(encoded);

    const decoded = try candid.decode(CreateResult, testing.allocator, encoded);
    defer testing.allocator.free(decoded.canister_id.bytes);
    try testing.expectEqualSlices(u8, principal_bytes, decoded.canister_id.bytes);
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
