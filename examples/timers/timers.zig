const cdk = @import("cdk");

var counter: u32 = 0;
var interval_id: ?cdk.timers.TimerId = null;

fn init() void {
    // Set up a repeating timer that increments the counter every second.
    interval_id = cdk.timers.setTimerInterval(1_000_000_000, increment);

    // Set a one-shot timer that fires after 5 seconds.
    _ = cdk.timers.setTimer(5_000_000_000, struct {
        fn f() void {
            counter += 100;
        }
    }.f);
}

fn increment() void {
    counter += 1;
}

fn getCounter() u32 {
    return counter;
}

fn stopInterval() void {
    if (interval_id) |id| {
        cdk.timers.cancelTimer(id);
        interval_id = null;
    }
    cdk.replyRaw("");
}

comptime {
    cdk.init(init);
    cdk.globalTimer(cdk.timers.processTimers);
    cdk.query(getCounter, "get_counter");
    cdk.update(stopInterval, "stop_interval");
}
