#!/usr/bin/env python3
"""Fake Exasol DB side for testing the native Mojo container's `double`.

Binds a ZMQ REP socket and plays the exact MT_* sequence dispatch.rs expects,
feeding one batch of BIGINTs and asserting the container's MT_EMIT holds the
doubled values. Hand-rolled protobuf (no protobuf lib); only needs pyzmq.

  pip install pyzmq
  python3 fake_exasol.py --bind tcp://127.0.0.1:6583 --expect-double
  ./mojoudfclient tcp://127.0.0.1:6583 lang=mojo
"""
import argparse
import struct
import sys

import zmq

# message_type
MT_CLIENT, MT_INFO, MT_META, MT_CLOSE = 1, 2, 3, 4
MT_NEXT, MT_EMIT, MT_RUN, MT_DONE, MT_CLEANUP, MT_FINISHED = 6, 8, 9, 10, 11, 12
PB_INT64 = 3
PB_NUMERIC = 4
CONN = 1  # connection_id the DB assigns

# ---- protobuf writing -----------------------------------------------------

def varint(v):
    v &= (1 << 64) - 1  # 64-bit two's complement (sign-extended int64/int32)
    out = bytearray()
    while True:
        b = v & 0x7F
        v >>= 7
        if v:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)

def tag(field, wire):
    return varint((field << 3) | wire)

def f_varint(field, v):
    return tag(field, 0) + varint(v)

def f_len(field, body):
    return tag(field, 2) + varint(len(body)) + body

def f_string(field, s):
    return f_len(field, s.encode("utf-8"))

def packed_i64(values):
    return b"".join(varint(v) for v in values)

def packed_bool(values):
    return bytes(1 if v else 0 for v in values)

def envelope(mt, *parts):
    return f_varint(1, mt) + f_varint(2, CONN) + b"".join(parts)

# ---- protobuf reading (field walker) --------------------------------------

def read_varint(buf, i):
    result = 0
    shift = 0
    while True:
        b = buf[i]
        i += 1
        result |= (b & 0x7F) << shift
        if not (b & 0x80):
            return result, i
        shift += 7

def to_i64(u):
    u &= (1 << 64) - 1
    return u - (1 << 64) if u & (1 << 63) else u

def walk(buf, start, end):
    """Yield (field, wire, value) where value is int (varint) or (s,e) slice."""
    i = start
    while i < end:
        key, i = read_varint(buf, i)
        field, wire = key >> 3, key & 7
        if wire == 0:
            v, i = read_varint(buf, i)
            yield field, wire, v
        elif wire == 2:
            n, i = read_varint(buf, i)
            yield field, wire, (i, i + n)
            i += n
        elif wire == 1:
            yield field, wire, (i, i + 8)
            i += 8
        elif wire == 5:
            yield field, wire, (i, i + 4)
            i += 4
        else:
            raise ValueError("bad wire type %d" % wire)

def msg_type(buf):
    for field, wire, val in walk(buf, 0, len(buf)):
        if field == 1 and wire == 0:
            return val
    return -1

def emit_int64s(buf):
    """Extract data_int64 from an MT_EMIT: emit(7) -> table(2) -> data_int64(6)."""
    def sub(field_no, start, end):
        for f, w, v in walk(buf, start, end):
            if f == field_no and w == 2:
                return v
        return None
    emit = sub(7, 0, len(buf))
    if emit is None:
        raise AssertionError("MT_EMIT has no emit(7) field")
    table = sub(2, *emit)
    if table is None:
        raise AssertionError("emit has no table(2) field")
    for f, w, v in walk(buf, table[0], table[1]):
        if f == 6 and w == 2:  # data_int64 (packed)
            s, e = v
            out, i = [], s
            while i < e:
                u, i = read_varint(buf, i)
                out.append(to_i64(u))
            return out
    return []

def emit_strings(buf):
    """Extract data_string (repeated field 2) from an MT_EMIT table, as ints."""
    def sub(field_no, start, end):
        for f, w, v in walk(buf, start, end):
            if f == field_no and w == 2:
                return v
        return None
    emit = sub(7, 0, len(buf))
    table = sub(2, *emit) if emit else None
    if table is None:
        raise AssertionError("emit has no table")
    out = []
    for f, w, v in walk(buf, table[0], table[1]):
        if f == 2 and w == 2:  # data_string element
            s, e = v
            out.append(int(bytes(buf[s:e]).decode()))
    return out

def close_message(buf):
    """Extract exception_message from an MT_CLOSE: close(5) -> exception_message(1)."""
    def sub(field_no, start, end):
        for f, w, v in walk(buf, start, end):
            if f == field_no and w == 2:
                return v
        return None
    close = sub(5, 0, len(buf))
    if close is None:
        return "(no close field)"
    msg = sub(1, *close)
    if msg is None:
        return "(empty)"
    s, e = msg
    return bytes(buf[s:e]).decode("utf-8", "replace")

# ---- messages the DB sends ------------------------------------------------

def m_info(script="DOUBLE"):
    info = f_string(3, script)  # exascript_info.script_name; other fields omitted
    return envelope(MT_INFO, f_len(4, info))

def m_meta(col_type=PB_INT64):
    col = lambda name: f_string(1, name) + f_varint(2, col_type)
    meta = (f_varint(1, 1)          # input_iter_type = PB_EXACTLY_ONCE
            + f_varint(2, 1)         # output_iter_type = PB_EXACTLY_ONCE
            + f_len(3, col("val"))   # input_columns[0]
            + f_len(4, col("out"))   # output_columns[0]
            + f_varint(5, 0))        # single_call_mode = false
    return envelope(MT_META, f_len(5, meta))

def m_next(values):
    nulls = packed_bool([False] * len(values))
    table = (f_varint(1, len(values))       # rows
             + f_varint(8, len(values))     # rows_in_group
             + f_len(3, nulls)              # data_nulls
             + f_len(6, packed_i64(values)))# data_int64
    return envelope(MT_NEXT, f_len(8, f_len(2, table)))

def m_next_str(values):
    """Send the input in the data_string (NUMERIC/DECIMAL) block, as decimal text."""
    nulls = packed_bool([False] * len(values))
    body = f_varint(1, len(values)) + f_varint(8, len(values)) + f_len(3, nulls)
    for v in values:                        # data_string: one repeated entry per row
        body += f_string(2, str(v))
    return envelope(MT_NEXT, f_len(8, f_len(2, body)))

def bare(mt):
    return envelope(mt)

# ---- input chunking (multi-batch tests) -----------------------------------

def chunk(values, splits):
    """Split values into `splits` non-empty, contiguous chunks (fewer if short).

    Exercises the container's run loop, which requests MT_NEXT repeatedly and
    accumulates every batch's rows into the group until MT_DONE. splits=1 sends
    the whole group in one batch (the original behaviour)."""
    if splits <= 1 or len(values) <= 1:
        return [list(values)]
    splits = min(splits, len(values))
    size = (len(values) + splits - 1) // splits  # ceil, so no trailing empties
    out = [values[i:i + size] for i in range(0, len(values), size)]
    return [c for c in out if c]

# ---- the scripted DB session ----------------------------------------------

MTN = {1: "CLIENT", 2: "INFO", 3: "META", 6: "NEXT", 8: "EMIT", 9: "RUN",
       10: "DONE", 11: "CLEANUP", 12: "FINISHED", 13: "PING"}

def run(bind, values, numeric=False, sum_mode=False, py_mode=False, splits=1):
    ctx = zmq.Context()
    sock = ctx.socket(zmq.REP)
    sock.setsockopt(zmq.RCVTIMEO, 10000)   # 10s: fail loudly instead of hanging
    sock.bind(bind)
    if py_mode:                                    # PY_SCALE: Python interop, v*10
        script = "PY_SCALE"; expected = [v * 10 for v in values]
    elif sum_mode:
        script = "SUM_POSITIVE"; expected = [sum(v for v in values if v > 0)]
    else:
        script = "DOUBLE_MOJO"; expected = [v * 2 for v in values]

    def step(expect_mt):
        try:
            got = sock.recv()
        except zmq.Again:
            print("TIMEOUT waiting for %s(%d) — the container sent nothing"
                  % (MTN.get(expect_mt, "?"), expect_mt), file=sys.stderr)
            sys.exit(2)
        mt = msg_type(got)
        print("  <- %s(%d)" % (MTN.get(mt, "?"), mt), flush=True)
        if mt != expect_mt:
            if mt == MT_CLOSE:                       # surface the UDF error text
                print("  !! container CLOSE: " + close_message(got), file=sys.stderr)
            print("  !! expected %s(%d) but the container sent %s(%d)"
                  % (MTN.get(expect_mt, "?"), expect_mt, MTN.get(mt, "?"), mt),
                  file=sys.stderr)
            sys.exit(3)
        return got

    batches = chunk(values, splits)

    step(MT_CLIENT);   sock.send(m_info(script))
    step(MT_META);     sock.send(m_meta(PB_NUMERIC if numeric else PB_INT64))
    step(MT_RUN);      sock.send(bare(MT_RUN))     # open group
    for b in batches:                              # one MT_NEXT per input batch
        step(MT_NEXT); sock.send(m_next_str(b) if numeric else m_next(b))
    step(MT_NEXT);     sock.send(bare(MT_DONE))    # input exhausted
    if len(batches) > 1:
        print("  (input sent in %d batches: %s)" % (len(batches), batches), flush=True)
    emit = step(MT_EMIT); sock.send(bare(MT_EMIT)) # ack
    got = emit_strings(emit) if numeric else emit_int64s(emit)
    step(MT_DONE);     sock.send(bare(MT_DONE))
    step(MT_RUN);      sock.send(bare(MT_CLEANUP)) # no more groups
    step(MT_FINISHED); sock.send(bare(MT_FINISHED))

    if got == expected:
        print("OK: %s verified: %s -> %s" % (script, values, got))
        return 0
    print("FAIL(%s): expected %s, container emitted %s" % (script, expected, got),
          file=sys.stderr)
    return 1

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bind", default="tcp://127.0.0.1:6583")
    ap.add_argument("--expect-double", action="store_true")
    ap.add_argument("--numeric", action="store_true",
                    help="send input in the NUMERIC/DECIMAL string block")
    ap.add_argument("--sum", action="store_true",
                    help="drive SUM_POSITIVE (SET) instead of DOUBLE (scalar)")
    ap.add_argument("--pyscale", action="store_true",
                    help="drive PY_SCALE (Python-interop scalar, v*10)")
    ap.add_argument("--splits", type=int, default=1,
                    help="send the group's rows across N MT_NEXT batches "
                         "(tests the run loop's batch accumulation)")
    ap.add_argument("--values", default="10,21,-5,0,7")
    args = ap.parse_args()
    values = [int(x) for x in args.values.split(",")]
    sys.exit(run(args.bind, values, numeric=args.numeric, sum_mode=args.sum,
                 py_mode=args.pyscale, splits=args.splits))

if __name__ == "__main__":
    main()
