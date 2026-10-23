#!/usr/bin/env python3
"""img2simg.py -- convert a raw disk image to an Android sparse image.

Pure-python replacement for the Android `img2simg` host tool (needed on macOS
where the SDK build-tools are not usually installed).

  python3 img2simg.py RAW.img OUT.simg [--block 4096] [--max-raw-blocks 512]

The output is understood by `fastboot flash` and can be split with
`fastboot -S 512M flash userdata OUT.simg`.

Layout (Android sparse format v1.0):
  file header : magic 0xED26FF3A, major 1, minor 0, header sizes, block size,
                total blocks, total chunks
  raw chunk   : header + data blocks
  dont-care   : header only (all-zero blocks; the flasher skips them)
  crc32 chunk : omitted (fastboot does not require it)
"""
import argparse
import os
import struct
import sys

SPARSE_HEADER_MAGIC = 0xED26FF3A
CHUNK_TYPE_RAW = 0xCAC1
CHUNK_TYPE_DONT_CARE = 0xCAC3

FILE_HDR_SIZE = 28
CHUNK_HDR_SIZE = 12


def read_blocks(path, block):
    with open(path, 'rb') as f:
        while True:
            b = f.read(block)
            if not b:
                return
            yield b


def plan_chunks(path, block, max_raw):
    """Yield (type, nblocks) without holding image data."""
    zero = b'\0' * block
    it = read_blocks(path, block)
    cur = next(it, None)
    while cur is not None:
        if cur == zero:
            n = 0
            while cur is not None and cur == zero:
                n += 1
                cur = next(it, None)
            yield (CHUNK_TYPE_DONT_CARE, n)
        else:
            run = 0
            while cur is not None and cur != zero and run < max_raw:
                run += 1
                cur = next(it, None)
            yield (CHUNK_TYPE_RAW, run)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('raw')
    ap.add_argument('out')
    ap.add_argument('--block', type=int, default=4096)
    ap.add_argument('--max-raw-blocks', type=int, default=512)
    args = ap.parse_args()

    size = os.path.getsize(args.raw)
    if size % args.block:
        print(f'error: {args.raw} size {size} is not a multiple of {args.block}',
              file=sys.stderr)
        return 1
    total_blks = size // args.block

    plan = list(plan_chunks(args.raw, args.block, args.max_raw_blocks))
    assert sum(n for _, n in plan) == total_blks, 'chunk plan does not cover all blocks'

    with open(args.out, 'wb') as fout:
        fout.write(struct.pack('<IHHHHIIII',
                               SPARSE_HEADER_MAGIC, 1, 0,
                               FILE_HDR_SIZE, CHUNK_HDR_SIZE,
                               args.block, total_blks, len(plan), 0))
        data_it = read_blocks(args.raw, args.block)
        for ctype, n in plan:
            if ctype == CHUNK_TYPE_DONT_CARE:
                for _ in range(n):
                    next(data_it)
                fout.write(struct.pack('<HHII', ctype, 0, n, CHUNK_HDR_SIZE))
            else:
                fout.write(struct.pack('<HHII', ctype, 0, n,
                                       CHUNK_HDR_SIZE + n * args.block))
                for _ in range(n):
                    fout.write(next(data_it))

    print(f'{args.raw}: {size} bytes, {total_blks} blocks, {len(plan)} chunks')
    print(f'{args.out}: {os.path.getsize(args.out)} bytes')
    return 0


if __name__ == '__main__':
    sys.exit(main())
