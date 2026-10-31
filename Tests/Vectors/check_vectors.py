"""Check the golden vectors against an independent reading of SPEC.md.

Usage: python3 -I Tests/Vectors/check_vectors.py   (from the repo root)

For each vector, encodes the decoded fields and compares the bytes, or
parses the bytes and compares the decoded fields. Also checks that ids are
unique, hex is well formed and every cited ledger id exists in LEDGER.md.
This is the reference model the Swift codec (Phase 4) is tested against;
it checks internal consistency, not device behaviour.
"""

import json
import pathlib
import re
import struct
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
VECTORS = pathlib.Path(__file__).resolve().parent
LEDGER_IDS = set(re.findall(r"^\| (L-\d{3}) \|", (ROOT / "docs/protocol/LEDGER.md").read_text(), re.M))

MAGIC = (0x04061973, 0x18101966)
STATUS_NAMES = ["success", "error", "timeout", "invalid command sequence", "invalid opcode category",
                "invalid state", "max transfer size exceeded", "invalid opcode index", "invalid argument",
                "not supported", "invalid response sequence"]


def opcode(category, index):
    return (category & 0xFFF) << 12 | (index & 0xFFF)


# SPEC.md section 1
def check_usb_setup(v, b):
    d = v["decoded"]
    expected = struct.pack("<BBHHH", d["bmRequestType"], d["bRequest"], d["wValue"], d["wIndex"], d["wLength"])
    assert b == expected, f"setup {b.hex()} != {expected.hex()}"
    if "data_u32" in d:
        data = bytes.fromhex(v["data"])
        assert len(data) == d["wLength"] and struct.unpack("<I", data)[0] == d["data_u32"]


# SPEC.md section 2
def parse_global_data(b):
    if len(b) != 24:
        return {"ok": False, "error": "badLength"}
    words = struct.unpack("<6I", b)
    if words[:2] != MAGIC:
        return {"ok": False, "error": "badMagic"}
    return {"ok": True, "dcp_version": words[2], "max_payload": words[4], "reset_with_brequest_1": words[2] > 1}


# SPEC.md section 3
def encode_request(category, index, sequence, payload):
    return struct.pack("<IHHII", opcode(category, index), len(payload), sequence, 0, 0) + payload


def parse_reply(b, category, index, sequence, max_payload):
    if len(b) < 16:
        return {"ok": False, "error": "replyTooShort"}
    op, length, seq, status, _ = struct.unpack_from("<IHHII", b)
    if op != opcode(category, index):
        return {"ok": False, "error": "opcodeMismatch"}
    if seq != sequence:
        return {"ok": False, "error": "sequenceMismatch"}
    if length + 16 != len(b):
        return {"ok": False, "error": "lengthMismatch"}
    if length > max_payload:
        return {"ok": False, "error": "replyTooLarge"}
    if status != 0:
        name = STATUS_NAMES[status] if status < len(STATUS_NAMES) else "unknown"
        return {"ok": False, "error": "dcpStatus", "status": status, "status_name": name}
    return {"ok": True, "status": 0, "payload": b[16:].hex()}


# SPEC.md section 5
def parse_interrupt(b):
    assert len(b) == 6
    b_info, attribute, w_value, w_index = struct.unpack("<BBHH", b)
    vendor = b_info == 0x01
    if not vendor:
        return {"vendor": False, "response_ready": False, "event_flags": 0, "read_input_state": False,
                "class_attribute": attribute, "class_wValue": w_value, "class_wIndex": w_index}
    v = w_value | w_index << 16
    ready = bool(v & 1)
    return {"vendor": True, "response_ready": ready, "event_flags": v & 0xFFE00000, "read_input_state": not ready}


# SPEC.md section 9
def parse_versions(b):
    w = struct.unpack("<6I", b)
    return {"firmware": [w[0] >> 12 & 0xF, w[0] >> 8 & 0xF, w[0] & 0xFF, w[1]], "fpga_count": w[3],
            "dice_build": w[4], "dice_version": [w[5] >> 20 & 0xF, w[5] >> 12 & 0xFF, w[5] & 0xFFF]}


# SPEC.md section 10
def parse_input_state(b):
    raw, = struct.unpack_from("<I", b)
    buttons = raw & 0x3FFFFFFF
    return {"buttons": buttons, "pressed": [i for i in range(30) if buttons >> i & 1],
            "encoders": list(struct.unpack_from("<4b", b, 4)), "faders": list(b[8:12])}


# SPEC.md section 8 (commands.md key lists; inferred from goxlr-utility)
def _ranges(*items):
    out = set()
    for item in items:
        out.update(range(item[0], item[1] + 1) if isinstance(item, tuple) else [item])
    return out


EFFECT_KEYS = _ranges(0x158, 0x73, 0x10, 0x11, 0x14, 0x15, 0x16, 0x17, 0x14B,
                      0x126, 0x127, 0xF8, 0xF9, 0x113, 0x114, 0x129, 0x12A, 0x116, 0x117, 0x11D, 0x11E,
                      0x12C, 0x12D, 0x120, 0x121, 0x109, 0x10A, 0x12F, 0x130, (0x13C, 0x140), 0x0B,
                      (0x2E, 0x39), 0x76, (0x1E, 0x2A), 0x75, 0x5D, 0x159, 0x167, 0x60, (0x3A, 0x49),
                      (0x133, 0x13B), 0x146, 0x147, 0x14D, 0x157, (0x59, 0x5F), 0x14E, 0xD7, 0xD8, 0xD5, 0xD6,
                      0x150, 0x151)
MIC_TYPE = 0x000
MIC_KEYS = _ranges((0x000, 0x003), 0x30200, 0x30400, 0x30600, 0x30900, (0x60200, 0x60700), 0x70100,
                   (0x40000, 0x40007), (0x50000, 0x50007))
GATES = {  # model: (animations, submix, mix2)
    "full": ((1, 3, 40, 0), (1, 4, 2, 107), (1, 5, 0, 0)),
    "mini": ((1, 1, 8, 0), (1, 2, 0, 46), (1, 3, 0, 0)),
}


def policy(category, index, payload, model, firmware, trusted=False):
    animations, submix, mix2 = (tuple(firmware) >= g for g in GATES[model])
    n = len(payload)

    def reject(reason):
        return {"allow": False, "reason": reason}

    rules = {
        0x800: ({0}, None), 0x80C: ({0}, None), 0x80F: ({0, 1}, None),
        0x801: ({0}, None), 0x802: (set(range(4)), None), 0x803: ({0}, None),
        0x804: (set(range(18)), None), 0x805: (set(range(4)), None), 0x806: (None, None),
        0x808: ({0}, None), 0x809: (set(range(11)), None), 0x80A: (set(range(4)), None),
        0x80B: ({0}, None), 0x811: (set(range(4)), None), 0x814: (set(range(4)), None),
        0x816: ({0}, animations), 0x817: ({0}, submix), 0x818: ({0}, submix),
    }
    if category not in rules:
        return reject("opcode")
    indices, gate = rules[category]
    if category == 0x806:
        bank, channel = index >> 4, index & 0xF
        if not ((bank == 0 and channel <= 10) or (bank == 1 and channel <= 7)):
            return reject("index")
        gate = submix if bank == 1 else None
    elif index not in indices:
        return reject("index")
    if gate is False:
        return reject("firmware")

    lengths = {0x800: 0, 0x80C: 0, 0x80F: 0, 0x802: 1024, 0x803: 520 if animations else 328,
               0x804: 26 if mix2 else 22, 0x805: 4, 0x806: 1, 0x808: 24, 0x809: 1, 0x80A: 1,
               0x811: 2, 0x814: 2, 0x816: 5, 0x817: 10 if mix2 else 8, 0x818: 1}
    if category in (0x801, 0x80B):
        if n == 0 or n % 8:
            return reject("length")
    elif n != lengths[category]:
        return reject("length")

    if category == 0x801:
        for key, _ in struct.iter_unpack("<Ii", payload):
            if key not in EFFECT_KEYS:
                return reject("value")
    if category == 0x80B:
        for key, value in struct.iter_unpack("<II", payload):
            if key not in MIC_KEYS:
                return reject("value")
            if key == MIC_TYPE and value == 1:
                if trusted:  # the user's decision (SPEC.md section 8): team-signed clients may
                    continue
                return reject("hardware-risk")
            if key == MIC_TYPE and value != 0:
                return reject("value")
    if category == 0x804:
        hardtune = 25 if mix2 else 21
        for i, byte in enumerate(payload):
            allowed = {0x00, 0x04, 0x10} if i == hardtune else ({0x00, 0x20} if i % 2 else {0x00})
            if byte not in allowed:
                return reject("value")
    if category == 0x805 and struct.unpack("<I", payload)[0] > 10:
        return reject("value")
    if category == 0x808 and any(byte > 4 for byte in payload):
        return reject("value")
    if category in (0x809, 0x818) and payload[0] not in (0, 1):
        return reject("value")
    return {"allow": True}


def check(v):
    kind = v["kind"]
    if kind == "policy":
        c = v["command"]
        payload = bytes.fromhex(c["payload"]) if "payload" in c else bytes(c["payload_length"])
        got = policy(c["category"], c["index"], payload, v["device"]["model"], v["device"]["firmware"],
                     v.get("trusted", False))
        assert got == v["decoded"], f"{got} != {v['decoded']}"
        return
    b = bytes.fromhex(v["bytes"])
    d = v["decoded"]
    if kind == "usb-setup":
        check_usb_setup(v, b)
    elif kind == "dcp-request":
        expected = encode_request(d["category"], d["index"], d["sequence"], bytes.fromhex(d["payload"]))
        assert b == expected, f"{b.hex()} != {expected.hex()}"
    elif kind == "dcp-reply":
        e = v["expect"]
        got = parse_reply(b, e["category"], e["index"], e["sequence"], e["max_payload"])
        assert got == d, f"{got} != {d}"
    else:
        parser = {"global-data": parse_global_data, "interrupt": parse_interrupt,
                  "versions": parse_versions, "input-state": parse_input_state}[kind]
        got = parser(b)
        assert got == d, f"{got} != {d}"


def main():
    seen, failures, count = set(), 0, 0
    for path in sorted(VECTORS.glob("*.json")):
        for v in json.loads(path.read_text())["vectors"]:
            count += 1
            try:
                assert v["id"] not in seen, "duplicate id"
                seen.add(v["id"])
                assert v.get("class") in ("observed", "derived", "inferred"), "bad class"
                missing = [i for i in v["ledger"] if i not in LEDGER_IDS]
                assert not missing, f"unknown ledger ids {missing}"
                for field in ("bytes", "data"):
                    if field in v:
                        assert re.fullmatch(r"(?:[0-9a-f]{2})*", v[field]), f"bad hex in {field}"
                check(v)
            except (AssertionError, KeyError, ValueError, struct.error) as error:
                failures += 1
                print(f"FAIL {path.name}:{v.get('id')}: {error}")
    print(f"{count - failures}/{count} vectors pass")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
