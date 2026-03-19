const cdk = @import("cdk");
const CallFuture = cdk.call.CallFuture;
const executor = cdk.executor;

var callee_principal: ?[]const u8 = null;

fn init() void {
    const arg = cdk.argData();
    if (arg.len == 0) return;
    callee_principal = cdk.principal.decode(arg) catch
        @panic("invalid principal");
}

// A task that chains two inter-canister calls and combines the results.
//
// Without the executor this would require nested onReply callbacks;
// with it the logic reads as a flat state machine.
const ChainedCallTask = struct {
    step: Step = .call_greet,
    future: ?CallFuture = null,
    first: ?[]const u8 = null,

    const Step = enum { call_greet, wait_greet, call_farewell };

    pub fn poll(self: *ChainedCallTask, waker: executor.Waker) executor.Poll {
        const callee = callee_principal orelse {
            cdk.trap("callee principal not set");
        };

        switch (self.step) {
            .call_greet => {
                self.future = CallFuture.call(callee, "greet", "") catch
                    cdk.trap("call_perform failed");
                self.future.?.onWake(executor.wakeCallback, waker.task_id);
                self.step = .wait_greet;
                return .pending;
            },
            .wait_greet => {
                const result = self.future.?.getResult() orelse return .pending;
                switch (result) {
                    .reply => |data| self.first = data,
                    .reject => |r| cdk.trap(r.message),
                }
                self.future = CallFuture.call(callee, "farewell", "") catch
                    cdk.trap("call_perform failed");
                self.future.?.onWake(executor.wakeCallback, waker.task_id);
                self.step = .call_farewell;
                return .pending;
            },
            .call_farewell => {
                const result = self.future.?.getResult() orelse return .pending;
                switch (result) {
                    .reply => |second| {
                        const first = self.first orelse cdk.trap("missing first result");
                        // Combine: "hello and goodbye"
                        const sep = " and ";
                        var buf: [64]u8 = undefined;
                        const total = first.len + sep.len + second.len;
                        if (total > buf.len) cdk.trap("reply too long");
                        @memcpy(buf[0..first.len], first);
                        @memcpy(buf[first.len..][0..sep.len], sep);
                        @memcpy(buf[first.len + sep.len ..][0..second.len], second);
                        cdk.replyRaw(buf[0..total]);
                    },
                    .reject => |r| cdk.trap(r.message),
                }
                return .ready;
            },
        }
    }
};

fn chainedCall() void {
    _ = executor.create(ChainedCallTask, .{});
    executor.pollAll();
}

comptime {
    cdk.init(init);
    cdk.update(chainedCall, "chained_call");
}
