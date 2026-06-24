# FixZipVersion — ZIP compatibility fix for `vfpcompression.fll`

A small Visual FoxPro 9 utility that makes ZIP archives produced by modern
libraries (for example .NET `System.IO.Compression`) extractable again by
Craig Boyd's `vfpcompression.fll` (`UnzipQuick`).

---

## The problem

`vfpcompression.fll` is strict about one field in the ZIP file format:
**"version needed to extract"**. Every entry in a ZIP stores the minimum
spec version a reader must support. The FLL refuses any entry where this
value is greater than `10` (ZIP spec 1.0).

Modern producers write the spec-correct value `20` (spec 2.0) for
Deflate-compressed entries — and that is exactly what the FLL rejects:

| Producer | `version needed` written | `UnzipQuick` result |
| --- | --- | --- |
| Node.js / jszip | `10` (technically loose, but accepted) | works |
| .NET `System.IO.Compression` | `20` (spec-correct for Deflate) | **fails** |

The confusing part: the archive itself is perfectly valid. Windows Explorer,
7-Zip and every other modern tool open it without complaint — they ignore the
`version needed` field and simply read the compression method. Only the old
FLL trips over it. So a backend migration (e.g. Node.js → .NET) can break ZIP
download/extraction on the client even though nothing is actually wrong with
the file.

This was confirmed by an isolated test: two byte-identical archives differing
**only** in the `version needed` field (`0x14` = 20 vs `0x0A` = 10) — the
`20` version fails, the `10` version extracts.

---

## What this tool does

`FixZipVersion_LowLevel.prg` rewrites the `version needed` field to `10`
(or a target value you choose) in **every** Local File Header and Central
Directory Header of a ZIP file, in place.

It is deliberately surgical:

- It walks the **Central Directory** (using the real header offsets stored in
  the file), so it only ever touches header fields — never random `PK` byte
  sequences that may appear inside compressed data.
- It reads only the End-Of-Central-Directory record and the Central Directory
  block. The compressed payload is never read or rewritten.
- It changes only 2-byte fields, so the file length stays identical.
- It writes a header only if the value actually differs, and reports how many
  fields it corrected.

### Is this safe?

Yes. `version needed to extract` is non-functional metadata for extraction —
the actual decompression is driven by the *compression method* field, which is
left untouched. Setting it to `10` simply matches what jszip already did and
what the FLL expects. No data is recompressed, reordered, or lost.

---

## Requirements

- Visual FoxPro 9 (uses the built-in low-level file functions).
- Read/write access to the ZIP file on disk.

No external libraries or DLLs are required.

---

## Installation

Copy `FixZipVersion_LowLevel.prg` into your project folder. You can then call
it directly, or make its functions available with `SET PROCEDURE`:

```foxpro
SET PROCEDURE TO FixZipVersion_LowLevel ADDITIVE
```

---

## Usage

### As a procedure (shows a result message box)

```foxpro
DO FixZipVersion_LowLevel WITH "c:\temp\resource.zip"
```

### As a function (silent — recommended for production)

```foxpro
LOCAL lnResult
lnResult = FixZipVersionLL("c:\temp\resource.zip", 10)
```

### Recommended pattern: fix right before extracting

Run it as a safety net immediately before `UnzipQuick`, so any incoming
archive is normalized regardless of which backend produced it:

```foxpro
IF FixZipVersionLL(tcZipFile, 10) >= 0
   UnzipQuick(tcZipFile, tcDestination, .F.)
ELSE
   * handle error: archive missing, unreadable, or ZIP64
ENDIF
```

### Return values

| Value | Meaning |
| --- | --- |
| `>= 0` | Success — number of header fields that were corrected (`0` = already fine) |
| `-1` | Error — file missing/unreadable, a ZIP64 archive, or a write failure |

---

## Optional: create a backup first

The tool writes directly into the original file. If you want a safety copy,
add one line before calling it:

```foxpro
COPY FILE (tcZipFile) TO (tcZipFile + ".bak")
lnResult = FixZipVersionLL(tcZipFile, 10)
```

---

## Limitations

- **ZIP64 archives are not supported.** If the archive uses ZIP64 (very large
  files or more than 65,535 entries), the tool detects this and returns `-1`
  instead of patching incorrectly. Standard resource archives are unaffected.
- The tool modifies the file in place and does not create an automatic backup
  (see the section above to add one).

---

## Fixing it at the source (the cleaner long-term option)

This PRG is a client-side safety net. If you control the system that *creates*
the archives, the most robust fix is to make the producer emit
`version needed = 10` directly. For a .NET backend using
`System.IO.Compression`, this means post-processing the finished archive to set
the field to `10` in all Local and Central headers (the field cannot be set
through the public API). Both approaches are functionally equivalent; using
both — server-side fix plus this client-side net — gives the most resilient
result.

---

## Author

Bernhard Reiter / crossVault GmbH

Provided as-is, without warranty.
