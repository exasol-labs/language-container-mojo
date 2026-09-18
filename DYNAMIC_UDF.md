# Dynamic Mojo UDFs from BucketFS (`%udf_object`)

This guide shows how to ship a UDF as a **shared object (`.so`)** that the
container loads from **BucketFS at run time**, instead of baking it into
`mojoudfclient`. Adding or changing a UDF is then just uploading a new `.so` — no
container rebuild.

It is an **extension**, not a replacement: a script that does **not** carry a
`%udf_object` line keeps using the compiled-in UDFs (`DOUBLE_MOJO`,
`SUM_POSITIVE`, `PY_SCALE`, `MIRROR_MOJO`). See [`src/loader.mojo`](src/loader.mojo)
for the ABI and [`examples/udf_so/double_ext.mojo`](examples/udf_so/double_ext.mojo)
for the template.

> **Prerequisite:** the Mojo SLC container is already deployed and the `MOJO`
> language is activated (README sections 4b + 5). The steps below add a UDF on
> top of that deployment.

---

## The one rule that matters: build with the container's toolchain

A `.so` links the **Mojo runtime**, which has **no stable ABI across compiler
versions**. Your `.so` therefore **must be built with the same Mojo toolchain as
the container** (the same `MOJO_VERSION` from the [`Dockerfile`](Dockerfile)). The
container checks an ABI version and **refuses** a mismatched `.so` with a clear
error rather than crashing — but the fix is always: rebuild with the matching
toolchain. Step 2 below builds *inside the repo's builder image* precisely so this
is guaranteed.

---

## Step 1 — Write the UDF

Copy the template and edit the body. The exported entry symbol **must** be
`__exa_udf_entry_<SCRIPT_NAME>`, where `<SCRIPT_NAME>` is the SQL script name in
`UPPER_SNAKE_CASE`. Keep the `__exa_udf_abi_version` and `__exa_udf_free` symbols
exactly as in the template.

```mojo
# my_udf.mojo  (script will be MY_UDF)
from memory import UnsafePointer

alias ABI_VERSION: Int64 = 1

@export
fn __exa_udf_abi_version() -> Int64:
    return ABI_VERSION

@export
fn __exa_udf_free(vals: UnsafePointer[Int64], nulls: UnsafePointer[Bool]) -> Int64:
    if vals: vals.free()
    if nulls: nulls.free()
    return 0

# MY_UDF(val BIGINT) RETURNS BIGINT — one output row per input row here; a SET
# UDF would return 1, an EMITS UDF more. Allocate the output and return its count.
@export
fn __exa_udf_entry_MY_UDF(
    in_vals: UnsafePointer[Int64], in_nulls: UnsafePointer[Bool], n_in: Int64,
    out_vals: UnsafePointer[UnsafePointer[Int64]],
    out_nulls: UnsafePointer[UnsafePointer[Bool]],
) -> Int64:
    var n = Int(n_in)
    var cap = n if n > 0 else 1
    var ov = UnsafePointer[Int64].alloc(cap)
    var onull = UnsafePointer[Bool].alloc(cap)
    for i in range(n):
        if in_nulls[i]:
            ov[i] = 0; onull[i] = True
        else:
            ov[i] = in_vals[i] * 3      # <-- your logic here
            onull[i] = False
    out_vals[0] = ov
    out_nulls[0] = onull
    return Int64(n)
```

**Hybrid Mojo + Python** works unchanged: call `Python.import_module(...)` inside
the entry. The `.so` bundles no Python — it reuses the CPython runtime already in
the container. Any extra pip packages it imports must be on the container's
`PYTHONPATH` (bundled via `requirements.txt`, or uploaded separately). Don't name
a parameter `out` — it's a reserved word in Mojo (use `out_vals`/`res`).

---

## Step 2 — Build the `.so` (with the matching toolchain)

**Recommended — build inside the repo's builder image** (guarantees the exact
Mojo version the container uses):

```bash
# once: build the builder image from this repo
docker build --target builder -t mojo-slc-builder .

# build your .so (mount the dir holding my_udf.mojo)
docker run --rm -v "$PWD:/work" -w /work mojo-slc-builder \
  mojo build --emit shared-lib my_udf.mojo -o my_udf.so
```

Or, **if you have the identical Mojo toolchain installed locally**:

```bash
mojo build --emit shared-lib my_udf.mojo -o my_udf.so
```

Sanity-check the entry symbol is exported:

```bash
nm -D my_udf.so | grep __exa_udf_entry_MY_UDF     # must print the symbol
```

---

## Step 3 — Upload the `.so` to BucketFS

Upload with an HTTP `PUT` to the BucketFS write endpoint (default port `2581`,
service `bfsdefault`, bucket `default`, write user `w`). Keep the write password
out of your shell history — let `curl` prompt for it:

```bash
# -T uploads the file; curl prompts for the write password after 'w:'
curl -k -T my_udf.so "https://w@<EXASOL_HOST>:2581/default/udfs/my_udf.so"
```

- **TLS:** `-k` skips certificate validation — fine for a lab, **not** for
  production. In production drop `-k` and pass your CA with `--cacert <ca.pem>`.
  You are uploading executable code; do not disable TLS.
- **Path:** you chose `udfs/my_udf.so` inside the `default` bucket here. Verify
  the upload:

```bash
curl -k "https://<EXASOL_HOST>:2581/default/udfs/"     # should list my_udf.so
```

BucketFS mounts each bucket **read-only inside the UDF sandbox** at
`/buckets/<service>/<bucket>/...`, so the file above is visible to the container
at:

```
/buckets/bfsdefault/default/udfs/my_udf.so
```

That sandbox path — **not** the upload URL — is what `%udf_object` references.

---

## Step 4 — Register the script with `%udf_object`

The script body is a single `%udf_object` line pointing at the sandbox path from
Step 3. The `RETURNS`/`EMITS` signature is normal SQL; the body just selects the
`.so`.

```sql
CREATE OR REPLACE MOJO SCALAR SCRIPT MY_UDF(val BIGINT)
RETURNS BIGINT AS
%udf_object /buckets/bfsdefault/default/udfs/my_udf.so
/
```

The SQL script name (`MY_UDF`) must match the exported entry
(`__exa_udf_entry_MY_UDF`).

---

## Step 5 — Run it

```sql
SELECT MY_UDF(val) FROM (VALUES 10, 21, -5) t(val);   -- 30, 63, -15
```

To update the UDF later: rebuild the `.so` (Step 2), re-upload it to the same
BucketFS path (Step 3). New UDF invocations pick up the new `.so`; the `CREATE`
does not need to change.

---

## Troubleshooting

Errors surface as SQL errors prefixed `F-UDF-CL-MOJO-0001`.

| Symptom | Cause & fix |
|---|---|
| `ABI version N != host M` | The `.so` was built with a different toolchain/template. Rebuild via the builder image (Step 2). |
| entry symbol not found / crash on first call | The script name and `__exa_udf_entry_<NAME>` disagree, or the template symbols were renamed. `nm -D my_udf.so` and make them match. |
| `.so` cannot be opened / not found | The `%udf_object` path doesn't match where the file landed in BucketFS. Re-check the bucket/service/upload path; it must resolve to `/buckets/<service>/<bucket>/<path>`. |
| a UDF-side error (e.g. bad input type) | Same contract as the baked-in UDFs — the container returns a clean `MT_CLOSE` with the message; fix the UDF or the input types. |

---

## Note: Exasol Nano

Nano deploys the SLC by mounting a directory (not BucketFS), and its buckets
mount point can be shadowed inside the sandbox. On Nano, place the `.so`
somewhere else in the mounted SLC tree that the sandbox exposes — e.g.
`…/slc/mojo/exaudf/my_udf.so` — and reference it as `/exaudf/my_udf.so` in
`%udf_object`. Everything else (build, register, run) is identical.
