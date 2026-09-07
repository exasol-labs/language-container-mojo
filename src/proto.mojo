# proto.mojo — minimal protobuf wire primitives (proto2 subset).
#
# Wire logic authoritative: field tag = (field_number << 3) | wire_type, then the
# value. Wire types: 0 varint, 1 64-bit LE, 2 len-delimited, 5 32-bit LE.
# int32/int64 are PLAIN varints (sign-extended), not zig-zag.

alias WIRE_VARINT = 0
alias WIRE_64BIT = 1
alias WIRE_LEN = 2
alias WIRE_32BIT = 5

# ---- signed<->unsigned 64-bit BIT reinterpretation (no `bitcast` builtin) -----
# Two's-complement pattern of a signed value, computed with only non-negative
# conversions and UInt64 bit ops so it is well-defined on every Mojo build.

fn to_u64_bits(v: Int64) -> UInt64:
    var low = UInt64(v & Int64(0x7FFFFFFFFFFFFFFF))   # low 63 bits (bit63 clear)
    if v < 0:
        return low | UInt64(0x8000000000000000)       # set the sign bit
    return low

fn to_i64_bits(u: UInt64) -> Int64:
    var low = Int64(u & UInt64(0x7FFFFFFFFFFFFFFF))    # low 63 bits fit Int64
    if (u & UInt64(0x8000000000000000)) != 0:
        return low - Int64(0x4000000000000000) - Int64(0x4000000000000000)  # -2^63
    return low

# ---- writing --------------------------------------------------------------

fn write_varint(mut buf: List[UInt8], value: UInt64):
    var v = value
    while v >= 0x80:
        buf.append(UInt8((v & 0x7F) | 0x80))
        v >>= 7
    buf.append(UInt8(v))

fn write_tag(mut buf: List[UInt8], field: Int, wire: Int):
    write_varint(buf, UInt64((field << 3) | wire))

fn write_uint64(mut buf: List[UInt8], field: Int, value: UInt64):
    write_tag(buf, field, WIRE_VARINT)
    write_varint(buf, value)

fn write_int64(mut buf: List[UInt8], field: Int, value: Int64):
    write_tag(buf, field, WIRE_VARINT)
    write_varint(buf, to_u64_bits(value))

fn write_bool(mut buf: List[UInt8], field: Int, value: Bool):
    write_tag(buf, field, WIRE_VARINT)
    write_varint(buf, 1 if value else 0)

fn write_bytes(mut buf: List[UInt8], field: Int, data: List[UInt8]):
    write_tag(buf, field, WIRE_LEN)
    write_varint(buf, UInt64(len(data)))
    for i in range(len(data)):
        buf.append(data[i])

fn write_string(mut buf: List[UInt8], field: Int, s: String):
    write_tag(buf, field, WIRE_LEN)
    var raw = s.as_bytes()          # UTF-8 bytes
    write_varint(buf, UInt64(len(raw)))
    for i in range(len(raw)):
        buf.append(raw[i])

# A length-delimited field whose body was already built (sub-message or packed).
fn write_len_field(mut buf: List[UInt8], field: Int, body: List[UInt8]):
    write_bytes(buf, field, body)

# ---- packed repeated bodies (caller wraps with write_len_field) ------------

fn packed_varints_i64(values: List[Int64]) -> List[UInt8]:
    var body = List[UInt8]()
    for i in range(len(values)):
        write_varint(body, to_u64_bits(values[i]))
    return body^

fn packed_bools(values: List[Bool]) -> List[UInt8]:
    var body = List[UInt8]()
    for i in range(len(values)):
        body.append(UInt8(1) if values[i] else UInt8(0))
    return body^

# NOTE: DOUBLE columns (data_double, wire type 1) would need f64<->u64 bit
# reinterpretation; not needed for the BIGINT `double` UDF. Add when supporting
# DOUBLE input/output.

# ---- reading --------------------------------------------------------------

struct Reader:
    var buf: List[UInt8]
    var pos: Int
    var end: Int

    fn __init__(out self, var buf: List[UInt8], start: Int, end: Int):
        self.buf = buf^
        self.pos = start
        self.end = end

    fn at_end(self) -> Bool:
        return self.pos >= self.end

    fn read_varint(mut self) raises -> UInt64:
        var result: UInt64 = 0
        var shift: Int = 0
        while True:
            if self.pos >= self.end:
                raise Error("protobuf: varint truncated")
            if shift >= 64:                       # a 64-bit varint is <= 10 bytes
                raise Error("protobuf: varint too long")
            var b = self.buf[self.pos]
            self.pos += 1
            result |= UInt64(b & 0x7F) << shift
            if (b & 0x80) == 0:
                break
            shift += 7
        return result

    fn read_tag(mut self) raises -> (Int, Int):
        var t = self.read_varint()
        return (Int(t >> 3), Int(t & 0x7))

    fn read_len(mut self) raises -> (Int, Int):
        # Validate the length against the bytes remaining BEFORE advancing, so a
        # huge/hostile length can't overflow `pos` past the end check (untrusted
        # input). `end - pos` is a non-negative Int (pos <= end invariant).
        var n = self.read_varint()
        if n > UInt64(self.end - self.pos):
            raise Error("protobuf: length-delimited field exceeds message")
        var s = self.pos
        self.pos += Int(n)
        return (s, self.pos)

    fn read_string(mut self) raises -> String:
        var span = self.read_len()
        var s = String()
        for i in range(span[0], span[1]):
            s += chr(Int(self.buf[i]))   # ASCII-safe (identifiers, aliases)
        return s^

    fn skip(mut self, wire: Int) raises:
        if wire == WIRE_VARINT:
            _ = self.read_varint()
        elif wire == WIRE_64BIT:
            self.pos += 8
        elif wire == WIRE_LEN:
            _ = self.read_len()
        elif wire == WIRE_32BIT:
            self.pos += 4
        else:
            raise Error("protobuf: unknown wire type " + String(wire))

    fn read_packed_varints(mut self, s: Int, e: Int) raises -> List[UInt64]:
        var out = List[UInt64]()
        var save_pos = self.pos
        var save_end = self.end
        self.pos = s
        self.end = e
        while self.pos < e:
            out.append(self.read_varint())
        self.pos = save_pos
        self.end = save_end
        return out^
