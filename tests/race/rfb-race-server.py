#!/usr/bin/env python3
"""Synthetic RFB server for the VncConnection torn-frame race test.

Implements just enough of the RFB 3.8 wire protocol for libvncclient
(0.9.15) to connect and keep decoding:

  - protocol version handshake ("RFB 003.008")
  - security: single type "None" (1), ok result
  - server init: 800x600, 32 bpp little-endian truecolor (R16 G8 B0)
  - a dedicated pusher thread sends a FULL-FRAME raw update every
    PUSH_INTERVAL (20 ms) so the client decode thread is continuously
    busy, independent of whatever the client sends
  - client messages (SetPixelFormat/SetEncodings/FrameRequest/...) are
    consumed and ignored

The frame pattern is a 40 px bright bar on a dark background that moves
STEP px per frame; the C++ test (vnc-race-test) reads the client
framebuffer the way VncViewWidget paints it and detects rows that came
from two different server frames at once (a torn frame).

Wire-protocol notes (these are the bits that took hours to get right):

  - FramebufferUpdate message header is 4 bytes: type(1) pad(1) nRects(2)
    x/y/w/h belong to the *rect* header, not to the update header.
  - rect header is 12 bytes: x(2) y(2) w(2) h(2) encoding(4).
  - All row slicing in make_frame() must be in BYTES (pixels * 4), the
    row is a bytes object; mixing pixel and byte indexes silently
    produces rows of the wrong length and desyncs the client.
"""
import os
import socket
import struct
import sys
import threading
import time

W, H = 800, 600
BAR = 40                 # bar width (pixels)
STEP = 30                # bar travel per frame (pixels)
PUSH_INTERVAL = 0.020    # 20 ms


def make_frame(n: int) -> bytes:
    bar_x = (n * STEP) % (W - BAR)
    bg = bytes((0x20, 0x20, 0x20, 0)) * W       # little-endian B,G,R,0
    bar = bytes((0xFF, 0xFF, 0xFF, 0)) * BAR
    row = bg[: bar_x * 4] + bar + bg[(bar_x + BAR) * 4:]
    return row * H


def full_update(raw: bytes) -> bytes:
    # FramebufferUpdate msg: type(1) pad(1) nRects(2); rect header:
    # x(2) y(2) w(2) h(2) encoding(4, 0 = raw); then w*h*4 bytes.
    return (struct.pack(">BBH", 0, 0, 1)
            + struct.pack(">HHHHI", 0, 0, W, H, 0)
            + raw)


# pixel format: 32/24, little-endian, truecolor, maxes 0xFF, shifts R16 G8 B0
PIXFMT = struct.pack(">BBBBHHHBBBBH", 32, 24, 0, 1,
                     0xFF, 0xFF, 0xFF, 16, 8, 0, 0, 0)


def recvall(conn, n: int) -> bytes:
    buf = b""
    while len(buf) < n:
        chunk = conn.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("client gone")
        buf += chunk
    return buf


def handle(conn, addr):
    stop = {"v": False}
    sent = {"n": 0}

    class _CountingSocket:
        def __init__(self, c):
            self.c = c

        def sendall(self, data):
            sent["n"] += len(data)
            self.c.sendall(data)

        def recv(self, n):
            return self.c.recv(n)

        def close(self):
            self.c.close()

    conn = _CountingSocket(conn)
    try:
        # 1. protocol version
        conn.sendall(b"RFB 003.008\n")
        recvall(conn, 12)

        # 2. security types: none
        conn.sendall(b"\x01\x01")
        recvall(conn, 1)                       # selected type
        conn.sendall(struct.pack(">I", 0))     # security result: ok

        # 3. client init
        recvall(conn, 1)

        # 4. server init
        name = b"rfb-race-test"
        conn.sendall(struct.pack(">HH", W, H) + PIXFMT
                     + struct.pack(">I", len(name)) + name)

        # 5. dedicated pusher: full-frame RAW update every PUSH_INTERVAL
        state = {"n": 0}

        def pusher():
            last = 0.0
            while not stop["v"]:
                if time.monotonic() - last >= PUSH_INTERVAL:
                    state["n"] = (state["n"] + 1) % 25
                    conn.sendall(full_update(make_frame(state["n"])))
                    last = time.monotonic()
                time.sleep(0.004)

        threading.Thread(target=pusher, daemon=True).start()

        # 6. consume client messages (SetPixelFormat/SetEncodings/etc.)
        while not stop["v"]:
            hdr = recvall(conn, 2)
            mtype = hdr[0]
            if mtype == 2:            # SetEncodings: 4B + 4B*count
                c = struct.unpack(">H", recvall(conn, 2))[0]
                recvall(conn, 4 * c)
            elif mtype == 3:          # FramebufferUpdateRequest: 10B total
                recvall(conn, 8)
            elif mtype == 0:          # SetPixelFormat: 20B total
                recvall(conn, 18)
            elif mtype == 4:          # PointerEvent: 5B total
                recvall(conn, 3)
            elif mtype == 5:          # KeyEvent: 4B total
                recvall(conn, 2)
            elif mtype == 6:          # ClientCutText: 6B + data
                n = struct.unpack(">I", recvall(conn, 4))[0]
                if n:
                    recvall(conn, n)
            elif mtype >= 253:        # pseudo client messages: 6B total
                recvall(conn, 4)
            else:
                print(f"unexpected message type {mtype}", flush=True)
    except (ConnectionError, OSError):
        pass
    finally:
        stop["v"] = True
        print(f"connection closed: {sent['n']} bytes", flush=True)
        try:
            conn.close()
        except OSError:
            pass


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 12345
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", port))
    s.listen(4)
    print(f"rfb race server on 127.0.0.1:{port}", flush=True)
    while True:
        conn, addr = s.accept()
        threading.Thread(target=handle, args=(conn, addr), daemon=True).start()


if __name__ == "__main__":
    main()
