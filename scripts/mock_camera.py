#!/usr/bin/env python3
# 🐱 TEST DOUBLE ONLY. Emulates the community-documented Insta360 TCP protocol so ace-probe and the app can be
# 🐱 exercised without hardware. A successful run against this mock says nothing about the real camera.
# 🐱
# 🐱   python3 scripts/mock_camera.py --stream Tests/CameraKitTests/Fixtures/testsrc_160x120_30f.h264 --port 6666
# 🐱   swift run -c release ace-probe probe --host 127.0.0.1 --port 6666 --seconds 5
import argparse
import socket
import struct
import threading
import time

SYNC = b"\x06\x00\x00syNceNdinS"
KEEPALIVE = b"\x05\x00\x00"


def frame(payload: bytes) -> bytes:
    return struct.pack("<I", len(payload) + 4) + payload


def message(code: int, seq: int, body: bytes = b"") -> bytes:
    return frame(b"\x04\x00\x00" + struct.pack("<H", code) + b"\x02" + struct.pack("<I", seq)[:3] + b"\x80\x00\x00" + body)


def varint(v: int) -> bytes:
    out = bytearray()
    while v >= 0x80:
        out.append((v & 0x7F) | 0x80)
        v >>= 7
    out.append(v)
    return bytes(out)


def split_nals(data: bytes):
    # 🐱 Split Annex B into NAL units (without start codes).
    starts = []
    i = 0
    while i + 2 < len(data):
        if data[i] == 0 and data[i + 1] == 0 and data[i + 2] == 1:
            starts.append(i + 3)
            i += 3
        else:
            i += 1
    nals = []
    for k, s in enumerate(starts):
        e = starts[k + 1] - 3 if k + 1 < len(starts) else len(data)
        while e > s and data[e - 1] == 0:
            e -= 1
        nals.append(data[s:e])
    return nals


def access_units(data: bytes, hevc: bool):
    units, cur, has_pic = [], [], False
    for nal in split_nals(data):
        t = (nal[0] >> 1) & 0x3F if hevc else nal[0] & 0x1F
        vcl = t <= 31 if hevc else 1 <= t <= 5
        first = vcl and ((nal[2] & 0x80) if hevc else (nal[1] & 0x80))
        if has_pic and (not vcl or first):
            units.append(cur)
            cur, has_pic = [], False
        cur.append(nal)
        has_pic = has_pic or vcl
    if cur:
        units.append(cur)
    return [b"".join(b"\x00\x00\x00\x01" + n for n in u) for u in units]


def serve(conn, units, hevc, fps, chunk):
    lock = threading.Lock()
    streaming = threading.Event()

    def send(b):
        with lock:
            conn.sendall(b)

    def streamer():
        ts = 10_000_000
        i = 0
        while streaming.is_set():
            au = units[i % len(units)]
            for off in range(0, len(au), chunk):
                send(frame(b"\x01\x00\x00\x20" + struct.pack("<Q", ts) + au[off:off + chunk]))
            ts += int(1e6 / fps)
            i += 1
            time.sleep(1 / fps)

    buf = b""
    while True:
        data = conn.recv(65536)
        if not data:
            break
        buf += data
        while len(buf) >= 4:
            n = struct.unpack("<I", buf[:4])[0]
            if len(buf) < n:
                break
            p, buf = buf[4:n], buf[n:]
            if p == SYNC:
                send(frame(SYNC))
            elif p[:3] == b"\x04\x00\x00" and len(p) >= 12:
                code = struct.unpack("<H", p[3:5])[0]
                seq = struct.unpack("<I", p[6:9] + b"\x00")[0]
                if code == 8:  # 🐱 GET_OPTIONS: camera_type(48), firmwareRevision(30)
                    opts = b"\x82\x03" + varint(len(b"MOCK camera")) + b"MOCK camera" + b"\xf2\x01" + varint(4) + b"mock"
                    send(message(200, seq, b"\x12" + varint(len(opts)) + opts))
                else:
                    send(message(200, seq))
                if code == 1 and not streaming.is_set():
                    params = b"\x08" + varint(1 if hevc else 0) + b"\x10" + varint(160) + b"\x18" + varint(120) + b"\x20" + varint(int(fps))
                    send(message(8234, 0, params))
                    streaming.set()
                    threading.Thread(target=streamer, daemon=True).start()
                elif code == 2:
                    streaming.clear()
    streaming.clear()


def main():
    ap = argparse.ArgumentParser(description="Insta360 protocol test double (NOT the real camera)")
    ap.add_argument("--stream", required=True, help="Annex B .h264/.h265 file to loop")
    ap.add_argument("--port", type=int, default=6666)
    ap.add_argument("--fps", type=float, default=30)
    ap.add_argument("--chunk", type=int, default=1400, help="max video bytes per stream packet")
    a = ap.parse_args()
    data = open(a.stream, "rb").read()
    hevc = a.stream.endswith((".h265", ".hevc"))
    units = access_units(data, hevc)
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", a.port))
    srv.listen(1)
    print(f"mock camera (TEST DOUBLE) on 127.0.0.1:{a.port}, {len(units)} pictures, {'HEVC' if hevc else 'H.264'}", flush=True)
    while True:
        conn, _ = srv.accept()
        threading.Thread(target=serve, args=(conn, units, hevc, a.fps, a.chunk), daemon=True).start()


if __name__ == "__main__":
    main()
