# System API imports, copied verbatim from the IC Interface Specification,
# section "Overview of imports". Multi-line declarations are joined onto one
# line; nothing else is altered.
#
# Source: https://github.com/dfinity/developer-docs/blob/main/docs/references/ic-interface-spec/canister-interface.md
# Vendored: 2026-11-11
#
# ic0.cost_http_request is deprecated in favour of ic0.cost_http_request_v2.
#
# The comment after each function lists the contexts it may be invoked from:
#
#   I    canister_init or canister_post_upgrade
#   G    canister_pre_upgrade
#   U    canister_update
#   RQ   canister_query, replicated
#   NRQ  canister_query, non-replicated
#   TQ   canister_query, as a http outcall transform
#   CQ   canister_composite_query
#   Ry   reply callback
#   Rt   reject callback
#   CRy  reply callback in a composite query
#   CRt  reject callback in a composite query
#   C    cleanup callback
#   CC   cleanup callback in a composite query
#   s    the (start) module initialization function
#   F    canister_inspect_message
#   T    system task: heartbeat, global timer, or on low wasm memory
#   *    I G U RQ NRQ TQ CQ Ry Rt CRy CRt C CC F T, but not (start)
#
# ic0.zig is checked against this file at compile time, in both directions.

ic0.msg_arg_data_size : () -> I;                                                      // I U RQ NRQ TQ CQ Ry CRy F
ic0.msg_arg_data_copy : (dst : I, offset : I, size : I) -> ();                        // I U RQ NRQ TQ CQ Ry CRy F
ic0.msg_caller_size : () -> I;                                                        // *
ic0.msg_caller_copy : (dst : I, offset : I, size : I) -> ();                          // *
ic0.msg_caller_info_data_size : () -> I;                                              // U RQ NRQ CQ Ry Rt CRy CRt C CC F
ic0.msg_caller_info_data_copy : (dst : I, offset : I, size : I) -> ();                // U RQ NRQ CQ Ry Rt CRy CRt C CC F
ic0.msg_caller_info_signer_size : () -> I;                                            // U RQ NRQ CQ Ry Rt CRy CRt C CC F
ic0.msg_caller_info_signer_copy : (dst : I, offset : I, size : I) -> ();              // U RQ NRQ CQ Ry Rt CRy CRt C CC F
ic0.msg_reject_code : () -> i32;                                                      // Ry Rt CRy CRt C
ic0.msg_reject_msg_size : () -> I;                                                    // Rt CRt
ic0.msg_reject_msg_copy : (dst : I, offset : I, size : I) -> ();                      // Rt CRt
ic0.msg_deadline : () -> i64;                                                         // U Q CQ Ry Rt CRy CRt
ic0.msg_reply_data_append : (src : I, size : I) -> ();                                // U RQ NRQ TQ CQ Ry Rt CRy CRt
ic0.msg_reply : () -> ();                                                             // U RQ NRQ TQ CQ Ry Rt CRy CRt
ic0.msg_reject : (src : I, size : I) -> ();                                           // U RQ NRQ TQ CQ Ry Rt CRy CRt
ic0.msg_cycles_available128 : (dst : I) -> ();                                        // U RQ Rt Ry
ic0.msg_cycles_refunded128 : (dst : I) -> ();                                         // Rt Ry
ic0.msg_cycles_accept128 : (max_amount_high : i64, max_amount_low: i64, dst : I) -> ();  // U RQ Rt Ry
ic0.cycles_burn128 : (amount_high : i64, amount_low : i64, dst : I) -> ();             // I G U RQ Ry Rt C T
ic0.canister_self_size : () -> I;                                                     // *
ic0.canister_self_copy : (dst : I, offset : I, size : I) -> ();                       // *
ic0.canister_cycle_balance128 : (dst : I) -> ();                                      // *
ic0.canister_liquid_cycle_balance128 : (dst : I) -> ();                               // *
ic0.canister_status : () -> i32;                                                      // *
ic0.canister_version : () -> i64;                                                     // *
ic0.subnet_self_size : () -> I;                                                       // *
ic0.subnet_self_copy : (dst : I, offset : I, size : I) -> ();                         // *
ic0.subnet_self_node_count : () -> i32;                                               // *
ic0.msg_method_name_size : () -> I;                                                   // F
ic0.msg_method_name_copy : (dst : I, offset : I, size : I) -> ();                     // F
ic0.accept_message : () -> ();                                                        // F
ic0.call_new : (callee_src : I, callee_size : I, name_src : I, name_size : I, reply_fun : I, reply_env : I, reject_fun : I, reject_env : I) -> ();  // U CQ Ry Rt CRy CRt T
ic0.call_on_cleanup : (fun : I, env : I) -> ();                                       // U CQ Ry Rt CRy CRt T
ic0.call_data_append : (src : I, size : I) -> ();                                     // U CQ Ry Rt CRy CRt T
ic0.call_with_best_effort_response : (timeout_seconds : i32) -> ();                   // U CQ Ry Rt CRy CRt T
ic0.call_cycles_add128 : (amount_high : i64, amount_low: i64) -> ();                  // U Ry Rt T
ic0.call_perform : () -> ( err_code : i32 );                                          // U CQ Ry Rt CRy CRt T
ic0.stable64_size : () -> (page_count : i64);                                         // * s
ic0.stable64_grow : (new_pages : i64) -> (old_page_count : i64);                      // * s
ic0.stable64_write : (offset : i64, src : i64, size : i64) -> ();                     // * s
ic0.stable64_read : (dst : i64, offset : i64, size : i64) -> ();                      // * s
ic0.root_key_size : () -> I;                                                          // I G U RQ Ry Rt C T
ic0.root_key_copy : (dst : I, offset : I, size : I) -> ();                            // I G U RQ Ry Rt C T
ic0.certified_data_set : (src : I, size : I) -> ();                                   // I G U Ry Rt T
ic0.data_certificate_present : () -> i32;                                             // *
ic0.data_certificate_size : () -> I;                                                  // NRQ CQ
ic0.data_certificate_copy : (dst : I, offset : I, size : I) -> ();                    // NRQ CQ
ic0.time : () -> (timestamp : i64);                                                   // *
ic0.global_timer_set : (timestamp : i64) -> i64;                                      // I G U Ry Rt C T
ic0.performance_counter : (counter_type : i32) -> (counter : i64);                    // * s
ic0.is_controller : (src : I, size : I) -> ( result : i32);                           // * s
ic0.in_replicated_execution : () -> (result : i32);                                   // * s
ic0.cost_call : (method_name_size: i64, payload_size : i64, dst : I) -> ();           // * s
ic0.cost_create_canister : (dst : I) -> ();                                           // * s
ic0.cost_http_request : (request_size : i64, max_res_bytes : i64, dst : I) -> ();     // * s
ic0.cost_http_request_v2 : (params_src : I, params_size : I, dst : I) -> ();          // * s
ic0.cost_sign_with_ecdsa : (src : I, size : I, ecdsa_curve: i32, dst : I) -> i32;     // * s
ic0.cost_sign_with_schnorr : (src : I, size : I, algorithm: i32, dst : I) -> i32;     // * s
ic0.cost_vetkd_derive_key : (src : I, size : I, vetkd_curve: i32, dst : I) -> i32;    // * s
ic0.env_var_count : () -> I;                                                          // *
ic0.env_var_name_size : (index: I) -> I;                                              // *
ic0.env_var_name_copy : (index: I, dst: I, offset: I, size: I) -> ();                 // *
ic0.env_var_name_exists : (name_src: I, name_size: I) -> i32;                         // *
ic0.env_var_value_size : (name_src: I, name_size: I) -> I;                            // *
ic0.env_var_value_copy : (name_src: I, name_size: I, dst: I, offset: I, size: I) -> ();  // *
ic0.debug_print : (src : I, size : I) -> ();                                          // * s
ic0.trap : (src : I, size : I) -> ();                                                 // * s

# Available only when I = i32, that is when the declared memory is 32-bit or
# the canister declares no memory. Deprecated, but still part of the API.

ic0.msg_cycles_available : () -> i64;                                                 // U RQ Rt Ry
ic0.msg_cycles_refunded : () -> i64;                                                  // Rt Ry
ic0.msg_cycles_accept : (max_amount : i64) -> (amount : i64);                         // U RQ Rt Ry
ic0.canister_cycle_balance : () -> i64;                                               // *
ic0.call_cycles_add : (amount : i64) -> ();                                           // U Ry Rt T
ic0.stable_size : () -> (page_count : i32);                                           // * s
ic0.stable_grow : (new_pages : i32) -> (old_page_count : i32);                        // * s
ic0.stable_write : (offset : i32, src : i32, size : i32) -> ();                       // * s
ic0.stable_read : (dst : i32, offset : i32, size : i32) -> ();                        // * s
