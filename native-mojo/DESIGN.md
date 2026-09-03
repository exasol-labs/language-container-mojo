# Native Mojo language container for Exasol (no Rust)

A container whose **host is written in Mojo**: it speaks Exasol's ZMQ + protobuf
protocol directly and runs the UDF in the same binary. No `exaudfclient`, no
vtable, no fingerprint, no `dlopen`, no C-accessor bridge — every Rust-bridge
mechanism from `mojo-bridge.patch` exists only to connect a Rust host to a
foreign `.so`, and all of it disappears here.

```
Exasol DB  <== ZMQ REQ/REP + protobuf ==>  mojoudfclient  (one Mojo binary: protocol loop + double())
                                              └ only C dependency: libzmq
```

## Status & honesty

- **Extracted from the repo, authoritative** (`crates/exa-proto`,
  `crates/exa-zmq-protocol`, `crates/exa-udf-runtime`): every field number, wire
  type, the handshake/run state machine, the socket options, and the
  `exascript_table_data` column layout below. Language-neutral — correct whether
  the host is Rust, Mojo, or C.
- **Unverified** (no Mojo toolchain / no Exasol here): all `src/*.mojo`. The
  *protocol logic* is faithful to the extraction; the *Mojo syntax and APIs* are
  best-effort and must be built and run against a real database.

## Architecture decision: single static binary, UDF baked in

For "one function: double" the simplest correct shape is **no dynamic loading at
all**: the protocol host and `double()` compile into one executable. The DB sends
the SQL script's `script_name` in the handshake; the host dispatches on it to a
compiled-in registry (here: one entry, `DOUBLE`).

Trade-off vs. the Rust project's `%udf_object` + `.so`: you rebuild the container
to add/change a UDF. Fine for a fixed function; for a general product you'd
either keep a registry of many baked-in functions, or ship the Mojo compiler in
the image and JIT-compile the script `source_code` at session start (like the
Python container interprets its source). Both are noted under "Evolving it".

## Dependencies

- **libzmq** (C) — `dlopen`'d at runtime via Mojo `DLHandle` (no build-time link;
  `mojo build` links C libs only through `-Xlinker` and some versions can't at
  all). Exasol's protocol *is* `localzmq`, so this is inherent, not incidental.
  Stage `libzmq.so.5` + its closure into the SLC rootfs (the Dockerfile does).
  The only external runtime dependency.
- **No protobuf library** — the wire format is hand-rolled (`src/proto.mojo`).
  proto2 on the wire is just tags + varints + length-delimited fields; the subset
  we use is small, and hand-rolling avoids a heavy libprotobuf/C++ dependency.
- **No Rust, no Mojo runtime beyond the stdlib the binary links.**

---

## The wire protocol (authoritative extraction)

### Transport (`transport.rs`)
- **REQ socket** connected to the endpoint from `argv[1]`. The DB binds REP →
  strict lock-step: every `send` is followed by exactly one `recv`.
- Socket options: `ZMQ_LINGER=0`, `ZMQ_RCVTIMEO=1000`, `ZMQ_SNDTIMEO=1000` (ms).
  A timeout returns `EAGAIN`; **retry** the same op (do not abort) up to a long
  backstop (~120 s). One payload frame per message (REQ manages the empty
  delimiter frame itself).
- Each frame is a protobuf-encoded envelope: outbound `exascript_request`,
  inbound `exascript_response`.

### Envelope (proto field numbers)
`exascript_request` / `exascript_response` share:
- field **1** `type` — `message_type` enum (varint)
- field **2** `connection_id` — uint64 (varint)

`message_type`: `MT_CLIENT=1 MT_INFO=2 MT_META=3 MT_CLOSE=4 MT_IMPORT=5 MT_NEXT=6
MT_RESET=7 MT_EMIT=8 MT_RUN=9 MT_DONE=10 MT_CLEANUP=11 MT_FINISHED=12
MT_PING_PONG=13 MT_TRY_AGAIN=14 MT_CALL=15 MT_RETURN=16 MT_UNDEFINED_CALL=17`.

Request payload sub-messages: field **3** `client`, **7** `emit`, **8** `ping`,
**5** `close`. Response payload sub-messages: field **4** `info`, **5** `meta`,
**8** `next`, **9** `ping`.

`connection_id` starts at **0**; set it from every response and echo it on every
request thereafter.

### Handshake (`loop_.rs`)
```
send  MT_CLIENT   { client{ client_name = <endpoint URL> } }   # conn_id 0
recv  MT_INFO     { info{ script_name, source_code, … } }      # remember conn_id
send  MT_META                                                   # bare envelope
recv  MT_META     { meta{ input/output iter + columns, single_call_mode } }
# MT_PING_PONG may arrive at any time → reply MT_PING_PONG{ ping{ meta_info } }
```

`exascript_info` (response.field 4): field 3 `script_name` (string), field 4
`source_code` (string) — plus session/db identity fields we can ignore for
`double`.

`exascript_metadata` (response.field 5):
- field 1 `input_iter_type`, field 2 `output_iter_type` — `iter_type` enum:
  `PB_EXACTLY_ONCE=1` (SCALAR/RETURNS), `PB_MULTIPLE=2` (SET/EMITS)
- field 3 `input_columns`, field 4 `output_columns` — repeated `column_definition`
- field 5 `single_call_mode` (bool) — `false` for `double`

`column_definition`: field 1 `name` (string), field 2 `type` (`column_type`
enum), field 3 `type_name` (string), field 4 `size`, field 5 `precision`,
field 6 `scale`. `column_type`: `PB_DOUBLE=1 PB_INT32=2 PB_INT64=3 PB_NUMERIC=4
PB_TIMESTAMP=5 PB_DATE=6 PB_STRING=7 PB_BOOLEAN=8`.

### Run loop (`dispatch.rs`)
```
loop:
  send MT_RUN;  recv → MT_RUN (group open) | MT_CLEANUP (session end → break)
  # --- one group ---
  loop:
    send MT_NEXT; recv → MT_NEXT{ next{ table } } (a batch) | MT_DONE (input done)
    decode table → rows; for each input row compute output row(s)
  send MT_EMIT { emit{ table } };  recv → MT_EMIT (ack)     # only if rows to emit
  send MT_DONE;  recv → MT_DONE | MT_CLEANUP
send MT_FINISHED; recv → MT_FINISHED; exit(0)
```
Even a SCALAR/RETURNS UDF like `double` returns its results as an **MT_EMIT
table** (one output row per input row, in order) — there is no separate
"return value" channel outside single-call mode.

### `exascript_table_data` — the column layout (`rowset.rs`)
Both directions use the same packing. Fields:
- **1** `rows` uint64 (required) — row count in this batch
- **8** `rows_in_group` uint64 (required) — 0 when emitting
- **2** `data_string` repeated string — holds NUMERIC, DATE, TIMESTAMP(_TZ),
  CHAR/VARCHAR, GEOMETRY, HASHTYPE, INTERVAL* (everything string-encoded)
- **3** `data_nulls` packed bool
- **4** `data_bool` packed bool
- **5** `data_int32` packed int32
- **6** `data_int64` packed int64  ← BIGINT lives here (what `double` uses)
- **7** `data_double` packed double (64-bit / wire type 1 per element)
- **9** `row_number` packed uint64 (leave empty when emitting)

**Layout rule (critical):**
- `data_nulls` is a flat **row-major** bitmap of length `rows × n_cols`; cell
  `(r, c)` is at index `r*n_cols + c`.
- The typed blocks are filled by walking **rows, then columns**; each *non-null*
  cell appends to the block for its **declared column type**. A **NULL cell
  occupies NO slot** in its type block — it is recorded only in `data_nulls`. So
  to decode, keep a per-type cursor that advances only on non-null cells.
- The block is chosen by the **column's declared type**, not the value: a DECIMAL
  column always goes to `data_string` even if the value is integral.

`packed` repeated (wire type 2 = length-delimited): a single field carrying the
concatenation of the elements — varints for bool/int32/int64/uint64, 8-byte
little-endian for double. int32/int64 are plain (not zig-zag), so negatives are
10-byte sign-extended varints.

### Errors
On failure, send `MT_CLOSE { close{ exception_message } }` (request field 5). The
Rust host prefixes `F-UDF-CL-RUST-####`; use your own prefix, e.g.
`F-UDF-CL-MOJO-0001: …`.

---

## `double`, concretely

Registered as `CREATE MOJO SCALAR SCRIPT myschema."DOUBLE"(val BIGINT) RETURNS
BIGINT` (quoted because `DOUBLE` is an Exasol type keyword). Handshake yields:
input 1 col `PB_INT64`, output 1 col `PB_INT64`,
`input_iter_type = PB_EXACTLY_ONCE`, `single_call_mode = false`. Per input batch
of N rows: read `data_int64[0..N]` (no nulls in the simple case), emit a table
with `rows=N`, `data_int64=[2*x for x in input]`, `data_nulls=[false;N]`.

---

## Build → package → register

1. **Build** the Mojo binary (links libzmq):
   ```
   mojo build src/main.mojo -o mojoudfclient   # + link flags for -lzmq (see build.md)
   ```
2. **Package** an SLC tarball with the same rootfs shape the Rust `Dockerfile`
   produces — a hermetic tree with the binary at `/exaudf/mojoudfclient`, the
   loader, libzmq, and the Mojo runtime libs it links (find them via `ldd`).
3. **Register** a `MOJO` alias pointing at the Mojo binary (note the executable
   name in the fragment):
   ```
   MOJO=localzmq+protobuf:///<svc>/<bucket>/<slc>?lang=mojo#buckets/<svc>/<bucket>/<slc>/exaudf/mojoudfclient
   ```
   (This is the same shape `scripts/lib/script_languages.sh` builds — only the
   executable name changes from `exaudfclient` to `mojoudfclient`.)
4. `SELECT myschema."DOUBLE"(21);` → `42`.

## Evolving it

- **Many functions:** grow the `src/udf.mojo` registry and dispatch on
  `script_name`; the protocol host is unchanged.
- **Arbitrary source (Python-like UX):** ship the Mojo compiler in the image,
  write `source_code` to a temp file at session start, `mojo build --emit
  shared-lib`, and `dlopen` it — reintroducing dynamic loading but still no Rust.
- **Types beyond BIGINT:** implement the other blocks in `src/wire.mojo`
  (`data_string` for DECIMAL/DATE/…, `data_double`, `data_bool`) following the
  layout rule above.

## Files

```
src/zmq.mojo     libzmq FFI (ctx/socket/connect/send/recv, options)
src/proto.mojo   protobuf primitives: varint + tag read/write, field walker
src/wire.mojo    encode requests / decode responses + exascript_table_data
src/udf.mojo     the double() function + name→function dispatch
src/main.mojo    argv, connect, handshake, run loop
build_info/language_definitions.json   SLC self-description (MOJO alias)
Dockerfile       build mojoudfclient + stage a hermetic SLC rootfs (ldd closure)
install-native.sh   one command: docker build → BucketFS upload → register MOJO
build.md         build + link + package + register runbook
test/fake_exasol.py   fake Exasol REP server — verify the wire protocol offline
```
