"""Relay tests: real TCP on 127.0.0.1 (port 0), the simulated calendar behind it."""

import asyncio
import contextlib
import json
import re
import sys
from contextlib import asynccontextmanager

import pytest

from ulani_epaper import client
from ulani_epaper import protocol as p
from ulani_epaper.protocol import UlaniError
from ulani_epaper.relay import BleBackend, FakeDevice, Relay, RelayError, build_parser

UNLOCK_OK = {"event": "notify", "char": "command", "data": "0400"}


def run(coro):
    return asyncio.run(coro)


class Client:
    """Test side of the wire format: requests by id, events collected in order."""

    def __init__(self, reader, writer):
        self.reader, self.writer = reader, writer
        self.events: list[dict] = []
        self._notes: list[tuple[str, bytes]] = []  # notifications not yet consumed
        self._responses: dict = {}
        self._id = 0

    @classmethod
    async def open(cls, port):
        return cls(*await asyncio.open_connection("127.0.0.1", port))

    async def close(self):
        self.writer.close()
        with contextlib.suppress(Exception):
            await self.writer.wait_closed()

    async def _read_one(self) -> dict:
        line = await self.reader.readline()
        if not line:
            raise EOFError("the relay closed the connection")
        msg = json.loads(line)
        if "event" in msg:
            self.events.append(msg)
            if msg["event"] == "notify":
                self._notes.append((msg["char"], bytes.fromhex(msg["data"])))
        else:
            self._responses[msg["id"]] = msg
        return msg

    async def send_line(self, line: bytes):
        self.writer.write(line)
        await self.writer.drain()

    async def response(self, rid, timeout=10.0) -> dict:
        async def wait():
            while rid not in self._responses:
                await self._read_one()
            return self._responses.pop(rid)

        return await asyncio.wait_for(wait(), timeout)

    async def request(self, op, timeout=10.0, **fields) -> dict:
        self._id += 1
        await self.send_line(json.dumps({"id": self._id, "op": op, **fields}).encode() + b"\n")
        return await self.response(self._id, timeout)

    async def ok(self, op, **fields) -> dict:
        reply = await self.request(op, **fields)
        assert reply["ok"] is True, reply
        return reply

    async def next_notify(self, char, timeout=2.0) -> bytes:
        async def wait():
            while True:
                for i, (c, data) in enumerate(self._notes):
                    if c == char:
                        del self._notes[i]
                        return data
                await self._read_one()

        return await asyncio.wait_for(wait(), timeout)

    async def command(self, payload: bytes, timeout=2.0) -> bytes:
        """Write a command and return the next notification on the command characteristic."""
        await self.ok("write", char="command", data=payload.hex())
        return await self.next_notify("command", timeout)

    async def reply(self, payload: bytes, timeout=2.0) -> bytes:
        """Write a command and return its answer, skipping other opcodes (like the session)."""
        await self.ok("write", char="command", data=payload.hex())
        while (data := await self.next_notify("command", timeout))[0] != payload[0]:
            pass
        return data

    async def wait_event(self, name, timeout=2.0) -> dict:
        async def wait():
            while True:
                for event in self.events:
                    if event["event"] == name:
                        return event
                await self._read_one()

        return await asyncio.wait_for(wait(), timeout)

    async def connect(self, **fields) -> dict:
        reply = await self.ok("connect", **fields)
        assert await self.next_notify("command") == bytes([0x05, 0x00])  # device ready
        return reply

    def progress(self, rid) -> list[dict]:
        return [e for e in self.events if e["event"] == "progress" and e["id"] == rid]


@asynccontextmanager
async def running(backend=None, **options):
    """A relay on a free port in front of ``backend`` (default: a FakeDevice with ``options``)."""
    backend = backend if backend is not None else FakeDevice(**options)
    relay = Relay(backend)
    await relay.start("127.0.0.1", 0)
    try:
        yield relay, backend
    finally:
        await relay.close()


@asynccontextmanager
async def connected(backend=None, **options):
    """A relay, its fake calendar, and a client that is connected to it."""
    async with running(backend, **options) as (relay, fake):
        c = await Client.open(relay.port)
        try:
            await c.connect()
            yield relay, fake, c
        finally:
            await c.close()


async def upload(c, frame, page, *, chunk=230, flush_every=10):
    """Header, then stream; returns (header reply, stream response, result notification)."""
    reply = await c.command(p.build_image_header(frame, page))
    if reply != p.RSP_HEADER_OK:
        return reply, None, None
    stream = await c.ok("stream", data=frame.hex(), chunk=chunk, flush_every=flush_every)
    return reply, stream, await c.next_notify("image")


async def until(predicate, timeout=2.0):
    loop = asyncio.get_running_loop()
    deadline = loop.time() + timeout
    while not predicate():
        assert loop.time() < deadline, "condition not reached in time"
        await asyncio.sleep(0.01)


def frame_of(page: int) -> bytes:
    return bytes((page * 37 + i) & 0xFF for i in range(p.FRAME_BYTES))


# --- wire format ----------------------------------------------------------------


def test_hello_reports_the_fake_device():
    async def go():
        async with running() as (relay, _):
            c = await Client.open(relay.port)
            try:
                return await c.request("hello")
            finally:
                await c.close()

    assert run(go()) == {"id": 1, "ok": True, "relay": 1, "fake": True}


def test_connect_reports_the_write_length_then_device_ready():
    async def go():
        async with running(write_length=180) as (relay, fake):
            c = await Client.open(relay.port)
            try:
                reply = await c.request("connect", address=None, scan_timeout=30)
                await c.next_notify("command")
                return reply, c.events, fake.connected, await c.request("write_length")
            finally:
                await c.close()

    reply, events, is_connected, length = run(go())
    assert reply == {"id": 1, "ok": True, "write_length": 180}
    assert events[0] == {"event": "notify", "char": "command", "data": "0500"}
    assert is_connected
    assert length == {"id": 2, "ok": True, "write_length": 180}


def test_unlock_round_trip_is_notified():
    async def go():
        async with connected() as (_, fake, c):
            reply = await c.request("write", char="command", data="044e42")
            await c.next_notify("command")
            return reply, c.events, fake.writes

    reply, events, writes = run(go())
    assert reply == {"id": 2, "ok": True}
    assert UNLOCK_OK in events
    assert writes == [(p.CHAR_COMMAND, p.CMD_UNLOCK)]


def test_a_wrong_unlock_code_is_rejected():
    async def go():
        async with connected() as (_, _fake, c):
            return await c.command(bytes([0x04, 0x41, 0x41]))

    assert run(go()) == bytes([0x04, 0x01])


def test_queries_and_reads():
    async def go():
        async with connected(shown=2, battery=3, stored={2: 0xDEADBEEF}) as (_, _fake, c):
            return (await c.command(p.CMD_BATTERY), await c.command(p.CMD_GET_SLOT),
                    await c.command(p.CMD_DEVICE_INFO), await c.command(p.build_show_slot(4)),
                    await c.command(p.CMD_GET_SLOT), await c.command(p.CMD_DISCONNECT),
                    await c.ok("read", char="model_number"), await c.ok("read", char="firmware_revision"))

    battery, slot, info, show, slot_after, goodbye, model, firmware = run(go())
    assert p.parse_battery(battery) == p.Battery(level=3, charging=False)
    assert p.parse_slot(slot) == (2, 0xDEADBEEF)
    assert p.parse_device_info(info).serial.startswith("FAKE")
    assert show == p.RSP_SHOW_SLOT_OK
    assert p.parse_slot(slot_after) == (4, 0)
    assert goodbye == bytes([0x09, 0x00])
    assert bytes.fromhex(model["data"]) == b"P7320E-B"
    assert bytes.fromhex(firmware["data"]) == b"v1.0.09"


def test_a_full_frame_is_stored_with_progress_events():
    frame = frame_of(2)

    async def go():
        async with connected(shown=4) as (_, fake, c):
            fake.log.clear()
            result = await upload(c, frame, 2)
            again = await c.command(p.build_image_header(frame, 2))
            return result, c.progress(3), fake.log, fake.stored[2], again

    (header, stream, data), progress, log, stored, again = run(go())
    assert header == p.RSP_HEADER_OK
    assert stream == {"id": 3, "ok": True, "sent": p.FRAME_BYTES}
    assert data == p.RSP_DATA_OK
    assert stored == p.crc32(frame)
    # 835 chunks of 230 bytes: an event every 10 chunks, and one after the last chunk
    assert len(progress) == 84
    assert progress[0] == {"event": "progress", "id": 3, "sent": 2300, "total": p.FRAME_BYTES}
    assert progress[-1]["sent"] == p.FRAME_BYTES
    assert log.count("w") == 835 and log.count("r") == 83
    assert again == p.RSP_HEADER_SAME_IMAGE


@pytest.mark.parametrize("flush_every, log, sent", [
    (10, "w" * 10 + "r" + "w" * 10 + "r" + "w" * 5, [200, 400, 500]),
    (0, "w" * 25, [200, 400, 500]),  # no barrier; progress still every 10 chunks
    (5, ("w" * 5 + "r") * 4 + "w" * 5, [100, 200, 300, 400, 500]),
])
def test_stream_reads_the_firmware_revision_every_flush_every_chunks(flush_every, log, sent):
    frame = bytes(range(250)) * 2  # 25 chunks of 20 bytes

    async def go():
        async with connected() as (_, fake, c):
            await c.command(p.build_image_header(frame, 1))
            fake.log.clear()
            await c.ok("stream", data=frame.hex(), chunk=20, flush_every=flush_every)
            assert await c.next_notify("image") == p.RSP_DATA_OK
            return "".join(fake.log), [e["sent"] for e in c.progress(3)]

    assert run(go()) == (log, sent)


def test_stream_stops_when_the_calendar_gives_up():
    frame = bytes(2000)

    async def go():
        async with connected(fail_after_packets=5) as (_, fake, c):
            header, stream, data = await upload(c, frame, 1, chunk=20, flush_every=0)
            return stream, data, fake.log.count("w")

    stream, data, packets = run(go())
    assert data == p.RSP_DATA_FAIL
    assert stream["sent"] < len(frame)
    assert stream["sent"] == packets * 20 and packets < 10


def test_data_that_does_not_match_the_header_fails():
    async def go():
        async with connected() as (_, fake, c):
            await c.command(p.build_image_header(bytes(400), 1))
            await c.ok("stream", data=(bytes([1]) * 400).hex(), chunk=200)
            return await c.next_notify("image"), fake.stored[1]

    data, stored = run(go())
    assert data == p.RSP_DATA_FAIL
    assert stored == 0


def _flip(header: bytes, index: int) -> bytes:
    return header[:index] + bytes([header[index] ^ 0xFF]) + header[index + 1:]


@pytest.mark.parametrize("tamper", [
    pytest.param(lambda h: _flip(h, 7), id="crc32"),
    pytest.param(lambda h: _flip(h, 11), id="crc16"),
    pytest.param(lambda h: h[:1] + (300).to_bytes(4, "big") + h[5:], id="length"),  # 400 bytes arrive
])
def test_a_header_field_that_does_not_match_the_data_fails(tamper):
    frame = bytes(range(200)) * 2

    async def go():
        async with connected() as (_, fake, c):
            header = await c.command(tamper(p.build_image_header(frame, 1)))
            stream = await c.ok("stream", data=frame.hex(), chunk=200)
            return header, stream["sent"], await c.next_notify("image"), fake.stored[1]

    assert run(go()) == (p.RSP_HEADER_OK, len(frame), p.RSP_DATA_FAIL, 0)


def test_data_that_starts_in_time_may_take_longer_than_the_start_timeout():
    class Slow(FakeDevice):  # paced like a real Bluetooth stream
        async def write(self, char, data, response):
            await super().write(char, data, response)
            if char == p.CHAR_IMAGE:
                await asyncio.sleep(0.02)

    frame = bytes(range(250)) * 2  # 25 chunks of 20 bytes: about 0.5 s

    async def go():
        async with connected(Slow(data_start_timeout=0.2)) as (_, fake, c):
            loop = asyncio.get_running_loop()
            started = loop.time()
            _, stream, data = await upload(c, frame, 1, chunk=20)
            return stream["sent"], data, fake.stored[1], loop.time() - started

    sent, data, stored, took = run(go())
    assert (sent, data, stored) == (len(frame), p.RSP_DATA_OK, p.crc32(frame))
    assert took > 0.4  # well past data_start_timeout


def test_a_new_header_replaces_an_upload_still_waiting_for_data():
    frame = bytes([0x44]) * 400

    async def go():
        async with connected(data_start_timeout=0.5) as (_, fake, c):
            loop = asyncio.get_running_loop()
            first = await c.command(p.build_image_header(bytes(400), 1))
            started = loop.time()
            await asyncio.sleep(0.3)
            second = await c.command(p.build_image_header(frame, 2))
            await asyncio.sleep(max(0.0, started + 0.65 - loop.time()))  # past the first deadline only
            await c.ok("stream", data=frame.hex(), chunk=200)
            return first, second, await c.next_notify("image"), dict(fake.stored)

    first, second, data, stored = run(go())
    assert (first, second, data) == (p.RSP_HEADER_OK, p.RSP_HEADER_OK, p.RSP_DATA_OK)
    assert stored == {1: 0, 2: p.crc32(frame), 3: 0, 4: 0}


def test_data_must_start_soon_after_the_header():
    async def go():
        async with connected(data_start_timeout=0.2) as (_, fake, c):
            header = await c.command(p.build_image_header(bytes(400), 1))
            data = await c.next_notify("image", timeout=1.0)
            # the device gave up: late data is ignored and the page keeps its image
            await c.ok("stream", data=bytes(400).hex(), chunk=200)
            with pytest.raises(asyncio.TimeoutError):
                await c.next_notify("image", timeout=0.3)
            return header, data, fake.stored[1]

    assert run(go()) == (p.RSP_HEADER_OK, p.RSP_DATA_FAIL, 0)


def test_the_calendar_is_silent_while_the_page_on_screen_refreshes():
    async def go():
        async with connected(shown=2, refresh_seconds=0.6) as (_, _fake, c):
            loop = asyncio.get_running_loop()
            *_, other = await upload(c, bytes(400), 1, chunk=200)
            assert other == p.RSP_DATA_OK
            assert await c.command(p.CMD_UNLOCK) == p.RSP_UNLOCK_OK  # page 1 is not on screen
            *_, shown = await upload(c, bytes(400), 2, chunk=200)
            replaced = loop.time()
            with pytest.raises(asyncio.TimeoutError):  # no reply at all, not even 01 01
                await c.command(p.build_image_header(bytes([7]) * 400, 3), timeout=0.3)
            await asyncio.sleep(max(0.0, replaced + 0.65 - loop.time()))
            return shown, await c.command(p.CMD_UNLOCK)

    assert run(go()) == (p.RSP_DATA_OK, p.RSP_UNLOCK_OK)


def test_a_page_that_already_holds_the_image_answers_01_02():
    frame = bytes([0x11]) * 400

    async def go():
        async with connected(stored={3: p.crc32(frame)}) as (_, fake, c):
            same = await c.command(p.build_image_header(frame, 3))
            other = await c.command(p.build_image_header(frame, 4))
            await c.ok("stream", data=frame.hex(), chunk=200)
            stored = await c.next_notify("image")
            return same, other, stored, await c.command(p.build_image_header(frame, 4)), fake.log

    same, other, stored, again, log = run(go())
    assert (same, other, stored, again) == (
        p.RSP_HEADER_SAME_IMAGE, p.RSP_HEADER_OK, p.RSP_DATA_OK, p.RSP_HEADER_SAME_IMAGE)
    assert log == ["w", "w"]  # nothing was streamed for the matching pages


def test_a_page_holds_the_image_only_when_both_crcs_match():
    frame = bytes([0x33]) * 400

    async def go():
        async with connected() as (_, fake, c):
            *_, data = await upload(c, frame, 3, chunk=200)
            header = p.build_image_header(frame, 3)
            other_crc16 = await c.command(_flip(header, 12))  # same CRC32
            return data, other_crc16, await c.command(header), fake.stored[3]

    assert run(go()) == (p.RSP_DATA_OK, p.RSP_HEADER_OK, p.RSP_HEADER_SAME_IMAGE, p.crc32(frame))


def test_headers_for_other_slots_are_ignored():
    async def go():
        async with connected() as (_, _fake, c):
            with pytest.raises(asyncio.TimeoutError):  # a slot outside 1-4, e.g. 16
                await c.command(p.build_image_header(bytes(10), p.IGNORED_SLOT), timeout=0.2)

    run(go())


def test_the_fake_keeps_its_pages_across_connections():
    frame = bytes([0x22]) * 400

    async def go():
        async with running(shown=4) as (relay, fake):
            first = await Client.open(relay.port)
            await first.connect()
            *_, data = await upload(first, frame, 1, chunk=200)
            await first.close()
            await until(lambda: not fake.connected)
            second = await Client.open(relay.port)
            try:
                await second.connect()
                return data, await second.command(p.build_image_header(frame, 1)), fake.connects
            finally:
                await second.close()

    assert run(go()) == (p.RSP_DATA_OK, p.RSP_HEADER_SAME_IMAGE, 2)


# --- errors ---------------------------------------------------------------------


@pytest.mark.parametrize("request_, kind", [
    ({"op": "nope"}, "protocol"),
    ({"op": ["hello"]}, "protocol"),
    ({"op": "read", "char": {"x": 1}}, "protocol"),
    ({"op": "write", "char": "battery", "data": "0600"}, "protocol"),
    ({"op": "write", "char": "command", "data": "zz"}, "protocol"),
    ({"op": "write", "char": "command", "data": ""}, "protocol"),
    ({"op": "read", "char": "command"}, "protocol"),
    ({"op": "stream", "data": "00", "chunk": 0}, "protocol"),
    ({"op": "stream", "data": "00", "chunk": 245}, "protocol"),  # longer than the link allows
    ({"op": "stream", "data": "00", "flush_every": -1}, "protocol"),
    ({"op": "connect", "address": "AA:BB:CC:DD:EE:FF"}, "not_found"),
    ({"op": "connect", "scan_timeout": "soon"}, "protocol"),
])
def test_bad_requests_get_an_error_with_a_kind(request_, kind):
    async def go():
        async with connected() as (_, _fake, c):
            reply = await c.request(**request_)
            return reply, await c.request("hello")  # the connection survives errors

    reply, hello = run(go())
    assert reply["ok"] is False and reply["kind"] == kind and reply["error"]
    assert reply["id"] == 2
    assert hello["ok"] is True


@pytest.mark.parametrize("command", ["0300", "0e00", "1000", "ff00", "aabbccdd"])
def test_commands_the_library_never_sends_are_never_forwarded(command):
    # opcodes outside SAFE_OPCODES are refused before they reach the device
    async def go():
        async with connected() as (_, fake, c):
            return await c.request("write", char="command", data=command), fake.writes

    reply, writes = run(go())
    assert reply["ok"] is False and reply["kind"] == "protocol"
    assert writes == []


def test_malformed_lines_get_an_error_without_an_id():
    async def go():
        async with running() as (relay, _):
            c = await Client.open(relay.port)
            try:
                replies = []
                for line in (b"not json\n", b"[1, 2]\n", b"\xff\xfe\n"):
                    await c.send_line(line)
                    replies.append(await c.response(None))
                return replies, await c.request("hello")
            finally:
                await c.close()

    replies, hello = run(go())
    for reply in replies:
        assert reply["ok"] is False and reply["kind"] == "protocol" and reply["id"] is None
    assert hello["ok"] is True


@pytest.mark.parametrize("op, fields", [
    ("write", {"char": "command", "data": "044e42"}),
    ("read", {"char": "firmware_revision"}),
    ("stream", {"data": "00"}),
    ("write_length", {}),
])
def test_operations_need_a_connection(op, fields):
    async def go():
        async with running() as (relay, _):
            c = await Client.open(relay.port)
            try:
                return await c.request(op, **fields)
            finally:
                await c.close()

    reply = run(go())
    assert reply["ok"] is False and reply["kind"] == "link"


def test_timeouts_have_their_own_kind():
    class Unreachable(FakeDevice):
        async def connect(self, *args, **kwargs):
            raise asyncio.TimeoutError()

    async def go():
        async with running(Unreachable()) as (relay, _):
            c = await Client.open(relay.port)
            try:
                return await c.request("connect")
            finally:
                await c.close()

    reply = run(go())
    assert reply["ok"] is False and reply["kind"] == "timeout"


# --- links and clients ----------------------------------------------------------


def test_disconnect_op_closes_the_link_and_allows_a_reconnect():
    async def go():
        async with connected() as (_, fake, c):
            bye = await c.request("disconnect")
            after = (fake.connected, await c.request("write", char="command", data="0600"))
            await c.connect()
            return bye, after, fake.connects, c.events

    bye, (is_connected, write), connects, events = run(go())
    assert bye == {"id": 2, "ok": True}
    assert not is_connected and write["kind"] == "link"
    assert connects == 2
    assert not any(e["event"] == "disconnected" for e in events)  # we asked for it


def test_a_dropped_link_is_reported():
    async def go():
        async with connected() as (_, fake, c):
            fake.drop_link("out of range")
            return await c.wait_event("disconnected"), await c.request("read", char="model_number")

    event, read = run(go())
    assert event == {"event": "disconnected", "reason": "out of range"}
    assert read["ok"] is False and read["kind"] == "link"


def test_a_second_client_is_refused_while_one_is_connected():
    async def go():
        async with running() as (relay, _):
            first = await Client.open(relay.port)
            second = None
            try:
                await first.ok("hello")
                second = await Client.open(relay.port)
                refusal = json.loads(await asyncio.wait_for(second.reader.readline(), 2))
                eof = await asyncio.wait_for(second.reader.readline(), 2)
                return refusal, eof, await first.request("hello")
            finally:
                await first.close()
                if second:
                    await second.close()

    refusal, eof, still = run(go())
    assert refusal["id"] is None and refusal["ok"] is False and refusal["kind"] == "link"
    assert "busy" in refusal["error"]
    assert eof == b""
    assert still["ok"] is True


def test_client_eof_disconnects_the_calendar():
    async def go():
        async with running() as (relay, fake):
            c = await Client.open(relay.port)
            await c.connect()
            assert fake.connected
            await c.close()
            await until(lambda: not fake.connected)
            return fake.connected

    assert run(go()) is False


def test_client_eof_stops_a_running_stream():
    class Slow(FakeDevice):
        async def write(self, char, data, response):
            await super().write(char, data, response)
            if char == p.CHAR_IMAGE:
                await asyncio.sleep(0.01)

    async def go():
        async with running(Slow()) as (relay, fake):
            c = await Client.open(relay.port)
            await c.connect()
            await c.command(p.build_image_header(bytes(4000), 1))
            await c.send_line(json.dumps({"id": 9, "op": "stream", "data": bytes(4000).hex(),
                                          "chunk": 20}).encode() + b"\n")
            await until(lambda: fake.log.count("w") > 3)
            await c.close()
            await until(lambda: not fake.connected)
            written = fake.log.count("w")
            await asyncio.sleep(0.1)
            return written, fake.log.count("w")

    written, later = run(go())
    assert written == later < 200


def test_a_new_client_waits_for_the_previous_one_to_disconnect():
    class SlowToDisconnect(FakeDevice):
        async def disconnect(self):
            if self.connected:
                await asyncio.sleep(0.3)
            await super().disconnect()

    async def go():
        async with running(SlowToDisconnect()) as (relay, fake):
            first = await Client.open(relay.port)
            await first.connect()
            await first.close()
            await until(lambda: relay.closing)
            second = await Client.open(relay.port)
            try:
                hello = await second.request("hello")
                return hello, fake.connected
            finally:
                await second.close()

    hello, is_connected = run(go())
    assert hello["ok"] is True
    assert not is_connected


# --- the Bluetooth backend, with bleak replaced by the fake calendar ------------


class FakeBleak:
    """bleak.BleakClient stand-in that talks to a FakeDevice."""

    device: FakeDevice
    instances: list = []
    connect_error: BaseException | None = None

    def __init__(self, ble_device, disconnected_callback=None, *, timeout=30.0):
        self.disconnected_callback = disconnected_callback
        self.timeout = timeout
        self.handlers = {}
        self.is_connected = False
        self.mtu_size = 247
        self.disconnects = 0
        FakeBleak.instances.append(self)

    async def connect(self):
        if FakeBleak.connect_error is not None:
            raise FakeBleak.connect_error
        await FakeBleak.device.connect(None, 0, self._dispatch, self._dropped)
        self.is_connected = True

    def _dispatch(self, char, data):
        handler = self.handlers.get(char)  # 05 00 arrives before anyone subscribed
        if handler:
            handler(None, bytearray(data))

    def _dropped(self, reason):
        self.is_connected = False
        self.disconnected_callback(self)

    async def start_notify(self, char, callback):
        self.handlers[char] = callback

    async def write_gatt_char(self, char, data, response=None):
        await FakeBleak.device.write(char, bytes(data), response)

    async def read_gatt_char(self, char):
        return bytearray(await FakeBleak.device.read(char))

    async def disconnect(self):
        self.disconnects += 1
        if self.is_connected:
            self.is_connected = False
            await FakeBleak.device.disconnect()
            self.disconnected_callback(self)  # bleak calls it for our own disconnects too


@pytest.fixture
def fake_bleak(monkeypatch):
    import bleak

    searches = []

    async def fake_find(address=None, timeout=20.0):
        searches.append((address, timeout))
        return object()

    FakeBleak.device, FakeBleak.instances, FakeBleak.connect_error = FakeDevice(), [], None
    monkeypatch.setattr(bleak, "BleakClient", FakeBleak)
    monkeypatch.setattr(client, "find", fake_find)
    return searches


def test_ble_backend_drives_bleak(fake_bleak):
    frame = bytes(range(200)) * 3

    async def go():
        relay = Relay(BleBackend(), address="AA:BB:CC:DD:EE:FF", scan_timeout=12)
        await relay.start("127.0.0.1", 0)
        c = await Client.open(relay.port)
        try:
            hello = await c.request("hello")
            connect = await c.request("connect", address=None)
            unlock = await c.reply(p.CMD_UNLOCK)
            FakeBleak.device.log.clear()
            *_, data = await upload(c, frame, 2, chunk=100, flush_every=2)
            log = "".join(FakeBleak.device.log)
            model = await c.ok("read", char="model_number")
            await c.close()
            await until(lambda: not FakeBleak.device.connected)
            return hello, connect, unlock, data, log, model, c.events
        finally:
            await relay.close()

    hello, connect, unlock, data, log, model, events = run(go())
    assert hello["fake"] is False
    assert fake_bleak == [("AA:BB:CC:DD:EE:FF", 12)]
    assert connect == {"id": 2, "ok": True, "write_length": 244}
    assert unlock == p.RSP_UNLOCK_OK and data == p.RSP_DATA_OK
    assert log == "wwrwwrww"
    assert bytes.fromhex(model["data"]) == b"P7320E-B"
    assert FakeBleak.instances[0].timeout == 30.0
    assert FakeBleak.instances[0].disconnects >= 1
    assert not any(e["event"] == "disconnected" for e in events)


def test_ble_backend_reports_a_dropped_link(fake_bleak):
    async def go():
        relay = Relay(BleBackend())
        await relay.start("127.0.0.1", 0)
        c = await Client.open(relay.port)
        try:
            await c.ok("connect")
            FakeBleak.device.drop_link("gone")
            return await c.wait_event("disconnected"), await c.request("write", char="command", data="0600")
        finally:
            await c.close()
            await relay.close()

    event, write = run(go())
    assert event == {"event": "disconnected", "reason": "the device dropped the link"}
    assert write["ok"] is False and write["kind"] == "link"


def test_ble_backend_maps_not_found(monkeypatch, fake_bleak):
    async def nothing(address=None, timeout=20.0):
        raise UlaniError("no e-paper device found (is Bluetooth on and the device nearby?)")

    monkeypatch.setattr(client, "find", nothing)

    async def go():
        async with running(BleBackend()) as (relay, _):
            c = await Client.open(relay.port)
            try:
                return await c.request("connect")
            finally:
                await c.close()

    reply = run(go())
    assert reply["ok"] is False and reply["kind"] == "not_found"
    assert FakeBleak.instances == []


@pytest.mark.parametrize("error, kind", [(asyncio.TimeoutError(), "timeout"), (OSError("cancelled"), "link")])
def test_ble_backend_cleans_up_a_failed_connect(fake_bleak, error, kind):
    FakeBleak.connect_error = error

    async def go():
        async with running(BleBackend()) as (relay, _):
            c = await Client.open(relay.port)
            try:
                return await c.request("connect")
            finally:
                await c.close()

    reply = run(go())
    assert reply["ok"] is False and reply["kind"] == kind
    assert FakeBleak.instances[0].disconnects >= 1


# --- command line ---------------------------------------------------------------


def test_parser_defaults():
    args = build_parser().parse_args([])
    assert (args.host, args.port, args.fake, args.refresh_seconds, args.address, args.scan_timeout) == (
        "127.0.0.1", 8765, False, 40.0, None, 30.0)


def test_runs_as_a_module_without_bluetooth():
    # bleak is made unimportable: --fake must never touch it
    code = ("import runpy, sys; sys.modules['bleak'] = None; "
            "sys.argv = ['relay', '--fake', '--port', '0', '--refresh-seconds', '2']; "
            "runpy.run_module('ulani_epaper.relay', run_name='__main__')")

    async def go():
        proc = await asyncio.create_subprocess_exec(sys.executable, "-c", code,
                                                    stderr=asyncio.subprocess.PIPE)
        try:
            match = None
            while not match:
                line = await asyncio.wait_for(proc.stderr.readline(), 30)
                assert line, "the relay exited before listening"
                match = re.search(rb"listening on 127\.0\.0\.1:(\d+)", line)
            c = await Client.open(int(match.group(1)))
            try:
                hello = await c.request("hello")
                await c.connect()
                return hello, await c.command(p.CMD_UNLOCK)
            finally:
                await c.close()
        finally:
            proc.terminate()
            await proc.communicate()

    hello, unlock = run(go())
    assert hello["fake"] is True and unlock == p.RSP_UNLOCK_OK


def test_relay_error_is_a_ulani_error():
    e = RelayError("not_found", "nothing nearby")
    assert isinstance(e, UlaniError) and e.kind == "not_found" and str(e) == "nothing nearby"


def test_help_calls_the_hardware_a_device():
    text = build_parser().format_help()
    assert "simulate a device" in text and "calendar" not in text.lower()
