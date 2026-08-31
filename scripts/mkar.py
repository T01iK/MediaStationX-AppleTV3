#!/usr/bin/env python3
"""Write a traditional ar archive, as dpkg expects inside a .deb.

macOS ships llvm-ar, which insists on a symbol table and drops non-Mach-O
members, so the container is written by hand here.
"""
import sys

def main(out, members):
    with open(out, "wb") as f:
        f.write(b"!<arch>\n")
        for path in members:
            name = path.rsplit("/", 1)[-1]
            data = open(path, "rb").read()
            if len(name) > 16:
                raise SystemExit(f"member name too long for traditional ar: {name}")
            f.write(name.ljust(16).encode())   # name
            f.write(b"0".ljust(12))            # mtime
            f.write(b"0".ljust(6))             # uid
            f.write(b"0".ljust(6))             # gid
            f.write(b"100644".ljust(8))        # mode
            f.write(str(len(data)).ljust(10).encode())
            f.write(b"`\n")
            f.write(data)
            if len(data) % 2:
                f.write(b"\n")

if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2:])
