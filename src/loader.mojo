# loader.mojo — the OPTIONAL dynamic-UDF path: load a user-supplied Mojo `.so`
# from BucketFS at runtime and call it, instead of the baked-in run_udf().
#
# This is an EXTENSION, not a replacement: main.mojo only takes this path when a
# script's source carries a `%udf_object <path>` directive; otherwise it falls
# back to the compiled-in UDFs in udf.mojo. Analogous to the Rust SLC's
# exaudfclient loading a `.so` via a C-ABI vtable — here via Mojo's DLHandle,
# the same runtime-dlopen mechanism zmq.mojo already uses for libzmq.
#
# ── The C ABI a UDF .so must export (see examples/udf_so/) ────────────────────
#   Int64 __exa_udf_abi_version()
#         returns EXA_UDF_ABI_VERSION; the host refuses to call a mismatched .so.
#   Int64 __exa_udf_entry_<SCRIPT_NAME>(
#             const Int64*  in_vals,   const Bool* in_nulls,  Int64 n_in,
#             Int64**       out_vals,  Bool**      out_nulls)
#         reads n_in input cells, ALLOCATES the output arrays (length = the
#         return value, which may differ from n_in — SET reduces, EMITS expands),
#         writes their addresses into *out_vals / *out_nulls, and returns the
#         output row count (>=0), or a negative value on error.
#   Int64 __exa_udf_free(Int64* vals, Bool* nulls)
#         frees what an entry allocated. Called by the host after it copies out.
#
# The `.so` links the Mojo runtime, so it MUST be built with the same Mojo
# toolchain version as this container; the abi_version check catches a stale ABI,
# but not a mismatched compiler — keep them in lockstep.

from sys.ffi import DLHandle
from memory import UnsafePointer

alias EXA_UDF_ABI_VERSION: Int64 = 1

alias _EntryFn = fn (UnsafePointer[Int64], UnsafePointer[Bool], Int64,
                     UnsafePointer[UnsafePointer[Int64]],
                     UnsafePointer[UnsafePointer[Bool]]) -> Int64
alias _FreeFn = fn (UnsafePointer[Int64], UnsafePointer[Bool]) -> Int64
alias _VersionFn = fn () -> Int64


@fieldwise_init
struct LoadedUdf(Copyable, Movable):
    """A dlopen'd UDF `.so` plus its resolved, ABI-checked entry/free symbols.

    The DLHandle is kept for the process lifetime (never dlclose'd) so the
    entry/free code stays mapped for every group the run loop dispatches."""

    var lib: DLHandle
    var entry: _EntryFn
    var free_fn: _FreeFn

    fn run(self, values: List[Int64], nulls: List[Bool]) raises -> (List[Int64], List[Bool]):
        var n = len(values)
        var cap = n if n > 0 else 1        # alloc(0) is avoided
        var iv = UnsafePointer[Int64].alloc(cap)
        var inu = UnsafePointer[Bool].alloc(cap)
        for i in range(n):
            iv[i] = values[i]
            inu[i] = nulls[i]
        var ovp = UnsafePointer[UnsafePointer[Int64]].alloc(1)
        var onp = UnsafePointer[UnsafePointer[Bool]].alloc(1)

        var n_out = self.entry(iv, inu, Int64(n), ovp, onp)

        var out_vals = List[Int64]()
        var out_nulls = List[Bool]()
        if n_out < 0:
            iv.free(); inu.free(); ovp.free(); onp.free()
            raise Error("udf .so entry returned error code " + String(n_out))
        var ov = ovp[0]
        var onull = onp[0]
        for i in range(Int(n_out)):
            out_vals.append(ov[i])
            out_nulls.append(onull[i])
        _ = self.free_fn(ov, onull)         # the .so owns/free's its output
        iv.free(); inu.free(); ovp.free(); onp.free()
        return (out_vals^, out_nulls^)


fn load_udf(path: String, name: String) raises -> LoadedUdf:
    """Open the `.so`, validate its ABI version, and resolve the entry/free
    symbols for `name` (the SQL script name, verbatim — UPPER_SNAKE_CASE)."""
    var lib = DLHandle(path)                # raises if the .so cannot be opened
    var ver = lib.get_function[_VersionFn]("__exa_udf_abi_version")()
    if ver != EXA_UDF_ABI_VERSION:
        raise Error("udf .so '" + path + "' ABI version " + String(ver)
                    + " != host " + String(EXA_UDF_ABI_VERSION)
                    + " — rebuild the .so with the matching template/toolchain")
    var entry = lib.get_function[_EntryFn]("__exa_udf_entry_" + name)
    var free_fn = lib.get_function[_FreeFn]("__exa_udf_free")
    return LoadedUdf(lib, entry, free_fn)
