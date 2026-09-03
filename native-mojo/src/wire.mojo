# wire.mojo — encode Exasol requests / decode responses (field numbers from
# zmqcontainer.proto, extracted in ../DESIGN.md). UNVERIFIED Mojo; wire logic
# authoritative.

from proto import (
    Reader, WIRE_LEN, WIRE_VARINT, to_i64_bits,
    write_tag, write_varint, write_uint64, write_int64, write_bool,
    write_string, write_len_field, packed_varints_i64, packed_bools,
)

# message_type
alias MT_CLIENT = 1
alias MT_INFO = 2
alias MT_META = 3
alias MT_CLOSE = 4
alias MT_NEXT = 6
alias MT_EMIT = 8
alias MT_RUN = 9
alias MT_DONE = 10
alias MT_CLEANUP = 11
alias MT_FINISHED = 12
alias MT_PING_PONG = 13

# column_type
alias PB_DOUBLE = 1
alias PB_INT32 = 2
alias PB_INT64 = 3
alias PB_NUMERIC = 4
alias PB_TIMESTAMP = 5
alias PB_DATE = 6
alias PB_STRING = 7
alias PB_BOOLEAN = 8

# Which typed block a column's cells live in.
alias BLK_STRING = 0
alias BLK_BOOL = 1
alias BLK_INT32 = 2
alias BLK_INT64 = 3
alias BLK_DOUBLE = 4

fn block_of(col_type: Int) -> Int:
    if col_type == PB_INT64: return BLK_INT64
    if col_type == PB_INT32: return BLK_INT32
    if col_type == PB_DOUBLE: return BLK_DOUBLE
    if col_type == PB_BOOLEAN: return BLK_BOOL
    # PB_NUMERIC, PB_TIMESTAMP, PB_DATE, PB_STRING → string block
    return BLK_STRING

# ---- decoded structures ---------------------------------------------------

@fieldwise_init
struct ColumnDef(Copyable, Movable):
    var name: String
    var col_type: Int

@fieldwise_init
struct TableData(Copyable, Movable):
    var rows: Int
    var data_string: List[String]
    var data_nulls: List[Bool]
    var data_bool: List[Bool]
    var data_int32: List[Int64]
    var data_int64: List[Int64]
    var data_double: List[Float64]

@fieldwise_init
struct Response(Copyable, Movable):
    var mt: Int
    var conn_id: UInt64
    var script_name: String       # from MT_INFO
    var input_cols: List[ColumnDef]
    var output_cols: List[ColumnDef]
    var input_iter: Int           # 1 = EXACTLY_ONCE (scalar), 2 = MULTIPLE (set)
    var single_call: Bool
    var has_table: Bool
    var table: TableData
    var ping_meta: String
    var close_msg: String

# ---- decoding responses ---------------------------------------------------

fn decode_column_def(mut r: Reader, s: Int, e: Int) raises -> ColumnDef:
    var name = String("")
    var col_type = 0
    var save_pos = r.pos; var save_end = r.end
    r.pos = s; r.end = e
    while not r.at_end():
        var t = r.read_tag()
        var field = t[0]; var wire = t[1]
        if field == 1 and wire == WIRE_LEN:      # name
            name = r.read_string()
        elif field == 2 and wire == WIRE_VARINT: # type (column_type enum)
            col_type = Int(r.read_varint())
        else:
            r.skip(wire)
    r.pos = save_pos; r.end = save_end
    return ColumnDef(name, col_type)

fn decode_table(mut r: Reader, s: Int, e: Int) raises -> TableData:
    var td = TableData(0, List[String](), List[Bool](), List[Bool](),
                       List[Int64](), List[Int64](), List[Float64]())
    var save_pos = r.pos; var save_end = r.end
    r.pos = s; r.end = e
    while not r.at_end():
        var t = r.read_tag()
        var field = t[0]; var wire = t[1]
        if field == 1 and wire == WIRE_VARINT:          # rows
            td.rows = Int(r.read_varint())
        elif field == 2 and wire == WIRE_LEN:           # data_string (repeated string)
            td.data_string.append(r.read_string())
        elif field == 3 and wire == WIRE_LEN:           # data_nulls (packed bool)
            var span = r.read_len()
            var arr = r.read_packed_varints(span[0], span[1])
            for i in range(len(arr)):
                td.data_nulls.append(arr[i] != 0)
        elif field == 4 and wire == WIRE_LEN:           # data_bool (packed bool)
            var span = r.read_len()
            var arr = r.read_packed_varints(span[0], span[1])
            for i in range(len(arr)):
                td.data_bool.append(arr[i] != 0)
        elif field == 5 and wire == WIRE_LEN:           # data_int32 (packed)
            var span = r.read_len()
            var arr = r.read_packed_varints(span[0], span[1])
            for i in range(len(arr)):
                td.data_int32.append(to_i64_bits(arr[i]))
        elif field == 6 and wire == WIRE_LEN:           # data_int64 (packed)
            var span = r.read_len()
            var arr = r.read_packed_varints(span[0], span[1])
            for i in range(len(arr)):
                td.data_int64.append(to_i64_bits(arr[i]))
        # field 7 data_double, field 8 rows_in_group, field 9 row_number:
        # skipped here — not needed for the BIGINT `double` path (extend as needed).
        else:
            r.skip(wire)
    r.pos = save_pos; r.end = save_end
    return td^

fn decode_response(var bytes: List[UInt8]) raises -> Response:
    var resp = Response(0, 0, String(""), List[ColumnDef](), List[ColumnDef](),
                        1, False, False,
                        TableData(0, List[String](), List[Bool](), List[Bool](),
                                  List[Int64](), List[Int64](), List[Float64]()),
                        String(""), String(""))
    var n = len(bytes)
    var r = Reader(bytes^, 0, n)
    while not r.at_end():
        var t = r.read_tag()
        var field = t[0]; var wire = t[1]
        if field == 1 and wire == WIRE_VARINT:          # type
            resp.mt = Int(r.read_varint())
        elif field == 2 and wire == WIRE_VARINT:        # connection_id
            resp.conn_id = r.read_varint()
        elif field == 4 and wire == WIRE_LEN:           # info (MT_INFO)
            var span = r.read_len()
            resp.script_name = extract_info_script_name(r, span[0], span[1])
        elif field == 5 and wire == WIRE_LEN:           # meta (MT_META)
            var span = r.read_len()
            decode_meta_into(r, span[0], span[1], resp)
        elif field == 8 and wire == WIRE_LEN:           # next { table }
            var span = r.read_len()
            resp.has_table = True
            resp.table = decode_next_table(r, span[0], span[1])
        elif field == 9 and wire == WIRE_LEN:           # ping { meta_info }
            var span = r.read_len()
            resp.ping_meta = extract_ping_meta(r, span[0], span[1])
        elif field == 6 and wire == WIRE_LEN:           # close { exception_message }
            var span = r.read_len()
            resp.close_msg = extract_close_msg(r, span[0], span[1])
        else:
            r.skip(wire)
    return resp^

fn extract_info_script_name(mut r: Reader, s: Int, e: Int) raises -> String:
    # exascript_info: field 3 = script_name.
    var name = String("")
    var sp = r.pos; var se = r.end
    r.pos = s; r.end = e
    while not r.at_end():
        var t = r.read_tag()
        if t[0] == 3 and t[1] == WIRE_LEN: name = r.read_string()
        else: r.skip(t[1])
    r.pos = sp; r.end = se
    return name

fn decode_meta_into(mut r: Reader, s: Int, e: Int, mut resp: Response) raises:
    # exascript_metadata: 1 input_iter, 2 output_iter, 3 input_columns,
    # 4 output_columns, 5 single_call_mode.
    var sp = r.pos; var se = r.end
    r.pos = s; r.end = e
    while not r.at_end():
        var t = r.read_tag()
        var f = t[0]; var w = t[1]
        if f == 1 and w == WIRE_VARINT: resp.input_iter = Int(r.read_varint())
        elif f == 2 and w == WIRE_VARINT: _ = r.read_varint()   # output_iter
        elif f == 3 and w == WIRE_LEN:
            var span = r.read_len(); resp.input_cols.append(decode_column_def(r, span[0], span[1]))
        elif f == 4 and w == WIRE_LEN:
            var span = r.read_len(); resp.output_cols.append(decode_column_def(r, span[0], span[1]))
        elif f == 5 and w == WIRE_VARINT: resp.single_call = r.read_varint() != 0
        else: r.skip(w)
    r.pos = sp; r.end = se

fn decode_next_table(mut r: Reader, s: Int, e: Int) raises -> TableData:
    # exascript_next_data_rep: field 2 = table.
    var td = TableData(0, List[String](), List[Bool](), List[Bool](),
                       List[Int64](), List[Int64](), List[Float64]())
    var sp = r.pos; var se = r.end
    r.pos = s; r.end = e
    while not r.at_end():
        var t = r.read_tag()
        if t[0] == 2 and t[1] == WIRE_LEN:
            var span = r.read_len(); td = decode_table(r, span[0], span[1])
        else: r.skip(t[1])
    r.pos = sp; r.end = se
    return td^

fn extract_ping_meta(mut r: Reader, s: Int, e: Int) raises -> String:
    var v = String("")
    var sp = r.pos; var se = r.end
    r.pos = s; r.end = e
    while not r.at_end():
        var t = r.read_tag()
        if t[0] == 1 and t[1] == WIRE_LEN: v = r.read_string()
        else: r.skip(t[1])
    r.pos = sp; r.end = se
    return v

fn extract_close_msg(mut r: Reader, s: Int, e: Int) raises -> String:
    var v = String("")
    var sp = r.pos; var se = r.end
    r.pos = s; r.end = e
    while not r.at_end():
        var t = r.read_tag()
        if t[0] == 1 and t[1] == WIRE_LEN: v = r.read_string()
        else: r.skip(t[1])
    r.pos = sp; r.end = se
    return v

# ---- reading a BIGINT column out of a decoded table -----------------------
#
# Faithful to rowset.rs: walk rows, then columns, advancing a per-type cursor
# only on non-null cells; collect the requested column. Requires the requested
# column to be an INT64 column.
fn column_i64(td: TableData, cols: List[ColumnDef], col: Int) raises -> (List[Int64], List[Bool]):
    var values = List[Int64]()
    var nulls = List[Bool]()
    var n_cols = len(cols)
    var cur = List[Int]()               # per-block cursors, index by BLK_*
    for _ in range(5): cur.append(0)
    for r in range(td.rows):
        for c in range(n_cols):
            var is_null = td.data_nulls[r * n_cols + c] if (r * n_cols + c) < len(td.data_nulls) else False
            var blk = block_of(cols[c].col_type)
            if c == col:
                if is_null:
                    values.append(0); nulls.append(True)
                else:
                    if blk != BLK_INT64:
                        raise Error("column_i64: column " + String(col) + " is not INT64")
                    values.append(td.data_int64[cur[BLK_INT64]]); nulls.append(False)
            if not is_null:
                cur[blk] += 1           # advance the consumed block's cursor
    return (values^, nulls^)

# ---- encoding requests ----------------------------------------------------

fn _envelope(mt: Int, conn_id: UInt64) -> List[UInt8]:
    var buf = List[UInt8]()
    write_uint64(buf, 1, UInt64(mt))     # field 1: type
    write_uint64(buf, 2, conn_id)        # field 2: connection_id
    return buf^

fn enc_bare(mt: Int, conn_id: UInt64) -> List[UInt8]:
    return _envelope(mt, conn_id)

fn enc_client(conn_id: UInt64, client_name: String) -> List[UInt8]:
    var buf = _envelope(MT_CLIENT, conn_id)
    var client = List[UInt8]()           # exascript_client: field 1 client_name
    write_string(client, 1, client_name)
    write_len_field(buf, 3, client)      # request field 3: client
    return buf^

fn enc_ping_reply(conn_id: UInt64, meta_info: String) -> List[UInt8]:
    var buf = _envelope(MT_PING_PONG, conn_id)
    var ping = List[UInt8]()             # exascript_ping: field 1 meta_info
    write_string(ping, 1, meta_info)
    write_len_field(buf, 8, ping)        # request field 8: ping
    return buf^

fn enc_close(conn_id: UInt64, message: String) -> List[UInt8]:
    var buf = _envelope(MT_CLOSE, conn_id)
    var close = List[UInt8]()            # exascript_close: field 1 exception_message
    write_string(close, 1, message)
    write_len_field(buf, 5, close)       # request field 5: close
    return buf^

# Emit one BIGINT output column (values + null flags) as MT_EMIT.
fn enc_emit_i64_single(conn_id: UInt64, values: List[Int64], nulls: List[Bool]) -> List[UInt8]:
    var buf = _envelope(MT_EMIT, conn_id)
    # exascript_table_data body
    var td = List[UInt8]()
    write_uint64(td, 1, UInt64(len(values)))     # field 1: rows (required)
    write_uint64(td, 8, 0)                        # field 8: rows_in_group (required)
    # field 3: data_nulls (packed bool)
    write_len_field(td, 3, packed_bools(nulls))
    # field 6: data_int64 (packed) — only the non-null values, in row order
    var nonnull = List[Int64]()
    for i in range(len(values)):
        if not nulls[i]: nonnull.append(values[i])
    write_len_field(td, 6, packed_varints_i64(nonnull))
    # wrap: exascript_emit_data_req field 2 = table
    var emit = List[UInt8]()
    write_len_field(emit, 2, td)
    write_len_field(buf, 7, emit)                 # request field 7: emit
    return buf^
