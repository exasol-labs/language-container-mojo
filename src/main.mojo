# main.mojo — the native Mojo language-container host.
#
# Launched by Exasol as:  mojoudfclient <endpoint> lang=mojo
# Speaks the ZMQ REQ/REP + protobuf protocol directly (no Rust, no dlopen).
#
# UNVERIFIED Mojo. The control flow mirrors dispatch.rs / loop_.rs exactly
# (see ../DESIGN.md, "Run loop"). Build/deploy: ../build.md.

from sys import argv
from sys.ffi import external_call
from zmq import ZmqReq
from wire import (
    ColumnDef, decode_response, column_i64,
    enc_client, enc_bare, enc_ping_reply, enc_close, enc_emit_i64,
    MT_INFO, MT_META, MT_RUN, MT_NEXT, MT_DONE, MT_EMIT, MT_CLEANUP,
    MT_FINISHED, MT_PING_PONG, PB_INT64,
)
from udf import run_udf, is_known

# Terminate the process with an explicit code (a returning main() exits 0, but a
# UDF client must signal errors non-zero). Uses libc exit — always available.
fn die(code: Int):
    external_call["exit", NoneType](Int32(code))

fn _setenv(name: String, value: String):
    var n = name + "\0"
    var v = value + "\0"
    _ = external_call["setenv", Int32](n.unsafe_ptr(), v.unsafe_ptr(), Int32(1))

# Point Mojo's Python interop at the CPython bundled in the SLC rootfs, so
# `Python.import_module(...)` works inside the sandbox (no python3 on PATH there).
#   MOJO_PYTHON_LIBRARY : fixed absolute path to libpython staged by the Dockerfile
#                         (a bare soname does not resolve for Mojo's Python loader)
#   PYTHONHOME          : prefix holding lib/python3.13 (Debian layout → /usr)
#   PYTHONPATH          : extra pip packages + the bundled pyudf/ package
#   PYTHONDONTWRITEBYTECODE : the rootfs is read-only; don't try to write .pyc
fn setup_python_env():
    _setenv("MOJO_PYTHON_LIBRARY", "/exaudf/libpython.so")
    _setenv("PYTHONHOME", "/usr")
    _setenv("PYTHONPATH", "/opt/pypkgs")
    _setenv("PYTHONDONTWRITEBYTECODE", "1")

fn fail(mut sock: ZmqReq, conn_id: UInt64, msg: String):
    # Best-effort MT_CLOSE with an F-UDF-CL-MOJO-#### message, then report + exit.
    try:
        sock.send(enc_close(conn_id, "F-UDF-CL-MOJO-0001: " + msg))
        _ = sock.recv()
    except:
        pass
    print("F-UDF-CL-MOJO-0001: " + msg)
    die(1)

fn main() raises:
    var args = argv()
    if len(args) < 3:
        print("F-UDF-CL-MOJO-0003: wrong argument count")
        print("usage: mojoudfclient <endpoint> lang=mojo")
        die(3)
    var endpoint = String(args[1])
    var lang = String(args[2])
    if lang != "lang=mojo":
        print("F-UDF-CL-MOJO-0002: unsupported language argument '" + lang + "'")
        die(2)

    setup_python_env()   # make the bundled CPython discoverable to Python interop

    var sock = ZmqReq(endpoint)
    var conn_id: UInt64 = 0

    # ---- handshake: MT_CLIENT → MT_INFO → MT_META → MT_META -----------------
    # client_name is documented as the client URL; send the endpoint.
    sock.send(enc_client(conn_id, endpoint))

    var script_name = String("")
    var input_cols = List[ColumnDef]()      # from MT_META; held for the run loop
    var output_cols = List[ColumnDef]()     # determines the emit block
    var have_meta = False
    while not have_meta:
        var resp = decode_response(sock.recv())
        conn_id = resp.conn_id
        if resp.mt == MT_PING_PONG:
            sock.send(enc_ping_reply(conn_id, resp.ping_meta))
        elif resp.mt == MT_INFO:
            script_name = resp.script_name
            sock.send(enc_bare(MT_META, conn_id))     # ask for column metadata
        elif resp.mt == MT_META:
            input_cols = resp.input_cols.copy()       # 1 col (BIGINT) for double
            output_cols = resp.output_cols.copy()     # 1 col (BIGINT) for double
            if not is_known(script_name):
                fail(sock, conn_id, "unknown script '" + script_name + "'")
                return
            have_meta = True
        else:
            fail(sock, conn_id, "unexpected message " + String(resp.mt) + " during handshake")
            return

    # ---- run loop -----------------------------------------------------------
    while True:
        sock.send(enc_bare(MT_RUN, conn_id))
        var opened = decode_response(sock.recv())
        conn_id = opened.conn_id
        if opened.mt == MT_CLEANUP:
            break                                     # session end
        # opened.mt == MT_RUN → a group is open.

        # Collect the whole group's input (column 0), then run the UDF once.
        # A SCALAR UDF returns one row per input row (map); a SET UDF returns one
        # row per group (reduce) — both are just run_udf over the group's column.
        var in_vals = List[Int64]()
        var in_nulls = List[Bool]()
        # Collect the whole group's input (column 0), then run the UDF once and
        # emit its output as one MT_EMIT, packed into the block the output
        # column's declared type uses (INT64 / INT32 / NUMERIC-string). A SCALAR
        # UDF returns one row per input row (map); a SET UDF returns one row per
        # group (reduce). The whole collect+run+emit is guarded so any failure —
        # an unsupported/non-integer-convertible input column, a malformed batch,
        # or a UDF-side error — becomes a clean MT_CLOSE instead of an uncaught
        # crash that would leave the DB waiting for a reply.
        try:
            while True:
                sock.send(enc_bare(MT_NEXT, conn_id))
                var batch = decode_response(sock.recv())
                conn_id = batch.conn_id
                if batch.mt == MT_DONE:
                    break                                 # group boundary
                if batch.mt == MT_CLEANUP:
                    sock.send(enc_bare(MT_FINISHED, conn_id)); _ = sock.recv()
                    return
                if not batch.has_table:
                    continue
                var col = column_i64(batch.table, input_cols, 0)   # column 0
                for i in range(len(col[0])):
                    in_vals.append(col[0][i]); in_nulls.append(col[1][i])

            var res = run_udf(script_name, in_vals, in_nulls)
            if len(res[0]) > 0:
                var out_type = output_cols[0].col_type if len(output_cols) > 0 else PB_INT64
                sock.send(enc_emit_i64(conn_id, out_type, res[0], res[1]))
                _ = sock.recv()                       # MT_EMIT ack
        except e:
            fail(sock, conn_id, "udf '" + script_name + "': " + String(e))
            return
        sock.send(enc_bare(MT_DONE, conn_id))
        var after = decode_response(sock.recv())
        conn_id = after.conn_id
        if after.mt == MT_CLEANUP:
            break

    # ---- teardown -----------------------------------------------------------
    sock.send(enc_bare(MT_FINISHED, conn_id))
    _ = sock.recv()                                   # DB echoes MT_FINISHED
    sock.close()
