# VncConnection torn-frame race — synthetic A/B test

Verifies the fix for the pixelated/torn artifacts in the macOS remote view
(`patches/0023-core-vncconnection-present-complete-updates.patch`,
upstream `20f0b6298`): the VNC decode thread wrote the client framebuffer
while the GUI paint thread read the same memory, so a repaint could catch
a frame half-updated (rows from two different server frames at once). The
fix decodes into a second buffer and copies the finished rectangles into
the presented `QImage` under a write lock; `presentCompleteUpdates` is
enabled for `UpdateMode::Live` (the full-size interactive view).

## Files

- `rfb-race-server.py` — synthetic RFB 3.8 server (800x600, 32 bpp). A
  dedicated thread pushes a full-frame RAW update every 20 ms so the
  decode thread is continuously busy; the frame is a 40 px bar that moves
  30 px per frame.
- `vnc-race-test.cpp` — links `libveyon-core`, connects a `VncConnection`
  to the server, and on a 16 ms GUI timer reads the image the way
  `VncViewWidget::paintEvent()` would (paced row walk spanning several
  updates). A capture is *torn* when the bar's left edge differs between
  rows by more than one frame step.
- `run-race-test.sh` — starts the server, builds the test against the
  `build/veyon-macos` stage tree, runs both modes and compares.

## Usage

    bash tests/race/run-race-test.sh [seconds] [veyon-macos-dir]

`RACE_MODE=0` (presentCompleteUpdates=false) reproduces the historical
racy behaviour, `RACE_MODE=1` uses the fix. Expected: mode 0 reports
`torn > 0`, mode 1 `torn == 0` (the script prints PASS when so).

## Verified results

macOS, veyon 4.11.2 + patches/0023, libvncclient 0.9.15, 800x600 full
frames at 50 fps:

| run (seconds) | mode 0 (unfixed) | mode 1 (fix) |
|---------------|------------------|--------------|
| 30            | 9 / 292 torn     | 0 / 292      |
| 45            | 13 / 438 torn    | 0 / 438      |
| 30            | 9 / 293 torn     | 0 / 292      |
| 45            | 5 / 528 torn     | 0 / 529      |

Torn rate without the fix is timing-sensitive (~0.3–3% depending on how
the decode bursts phase against the paint reads), but the fixed mode never
produced a torn frame across all runs.

## Debugging notes (what it took to get here)

The real Kali hosts were unreachable, hence the synthetic harness. Pitfalls
found along the way, in case the server is ever modified:

- The `FramebufferUpdate` message header is 4 bytes (type + pad + nRects);
  x/y/w/h belong to the rect header (12 bytes: x y w h encoding).
- Every row slice in `make_frame()` must be in bytes (`bar_x * 4`); mixing
  pixel and byte indexes produces rows of the wrong length and desyncs the
  client by the constant difference (it then reads pixel bytes where it
  expects a message type byte — "Unknown message type 32").
- libvncclient's `RFB_BUF_SIZE` internal socket buffer is 8192 bytes;
  `RFB_BUFFER_SIZE` (307200) is the per-read size in the raw decoder, not
  the socket buffer.
