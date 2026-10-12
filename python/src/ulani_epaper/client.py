"""Async BLE session with the device."""

from __future__ import annotations

import asyncio
import contextlib
import enum
from contextlib import asynccontextmanager
from dataclasses import dataclass
from typing import AsyncIterator, Callable, Literal, Mapping

from . import protocol as p
from .protocol import UlaniError

__all__ = [
    "Calendar", "DeviceBusy", "NoReply", "PushEvent", "UlaniError", "UploadFailed", "UploadResult",
    "connect", "find", "scan",
]

Progress = Callable[[int, int], None]


class NoReply(UlaniError):
    """A command got no answer (the device ignores commands while refreshing)."""


class DeviceBusy(UlaniError):
    """The device stayed busy (refreshing) for longer than we were willing to wait."""


class UploadFailed(UlaniError):
    """The device rejected the uploaded image data (CRC mismatch etc.)."""


class UploadResult(enum.Enum):
    OK = "ok"
    #: The slot already holds an image with the same CRC; nothing was sent.
    UNCHANGED = "unchanged"


@dataclass(frozen=True)
class PushEvent:
    """Progress of :meth:`Calendar.push_pages`, one event per step.

    ``phase`` is ``start`` (about to upload ``slot``), ``sending`` (``sent`` of
    ``total`` bytes written), ``done`` / ``unchanged`` (that page finished),
    or ``refreshing`` (the page on screen was replaced; the panel now
    refreshes for ~40 s). ``index`` / ``count`` give the position in the push.
    """

    slot: int
    phase: Literal["start", "sending", "done", "unchanged", "refreshing"]
    index: int
    count: int
    sent: int = 0
    total: int = 0


class Calendar:
    """Protocol session on top of an already-connected bleak client.

    ``gatt`` only needs ``start_notify``, ``write_gatt_char``,
    ``read_gatt_char`` and ``mtu_size``, which keeps this class testable.
    """

    def __init__(self, gatt, *, flush_every: int = 10, chunk_delay: float = 0.0,
                 reply_timeout: float = 5.0, result_timeout: float = 90.0,
                 busy_retry_delay: float = 3.0):
        self._gatt = gatt
        #: Pause between attempts while the device is silent or busy.
        self.busy_retry_delay = busy_retry_delay
        self._shown: int | None = None  # page on screen, as last read with 0C
        self._refreshing = False  # we just replaced the page on screen
        #: Do a GATT read every N image packets. Windows queues
        #: write-without-response and, most likely, drops packets when the
        #: queue overflows; the read only completes once the queue has drained.
        self.flush_every = flush_every
        self.chunk_delay = chunk_delay
        self.reply_timeout = reply_timeout
        self.result_timeout = result_timeout
        self._cmd_replies: asyncio.Queue[bytes] = asyncio.Queue()
        self._img_replies: asyncio.Queue[bytes] = asyncio.Queue()

    @property
    def chunk_size(self) -> int:
        return max(20, min(p.MAX_CHUNK, _write_size(self._gatt)))

    async def start(self) -> None:
        await self._gatt.start_notify(p.CHAR_COMMAND, lambda _, d: self._cmd_replies.put_nowait(bytes(d)))
        await self._gatt.start_notify(p.CHAR_IMAGE, lambda _, d: self._img_replies.put_nowait(bytes(d)))
        await self.unlock()

    async def _await_reply(self, queue: asyncio.Queue[bytes], op: int, timeout: float) -> bytes:
        async def wait() -> bytes:
            while True:
                data = await queue.get()
                if data and data[0] == op:
                    return data

        try:
            return await asyncio.wait_for(wait(), timeout)
        except asyncio.TimeoutError:
            raise NoReply(f"no reply to opcode 0x{op:02x} within {timeout}s") from None

    async def command(self, payload: bytes) -> bytes:
        """Write a command and return the notification that answers it."""
        while not self._cmd_replies.empty():
            self._cmd_replies.get_nowait()
        await self._gatt.write_gatt_char(p.CHAR_COMMAND, payload, response=True)
        return await self._await_reply(self._cmd_replies, payload[0], self.reply_timeout)

    async def unlock(self) -> None:
        reply = await self.command(p.CMD_UNLOCK)
        if reply != p.RSP_UNLOCK_OK:
            raise UlaniError(f"unlock rejected: {reply.hex(' ')}")

    async def battery(self) -> p.Battery:
        return p.parse_battery(await self.command(p.CMD_BATTERY))

    async def current_slot(self) -> tuple[int, int]:
        slot, crc = p.parse_slot(await self.command(p.CMD_GET_SLOT))
        self._shown = slot
        return slot, crc

    async def device_info(self) -> p.DeviceInfo:
        return p.parse_device_info(await self.command(p.CMD_DEVICE_INFO))

    async def show(self, slot: int) -> None:
        """Switch the page on screen to ``slot`` (1-4)."""
        reply = await self.command(p.build_show_slot(slot))
        if reply != p.RSP_SHOW_SLOT_OK:
            raise UlaniError(f"show slot {slot} rejected: {reply.hex(' ')}")

    async def model(self) -> str:
        return bytes(await self._gatt.read_gatt_char(p.CHAR_MODEL_NUMBER)).decode(errors="replace")

    async def firmware(self) -> str:
        return bytes(await self._gatt.read_gatt_char(p.CHAR_FIRMWARE_REVISION)).decode(errors="replace")

    async def _when_ready(self, attempt, busy_timeout: float, what: str):
        """Run ``attempt()`` until it answers; retry while the device is silent.

        ``attempt`` returns a reply, or None to mean "busy, try again".
        """
        loop = asyncio.get_running_loop()
        deadline = loop.time() + busy_timeout
        while True:
            try:
                reply = await attempt()
            except NoReply:
                reply = None
            if reply is not None:
                return reply
            if loop.time() >= deadline:
                raise DeviceBusy(f"the device did not accept {what} within {busy_timeout:.0f}s "
                                 "(still refreshing?); try again in a minute")
            await asyncio.sleep(self.busy_retry_delay)

    async def upload(self, raw: bytes, slot: int, mode: int = p.DEFAULT_MODE,
                     progress: Progress | None = None, busy_timeout: float = 60.0) -> UploadResult:
        """Send a raw frame (see :func:`ulani_epaper.image.encode`) to ``slot``.

        While the panel refreshes (~40 s after the page on screen changed) the
        device does not answer at all; the header is resent until
        ``busy_timeout`` seconds have passed.
        """
        header = p.build_image_header(raw, slot, mode)

        async def attempt() -> bytes | None:
            await self.unlock()
            reply = await self.command(header)
            return None if reply == p.RSP_HEADER_BUSY else reply

        reply = await self._when_ready(attempt, busy_timeout, f"an image for page {slot}")
        if reply == p.RSP_HEADER_SAME_IMAGE:
            return UploadResult.UNCHANGED
        if reply != p.RSP_HEADER_OK:
            raise UlaniError(f"page {slot}: unexpected header reply: {reply.hex(' ')}")

        while not self._img_replies.empty():
            self._img_replies.get_nowait()
        sent, total = 0, len(raw)
        for i, chunk in enumerate(p.chunks(raw, self.chunk_size), start=1):
            # Let pending notifications run even if the write below completes
            # without suspending (write-without-response often only queues).
            await asyncio.sleep(0)
            if not self._img_replies.empty():
                break  # the device already answered (it gave up); stop streaming
            await self._gatt.write_gatt_char(p.CHAR_IMAGE, chunk, response=False)
            sent += len(chunk)
            if self.flush_every and i % self.flush_every == 0 and sent < total:
                await self._gatt.read_gatt_char(p.CHAR_FIRMWARE_REVISION)
            if progress:
                progress(sent, total)
            if self.chunk_delay:
                await asyncio.sleep(self.chunk_delay)

        result = await self._await_reply(self._img_replies, p.OP_IMAGE_DATA, self.result_timeout)
        if result != p.RSP_DATA_OK:
            raise UploadFailed(f"page {slot}: device reported failure: {result.hex(' ')}")
        if slot == self._shown:
            # The panel now refreshes for ~40 s and ignores every command.
            self._refreshing = True
        return UploadResult.OK

    async def push_pages(self, frames: Mapping[int, bytes],
                         progress: Callable[[PushEvent], None] | None = None,
                         busy_timeout: float = 60.0) -> dict[int, UploadResult]:
        """Upload several raw frames ``{slot: frame}`` in one connection.

        Only replacing the page on screen makes the panel refresh (and go
        silent for ~40 s), so that page is uploaded last; the others go first
        in ascending order. Returns each slot's :class:`UploadResult`.

        The push stops at the first page that fails; the raised UlaniError
        carries ``.slot`` (the failed page) and ``.results`` (pages already
        done), and its message starts with ``page N:``.
        """
        bad = [s for s in frames if s not in p.USER_SLOTS]
        if bad:
            raise ValueError(f"slots must be 1-4, got {bad}")
        emit = progress or (lambda event: None)

        async def read_shown() -> bytes | None:
            return await self.command(p.CMD_GET_SLOT)

        shown, _ = p.parse_slot(await self._when_ready(read_shown, busy_timeout, "a status query"))
        self._shown = shown
        order = sorted(s for s in frames if s != shown) + ([shown] if shown in frames else [])
        results: dict[int, UploadResult] = {}
        for index, slot in enumerate(order):
            frame = frames[slot]
            emit(PushEvent(slot, "start", index, len(order), 0, len(frame)))

            def on_progress(sent: int, total: int, slot=slot, index=index) -> None:
                emit(PushEvent(slot, "sending", index, len(order), sent, total))

            try:
                results[slot] = await self.upload(frame, slot, progress=on_progress, busy_timeout=busy_timeout)
            except UlaniError as e:
                e.slot, e.results = slot, dict(results)
                raise
            done = "unchanged" if results[slot] is UploadResult.UNCHANGED else "done"
            emit(PushEvent(slot, done, index, len(order), len(frame), len(frame)))
            if slot == shown and results[slot] is UploadResult.OK:
                emit(PushEvent(slot, "refreshing", index, len(order), len(frame), len(frame)))
        return results

    async def say_goodbye(self) -> None:
        """Tell the device we are done so it can go back to sleep (best effort).

        Skipped right after the page on screen was replaced: the device is
        refreshing and would ignore it, costing a full reply timeout.
        """
        if self._refreshing:
            return
        with contextlib.suppress(Exception):
            await self.command(p.CMD_DISCONNECT)


def _write_size(gatt) -> int:
    """Largest write-without-response payload the link allows right now.

    Take the larger of the characteristic's own value and MTU minus the ATT
    header: BlueZ always reports mtu_size 23, while bleak 0.22.0/0.22.1 on
    Windows can report a stale characteristic size of 20.
    """
    from_mtu = (gatt.mtu_size or 23) - p.ATT_HEADER
    services = getattr(gatt, "services", None)
    if services is not None:
        with contextlib.suppress(Exception):
            char = services.get_characteristic(p.CHAR_IMAGE)
            size = getattr(char, "max_write_without_response_size", None) if char else None
            if size:
                return max(size, from_mtu)
    return from_mtu


# --- bleak glue (not unit-tested; exercised against real hardware) ---------

async def find(address: str | None = None, timeout: float = 20.0):
    """Find a device by address, or the first one advertising nearby."""
    from bleak import BleakScanner

    if address:
        device = await BleakScanner.find_device_by_address(address, timeout=timeout)
    else:
        device = await BleakScanner.find_device_by_filter(
            lambda d, adv: p.ADVERTISED_SERVICE in adv.service_uuids
            or (adv.local_name or "").startswith("ULANI"),
            timeout=timeout,
        )
    if device is None:
        raise UlaniError("no e-paper device found (is Bluetooth on and the device nearby?)")
    return device


async def scan(timeout: float = 20.0) -> list[tuple[str, str, int]]:
    """Return (address, name, rssi) of devices in range."""
    from bleak import BleakScanner

    found = await BleakScanner.discover(timeout=timeout, return_adv=True)
    return sorted(
        ((d.address, adv.local_name or d.name or "", adv.rssi)
         for d, adv in found.values()
         if p.ADVERTISED_SERVICE in adv.service_uuids or (adv.local_name or "").startswith("ULANI")),
        key=lambda t: -t[2],
    )


async def _wait_for_mtu(gatt, timeout: float = 3.0) -> None:
    # On Windows the MTU exchange finishes ~1.5 s after connect.
    loop = asyncio.get_running_loop()
    deadline = loop.time() + timeout
    while loop.time() < deadline:
        if not gatt.is_connected:
            raise UlaniError("link dropped right after connecting")
        if _write_size(gatt) > 20:
            return
        await asyncio.sleep(0.1)


async def _quietly_disconnect(gatt) -> None:
    with contextlib.suppress(Exception):
        await gatt.disconnect()


@asynccontextmanager
async def connect(address: str | None = None, *, timeout: float = 30.0, attempts: int = 4,
                  retry_delay: float = 5.0, **kwargs) -> AsyncIterator[Calendar]:
    """``async with connect() as cal: ...`` - find, connect, unlock, clean up.

    The device must already be bonded with this computer (pair it once in
    the OS Bluetooth settings while it is in pairing mode). It advertises
    only sparsely to save battery and drops new links while the panel is
    refreshing (~40 s after an upload), so the whole setup is retried
    ``attempts`` times, ``retry_delay`` seconds apart. Extra keyword
    arguments go to :class:`Calendar`.
    """
    from bleak import BleakClient
    from bleak.exc import BleakError

    # asyncio.TimeoutError is not the builtin TimeoutError before Python 3.11
    retryable = (UlaniError, BleakError, OSError, asyncio.TimeoutError)
    last: BaseException | None = None
    for attempt in range(1, attempts + 1):
        gatt = None
        try:
            gatt = BleakClient(await find(address, timeout), timeout=timeout)
            await gatt.connect()
            await _wait_for_mtu(gatt)
            cal = Calendar(gatt, **kwargs)
            await cal.start()
            break
        except BaseException as e:
            if gatt is not None:
                await _quietly_disconnect(gatt)
            if not isinstance(e, retryable):
                raise
            last = e
            if attempt < attempts:
                await asyncio.sleep(retry_delay)
    else:
        raise UlaniError(f"could not connect after {attempts} attempts: {last!r}")

    try:
        yield cal
        await cal.say_goodbye()
    finally:
        await _quietly_disconnect(gatt)
