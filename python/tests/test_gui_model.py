import asyncio
import queue
import threading

import pytest

from ulani_epaper import image
from ulani_epaper.client import PushEvent
from ulani_epaper.gui_model import (MIN_BOX, BleWorker, crop_or_default, describe, move_box, move_crop, nudge_crop,
                                    parse_times, photo_to_view, resize_box, resize_crop, view_to_photo, zoom_crop,
                                    zoom_level)


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


# --- crop editing helpers ------------------------------------------------------

PHOTO = (2400, 1800)


def test_move_clamps_inside():
    crop = image.default_crop(*PHOTO)
    moved = move_crop(crop, 5, 5, PHOTO)
    assert moved[0] == pytest.approx(0.0)  # full width already: cannot go sideways
    assert moved[1] == pytest.approx(1 - crop[3])  # as far down as it goes
    assert move_crop(zoom_crop(crop, 2, PHOTO), -5, -5, PHOTO)[:2] == (0.0, 0.0)


def test_zoom_limits_and_level():
    crop = crop_or_default(None, PHOTO)
    assert crop == image.default_crop(*PHOTO) and zoom_level(crop, PHOTO) == pytest.approx(1.0)
    assert zoom_level(zoom_crop(crop, 2, PHOTO), PHOTO) == pytest.approx(2.0)
    assert zoom_level(zoom_crop(crop, 100, PHOTO), PHOTO) == pytest.approx(image.MAX_ZOOM)
    assert zoom_crop(crop, 0.1, PHOTO) == crop
    # zooming keeps the centre
    zoomed = zoom_crop(move_crop(crop, 0, -0.01, PHOTO), 2, PHOTO)
    assert zoomed[0] + zoomed[2] / 2 == pytest.approx(0.5)


@pytest.mark.parametrize("corner, fixed", [("se", (0, 0)), ("nw", (1, 1)), ("ne", (0, 1)), ("sw", (1, 0))])
def test_resize_keeps_shape_and_opposite_corner(corner, fixed):
    photo = (1600, 1000)
    crop = zoom_crop(image.default_crop(*photo), 2, photo)
    left, top, w, h = crop
    anchor = (left + fixed[0] * w, top + fixed[1] * h)
    # pointer at the dragged corner, pulled a bit towards the anchor
    x = left + (1 - fixed[0]) * w + (0.05 if fixed[0] else -0.05)
    y = top + (1 - fixed[1]) * h + (0.05 if fixed[1] else -0.05)
    out = resize_crop(crop, corner, x, y, photo)
    assert out[2] < w
    assert out[2] * photo[0] / (out[3] * photo[1]) == pytest.approx(800 / 480)
    assert (out[0] + fixed[0] * out[2], out[1] + fixed[1] * out[3]) == pytest.approx(anchor)
    image.check_crop(out, *photo)


def test_nudge_steps():
    crop = zoom_crop(image.default_crop(*PHOTO), 4, PHOTO)
    start = (0.4, 0.4, crop[2], crop[3])
    assert nudge_crop(start, "Right", False, PHOTO)[0] == pytest.approx(0.41)
    assert nudge_crop(start, "Left", True, PHOTO)[0] == pytest.approx(0.3)
    assert nudge_crop(start, "Down", False, PHOTO)[1] == pytest.approx(0.41)
    assert nudge_crop(start, "Up", True, PHOTO)[1] == pytest.approx(0.3)


def test_view_round_trip():
    view = (10, 20, 810, 620)
    crop = zoom_crop(image.default_crop(*PHOTO), 2, PHOTO)
    x0, y0, x1, y1 = photo_to_view(crop, PHOTO, view)
    assert (x0, y0) == (10 + round(crop[0] * 800), 20 + round(crop[1] * 600))
    left, top = view_to_photo(x0, y0, PHOTO, view)
    assert (left, top) == pytest.approx((crop[0], crop[1]), abs=1 / 600)
    assert view_to_photo(10, 20, PHOTO, view) == (0.0, 0.0) and view_to_photo(810, 620, PHOTO, view) == (1.0, 1.0)


@pytest.mark.parametrize("photo", [(4000, 300), (300, 4000), (120, 80)])
def test_extreme_photos(photo):
    default = image.default_crop(*photo)
    results = [
        crop_or_default(None, photo),
        zoom_crop(default, 4, photo), zoom_crop(default, 100, photo), zoom_crop(default, 0.01, photo),
        move_crop(default, 9, -9, photo), nudge_crop(default, "Right", True, photo),
    ]
    zoomed = zoom_crop(default, 100, photo)
    for corner, x, y in (("se", 0, 0), ("nw", 1, 1), ("ne", 0.5, 0.9), ("sw", 0.9, 0.1)):
        results += [resize_crop(default, corner, x, y, photo), resize_crop(zoomed, corner, x, y, photo)]
    for crop in results:
        image.check_crop(crop, *photo)
    if photo == (120, 80):
        assert zoom_crop(default, 4, photo) == default


# --- card text boxes (fractions of the screen) ------------------------------------------


def test_text_boxes_move_and_resize_but_stay_on_the_screen():
    box = (0.1, 0.2, 0.5, 0.3)
    assert move_box(box, 0.1, -0.1) == pytest.approx((0.2, 0.1, 0.5, 0.3))
    assert move_box(box, 2, 2) == pytest.approx((0.5, 0.7, 0.5, 0.3))  # as far as it goes, same size
    assert move_box(box, -2, -2) == (0.0, 0.0, 0.5, 0.3)
    assert resize_box(box, "se", 0.9, 0.9) == pytest.approx((0.1, 0.2, 0.8, 0.7))  # the opposite corner stays
    assert resize_box(box, "nw", 0.0, 0.0) == pytest.approx((0.0, 0.0, 0.6, 0.5))
    assert resize_box(box, "ne", 5, -5) == pytest.approx((0.1, 0.0, 0.9, 0.5))  # never off the screen
    assert resize_box(box, "se", 0.0, 0.0) == pytest.approx((0.1, 0.2, MIN_BOX, MIN_BOX))  # never smaller than this
    assert resize_box(box, "sw", 0.9, 0.9) == pytest.approx((0.6 - MIN_BOX, 0.2, MIN_BOX, 0.7))
