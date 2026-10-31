# Golden vectors

Byte-exact vectors for the control protocol in
[SPEC.md](../../docs/protocol/SPEC.md). GoXLRKit's codec and the dext's
command policy are unit-tested against them (Phase 4).

| File | Contents |
|---|---|
| `transport.json` | USB setup packets, DCP global data, the reset, reply parsing and every reply error, interrupt messages |
| `commands.json` | Command requests, plus decoding of the versions (0x80F:0) and input-state (0x800:0) payloads |
| `policy.json` | Allowlist verdicts (SPEC.md §8–9): opcode, index, firmware gate, length, value, and hardware-risk rejections |

Each vector has:
- an `id`;
- a `kind`;
- the `ledger` ids it relies on;
- a `class` (`derived` or `inferred`, as in the ledger);
- the `firmware` it applies to;
- the `bytes` (lower-case hex) or a `command`;
- the expected `decoded` result.

`synthetic` marks example values that were not read from a device. Their
encoding still follows the cited entries. Vectors that rest on goxlr-utility
numbering are `inferred` until Phase 5 checks them on hardware.

Check them with:

```bash
python3 -I Tests/Vectors/check_vectors.py
```

The dext's policy evaluator, generated from `docs/protocol/policy-table.json`,
runs `policy.json` with `python3 -I Tests/Policy/check_policy.py`, and
GoXLRKit's codec runs `transport.json` and `commands.json` with `swift test`
in `Packages/GoXLRKit`.

`check_vectors.py` is an independent Python reading of SPEC.md. It checks
that each vector's bytes and decoded fields agree, that ids are unique, and
that every ledger id exists. It doesn't test device behaviour.

A mutation pass flipped every byte of every parsed vector. The only changes
the checker missed were in fields the spec says not to read:
- unused words in the global data and the versions reply;
- the reply's reserved word at offset 12;
- bytes after the first failed reply check;
- the interrupt's `bAttribute` and the high byte of `wValue`.
