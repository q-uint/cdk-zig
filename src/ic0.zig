// Message input/output
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
pub extern "ic0" fn msg_deadline() i64;

// Cycles (message-level)
pub extern "ic0" fn msg_cycles_available() i64;
pub extern "ic0" fn msg_cycles_available128(dst: [*]const u8) void;
pub extern "ic0" fn msg_cycles_refunded() i64;
pub extern "ic0" fn msg_cycles_refunded128(dst: [*]const u8) void;
pub extern "ic0" fn msg_cycles_accept(max_amount: i64) i64;
pub extern "ic0" fn msg_cycles_accept128(max_amount_high: i64, max_amount_low: i64, dst: [*]const u8) void;
pub extern "ic0" fn cycles_burn128(amount_high: i64, amount_low: i64, dst: [*]const u8) void;

// Canister info
pub extern "ic0" fn canister_self_size() i32;
pub extern "ic0" fn canister_self_copy(dst: [*]const u8, offset: i32, size: i32) void;
pub extern "ic0" fn canister_cycle_balance() i64;
pub extern "ic0" fn canister_cycle_balance128(dst: [*]const u8) void;
pub extern "ic0" fn canister_liquid_cycle_balance128(dst: [*]const u8) void;
pub extern "ic0" fn canister_status() i32;
pub extern "ic0" fn canister_version() i64;

// Subnet info
pub extern "ic0" fn subnet_self_size() i32;
pub extern "ic0" fn subnet_self_copy(dst: [*]const u8, offset: i32, size: i32) void;

// Method name
pub extern "ic0" fn msg_method_name_size() i32;
pub extern "ic0" fn msg_method_name_copy(dst: [*]const u8, offset: i32, size: i32) void;

// Message acceptance
pub extern "ic0" fn accept_message() void;

// Inter-canister calls
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
pub extern "ic0" fn call_with_best_effort_response(timeout_seconds: i32) void;

// Stable memory (32-bit)
pub extern "ic0" fn stable_size() i32;
pub extern "ic0" fn stable_grow(new_pages: i32) i32;
pub extern "ic0" fn stable_write(offset: i32, src: [*]const u8, size: i32) void;
pub extern "ic0" fn stable_read(dst: [*]const u8, offset: i32, size: i32) void;

// Stable memory (64-bit)
pub extern "ic0" fn stable64_size() i64;
pub extern "ic0" fn stable64_grow(new_pages: i64) i64;
pub extern "ic0" fn stable64_write(offset: i64, src: i64, size: i64) void;
pub extern "ic0" fn stable64_read(dst: i64, offset: i64, size: i64) void;

// Certified data
pub extern "ic0" fn certified_data_set(src: [*]const u8, len: i32) void;
pub extern "ic0" fn data_certificate_present() i32;
pub extern "ic0" fn data_certificate_size() i32;
pub extern "ic0" fn data_certificate_copy(dst: [*]const u8, offset: i32, size: i32) void;

// Root key
pub extern "ic0" fn root_key_size() i32;
pub extern "ic0" fn root_key_copy(dst: [*]const u8, offset: i32, size: i32) void;

// Time and timers
pub extern "ic0" fn time() i64;
pub extern "ic0" fn global_timer_set(timestamp: i64) i64;

// Performance
pub extern "ic0" fn performance_counter(counter_type: i32) i64;

// Authorization
pub extern "ic0" fn is_controller(src: [*]const u8, len: i32) i32;

// Execution context
pub extern "ic0" fn in_replicated_execution() i32;

// Debug/trap
pub extern "ic0" fn debug_print(src: [*]const u8, len: i32) void;
pub extern "ic0" fn trap(src: [*]const u8, len: i32) void;

// Cost estimation
pub extern "ic0" fn cost_call(method_name_size: i64, payload_size: i64, dst: [*]const u8) void;
pub extern "ic0" fn cost_create_canister(dst: [*]const u8) void;
pub extern "ic0" fn cost_http_request(request_size: i64, max_response_bytes: i64, dst: [*]const u8) void;
pub extern "ic0" fn cost_sign_with_ecdsa(key_name_src: [*]const u8, key_name_len: i32, ecdsa_curve: i32, dst: [*]const u8) i32;
pub extern "ic0" fn cost_sign_with_schnorr(key_name_src: [*]const u8, key_name_len: i32, algorithm: i32, dst: [*]const u8) i32;
pub extern "ic0" fn cost_vetkd_derive_key(key_name_src: [*]const u8, key_name_len: i32, vetkd_curve: i32, dst: [*]const u8) i32;

// Environment variables
pub extern "ic0" fn env_var_count() i32;
pub extern "ic0" fn env_var_name_size(index: i32) i32;
pub extern "ic0" fn env_var_name_copy(index: i32, dst: [*]const u8, offset: i32, size: i32) void;
pub extern "ic0" fn env_var_name_exists(name_src: [*]const u8, name_len: i32) i32;
pub extern "ic0" fn env_var_value_size(name_src: [*]const u8, name_len: i32) i32;
pub extern "ic0" fn env_var_value_copy(name_src: [*]const u8, name_len: i32, dst: [*]const u8, offset: i32, size: i32) void;
