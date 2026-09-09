#!/usr/bin/env python3
import os
import plistlib
import struct
import sys

MH_MAGIC_64 = 0xFEEDFACF
LC_SEGMENT_64 = 0x19
LC_LOAD_WEAK_DYLIB = 0x80000018
HEADER_SIZE = 32
SEGMENT64_SIZE = 72
SECTION64_SIZE = 80
DYLIB_COMMAND_SIZE = 24


def align8(value: int) -> int:
    return (value + 7) & ~7


def read_header(data: bytearray):
    if len(data) < HEADER_SIZE:
        raise RuntimeError("Mach-O is too small")
    fields = struct.unpack_from("<8I", data, 0)
    if fields[0] != MH_MAGIC_64:
        raise RuntimeError(f"Expected thin arm64 Mach-O (magic 0x{MH_MAGIC_64:x}), got 0x{fields[0]:x}")
    return fields


def inject(executable: str, load_path: str):
    with open(executable, "rb") as f:
        data = bytearray(f.read())

    magic, cputype, cpusubtype, filetype, ncmds, sizeofcmds, flags, reserved = read_header(data)
    command_offset = HEADER_SIZE
    first_section_offset = None

    for _ in range(ncmds):
        if command_offset + 8 > len(data):
            raise RuntimeError("Truncated Mach-O load commands")
        cmd, cmdsize = struct.unpack_from("<II", data, command_offset)
        if cmdsize < 8 or command_offset + cmdsize > len(data):
            raise RuntimeError("Invalid Mach-O load command size")

        if cmd == LC_SEGMENT_64:
            segname = bytes(data[command_offset + 8:command_offset + 24]).split(b"\0", 1)[0]
            nsects = struct.unpack_from("<I", data, command_offset + 64)[0]
            if segname == b"__TEXT":
                section_base = command_offset + SEGMENT64_SIZE
                for index in range(nsects):
                    section = section_base + index * SECTION64_SIZE
                    if section + SECTION64_SIZE > command_offset + cmdsize:
                        raise RuntimeError("Malformed __TEXT section table")
                    file_offset = struct.unpack_from("<I", data, section + 48)[0]
                    if file_offset:
                        first_section_offset = file_offset if first_section_offset is None else min(first_section_offset, file_offset)
        command_offset += cmdsize

    if first_section_offset is None:
        raise RuntimeError("Could not locate first __TEXT section")

    raw_path = load_path.encode("utf-8") + b"\0"
    cmdsize = DYLIB_COMMAND_SIZE + align8(len(raw_path))
    header_end = HEADER_SIZE + sizeofcmds
    available = first_section_offset - header_end

    print(f"Mach-O commands: {ncmds}, sizeofcmds=0x{sizeofcmds:x}")
    print(f"Header end: 0x{header_end:x}, first section: 0x{first_section_offset:x}, free={available} bytes")
    print(f"Injecting {load_path} ({cmdsize} bytes)")

    if available < cmdsize:
        raise RuntimeError(f"Not enough Mach-O header space: need {cmdsize}, have {available}")

    region = data[header_end:header_end + cmdsize]
    if any(region):
        raise RuntimeError("Mach-O header padding is not zero-filled; refusing destructive injection")

    command = struct.pack(
        "<6I",
        LC_LOAD_WEAK_DYLIB,
        cmdsize,
        DYLIB_COMMAND_SIZE,
        0,
        0,
        0,
    )
    command += raw_path
    command += b"\0" * (cmdsize - len(command))

    data[header_end:header_end + cmdsize] = command
    struct.pack_into("<I", data, 16, ncmds + 1)
    struct.pack_into("<I", data, 20, sizeofcmds + cmdsize)

    with open(executable, "wb") as f:
        f.write(data)

    print("Injection complete")


def main():
    if len(sys.argv) != 3:
        print(f"usage: {sys.argv[0]} APP_PATH DYLIB_LOAD_PATH", file=sys.stderr)
        raise SystemExit(2)

    app_path, load_path = sys.argv[1:]
    info_path = os.path.join(app_path, "Info.plist")
    with open(info_path, "rb") as f:
        info = plistlib.load(f)
    executable_name = info["CFBundleExecutable"]
    executable = os.path.join(app_path, executable_name)
    inject(executable, load_path)


if __name__ == "__main__":
    main()
