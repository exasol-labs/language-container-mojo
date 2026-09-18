# test_codec.mojo — unit tests for the pure protobuf/wire codec functions in
# src/proto.mojo and src/wire.mojo. This is the Mojo analogue of the Rust SLC's
# per-module unit tests (crates/exa-*/src/*_tests.rs): it exercises the codec in
# isolation, with no ZMQ and no Exasol, so a codec regression is caught long
# before the protocol self-test (test/fake_exasol.py) would surface it.
#
# It is a self-checking binary rather than a `mojo test` suite so it runs the
# same way everywhere: `mojo build test/mojo/test_codec.mojo -I src` then run it;
# every case reports PASS, and the process exits non-zero if any case fails.
# Wired into CI through the Dockerfile `unittest` stage.

from testing import assert_equal, assert_true, assert_false

from proto import (
    to_u64_bits, to_i64_bits, write_varint, Reader,
    packed_varints_i64, packed_bools,
)
from wire import (
    parse_decimal_i64, block_of,
    PB_DOUBLE, PB_INT32, PB_INT64, PB_NUMERIC, PB_TIMESTAMP, PB_DATE,
    PB_STRING, PB_BOOLEAN,
    BLK_STRING, BLK_BOOL, BLK_INT32, BLK_INT64, BLK_DOUBLE,
)

alias I64_MAX: Int64 = 9223372036854775807
alias I64_MIN: Int64 = Int64(-9223372036854775807) - 1


# ---- helpers ---------------------------------------------------------------

fn _rt_varint(v: UInt64) raises -> UInt64:
    """Encode a varint and read it back through the Reader."""
    var buf = List[UInt8]()
    write_varint(buf, v)
    var n = len(buf)
    var r = Reader(buf^, 0, n)
    return r.read_varint()


# ---- tests -----------------------------------------------------------------

fn test_bit_reinterpret() raises:
    # Round-trip: to_i64_bits ∘ to_u64_bits is the identity on Int64.
    var samples = List[Int64](0, 1, -1, 2, -2, 42, -42, I64_MAX, I64_MIN)
    for i in range(len(samples)):
        assert_equal(to_i64_bits(to_u64_bits(samples[i])), samples[i])
    # Exact two's-complement patterns.
    assert_equal(to_u64_bits(Int64(-1)), UInt64(0xFFFFFFFFFFFFFFFF))
    assert_equal(to_u64_bits(I64_MIN), UInt64(0x8000000000000000))
    assert_equal(to_u64_bits(Int64(0)), UInt64(0))
    assert_equal(to_i64_bits(UInt64(0x8000000000000000)), I64_MIN)


fn test_varint_roundtrip() raises:
    var vals = List[UInt64](0, 1, 127, 128, 300, 16384, 65535,
                            UInt64(0xFFFFFFFF), UInt64(0xFFFFFFFFFFFFFFFF))
    for i in range(len(vals)):
        assert_equal(_rt_varint(vals[i]), vals[i])


fn test_varint_encoding_length() raises:
    # Boundary widths: <128 is one byte, 128..16383 is two.
    var one = List[UInt8]()
    write_varint(one, 127)
    assert_equal(len(one), 1)
    var two = List[UInt8]()
    write_varint(two, 128)
    assert_equal(len(two), 2)
    var big = List[UInt8]()
    write_varint(big, UInt64(0xFFFFFFFFFFFFFFFF))  # max u64 -> 10 bytes
    assert_equal(len(big), 10)


fn test_packed_i64_roundtrip() raises:
    var values = List[Int64](0, 1, -1, 10, 21, -5, 7, I64_MAX, I64_MIN)
    var body = packed_varints_i64(values)
    var n = len(body)
    var r = Reader(body^, 0, n)
    var raw = r.read_packed_varints(0, n)
    assert_equal(len(raw), len(values))
    for i in range(len(values)):
        assert_equal(to_i64_bits(raw[i]), values[i])


fn test_read_len_rejects_overrun() raises:
    # A length-delimited field whose declared length exceeds the bytes remaining
    # must raise, not advance past the end — the untrusted-input guard.
    var buf = List[UInt8]()
    write_varint(buf, 100)        # claims a 100-byte body...
    buf.append(1); buf.append(2)  # ...but only two bytes follow
    var n = len(buf)
    var r = Reader(buf^, 0, n)
    var raised = False
    try:
        _ = r.read_len()
    except:
        raised = True
    assert_true(raised)


fn test_read_len_accepts_exact() raises:
    # The exact-fit boundary must be accepted (off-by-one guard).
    var buf = List[UInt8]()
    write_varint(buf, 2)
    buf.append(9); buf.append(8)
    var n = len(buf)
    var r = Reader(buf^, 0, n)
    var span = r.read_len()
    assert_equal(span[1] - span[0], 2)


fn test_read_varint_truncated() raises:
    var buf = List[UInt8]()
    buf.append(UInt8(0x80))       # continuation bit set, no next byte
    var r = Reader(buf^, 0, 1)
    var raised = False
    try:
        _ = r.read_varint()
    except:
        raised = True
    assert_true(raised)


fn test_read_varint_too_long() raises:
    var buf = List[UInt8]()
    for _ in range(11):           # 11 continuation bytes -> shift passes 64
        buf.append(UInt8(0x80))
    var n = len(buf)
    var r = Reader(buf^, 0, n)
    var raised = False
    try:
        _ = r.read_varint()
    except:
        raised = True
    assert_true(raised)


fn test_parse_decimal() raises:
    assert_equal(parse_decimal_i64("42"), Int64(42))
    assert_equal(parse_decimal_i64("-5"), Int64(-5))
    assert_equal(parse_decimal_i64("+7"), Int64(7))
    assert_equal(parse_decimal_i64("0"), Int64(0))
    assert_equal(parse_decimal_i64("100.00"), Int64(100))  # fraction truncated
    assert_equal(parse_decimal_i64("-3.9"), Int64(-3))     # toward zero
    assert_equal(parse_decimal_i64("123456789"), Int64(123456789))


fn _decimal_raises(s: String) -> Bool:
    try:
        _ = parse_decimal_i64(s)
        return False
    except:
        return True


fn test_parse_decimal_rejects_garbage() raises:
    assert_true(_decimal_raises("abc"))
    assert_true(_decimal_raises(""))
    assert_true(_decimal_raises("."))
    assert_true(_decimal_raises("1x2"))


fn test_block_of() raises:
    assert_equal(block_of(PB_INT64), BLK_INT64)
    assert_equal(block_of(PB_INT32), BLK_INT32)
    assert_equal(block_of(PB_DOUBLE), BLK_DOUBLE)
    assert_equal(block_of(PB_BOOLEAN), BLK_BOOL)
    # NUMERIC / TIMESTAMP / DATE / STRING all live in the string block.
    assert_equal(block_of(PB_NUMERIC), BLK_STRING)
    assert_equal(block_of(PB_TIMESTAMP), BLK_STRING)
    assert_equal(block_of(PB_DATE), BLK_STRING)
    assert_equal(block_of(PB_STRING), BLK_STRING)


fn test_packed_bools() raises:
    var bs = List[Bool](True, False, True, True, False)
    var body = packed_bools(bs)
    assert_equal(len(body), 5)
    assert_equal(body[0], UInt8(1))
    assert_equal(body[1], UInt8(0))
    assert_equal(body[3], UInt8(1))


# ---- runner ----------------------------------------------------------------
# Each case runs in its own try/except so one failure does not hide the rest.
# `fn() raises` values are passed to a small helper; the failure count comes back
# as the helper's return so no closure has to capture mutable outer state.

fn _guard(name: String, test: fn() raises -> None) -> Int:
    try:
        test()
        print("PASS:", name)
        return 0
    except e:
        print("FAIL:", name, "->", e)
        return 1


fn main() raises:
    var failures = 0
    failures += _guard("test_bit_reinterpret", test_bit_reinterpret)
    failures += _guard("test_varint_roundtrip", test_varint_roundtrip)
    failures += _guard("test_varint_encoding_length", test_varint_encoding_length)
    failures += _guard("test_packed_i64_roundtrip", test_packed_i64_roundtrip)
    failures += _guard("test_read_len_rejects_overrun", test_read_len_rejects_overrun)
    failures += _guard("test_read_len_accepts_exact", test_read_len_accepts_exact)
    failures += _guard("test_read_varint_truncated", test_read_varint_truncated)
    failures += _guard("test_read_varint_too_long", test_read_varint_too_long)
    failures += _guard("test_parse_decimal", test_parse_decimal)
    failures += _guard("test_parse_decimal_rejects_garbage", test_parse_decimal_rejects_garbage)
    failures += _guard("test_block_of", test_block_of)
    failures += _guard("test_packed_bools", test_packed_bools)

    if failures > 0:
        raise Error(String(failures) + " unit test(s) failed")
    print("=== ALL CODEC UNIT TESTS PASSED ===")
