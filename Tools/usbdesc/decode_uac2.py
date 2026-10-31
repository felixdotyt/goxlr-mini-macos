"""Decode usbdesc output (USB 2.0 + UAC2 descriptors) into readable text.

Usage: python3 -I decode_uac2.py descriptors.txt [--strings-needed]

With --strings-needed, prints only the string indices the descriptors refer
to, for a second `usbdesc <index ...>` run. String records present in the
input are shown next to the fields that reference them.
"""

import struct
import sys

TERMINAL_TYPES = {
    0x0101: "USB streaming",
    0x0201: "microphone",
    0x0301: "speaker",
    0x0302: "headphones",
    0x0400: "bi-directional",
    0x0601: "analog connector",
    0x0602: "digital audio interface",
    0x0603: "line connector",
    0x0605: "S/PDIF",
}
EP_TYPES = ["control", "isochronous", "bulk", "interrupt"]
EP_SYNC = ["none", "async", "adaptive", "sync"]
EP_USAGE = ["data", "feedback", "implicit feedback data", "reserved"]


def u8(b, o):
    return b[o]


def u16(b, o):
    return struct.unpack_from("<H", b, o)[0]


def u32(b, o):
    return struct.unpack_from("<I", b, o)[0]


def load(path):
    records = {"strings": {}}
    with open(path, encoding="ascii") as f:
        for line in f:
            parts = line.split()
            if not parts:
                continue
            if parts[0] in ("device", "config"):
                records[parts[0]] = bytes.fromhex(parts[1])
            elif parts[0] == "string":
                raw = bytes.fromhex(parts[2])
                records["strings"][int(parts[1])] = raw[2 : raw[0]].decode("utf-16-le", "replace")
    return records


def split(config):
    out, o = [], 0
    while o + 2 <= len(config):
        length = config[o]
        if length < 2 or o + length > len(config):
            out.append(("truncated", config[o:]))
            break
        out.append((config[o + 1], config[o : o + length]))
        o += length
    return out


class Decoder:
    def __init__(self, strings):
        self.strings = strings
        self.needed = set()
        self.subclass = None  # current interface subclass: 1 = AC, 2 = AS

    def s(self, index):
        if index == 0:
            return "0"
        self.needed.add(index)
        name = self.strings.get(index)
        return f'{index} "{name}"' if name is not None else str(index)

    def names(self, first, count):
        """UAC2 channel names: consecutive string indices starting at iChannelNames."""
        if first == 0:
            return "0"
        indices = range(first, first + count)
        self.needed.update(indices)
        listed = "".join(f'\n      ch{n + 1}: {self.strings.get(i, "?")}' for n, i in enumerate(indices))
        return f"{first}..{first + count - 1}{listed}"

    def line(self, b):
        t = b[1]
        if t == 0x02:
            return (f"CONFIGURATION wTotalLength={u16(b, 2)} bNumInterfaces={b[4]} "
                    f"bConfigurationValue={b[5]} iConfiguration={self.s(b[6])} "
                    f"bmAttributes=0x{b[7]:02x} bMaxPower={b[8] * 2}mA")
        if t == 0x0B:
            return (f"IAD bFirstInterface={b[2]} bInterfaceCount={b[3]} class={b[4]:02x}/{b[5]:02x}/{b[6]:02x} "
                    f"iFunction={self.s(b[7])}")
        if t == 0x04:
            self.subclass = b[6] if b[5] == 0x01 else None
            return (f"INTERFACE {b[2]} alt {b[3]} bNumEndpoints={b[4]} "
                    f"class={b[5]:02x}/{b[6]:02x}/{b[7]:02x} iInterface={self.s(b[8])}")
        if t == 0x05:
            attr, mps = b[3], u16(b, 4)
            usage = EP_USAGE[(attr >> 4) & 3]
            return (f"  ENDPOINT 0x{b[2]:02x} ({'IN' if b[2] & 0x80 else 'OUT'}) "
                    f"{EP_TYPES[attr & 3]} sync={EP_SYNC[(attr >> 2) & 3]} usage={usage} "
                    f"wMaxPacketSize={mps & 0x7FF} x{((mps >> 11) & 3) + 1} bInterval={b[6]}")
        if t == 0x24 and self.subclass == 0x01:
            return "  AC " + self.ac(b)
        if t == 0x24 and self.subclass == 0x02:
            return "  AS " + self.as_(b)
        if t == 0x25:
            return (f"  CS_ENDPOINT subtype={b[2]} bmAttributes=0x{b[3]:02x} bmControls=0x{b[4]:02x} "
                    f"bLockDelayUnits={b[5]} wLockDelay={u16(b, 6)}")
        return f"  type 0x{t:02x}: {b.hex()}"

    def ac(self, b):
        st = b[2]
        if st == 0x01:
            return (f"HEADER bcdADC={u16(b, 3):04x} bCategory=0x{b[5]:02x} wTotalLength={u16(b, 6)} "
                    f"bmControls=0x{b[8]:02x}")
        if st == 0x02:
            tt = u16(b, 4)
            return (f"INPUT_TERMINAL id={b[3]} type=0x{tt:04x} ({TERMINAL_TYPES.get(tt, '?')}) "
                    f"assoc={b[6]} clock={b[7]} channels={b[8]} bmChannelConfig=0x{u32(b, 9):08x} "
                    f"bmControls=0x{u16(b, 14):04x} iTerminal={self.s(b[16])} iChannelNames={self.names(b[13], b[8])}")
        if st == 0x03:
            tt = u16(b, 4)
            return (f"OUTPUT_TERMINAL id={b[3]} type=0x{tt:04x} ({TERMINAL_TYPES.get(tt, '?')}) "
                    f"assoc={b[6]} source={b[7]} clock={b[8]} bmControls=0x{u16(b, 9):04x} "
                    f"iTerminal={self.s(b[11])}")
        if st == 0x06:
            n = (b[0] - 6) // 4
            controls = " ".join(f"{u32(b, 5 + 4 * i):08x}" for i in range(n))
            return (f"FEATURE_UNIT id={b[3]} source={b[4]} channels={n - 1} "
                    f"bmaControls[master,1..]={controls} iFeature={self.s(b[-1])}")
        if st == 0x0A:
            return (f"CLOCK_SOURCE id={b[3]} bmAttributes=0x{b[4]:02x} bmControls=0x{b[5]:02x} "
                    f"assoc={b[6]} iClockSource={self.s(b[7])}")
        if st == 0x0B:
            n = b[4]
            return (f"CLOCK_SELECTOR id={b[3]} inputs={list(b[5:5 + n])} bmControls=0x{b[5 + n]:02x} "
                    f"iClockSelector={self.s(b[6 + n])}")
        if st == 0x0C:
            return f"CLOCK_MULTIPLIER id={b[3]} source={b[4]} bmControls=0x{b[5]:02x} iClockMultiplier={self.s(b[6])}"
        if st == 0x04:
            p = b[4]
            sources = list(b[5:5 + p])
            o = 5 + p
            ch = b[o]
            return (f"MIXER_UNIT id={b[3]} sources={sources} channels={ch} bmChannelConfig=0x{u32(b, o + 1):08x} "
                    f"iChannelNames={self.s(b[o + 5])} raw={b.hex()}")
        if st == 0x05:
            p = b[4]
            return (f"SELECTOR_UNIT id={b[3]} sources={list(b[5:5 + p])} bmControls=0x{b[5 + p]:02x} "
                    f"iSelector={self.s(b[6 + p])}")
        if st == 0x09:
            p = b[6]
            return f"EXTENSION_UNIT id={b[3]} code=0x{u16(b, 4):04x} sources={list(b[7:7 + p])} raw={b.hex()}"
        return f"subtype 0x{st:02x}: {b.hex()}"

    def as_(self, b):
        st = b[2]
        if st == 0x01:
            return (f"AS_GENERAL terminal={b[3]} bmControls=0x{b[4]:02x} bFormatType={b[5]} "
                    f"bmFormats=0x{u32(b, 6):08x} channels={b[10]} bmChannelConfig=0x{u32(b, 11):08x} "
                    f"iChannelNames={self.names(b[15], b[10])}")
        if st == 0x02 and b[3] == 1:
            return f"FORMAT_TYPE_I bSubslotSize={b[4]} bBitResolution={b[5]}"
        return f"subtype 0x{st:02x}: {b.hex()}"


def main(argv):
    records = load(argv[1])
    decoder = Decoder(records["strings"])
    lines = []
    dev = records.get("device")
    if dev:
        lines.append(
            f"DEVICE bcdUSB={u16(dev, 2):04x} class={dev[4]:02x}/{dev[5]:02x}/{dev[6]:02x} "
            f"bMaxPacketSize0={dev[7]} idVendor={u16(dev, 8):04x} idProduct={u16(dev, 10):04x} "
            f"bcdDevice={u16(dev, 12):04x} iManufacturer={decoder.s(dev[14])} iProduct={decoder.s(dev[15])} "
            f"iSerialNumber={dev[16]} bNumConfigurations={dev[17]}"
        )
    for t, b in split(records["config"]):
        lines.append(f"truncated: {b.hex()}" if t == "truncated" else decoder.line(b))
    if "--strings-needed" in argv:
        print(" ".join(str(i) for i in sorted(decoder.needed)))
    else:
        print("\n".join(lines))


if __name__ == "__main__":
    main(sys.argv)
