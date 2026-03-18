pub extern "ic0" fn msg_arg_data_size() i32;
pub extern "ic0" fn msg_arg_data_copy(dst: [*]const u8, offset: i32, size: i32) void;
pub extern "ic0" fn msg_caller_size() i32;
pub extern "ic0" fn msg_caller_copy(dst: [*]const u8, offset: i32, size: i32) void;
pub extern "ic0" fn msg_reject_code() i32;
pub extern "ic0" fn msg_reject_msg_size() i32;
pub extern "ic0" fn msg_reject_msg_copy(dst: [*]const u8, offset: i32, size: i32) void;
pub extern "ic0" fn msg_reply_data_append(src: [*]const u8, len: i32) void;
pub extern "ic0" fn msg_reply() void;
pub extern "ic0" fn msg_reject(src: [*]const u8, len: i32) void;
pub extern "ic0" fn msg_cycles_available() i64;
pub extern "ic0" fn msg_cycles_available128(dst: [*]const u8) void;
pub extern "ic0" fn msg_cycles_refunded() i64;
pub extern "ic0" fn msg_cycles_refunded128(dst: [*]const u8) void;
pub extern "ic0" fn msg_cycles_accept(max_amount: i64) i64;
pub extern "ic0" fn msg_cycles_accept128(max_amount_high: i64, max_amount_low: i64, dst: [*]const u8) void;
pub extern "ic0" fn cycles_burn128(amount_high: i64, amount_low: i64, dst: [*]const u8) void;
pub extern "ic0" fn canister_self_size() i32;
pub extern "ic0" fn canister_self_copy(dst: [*]const u8, offset: i32, size: i32) void;
pub extern "ic0" fn canister_cycle_balance() i64;
pub extern "ic0" fn canister_cycle_balance128(dst: [*]const u8) void;
pub extern "ic0" fn canister_status() i32;
pub extern "ic0" fn canister_version() i64;
pub extern "ic0" fn msg_method_name_size() i32;
pub extern "ic0" fn msg_method_name_copy(dst: [*]const u8, offset: i32, size: i32) void;
pub extern "ic0" fn accept_message() void;
pub extern "ic0" fn call_new(
    callee_src: [*]const u8,
    callee_len: i32,
    name_src: [*]const u8,
    name_len: i32,
    reply_fun: i32,
    reply_env: i32,
    reject_fun: i32,
    reject_env: i32,
) void;
pub extern "ic0" fn call_on_cleanup(fun: i32, env: i32) void;
pub extern "ic0" fn call_data_append(src: [*]const u8, len: i32) void;
pub extern "ic0" fn call_cycles_add(amount: i64) void;
pub extern "ic0" fn call_cycles_add128(amount_high: i64, amount_low: i64) void;
pub extern "ic0" fn call_perform() i32;
pub extern "ic0" fn stable_size() i32;
pub extern "ic0" fn stable_grow(new_pages: i32) i32;
pub extern "ic0" fn stable_write(offset: i32, src: [*]const u8, size: i32) void;
pub extern "ic0" fn stable_read(dst: [*]const u8, offset: i32, size: i32) void;
pub extern "ic0" fn stable64_size() i64;
pub extern "ic0" fn stable64_grow(new_pages: i64) i64;
pub extern "ic0" fn stable64_write(offset: i64, src: [*]const u8, size: i64) void;
pub extern "ic0" fn stable64_read(dst: [*]const u8, offset: i64, size: i64) void;
pub extern "ic0" fn certified_data_set(src: [*]const u8, len: i32) void;
pub extern "ic0" fn data_certificate_present() i32;
pub extern "ic0" fn data_certificate_size() i32;
pub extern "ic0" fn data_certificate_copy(dst: [*]const u8, offset: i32, size: i32) void;
pub extern "ic0" fn time() i64;
pub extern "ic0" fn global_timer_set(timestamp: i64) i64;
pub extern "ic0" fn performance_counter(counter_type: i32) i64;
pub extern "ic0" fn is_controller(src: [*]const u8, len: i32) i32;
pub extern "ic0" fn in_replicated_execution() i32;
pub extern "ic0" fn debug_print(src: [*]const u8, len: i32) void;
pub extern "ic0" fn trap(src: [*]const u8, len: i32) void;
