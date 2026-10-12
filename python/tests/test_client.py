import asyncio

import pytest

from ulani_epaper import protocol as p
from ulani_epaper.client import (
    Calendar,
    DeviceBusy,
    NoReply,
    PushEvent,
    UlaniError,
    UploadFailed,
    UploadResult,
)


class FakeGatt:
    """Minimal stand-in for a connected bleak.BleakClient talking to a device."""

    def __init__(self, mtu=247, header_reply=p.RSP_HEADER_OK, data_reply=p.RSP_DATA_OK, silent=(),
                 stray=None, fail_after_packets=None, silent_headers=0, busy_headers=0, shown=3,
                 refresh_silence=False, fail_slots=(), quiet_after_refresh=0, same_slots=(),
                 show_reply=bytes([0x0B, 0x00])):
        #: after the page on screen is replaced, ignore every command (the panel refreshes)
        self.refresh_silence = refresh_silence
        #: after a panel refresh starts (page on screen replaced, or switched), ignore this many commands
        self.quiet_after_refresh = quiet_after_refresh
        self.quiet = 0
        self.refreshes = 0  # panel refreshes so far
        #: answer the image headers for these pages with "same image"
        self.same_slots = set(same_slots)
        self.show_reply = show_reply
        #: ("header", slot) for every answered image header and ("show", slot) for every switch, in order
        self.sequence: list[tuple[str, int]] = []
        self.refreshing = False
        #: answer 02 01 for the data of these pages
        self.fail_slots = set(fail_slots)
        self.current_slot = None
        #: ignore this many image headers (the device is refreshing and stays silent)
        self.silent_headers = silent_headers
        #: answer this many image headers with 01 01 (busy)
        self.busy_headers = busy_headers
        self.shown = shown  # page on screen, reported by 0C
        self.header_slots: list[int] = []  # slots of the headers that were answered 01 00
        self.mtu_size = mtu
        self.header_reply = header_reply
        self.data_reply = data_reply
        self.silent = set(silent)  # opcodes the device ignores
        #: unrelated notification sent on the same characteristic just before each real reply
        self.stray = stray
        #: report 02 01 after this many image packets (device gave up early)
        self.fail_after_packets = fail_after_packets
        self.dead = False  # link gone: every write raises
        self.packets = 0
        self.writes: list[tuple[str, bytes, bool]] = []
        self.log: list[str] = []  # "w" per image write, "r" per read, in order
        self.callbacks = {}
        self.expected = 0
        self.received = 0
        self.reads = {
            p.CHAR_MODEL_NUMBER: b"P7320E-B",
            p.CHAR_FIRMWARE_REVISION: b"v1.0.09",
        }

    async def start_notify(self, char, cb):
        self.callbacks[char] = cb

    async def read_gatt_char(self, char):
        self.log.append("r")
        return bytearray(self.reads[char])

    def _notify(self, char, data):
        asyncio.get_running_loop().call_soon(self.callbacks[char], None, bytearray(data))

    async def write_gatt_char(self, char, data, response=False):
        if self.dead:
            raise OSError("[WinError -2147023673] The operation was canceled by the user.")
        data = bytes(data)
        self.writes.append((char, data, response))
        if char == p.CHAR_COMMAND:
            op = data[0]
            if op in self.silent or self.refreshing:
                return
            if self.quiet:
                self.quiet -= 1
                return
            if op == p.OP_IMAGE_HEADER and self.silent_headers:
                self.silent_headers -= 1
                return
            if op == p.OP_IMAGE_HEADER and self.busy_headers:
                self.busy_headers -= 1
                self._notify(p.CHAR_COMMAND, p.RSP_HEADER_BUSY)
                return
            header_reply = self.header_reply
            if op == p.OP_IMAGE_HEADER:
                self.sequence.append(("header", data[5]))
                if data[5] in self.same_slots:
                    header_reply = p.RSP_HEADER_SAME_IMAGE
            if op == p.OP_IMAGE_HEADER and header_reply == p.RSP_HEADER_OK:
                self.header_slots.append(data[5])
                self.current_slot = data[5]
            reply = {
                p.OP_UNLOCK: p.RSP_UNLOCK_OK,
                p.OP_BATTERY: bytes([0x06, 0x04]),
                p.OP_GET_SLOT: bytes([0x0C, self.shown]) + bytes.fromhex("deadbeef"),
                p.OP_DEVICE_INFO: bytes.fromhex("0a112233445566") + b"SERIAL",
                p.OP_DISCONNECT: bytes([0x09, 0x00]),
                p.OP_SHOW_SLOT: self.show_reply,
                p.OP_IMAGE_HEADER: header_reply,
            }[op]
            if op == p.OP_IMAGE_HEADER:
                self.expected = int.from_bytes(data[1:5], "big")
                self.received = 0
            if self.stray is not None:
                self._notify(p.CHAR_COMMAND, self.stray)
            self._notify(p.CHAR_COMMAND, reply)
            if op == p.OP_SHOW_SLOT and reply == bytes([0x0B, 0x00]):
                self.sequence.append(("show", data[1]))
                if data[1] != self.shown:
                    self.shown = data[1]
                    self.refreshes += 1
                    self.quiet = self.quiet_after_refresh
        elif char == p.CHAR_IMAGE:
            self.log.append("w")
            self.packets += 1
            self.received += len(data)
            if self.fail_after_packets is not None and self.packets == self.fail_after_packets:
                self._notify(p.CHAR_IMAGE, p.RSP_DATA_FAIL)
            elif self.received == self.expected:
                if self.stray is not None:
                    self._notify(p.CHAR_IMAGE, self.stray)
                failed = self.current_slot in self.fail_slots
                self._notify(p.CHAR_IMAGE, p.RSP_DATA_FAIL if failed else self.data_reply)
                if not failed and self.current_slot == self.shown:
                    self.refreshes += 1
                    self.quiet = self.quiet_after_refresh
                    if self.refresh_silence:
                        self.refreshing = True

    def image_writes(self):
        return [d for c, d, _ in self.writes if c == p.CHAR_IMAGE]


def run(coro):
    return asyncio.run(coro)


async def _started(gatt, **kw):
    cal = Calendar(gatt, reply_timeout=0.5, result_timeout=0.5, **kw)
    await cal.start()
    return cal


def test_start_subscribes_and_unlocks():
    gatt = FakeGatt()
    run(_started(gatt))
    assert set(gatt.callbacks) == {p.CHAR_COMMAND, p.CHAR_IMAGE}
    assert gatt.writes[0] == (p.CHAR_COMMAND, p.CMD_UNLOCK, True)


def test_simple_queries():
    async def go():
        cal = await _started(FakeGatt())
        return (await cal.battery(), await cal.current_slot(), await cal.device_info(),
                await cal.model(), await cal.firmware())

    battery, slot, info, model, fw = run(go())
    assert battery == p.Battery(level=4, charging=False)
    assert slot == (3, 0xDEADBEEF)
    assert info.serial == "SERIAL"
    assert (model, fw) == ("P7320E-B", "v1.0.09")


def test_show_switches_displayed_slot():
    gatt = FakeGatt()

    async def go():
        await (await _started(gatt)).show(3)

    run(go())
    assert (p.CHAR_COMMAND, bytes([0x0B, 0x03]), True) in gatt.writes


def test_upload_happy_path():
    gatt = FakeGatt(mtu=103)
    raw = bytes(range(256)) * 3
    progress = []

    async def go():
        cal = await _started(gatt)
        return await cal.upload(raw, slot=2, progress=lambda s, t: progress.append((s, t)))

    assert run(go()) is UploadResult.OK
    header = [d for c, d, _ in gatt.writes if c == p.CHAR_COMMAND and d[0] == p.OP_IMAGE_HEADER]
    assert header == [p.build_image_header(raw, slot=2)]
    chunks = gatt.image_writes()
    assert b"".join(chunks) == raw
    assert max(map(len, chunks)) == 100  # mtu - ATT header
    assert all(resp is False for c, _, resp in gatt.writes if c == p.CHAR_IMAGE)
    assert progress[-1] == (len(raw), len(raw))


def test_upload_uses_read_barrier_for_flow_control():
    # Windows queues write-without-response and most likely drops on overflow;
    # a GATT read every N packets waits until the queue has drained.
    gatt = FakeGatt(mtu=23)  # 20-byte chunks

    async def go():
        cal = await _started(gatt, flush_every=3)
        gatt.log.clear()
        return await cal.upload(bytes(200), slot=1)  # 10 chunks

    assert run(go()) is UploadResult.OK
    assert "".join(gatt.log) == "wwwrwwwrwwwrw"


def test_flush_every_zero_disables_barrier():
    gatt = FakeGatt(mtu=23)

    async def go():
        cal = await _started(gatt, flush_every=0)
        gatt.log.clear()
        return await cal.upload(bytes(100), slot=1)

    run(go())
    assert "r" not in gatt.log


def test_upload_same_image_sends_no_data():
    gatt = FakeGatt(header_reply=p.RSP_HEADER_SAME_IMAGE)

    async def go():
        return await (await _started(gatt)).upload(b"\x11" * 10, slot=1)

    assert run(go()) is UploadResult.UNCHANGED
    assert gatt.image_writes() == []


def test_upload_busy_until_the_deadline_raises_device_busy():
    gatt = FakeGatt(header_reply=p.RSP_HEADER_BUSY)

    async def go():
        cal = _quick(gatt)
        await cal.start()
        return await cal.upload(b"\x11", slot=1, busy_timeout=0.2)

    with pytest.raises(DeviceBusy, match="^the device did not accept an image for page 1 "):
        run(go())
    assert gatt.image_writes() == []


def test_upload_data_failure():
    async def go():
        return await (await _started(FakeGatt(data_reply=p.RSP_DATA_FAIL))).upload(b"\x11" * 4, slot=1)

    with pytest.raises(UploadFailed):
        run(go())


@pytest.mark.parametrize("mtu, expected", [(23, 20), (100, 97), (517, p.MAX_CHUNK), (None, 20)])
def test_chunk_size_follows_mtu(mtu, expected):
    gatt = FakeGatt()
    gatt.mtu_size = mtu
    assert Calendar(gatt).chunk_size == expected


def test_command_without_reply_times_out():
    async def go():
        cal = await _started(FakeGatt(silent={p.OP_BATTERY}))
        await cal.battery()

    with pytest.raises(UlaniError):
        run(go())


def test_unrelated_notifications_are_skipped():
    # the stray "device ready" arrives AFTER the command is written and BEFORE
    # the real reply, so only the opcode filter can skip it
    gatt = FakeGatt(stray=bytes([0x05, 0x00]))

    async def go():
        cal = await _started(gatt)
        battery = await cal.battery()
        result = await cal.upload(bytes(100), slot=1)
        return battery, result

    battery, result = run(go())
    assert battery.level == 4
    assert result is UploadResult.OK


def test_command_timeout_is_a_noreply_error():
    async def go():
        cal = await _started(FakeGatt(silent={p.OP_BATTERY}))
        await cal.battery()

    with pytest.raises(NoReply):
        run(go())


def _quick(gatt, **kw):
    """A client with short timeouts so retry tests run fast."""
    cal = Calendar(gatt, reply_timeout=0.05, result_timeout=0.5, busy_retry_delay=0.01, **kw)
    return cal


@pytest.mark.parametrize("fake", [lambda: FakeGatt(silent_headers=3), lambda: FakeGatt(busy_headers=3)])
def test_upload_waits_while_the_panel_is_refreshing(fake):
    gatt = fake()

    async def go():
        cal = _quick(gatt)
        await cal.start()
        return await cal.upload(bytes(500), slot=1, busy_timeout=5)

    assert run(go()) is UploadResult.OK
    headers = [d for c, d, _ in gatt.writes if c == p.CHAR_COMMAND and d[0] == p.OP_IMAGE_HEADER]
    assert len(headers) == 4  # 3 ignored/busy + 1 accepted
    assert gatt.received == 500


def test_upload_gives_up_when_the_device_stays_silent():
    gatt = FakeGatt(silent_headers=10_000)

    async def go():
        cal = _quick(gatt)
        await cal.start()
        await cal.upload(bytes(10), slot=1, busy_timeout=0.3)

    with pytest.raises(DeviceBusy):
        run(go())


@pytest.mark.parametrize("shown, slots, order", [
    (2, [1, 2, 3, 4], [1, 3, 4, 2]),   # page on screen goes last
    (4, [2, 4], [2, 4]),
    (3, [4, 1], [1, 4]),               # shown page not among them: ascending
    (1, [1], [1]),
])
def test_push_pages_uploads_the_shown_page_last(shown, slots, order):
    gatt = FakeGatt(shown=shown)

    async def go():
        cal = _quick(gatt)
        await cal.start()
        return await cal.push_pages({s: bytes([s]) * 300 for s in slots})

    results = run(go())
    assert gatt.header_slots == order
    assert results == {s: UploadResult.OK for s in slots}


def test_push_pages_reports_progress_per_page():
    gatt = FakeGatt(shown=2)
    events: list[PushEvent] = []

    async def go():
        cal = _quick(gatt)
        await cal.start()
        await cal.push_pages({1: bytes(500), 2: bytes(500)}, progress=events.append)

    run(go())
    phases = [(e.slot, e.phase) for e in events if e.phase != "sending"]
    assert phases == [(1, "start"), (1, "done"), (2, "start"), (2, "done"), (2, "refreshing")]
    sending = [e for e in events if e.phase == "sending"]
    assert sending and sending[-1].sent == sending[-1].total == 500
    assert {e.count for e in events} == {2} and [e.index for e in events if e.phase == "start"] == [0, 1]


def test_goodbye_is_skipped_while_the_panel_refreshes():
    import time

    gatt = FakeGatt(shown=2, refresh_silence=True)

    async def go():
        cal = Calendar(gatt, reply_timeout=1.0, result_timeout=0.5, busy_retry_delay=0.01)
        await cal.start()
        await cal.push_pages({1: bytes(100), 2: bytes(100)})
        started = time.monotonic()
        await cal.say_goodbye()
        return time.monotonic() - started

    assert run(go()) < 0.2  # no 1 s wait for an answer that cannot come
    assert (p.CHAR_COMMAND, p.CMD_DISCONNECT, True) not in gatt.writes


def test_goodbye_is_sent_when_the_panel_is_not_refreshing():
    gatt = FakeGatt(shown=2, refresh_silence=True)

    async def go():
        cal = _quick(gatt)
        await cal.start()
        await cal.push_pages({1: bytes(100)})  # page 2 stays on screen: no refresh
        await cal.say_goodbye()

    run(go())
    assert (p.CHAR_COMMAND, p.CMD_DISCONNECT, True) in gatt.writes


def test_push_failure_names_the_page_and_keeps_earlier_results():
    gatt = FakeGatt(shown=4, fail_slots={2})

    async def go():
        cal = _quick(gatt)
        await cal.start()
        await cal.push_pages({1: bytes(100), 2: bytes(100), 3: bytes(100), 4: bytes(100)})

    with pytest.raises(UploadFailed, match="page 2") as info:
        run(go())
    assert info.value.slot == 2
    assert info.value.results == {1: UploadResult.OK}
    assert gatt.header_slots == [1, 2]  # stops at the first failure


# --- push_pages(show=...): switch the display in the same connection ----------


def _push(gatt, frames, **kw):
    async def go():
        cal = _quick(gatt)
        await cal.start()
        results = await cal.push_pages(frames, busy_timeout=5, **kw)
        return cal, results

    return run(go())


@pytest.mark.parametrize("shown, slots, show, sequence", [
    # every page except the one on screen, then the switch, then the page that was on screen
    (2, [1, 2, 3, 4], 4, [("header", 1), ("header", 3), ("header", 4), ("show", 4), ("header", 2)]),
    (1, [1, 4], 4, [("header", 4), ("show", 4), ("header", 1)]),
    # the page on screen is not being replaced: switch at the end
    (3, [1, 4], 4, [("header", 1), ("header", 4), ("show", 4)]),
    # the page to show is not in this push: it is shown anyway
    (2, [1], 3, [("header", 1), ("show", 3)]),
    (2, [2], 3, [("show", 3), ("header", 2)]),
])
def test_push_pages_switches_the_display_with_one_refresh(shown, slots, show, sequence):
    gatt = FakeGatt(shown=shown, quiet_after_refresh=3)  # the device ignores 3 commands while refreshing
    cal, results = _push(gatt, {s: bytes([s]) * 300 for s in slots}, show=show)
    assert gatt.sequence[-len(sequence):] == sequence
    assert [s for s in gatt.sequence if s[0] == "show"] == [("show", show)]
    assert gatt.refreshes == 1 and gatt.shown == show
    assert results == {s: UploadResult.OK for s in slots}


def test_the_page_that_was_on_screen_waits_for_the_refresh():
    gatt = FakeGatt(shown=2, quiet_after_refresh=4)
    _, results = _push(gatt, {1: bytes(300), 2: bytes(300)}, show=1)
    assert results == {1: UploadResult.OK, 2: UploadResult.OK}
    assert gatt.header_slots == [1, 2] and gatt.refreshes == 1
    assert gatt.received == 300  # page 2 went through completely after the refresh


def test_an_unchanged_page_to_show_is_still_switched_to():
    gatt = FakeGatt(shown=1, same_slots={4})
    _, results = _push(gatt, {3: bytes(300), 4: bytes(300)}, show=4)
    assert results == {3: UploadResult.OK, 4: UploadResult.UNCHANGED}
    assert gatt.sequence[-3:] == [("header", 3), ("header", 4), ("show", 4)]
    assert gatt.refreshes == 1


@pytest.mark.parametrize("show", [2, None])
def test_showing_the_page_on_screen_is_the_usual_push(show):
    gatt = FakeGatt(shown=2)
    events: list[PushEvent] = []
    _push(gatt, {1: bytes(300), 2: bytes(300)}, show=show, progress=events.append)
    assert gatt.sequence[-2:] == [("header", 1), ("header", 2)]
    assert ("show", 2) not in gatt.sequence and gatt.refreshes == 1  # replacing page 2 refreshes the panel
    assert [e.phase for e in events if e.phase not in ("sending",)][-2:] == ["done", "refreshing"]


def test_switching_is_reported_as_its_own_step():
    gatt = FakeGatt(shown=2)
    events: list[PushEvent] = []
    _push(gatt, {1: bytes(300), 2: bytes(300), 3: bytes(300)}, show=3, progress=events.append)
    phases = [(e.slot, e.phase) for e in events if e.phase != "sending"]
    assert phases == [(1, "start"), (1, "done"), (3, "start"), (3, "done"), (3, "switching"),
                      (2, "start"), (2, "done")]  # page 2 is no longer on screen: no "refreshing"
    switching, = (e for e in events if e.phase == "switching")
    assert (switching.index, switching.count) == (2, 3)


def test_goodbye_is_skipped_after_switching():
    gatt = FakeGatt(shown=2)

    async def go():
        cal = _quick(gatt)
        await cal.start()
        await cal.push_pages({1: bytes(100)}, show=1)
        await cal.say_goodbye()

    run(go())
    assert (p.CHAR_COMMAND, p.CMD_DISCONNECT, True) not in gatt.writes


def test_a_rejected_switch_names_the_page_and_keeps_the_results():
    gatt = FakeGatt(shown=2, show_reply=bytes([0x0B, 0x01]))
    with pytest.raises(UlaniError, match="^page 4: switching the display was rejected") as info:
        _push(gatt, {1: bytes(100), 2: bytes(100), 4: bytes(100)}, show=4)
    assert info.value.slot == 4 and info.value.results == {1: UploadResult.OK, 4: UploadResult.OK}
    assert gatt.header_slots == [1, 4]  # the page on screen was not touched


@pytest.mark.parametrize("show", [0, 5])
def test_push_pages_rejects_a_bad_page_to_show(show):
    gatt = FakeGatt()
    with pytest.raises(ValueError, match="1-4"):
        _push(gatt, {1: bytes(10)}, show=show)
    assert gatt.header_slots == []


def test_push_pages_rejects_bad_slots():
    async def go():
        cal = _quick(FakeGatt())
        await cal.start()
        await cal.push_pages({5: bytes(10)})

    with pytest.raises(ValueError):
        run(go())


def test_chunk_size_prefers_characteristic_write_size():
    # BlueZ always reports mtu_size 23; the characteristic knows the real size
    class Char:
        max_write_without_response_size = 180

    class Services:
        def get_characteristic(self, uuid):
            return Char() if uuid == p.CHAR_IMAGE else None

    gatt = FakeGatt(mtu=23)
    gatt.services = Services()
    assert Calendar(gatt).chunk_size == 180


def test_chunk_size_ignores_a_stale_characteristic_size():
    # bleak 0.22.0/0.22.1 on Windows report 20 even after the MTU grew
    class Char:
        max_write_without_response_size = 20

    class Services:
        def get_characteristic(self, uuid):
            return Char()

    gatt = FakeGatt(mtu=247)
    gatt.services = Services()
    assert Calendar(gatt).chunk_size == p.MAX_CHUNK


def test_upload_stops_streaming_when_device_gives_up():
    gatt = FakeGatt(mtu=23, fail_after_packets=5)

    async def go():
        cal = await _started(gatt, flush_every=0)
        await cal.upload(bytes(2000), slot=1)  # 100 packets of 20 bytes

    with pytest.raises(UploadFailed):
        run(go())
    assert gatt.packets < 10


def test_say_goodbye_is_best_effort_on_a_dead_link():
    gatt = FakeGatt()

    async def go():
        cal = await _started(gatt)
        gatt.dead = True
        await cal.say_goodbye()  # must not raise

    run(go())


# --- connect(): retries and cleanup, with bleak replaced by fakes ------------

class FakeBleakClient:
    """Stands in for bleak.BleakClient; behaviour per attempt comes from ``plan``."""

    plan: list = []
    instances: list = []

    def __init__(self, device, timeout=None):
        self.step = FakeBleakClient.plan.pop(0)
        self.disconnected = False
        self.gatt = FakeGatt()
        FakeBleakClient.instances.append(self)

    @property
    def mtu_size(self):
        return self.gatt.mtu_size

    @property
    def is_connected(self):
        return not self.disconnected

    async def connect(self):
        if self.step == "connect-timeout":
            raise asyncio.TimeoutError()  # what bleak raises on Python 3.10

    async def disconnect(self):
        self.disconnected = True

    async def start_notify(self, char, cb):
        if self.step == "notify-cancelled":
            raise OSError("[WinError -2147023673] operation cancelled")
        if self.step == "notify-typeerror":
            raise TypeError("programming error")
        await self.gatt.start_notify(char, cb)

    async def write_gatt_char(self, *a, **k):
        await self.gatt.write_gatt_char(*a, **k)

    async def read_gatt_char(self, char):
        return await self.gatt.read_gatt_char(char)


@pytest.fixture
def fake_bleak(monkeypatch):
    import bleak

    from ulani_epaper import client

    async def fake_find(address=None, timeout=0):
        return object()

    FakeBleakClient.plan = []
    FakeBleakClient.instances = []
    monkeypatch.setattr(bleak, "BleakClient", FakeBleakClient)
    monkeypatch.setattr(client, "find", fake_find)
    return FakeBleakClient


def _use(**kw):
    from ulani_epaper.client import connect

    async def go():
        async with connect(retry_delay=0, reply_timeout=0.5, **kw) as cal:
            return await cal.battery()

    return run(go())


def test_connect_retries_timeouts_and_link_drops(fake_bleak):
    fake_bleak.plan = ["connect-timeout", "notify-cancelled", "ok"]
    assert _use(attempts=3).level == 4
    assert [c.disconnected for c in fake_bleak.instances] == [True, True, True]


def test_connect_gives_up_after_attempts(fake_bleak):
    fake_bleak.plan = ["connect-timeout"] * 2
    with pytest.raises(UlaniError, match="after 2 attempts"):
        _use(attempts=2)
    assert all(c.disconnected for c in fake_bleak.instances)


def test_connect_cleans_up_and_reraises_unexpected_errors(fake_bleak):
    fake_bleak.plan = ["notify-typeerror", "ok"]
    with pytest.raises(TypeError):
        _use(attempts=3)
    assert len(fake_bleak.instances) == 1
    assert fake_bleak.instances[0].disconnected
