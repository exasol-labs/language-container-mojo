//! host/c_ctx.rs — ORIGINAL SKETCH. Superseded by the verified, buildable patch
//! `../mojo-bridge.patch` (see ../PATCH.md), which wires this into
//! `exa-udf-runtime` as the off-by-default `mojo-bridge` feature, compiles
//! against toolchain 1.94.1, passes clippy + tests, and exports all 19 symbols
//! from the linked `exaudfclient` binary. Kept here for readability; build from
//! the patch, not this file.
//!
//! C-ABI context accessor bridge (the one MANDATORY host change).
//!
//! Add this module to `crates/exa-udf-runtime` (or a companion `cdylib`
//! `libexa_udf_host.so`) and export its symbols so a non-Rust `.so` can read
//! inputs and write outputs without touching the Rust `Value` enum or the
//! `UdfContext` trait vtable.
//!
//! Every function takes the SAME opaque `ctx` the host passes to `run`
//! (`*mut c_void` = double-indirected `&mut dyn UdfContext`) and undoes the
//! indirection exactly like the generated run shim does
//! (`exasol-udf-macros/src/lib.rs:634`). Return code convention: 0 = ok,
//! 1 = type/range error, 2 = NULL where a value was required (caller decides).
//!
//! SAFETY: the host serializes all UDF calls on one thread, and `ctx` is valid
//! only for the duration of the `run` call the accessor is invoked from — a
//! Mojo UDF must not stash these pointers.
//!
//! Build note: export these in the host's dynamic symbol table (link the host
//! binary with `-C link-arg=-rdynamic`), OR compile this file into a shared
//! `libexa_udf_host.so` that both the host and the Mojo `.so` link against.

use std::ffi::{c_char, c_void};
use exasol_udf_sdk::context::UdfContext;
use exasol_udf_sdk::value::Value;

/// Restore `&mut dyn UdfContext` from the opaque double-indirected pointer.
#[inline]
unsafe fn ctx<'a>(p: *mut c_void) -> &'a mut dyn UdfContext {
    // Identical cast to the run shim: `p` points at a `&mut dyn UdfContext`.
    *unsafe { &mut *(p as *mut &mut dyn UdfContext) }
}

// ---- input side -----------------------------------------------------------

#[no_mangle]
pub unsafe extern "C" fn exa_ctx_num_columns(p: *mut c_void) -> usize {
    unsafe { ctx(p) }.num_columns()
}

/// `is_null` out-param is set to 1 for SQL NULL, else 0. Returns 0 on success,
/// 1 on a type mismatch (value present but not integral).
#[no_mangle]
pub unsafe extern "C" fn exa_ctx_get_i64(
    p: *mut c_void, col: usize, out: *mut i64, is_null: *mut i32,
) -> i32 {
    match unsafe { ctx(p) }.get_i64(col) {
        Ok(None)    => { unsafe { *is_null = 1; } 0 }
        Ok(Some(v)) => { unsafe { *is_null = 0; *out = v; } 0 }
        Err(_)      => 1,
    }
}

#[no_mangle]
pub unsafe extern "C" fn exa_ctx_get_f64(
    p: *mut c_void, col: usize, out: *mut f64, is_null: *mut i32,
) -> i32 {
    match unsafe { ctx(p) }.get_f64(col) {
        Ok(None)    => { unsafe { *is_null = 1; } 0 }
        Ok(Some(v)) => { unsafe { *is_null = 0; *out = v; } 0 }
        Err(_)      => 1,
    }
}

#[no_mangle]
pub unsafe extern "C" fn exa_ctx_get_bool(
    p: *mut c_void, col: usize, out: *mut i32, is_null: *mut i32,
) -> i32 {
    match unsafe { ctx(p) }.get_bool(col) {
        Ok(None)    => { unsafe { *is_null = 1; } 0 }
        Ok(Some(v)) => { unsafe { *is_null = 0; *out = v as i32; } 0 }
        Err(_)      => 1,
    }
}

/// Borrow a UTF-8 string column as (ptr,len) valid until the next accessor call
/// on this ctx. The Mojo side must copy immediately. `is_null` as above.
#[no_mangle]
pub unsafe extern "C" fn exa_ctx_get_string(
    p: *mut c_void, col: usize, out_ptr: *mut *const c_char, out_len: *mut usize, is_null: *mut i32,
) -> i32 {
    match unsafe { ctx(p) }.get_string(col) {
        Ok(None)    => { unsafe { *is_null = 1; } 0 }
        Ok(Some(s)) => {
            unsafe { *is_null = 0; *out_ptr = s.as_ptr() as *const c_char; *out_len = s.len(); }
            0
        }
        Err(_) => 1,
    }
}

/// Advance a SET-mode group. `has_next` out-param: 1 if a row is now current,
/// 0 at the group boundary. Returns 1 if called on scalar input (host bans it).
#[no_mangle]
pub unsafe extern "C" fn exa_ctx_next(p: *mut c_void, has_next: *mut i32) -> i32 {
    match unsafe { ctx(p) }.next() {
        Ok(more) => { unsafe { *has_next = more as i32; } 0 }
        Err(_)   => 1,
    }
}

// ---- output side ----------------------------------------------------------
// RETURNS-shape UDFs call exactly one `exa_ctx_set_*` (or set_null) per row.

#[no_mangle]
pub unsafe extern "C" fn exa_ctx_set_return_i64(p: *mut c_void, v: i64) -> i32 {
    to_rc(unsafe { ctx(p) }.set_return(Some(Value::Int64(v))))
}

#[no_mangle]
pub unsafe extern "C" fn exa_ctx_set_return_f64(p: *mut c_void, v: f64) -> i32 {
    to_rc(unsafe { ctx(p) }.set_return(Some(Value::Double(v))))
}

#[no_mangle]
pub unsafe extern "C" fn exa_ctx_set_return_bool(p: *mut c_void, v: i32) -> i32 {
    to_rc(unsafe { ctx(p) }.set_return(Some(Value::Bool(v != 0))))
}

/// `ptr`/`len` is a borrowed UTF-8 buffer owned by the Mojo `.so`; copied here.
#[no_mangle]
pub unsafe extern "C" fn exa_ctx_set_return_string(p: *mut c_void, ptr: *const c_char, len: usize) -> i32 {
    let bytes = unsafe { std::slice::from_raw_parts(ptr as *const u8, len) };
    match std::str::from_utf8(bytes) {
        Ok(s) => to_rc(unsafe { ctx(p) }.set_return(Some(Value::String(s.to_owned())))),
        Err(_) => 1,
    }
}

#[no_mangle]
pub unsafe extern "C" fn exa_ctx_set_return_null(p: *mut c_void) -> i32 {
    to_rc(unsafe { ctx(p) }.set_return(None))
}

// EMITS-shape UDFs build a row column-by-column then flush it. A tiny per-ctx
// row buffer keyed by the ctx pointer would live in the runtime; sketched as a
// single-column emit for brevity.
#[no_mangle]
pub unsafe extern "C" fn exa_ctx_emit_i64(p: *mut c_void, v: i64) -> i32 {
    to_rc(unsafe { ctx(p) }.emit(&[Value::Int64(v)]))
}

/// Allocate a C string with the C allocator so the host can `free` it — used for
/// the `error_out` channel from Mojo. Mojo may call this instead of its own malloc.
#[no_mangle]
pub unsafe extern "C" fn exa_alloc_cstring(ptr: *const c_char, len: usize) -> *mut c_char {
    unsafe extern "C" { fn malloc(n: usize) -> *mut c_void; }
    let buf = unsafe { malloc(len + 1) } as *mut u8;
    if buf.is_null() { return std::ptr::null_mut(); }
    unsafe {
        std::ptr::copy_nonoverlapping(ptr as *const u8, buf, len);
        *buf.add(len) = 0;
    }
    buf as *mut c_char
}

#[inline]
fn to_rc(r: Result<(), exasol_udf_sdk::error::UdfError>) -> i32 {
    match r { Ok(()) => 0, Err(_) => 1 }
}
