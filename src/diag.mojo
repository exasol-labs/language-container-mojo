# diag.mojo — diagnostic entry point. Drop-in replacement for main.mojo that does
# the handshake + one MT_RUN/MT_NEXT cycle, then deliberately sends MT_CLOSE with
# a report of exactly what Exasol sent. Exasol surfaces that as the query error,
# so `SELECT ...double(21)` fails with a line like:
#
#   MOJO-DIAG script=DOUBLE in_iter=1 single=0 in_types=[..] out_types=[..]
#             | RUN->6 rows=1 nulls=1 i64=1 i32=0 str=0 first_i64=21
#
# in_types/out_types are column_type enums: 1=DOUBLE 2=INT32 3=INT64 4=NUMERIC
# 5=TIMESTAMP 6=DATE 7=STRING 8=BOOLEAN. That tells us which block Exasol uses for
# the BIGINT column (i64 vs str) — the answer to the empty-result mystery.
#
# Build with:  docker build --build-arg ENTRY=diag.mojo ...

from sys import argv
from sys.ffi import external_call
from zmq import ZmqReq
from wire import (
    ColumnDef, decode_response,
    enc_client, enc_bare, enc_ping_reply, enc_close,
    MT_INFO, MT_META, MT_RUN, MT_NEXT, MT_DONE, MT_CLEANUP, MT_PING_PONG,
)

fn die(code: Int):
    external_call["exit", NoneType](Int32(code))

fn types_str(cols: List[ColumnDef]) -> String:
    var s = String("[")
    for i in range(len(cols)):
        if i > 0: s += ","
        s += String(cols[i].col_type)
    s += "]"
    return s^

fn main() raises:
    var args = argv()
    if len(args) < 3:
        print("F-UDF-CL-MOJO-0003: wrong argument count")   # packaging self-test
        die(3)
    var endpoint = String(args[1])
    var sock = ZmqReq(endpoint)
    var conn_id: UInt64 = 0
    sock.send(enc_client(conn_id, endpoint))

    var report = String("MOJO-DIAG ")
    var script_name = String("")
    var in_cols = List[ColumnDef]()
    var out_cols = List[ColumnDef]()
    var in_iter = 0
    var single = False
    var have_meta = False
    while not have_meta:
        var resp = decode_response(sock.recv())
        conn_id = resp.conn_id
        if resp.mt == MT_PING_PONG:
            sock.send(enc_ping_reply(conn_id, resp.ping_meta))
        elif resp.mt == MT_INFO:
            script_name = resp.script_name
            sock.send(enc_bare(MT_META, conn_id))
        elif resp.mt == MT_META:
            in_cols = resp.input_cols.copy()
            out_cols = resp.output_cols.copy()
            in_iter = resp.input_iter
            single = resp.single_call
            have_meta = True
        else:
            report += "unexpected_handshake_mt=" + String(resp.mt)
            sock.send(enc_close(conn_id, report)); _ = sock.recv(); die(1)

    report += "script=" + script_name
    report += " in_iter=" + String(in_iter)
    report += " single=" + String(1 if single else 0)
    report += " in_types=" + types_str(in_cols)
    report += " out_types=" + types_str(out_cols)

    # one MT_RUN / MT_NEXT cycle to observe how the input batch is encoded
    sock.send(enc_bare(MT_RUN, conn_id))
    var opened = decode_response(sock.recv())
    conn_id = opened.conn_id
    if opened.mt == MT_CLEANUP:
        report += " | RUN->CLEANUP(no group)"
    elif opened.mt == MT_RUN:
        sock.send(enc_bare(MT_NEXT, conn_id))
        var batch = decode_response(sock.recv())
        conn_id = batch.conn_id
        report += " | RUN->" + String(batch.mt)
        if batch.has_table:
            report += " rows=" + String(batch.table.rows)
            report += " nulls=" + String(len(batch.table.data_nulls))
            report += " i64=" + String(len(batch.table.data_int64))
            report += " i32=" + String(len(batch.table.data_int32))
            report += " str=" + String(len(batch.table.data_string))
            if len(batch.table.data_int64) > 0:
                report += " first_i64=" + String(batch.table.data_int64[0])
            if len(batch.table.data_string) > 0:
                report += " first_str=" + batch.table.data_string[0]
        else:
            report += " no_table"
    else:
        report += " | RUN->" + String(opened.mt)

    # Exfiltrate the report as the query error.
    sock.send(enc_close(conn_id, report))
    _ = sock.recv()
    die(1)
