import asyncio
import queue
import threading

import pytest

from ulani_epaper.client import PushEvent
from ulani_epaper.gui_model import BleWorker, describe, parse_times


@pytest.mark.parametrize("text, times", [
    ("06:00, 12:00, 18:00", ["06:00", "12:00", "18:00"]),
    ("18:00，7:30、12:00 7:30", ["07:30", "12:00", "18:00"]),
    ("  23:59 ", ["23:59"]),
    ("１８：００、７：３０", ["07:30", "18:00"]),  # full-width, as a Chinese IME types it
])
def test_parse_times(text, times):
    assert parse_times(text) == times


@pytest.mark.parametrize("text", ["", " , ", "7pm", "24:00", "12:60", "12", "1200", "٠٧:٣٠"])
def test_parse_times_rejects(text):
    with pytest.raises(ValueError):
        parse_times(text)


@pytest.mark.parametrize("event, text, percent", [
    (PushEvent(2, "start", 0, 4, 0, 1000), "準備傳送（1/4）", 0),
    (PushEvent(2, "sending", 0, 4, 250, 1000), "傳送中 25%", 25),
    (PushEvent(2, "done", 0, 4, 1000, 1000), "完成", 100),
    (PushEvent(2, "unchanged", 0, 4, 1000, 1000), "已是這張照片，略過", 100),
    (PushEvent(2, "refreshing", 3, 4, 1000, 1000), "完成（畫面約需 40 秒刷新）", 100),
    (PushEvent(2, "switching", 3, 4), "切換顯示這一頁（畫面約需 40 秒刷新）", 100),
])
def test_describe_turns_push_events_into_tile_text(event, text, percent):
    assert describe(event) == (2, text, percent)


def test_worker_runs_coroutines_off_the_calling_thread_and_reports_back():
    results: queue.Queue = queue.Queue()
    worker = BleWorker()
    try:
        caller = threading.get_ident()

        async def job(report):
            report("progress", 1)
            await asyncio.sleep(0)
            return threading.get_ident()

        worker.submit(job, results.put)
        kinds = [results.get(timeout=5) for _ in range(2)]
        assert kinds[0] == ("progress", 1)
        assert kinds[1][0] == "done" and kinds[1][1] != caller
    finally:
        worker.close()


def test_worker_reports_errors_instead_of_crashing():
    results: queue.Queue = queue.Queue()
    worker = BleWorker()
    try:
        async def job(report):
            raise RuntimeError("boom")

        worker.submit(job, results.put)
        kind, err = results.get(timeout=5)
        assert kind == "error" and isinstance(err, RuntimeError)
    finally:
        worker.close()


def test_worker_close_cancels_a_running_job_and_lets_it_clean_up():
    cleaned = threading.Event()
    started = threading.Event()
    worker = BleWorker()

    async def long_push(report):
        try:
            started.set()
            await asyncio.sleep(60)
        finally:
            await asyncio.sleep(0)  # cleanup may await (e.g. disconnect)
            cleaned.set()

    worker.submit(long_push, lambda msg: None)
    assert started.wait(5)
    worker.close()
    assert cleaned.is_set()
    assert worker._loop.is_closed()


def test_worker_close_stops_and_closes_its_loop():
    worker = BleWorker()
    worker.close()
    assert worker._loop.is_closed()
    assert not worker._thread.is_alive()
    worker.close()  # idempotent


def test_worker_refuses_a_second_job_while_busy():
    results: queue.Queue = queue.Queue()
    release = threading.Event()
    worker = BleWorker()
    try:
        async def slow(report):
            while not release.is_set():
                await asyncio.sleep(0.01)

        assert worker.submit(slow, results.put) is True
        assert worker.busy
        assert worker.submit(slow, results.put) is False
        release.set()
        assert results.get(timeout=5)[0] == "done"
        assert not worker.busy
    finally:
        worker.close()
