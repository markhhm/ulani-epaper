"""TCP relay to the device's GATT link, for testing clients that are out of radio range.

The Apple app (UlaniKit's ``RelayLink``) is developed on a Mac that cannot be
moved next to the device, so this relay runs on a computer that can and
forwards GATT operations as JSON lines::

    python -m ulani_epaper.relay              # the real device, through bleak
    python -m ulani_epaper.relay --fake       # a simulated device, no Bluetooth

It listens on 127.0.0.1:8765 by default; reach it from another machine with
``ssh -L 8765:127.0.0.1:8765 <host>``. One client at a time; when the client
goes away the Bluetooth link is closed.

Wire format (one JSON object per line, UTF-8, ``\\n``-terminated; bytes as hex)::

    -> {"id":1,"op":"hello"}                        <- {"id":1,"ok":true,"relay":1,"fake":false}
    -> {"id":2,"op":"connect","address":null,"scan_timeout":30}
                                                    <- {"id":2,"ok":true,"write_length":244}
    -> {"id":3,"op":"write","char":"command","data":"044e42"}      (with response)
    -> {"id":4,"op":"read","char":"firmware_revision"}             <- {...,"data":"76312e302e3039"}
    -> {"id":5,"op":"stream","data":"<hex>","chunk":230,"flush_every":10}  <- {...,"sent":192000}
    -> {"id":6,"op":"write_length"}                 <- {"id":6,"ok":true,"write_length":244}
    -> {"id":7,"op":"disconnect"}
    <- {"id":n,"ok":false,"error":"...","kind":"not_found|link|timeout|protocol"}
    <- {"event":"notify","char":"command|image","data":"0400"}
    <- {"event":"progress","id":5,"sent":2300,"total":192000}
    <- {"event":"disconnected","reason":"..."}

The image stream runs entirely on the relay host: Windows' write-without-response
only queues, so ``stream`` awaits every write and reads the firmware revision
every ``flush_every`` chunks, exactly like :meth:`Calendar.upload`, and stops
early once an image notification (the device giving up) arrives. The device
expects the data within ~4 s of ``01 00``, so send ``stream`` right after it.
"""

from __future__ import annotations

import argparse
import asyncio
import contextlib
import json
import logging
import sys
import time
from dataclasses import dataclass, field
from typing import Any, Callable, Mapping, Protocol

from . import client
from . import protocol as p
from .protocol import UlaniError

__all__ = ["Backend", "BleBackend", "FakeDevice", "Relay", "RelayError", "build_parser", "main"]

log = logging.getLogger(__name__)

RELAY_VERSION = 1
DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 8765
#: Longest request line: a hex-encoded frame (384 000 characters) plus the JSON around it.
LINE_LIMIT = 1 << 20
#: Progress events are sent every this many chunks when the stream has no read barrier.
PROGRESS_EVERY = 10
#: How long a new client waits for the previous one's clean-up (the Bluetooth disconnect).
HANDOVER_TIMEOUT = 10.0
#: The device gives up ~4 s after ``01 00`` without data; warn when the stream starts late.
LATE_STREAM = 3.0

#: Commands the relay forwards: only the ones this library sends itself. Everything
#: else is refused, so a client cannot send anything that might change the device.
SAFE_OPCODES = frozenset({p.OP_IMAGE_HEADER, p.OP_UNLOCK, p.OP_BATTERY, p.OP_DISCONNECT,
                          p.OP_DEVICE_INFO, p.OP_SHOW_SLOT, p.OP_GET_SLOT})
WRITABLE = {"command": p.CHAR_COMMAND, "image": p.CHAR_IMAGE}
READABLE = {"model_number": p.CHAR_MODEL_NUMBER, "firmware_revision": p.CHAR_FIRMWARE_REVISION}
NOTIFYING = {p.CHAR_COMMAND: "command", p.CHAR_IMAGE: "image"}

#: Notified on the command characteristic right after connecting.
RSP_DEVICE_READY = bytes([0x05, 0x00])

Notify = Callable[[str, bytes], None]
Disconnected = Callable[[str], None]


class RelayError(UlaniError):
    """A request failed; ``kind`` (not_found, link, timeout or protocol) is sent to the client."""

    def __init__(self, kind: str, message: str):
        super().__init__(message)
        self.kind = kind


def error_kind(e: BaseException) -> str:
    if isinstance(e, RelayError):
        return e.kind
    # asyncio.TimeoutError is not the builtin TimeoutError before Python 3.11
    if isinstance(e, (asyncio.TimeoutError, TimeoutError)):
        return "timeout"
    return "link"


class Backend(Protocol):
    """What the relay drives: :class:`BleBackend` or :class:`FakeDevice`.

    Characteristics are the UUIDs from :mod:`ulani_epaper.protocol`.
    """

    fake: bool

    async def connect(self, address: str | None, scan_timeout: float,
                      on_notify: Notify, on_disconnect: Disconnected) -> None: ...

    def write_length(self) -> int: ...

    async def write(self, char: str, data: bytes, response: bool) -> None: ...

    async def read(self, char: str) -> bytes: ...

    async def disconnect(self) -> None: ...


# --- the real device --------------------------------------------------------


class BleBackend:
    """The device through bleak, set up like :func:`ulani_epaper.client.connect` (one attempt).

    bleak is imported on first use, so ``--fake`` works without Bluetooth.
    """

    fake = False

    def __init__(self, *, connect_timeout: float = 30.0, op_timeout: float = 30.0):
        self.connect_timeout = connect_timeout
        #: Upper bound for one GATT write or read, so a stuck link cannot hang a stream.
        self.op_timeout = op_timeout
        self._gatt = None

    async def connect(self, address: str | None, scan_timeout: float,
                      on_notify: Notify, on_disconnect: Disconnected) -> None:
        from bleak import BleakClient

        await self.disconnect()
        try:
            device = await client.find(address, scan_timeout)
        except UlaniError as e:
            raise RelayError("not_found", str(e)) from None

        def disconnected(_gatt) -> None:
            if self._gatt is gatt:  # not our own disconnect, not a failed setup
                self._gatt = None
                on_disconnect("the device dropped the link")

        gatt = BleakClient(device, disconnected_callback=disconnected, timeout=self.connect_timeout)
        try:
            await gatt.connect()
            await client._wait_for_mtu(gatt)
            await gatt.start_notify(p.CHAR_COMMAND, lambda _, d: on_notify(p.CHAR_COMMAND, bytes(d)))
            await gatt.start_notify(p.CHAR_IMAGE, lambda _, d: on_notify(p.CHAR_IMAGE, bytes(d)))
        except BaseException:
            await client._quietly_disconnect(gatt)
            raise
        self._gatt = gatt

    def _connected(self):
        if self._gatt is None:
            raise RelayError("link", "not connected to the device")
        return self._gatt

    def write_length(self) -> int:
        return client._write_size(self._connected())

    async def write(self, char: str, data: bytes, response: bool) -> None:
        await asyncio.wait_for(self._connected().write_gatt_char(char, data, response=response),
                               self.op_timeout)

    async def read(self, char: str) -> bytes:
        return bytes(await asyncio.wait_for(self._connected().read_gatt_char(char), self.op_timeout))

    async def disconnect(self) -> None:
        gatt, self._gatt = self._gatt, None
        if gatt is not None:
            await client._quietly_disconnect(gatt)


# --- the simulated device ---------------------------------------------------


@dataclass
class _Upload:
    slot: int
    length: int
    crc32: int
    crc16: int
    data: bytearray = field(default_factory=bytearray)
    packets: int = 0


class FakeDevice:
    """A simulated device (``--fake``) that behaves as observed on hardware (shared/PROTOCOL.md).

    It notifies ``05 00`` after connecting; answers ``01 02`` when a page already
    holds the announced image (same CRC32/CRC16; a page seeded through ``stored``
    has only a CRC32, which then decides alone); ``02 01`` when the data does not
    match the header's length/CRC32/CRC16 or does not start within
    ``data_start_timeout`` seconds of ``01 00`` (a new header replaces an upload
    still waiting for data); and does not answer at all for ``refresh_seconds``
    after the page on screen was replaced. Its pages survive reconnects.
    """

    fake = True
    address = "ULANI-FAKE"
    model = b"P7320E-B"
    firmware = b"v1.0.09"
    #: Obviously not a real device: a locally administered MAC and a made-up serial.
    mac = bytes.fromhex("020000000001")
    serial = b"FAKE00000001"

    def __init__(self, *, shown: int = 1, refresh_seconds: float = 40.0, data_start_timeout: float = 4.0,
                 write_length: int = 244, stored: Mapping[int, int] | None = None, battery: int = 4,
                 fail_after_packets: int | None = None):
        if shown not in p.USER_SLOTS:
            raise ValueError(f"shown must be 1-4, got {shown}")
        self.shown = shown
        self.refresh_seconds = refresh_seconds
        self.data_start_timeout = data_start_timeout
        self.battery = battery
        #: answer 02 01 after this many image packets of an upload (the device gave up early)
        self.fail_after_packets = fail_after_packets
        #: CRC32 of the image each page holds (0 = never written)
        self.stored = {slot: 0 for slot in p.USER_SLOTS}
        self.stored.update(stored or {})
        #: CRC16 of the image each page holds, None when unknown (never written or seeded by CRC32)
        self.stored_crc16: dict[int, int | None] = {slot: None for slot in p.USER_SLOTS}
        self.connected = False
        self.connects = 0
        self.writes: list[tuple[str, bytes]] = []
        self.log: list[str] = []  # "w" per image write, "r" per read, in order
        self._write_length = write_length
        self._refresh_until = 0.0
        self._upload: _Upload | None = None
        self._give_up: asyncio.TimerHandle | None = None
        self._on_notify: Notify | None = None
        self._on_disconnect: Disconnected | None = None

    @property
    def refreshing(self) -> bool:
        return time.monotonic() < self._refresh_until

    async def connect(self, address: str | None, scan_timeout: float,
                      on_notify: Notify, on_disconnect: Disconnected) -> None:
        if address is not None and address.upper() != self.address:
            raise RelayError("not_found",
                             f"no device with address {address} (the fake one is {self.address})")
        self._unlink()
        self._on_notify, self._on_disconnect = on_notify, on_disconnect
        self.connected = True
        self.connects += 1
        self._notify(p.CHAR_COMMAND, RSP_DEVICE_READY)

    def _require(self) -> None:
        if not self.connected:
            raise RelayError("link", "not connected to the device")

    def write_length(self) -> int:
        self._require()
        return self._write_length

    async def write(self, char: str, data: bytes, response: bool) -> None:
        self._require()
        data = bytes(data)
        self.writes.append((char, data))
        if char == p.CHAR_COMMAND:
            self._command(data)
        elif char == p.CHAR_IMAGE:
            if len(data) > self._write_length:
                raise RelayError("link", f"{len(data)}-byte write exceeds the link's {self._write_length}")
            self.log.append("w")
            self._data(data)

    async def read(self, char: str) -> bytes:
        self._require()
        self.log.append("r")
        return {p.CHAR_MODEL_NUMBER: self.model, p.CHAR_FIRMWARE_REVISION: self.firmware}[char]

    async def disconnect(self) -> None:
        self._unlink()

    def drop_link(self, reason: str = "the device dropped the link") -> None:
        """Simulate an unexpected disconnect (out of range, flat battery)."""
        callback = self._on_disconnect
        self._unlink()
        if callback is not None:
            callback(reason)

    def _unlink(self) -> None:
        self.connected = False
        self._on_notify = self._on_disconnect = None
        self._abandon_upload()

    def _notify(self, char: str, data: bytes) -> None:
        # Delivered on the next loop iteration, like a real notification.
        callback = self._on_notify

        def deliver() -> None:
            if callback is not None and self._on_notify is callback:
                callback(char, data)

        asyncio.get_running_loop().call_soon(deliver)

    def _command(self, data: bytes) -> None:
        if self.refreshing:
            return  # the panel refreshes: no reply at all, not even 01 01
        op = data[0]
        if op == p.OP_UNLOCK:
            reply = p.RSP_UNLOCK_OK if data == p.CMD_UNLOCK else bytes([p.OP_UNLOCK, 0x01])
        elif op == p.OP_BATTERY:
            reply = bytes([p.OP_BATTERY, self.battery])
        elif op == p.OP_GET_SLOT:
            reply = bytes([p.OP_GET_SLOT, self.shown]) + self.stored[self.shown].to_bytes(4, "big")
        elif op == p.OP_DEVICE_INFO:
            reply = bytes([p.OP_DEVICE_INFO]) + self.mac + self.serial
        elif op == p.OP_SHOW_SLOT and data[1:2] and data[1] in p.USER_SLOTS:
            self.shown = data[1]
            reply = p.RSP_SHOW_SLOT_OK
        elif op == p.OP_DISCONNECT:
            reply = bytes([p.OP_DISCONNECT, 0x00])
        elif op == p.OP_IMAGE_HEADER and len(data) == 13 and data[5] in p.USER_SLOTS:
            reply = self._header(data)
        else:
            return  # unknown, malformed or a slot outside 1-4: ignored
        self._notify(p.CHAR_COMMAND, reply)

    def _header(self, data: bytes) -> bytes:
        self._abandon_upload()
        slot, crc32, crc16 = data[5], int.from_bytes(data[7:11], "big"), int.from_bytes(data[11:13], "big")
        if self.stored[slot] == crc32 and self.stored_crc16[slot] in (None, crc16):
            return p.RSP_HEADER_SAME_IMAGE
        length = int.from_bytes(data[1:5], "big")
        self._upload = _Upload(slot, length, crc32, crc16)
        loop = asyncio.get_running_loop()
        self._give_up = loop.call_later(self.data_start_timeout, self._finish, False)
        return p.RSP_HEADER_OK

    def _data(self, data: bytes) -> None:
        upload = self._upload
        if upload is None or self.refreshing:
            return
        if self._give_up is not None:  # the data started in time
            self._give_up.cancel()
            self._give_up = None
        upload.data += data
        upload.packets += 1
        if upload.packets == self.fail_after_packets:
            self._finish(False)
        elif len(upload.data) >= upload.length:
            raw = bytes(upload.data)
            self._finish(len(raw) == upload.length and p.crc32(raw) == upload.crc32
                         and p.crc16(raw) == upload.crc16)

    def _finish(self, ok: bool) -> None:
        upload = self._upload
        self._abandon_upload()
        if upload is None:
            return
        if ok:
            self.stored[upload.slot], self.stored_crc16[upload.slot] = upload.crc32, upload.crc16
            if upload.slot == self.shown:
                self._refresh_until = time.monotonic() + self.refresh_seconds
        self._notify(p.CHAR_IMAGE, p.RSP_DATA_OK if ok else p.RSP_DATA_FAIL)

    def _abandon_upload(self) -> None:
        self._upload = None
        if self._give_up is not None:
            self._give_up.cancel()
            self._give_up = None


# --- the relay --------------------------------------------------------------


def _encode(message: Mapping[str, Any]) -> bytes:
    return json.dumps(message, separators=(",", ":")).encode() + b"\n"


def _error(rid: Any, e: BaseException) -> dict:
    return {"id": rid, "ok": False, "error": str(e) or type(e).__name__, "kind": error_kind(e)}


def _choice(req: Mapping[str, Any], key: str, options: Mapping[str, str]) -> str:
    value = req.get(key)
    if not isinstance(value, str) or value not in options:
        raise RelayError("protocol", f"{key} must be one of {', '.join(options)}, got {value!r}")
    return options[value]


def _hex(req: Mapping[str, Any], key: str) -> bytes:
    value = req.get(key)
    try:
        return bytes.fromhex(value)
    except (TypeError, ValueError):
        raise RelayError("protocol", f"{key} must be a hex string") from None


def _int(req: Mapping[str, Any], key: str, default: int, minimum: int) -> int:
    value = req.get(key, default)
    if not isinstance(value, int) or isinstance(value, bool) or value < minimum:
        raise RelayError("protocol", f"{key} must be an integer >= {minimum}, got {value!r}")
    return value


class _Client:
    """One TCP client: an ordered outbox and what its stream needs to know."""

    def __init__(self, writer: asyncio.StreamWriter):
        self.writer = writer
        self.outbox: asyncio.Queue[bytes | None] = asyncio.Queue()
        self.image_notifications = 0
        self.header_ok_at: float | None = None
        self.closing = False

    def send(self, message: Mapping[str, Any]) -> None:
        self.outbox.put_nowait(_encode(message))

    async def pump(self) -> None:
        with contextlib.suppress(OSError):  # the client went away
            while (data := await self.outbox.get()) is not None:
                self.writer.write(data)
                await self.writer.drain()


class Relay:
    """Serve one client at a time, forwarding its requests to ``backend``.

    ``address`` and ``scan_timeout`` are the defaults for a ``connect`` request.
    Requests run one after another, in order; notifications and progress go out
    as they happen. When the client disconnects the backend is disconnected.
    """

    def __init__(self, backend: Backend, *, address: str | None = None, scan_timeout: float = 30.0):
        self.backend = backend
        self.address = address
        self.scan_timeout = scan_timeout
        self._server: asyncio.base_events.Server | None = None
        self._client: _Client | None = None
        self._task: asyncio.Task | None = None
        self._idle = asyncio.Event()
        self._idle.set()
        self._ops = {
            "hello": self._hello, "connect": self._connect, "write": self._write, "read": self._read,
            "stream": self._stream, "write_length": self._write_length, "disconnect": self._disconnect,
        }

    @property
    def port(self) -> int:
        return self._server.sockets[0].getsockname()[1]

    @property
    def closing(self) -> bool:
        """The current client has gone and the relay is cleaning up after it."""
        return self._client is not None and self._client.closing

    async def start(self, host: str = DEFAULT_HOST, port: int = DEFAULT_PORT) -> None:
        self._server = await asyncio.start_server(self._serve, host, port, limit=LINE_LIMIT)

    async def serve_forever(self) -> None:
        await self._server.serve_forever()

    async def close(self) -> None:
        if self._server is None:
            return
        self._server.close()
        task = self._task
        if task is not None:
            if not self.closing:  # never interrupt a clean-up that is already running
                task.cancel()
            await asyncio.gather(task, return_exceptions=True)
        with contextlib.suppress(Exception):
            await self.backend.disconnect()
        await self._server.wait_closed()

    async def _claim(self) -> bool:
        if self.closing:
            with contextlib.suppress(asyncio.TimeoutError):
                await asyncio.wait_for(self._idle.wait(), HANDOVER_TIMEOUT)
        if self._client is not None:
            return False
        self._idle.clear()
        return True

    async def _serve(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        peer = writer.get_extra_info("peername")
        if not await self._claim():
            log.warning("refused %s: another client is connected", peer)
            busy = RelayError("link", "the relay is busy: another client is connected")
            with contextlib.suppress(Exception):
                writer.write(_encode(_error(None, busy)))
                await writer.drain()
            await _close(writer)
            return

        conn = self._client = _Client(writer)
        self._task = asyncio.current_task()
        log.info("client %s connected", peer)
        requests: asyncio.Queue[bytes] = asyncio.Queue()
        pump = asyncio.create_task(conn.pump())
        worker = asyncio.create_task(self._work(conn, requests))
        try:
            while True:
                try:
                    line = await reader.readline()
                except ValueError:  # longer than LINE_LIMIT
                    conn.send(_error(None, RelayError("protocol", f"request longer than {LINE_LIMIT} bytes")))
                    break
                except OSError:
                    break
                if not line:
                    break
                if line.strip():
                    requests.put_nowait(line)
        finally:
            # Client gone: stop what it started, then let go of the device.
            conn.closing = True
            worker.cancel()
            await asyncio.gather(worker, return_exceptions=True)
            try:
                await asyncio.wait_for(self.backend.disconnect(), HANDOVER_TIMEOUT)
            except Exception:
                log.exception("disconnecting the device failed")
            conn.outbox.put_nowait(None)
            with contextlib.suppress(Exception):
                await asyncio.wait_for(pump, 2.0)
            await _close(writer)
            self._client = self._task = None
            self._idle.set()
            log.info("client %s disconnected", peer)

    async def _work(self, conn: _Client, requests: asyncio.Queue[bytes]) -> None:
        while True:
            conn.send(await self._respond(conn, await requests.get()))

    async def _respond(self, conn: _Client, line: bytes) -> dict:
        rid = None
        try:
            try:
                req = json.loads(line)
            except ValueError:
                raise RelayError("protocol", "request is not valid JSON") from None
            if not isinstance(req, dict):
                raise RelayError("protocol", "request must be a JSON object")
            rid, name = req.get("id"), req.get("op")
            op = self._ops.get(name) if isinstance(name, str) else None
            if op is None:
                raise RelayError("protocol", f"unknown op {name!r}")
            result = await op(conn, req)
        except Exception as e:
            # Bluetooth and request errors are routine; anything else is a bug: show where.
            routine = isinstance(e, (UlaniError, OSError, asyncio.TimeoutError)) \
                or type(e).__module__.startswith("bleak")
            log.warning("request %r failed (%s): %s", rid, error_kind(e), str(e) or type(e).__name__,
                        exc_info=not routine)
            return _error(rid, e)
        return {"id": rid, "ok": True, **result}

    def _notified(self, conn: _Client, char: str, data: bytes) -> None:
        name = NOTIFYING.get(char)
        if name is None:
            return
        if name == "image":
            conn.image_notifications += 1
        elif data[:2] == p.RSP_HEADER_OK:
            conn.header_ok_at = time.monotonic()
        conn.send({"event": "notify", "char": name, "data": data.hex()})

    def _dropped(self, conn: _Client, reason: str) -> None:
        log.warning("device link lost: %s", reason)
        conn.send({"event": "disconnected", "reason": reason})

    # --- ops -------------------------------------------------------------

    async def _hello(self, conn: _Client, req: Mapping[str, Any]) -> dict:
        return {"relay": RELAY_VERSION, "fake": bool(self.backend.fake)}

    async def _connect(self, conn: _Client, req: Mapping[str, Any]) -> dict:
        address = req.get("address") or self.address
        if address is not None and not isinstance(address, str):
            raise RelayError("protocol", f"address must be a string or null, got {address!r}")
        scan_timeout = req.get("scan_timeout") or self.scan_timeout
        if not isinstance(scan_timeout, (int, float)) or isinstance(scan_timeout, bool) or scan_timeout <= 0:
            raise RelayError("protocol", f"scan_timeout must be a positive number, got {scan_timeout!r}")
        log.info("connecting to %s (scan %ss)", address or "the first device found", scan_timeout)
        await self.backend.connect(address, float(scan_timeout),
                                   lambda char, data: self._notified(conn, char, data),
                                   lambda reason: self._dropped(conn, reason))
        length = self.backend.write_length()
        log.info("connected, write length %d", length)
        return {"write_length": length}

    async def _write(self, conn: _Client, req: Mapping[str, Any]) -> dict:
        char = _choice(req, "char", WRITABLE)
        data = _hex(req, "data")
        if not data:
            raise RelayError("protocol", "data must not be empty")
        if char == p.CHAR_COMMAND and data[0] not in SAFE_OPCODES:
            raise RelayError("protocol", f"refused: the relay does not forward opcode 0x{data[0]:02x}")
        await self.backend.write(char, data, response=char == p.CHAR_COMMAND)
        return {}

    async def _read(self, conn: _Client, req: Mapping[str, Any]) -> dict:
        return {"data": (await self.backend.read(_choice(req, "char", READABLE))).hex()}

    async def _stream(self, conn: _Client, req: Mapping[str, Any]) -> dict:
        data = _hex(req, "data")
        chunk = _int(req, "chunk", p.MAX_CHUNK, minimum=1)
        flush_every = _int(req, "flush_every", 10, minimum=0)
        limit = self.backend.write_length()
        if chunk > limit:
            raise RelayError("protocol", f"chunk {chunk} exceeds the link's write length {limit}")
        rid, every = req.get("id"), flush_every or PROGRESS_EVERY
        started = time.monotonic()
        if conn.header_ok_at is not None:
            delay = started - conn.header_ok_at
            (log.warning if delay > LATE_STREAM else log.info)(
                "stream starts %.2fs after 01 00 (the device waits ~4s)", delay)
            conn.header_ok_at = None
        seen = conn.image_notifications  # one more means the device answered: stop
        sent, total = 0, len(data)
        for i, piece in enumerate(p.chunks(data, chunk), start=1):
            # Let pending notifications run even if the write below completes
            # without suspending (write-without-response often only queues).
            await asyncio.sleep(0)
            if conn.image_notifications != seen:
                break
            await self.backend.write(p.CHAR_IMAGE, piece, response=False)
            sent += len(piece)
            if flush_every and i % flush_every == 0 and sent < total:
                await self.backend.read(p.CHAR_FIRMWARE_REVISION)
            if i % every == 0 or sent == total:
                conn.send({"event": "progress", "id": rid, "sent": sent, "total": total})
        log.info("streamed %d of %d bytes in %.1fs", sent, total, time.monotonic() - started)
        return {"sent": sent}

    async def _write_length(self, conn: _Client, req: Mapping[str, Any]) -> dict:
        return {"write_length": self.backend.write_length()}

    async def _disconnect(self, conn: _Client, req: Mapping[str, Any]) -> dict:
        await self.backend.disconnect()
        log.info("disconnected on request")
        return {}


async def _close(writer: asyncio.StreamWriter) -> None:
    writer.close()
    try:
        await asyncio.wait_for(writer.wait_closed(), 2.0)
    except asyncio.TimeoutError:
        writer.transport.abort()  # the client stopped reading
    except Exception:
        pass


# --- command line -------------------------------------------------------------


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="python -m ulani_epaper.relay",
        description="Relay the device's Bluetooth link over TCP (JSON lines) for remote testing.")
    parser.add_argument("--host", default=DEFAULT_HOST,
                        help="address to listen on (default: %(default)s; reach it with ssh -L)")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT, help="TCP port (default: %(default)s)")
    parser.add_argument("--fake", action="store_true", help="simulate a device instead of using Bluetooth")
    parser.add_argument("--refresh-seconds", type=float, default=40.0, metavar="SEC",
                        help="fake only: silence after the page on screen is replaced (default: %(default)s)")
    parser.add_argument("--address", help="BLE address of the device (default: the first one found)")
    parser.add_argument("--scan-timeout", type=float, default=30.0, metavar="SEC",
                        help="default scan time for connect (default: %(default)s)")
    return parser


async def _run(args: argparse.Namespace) -> None:
    backend = FakeDevice(refresh_seconds=args.refresh_seconds) if args.fake else BleBackend()
    relay = Relay(backend, address=args.address, scan_timeout=args.scan_timeout)
    await relay.start(args.host, args.port)
    log.info("relay listening on %s:%d (%s)", args.host, relay.port,
             "fake device" if args.fake else "Bluetooth")
    try:
        await relay.serve_forever()
    finally:
        await relay.close()


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    logging.basicConfig(level=logging.INFO, stream=sys.stderr, format="%(asctime)s %(message)s",
                        datefmt="%H:%M:%S")
    try:
        asyncio.run(_run(args))
    except KeyboardInterrupt:
        return 130
    except OSError as e:  # e.g. the port is in use
        print(f"error: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
