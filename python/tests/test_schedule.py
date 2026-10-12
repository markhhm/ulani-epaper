import subprocess
import xml.etree.ElementTree as ET
from datetime import date

import pytest

from ulani_epaper import schedule
from ulani_epaper.protocol import UlaniError

NS = {"t": "http://schemas.microsoft.com/windows/2004/02/mit/task"}


def parse(xml):
    return ET.fromstring(xml)


def test_task_xml_has_one_daily_trigger_per_time():
    root = parse(schedule.task_xml(["06:00", "18:30"], r"C:\Program Files\U & I\Paperhue.exe", "--sync",
                                   today=date(2026, 10, 12)))
    starts = [e.text for e in root.findall("t:Triggers/t:CalendarTrigger/t:StartBoundary", NS)]
    assert starts == ["2026-10-12T06:00:00", "2026-10-12T18:30:00"]
    assert root.findall("t:Triggers/t:CalendarTrigger/t:ScheduleByDay/t:DaysInterval", NS)[0].text == "1"
    assert root.find("t:Actions/t:Exec/t:Command", NS).text == r"C:\Program Files\U & I\Paperhue.exe"
    assert root.find("t:Actions/t:Exec/t:Arguments", NS).text == "--sync"


def test_task_runs_as_the_signed_in_user_and_catches_up_missed_runs():
    root = parse(schedule.task_xml(["06:00"], "x.exe", "--sync", today=date(2026, 10, 12)))
    assert root.find("t:Principals/t:Principal/t:LogonType", NS).text == "InteractiveToken"  # Bluetooth + keyring
    assert root.find("t:Principals/t:Principal/t:RunLevel", NS).text == "LeastPrivilege"
    s = root.find("t:Settings", NS)
    assert s.find("t:StartWhenAvailable", NS).text == "true"
    assert s.find("t:DisallowStartIfOnBatteries", NS).text == "false"
    assert s.find("t:MultipleInstancesPolicy", NS).text == "IgnoreNew"
    assert s.find("t:ExecutionTimeLimit", NS).text == "PT30M"


def test_command_for_a_frozen_app(monkeypatch):
    monkeypatch.setattr(schedule.sys, "frozen", True, raising=False)
    monkeypatch.setattr(schedule.sys, "executable", r"C:\Apps\Paperhue.exe")
    assert schedule.command() == (r"C:\Apps\Paperhue.exe", "--sync")


def test_the_frozen_cli_schedules_the_windowless_app_next_to_it(monkeypatch, tmp_path):
    (tmp_path / "Paperhue.exe").write_bytes(b"")
    monkeypatch.setattr(schedule.sys, "frozen", True, raising=False)
    monkeypatch.setattr(schedule.sys, "executable", str(tmp_path / "ulani.exe"))
    assert schedule.command() == (str(tmp_path / "Paperhue.exe"), "--sync")


def test_the_frozen_cli_alone_schedules_itself(monkeypatch, tmp_path):
    monkeypatch.setattr(schedule.sys, "frozen", True, raising=False)
    monkeypatch.setattr(schedule.sys, "executable", str(tmp_path / "ulani.exe"))
    assert schedule.command() == (str(tmp_path / "ulani.exe"), "--sync")  # the CLI accepts --sync too


def test_command_for_a_python_install_has_no_console_window(monkeypatch, tmp_path):
    (tmp_path / "pythonw.exe").write_bytes(b"")
    monkeypatch.delattr(schedule.sys, "frozen", raising=False)
    monkeypatch.setattr(schedule.sys, "executable", str(tmp_path / "python.exe"))
    assert schedule.command() == (str(tmp_path / "pythonw.exe"), "-m ulani_epaper.syncjob")


class FakeSchtasks:
    def __init__(self, returncode=0, stdout=""):
        self.calls, self.returncode, self.stdout = [], returncode, stdout

    def __call__(self, args, **kw):
        xml_arg = args[args.index("/xml") + 1] if "/create" in args else None  # /query ... /xml has no file
        self.calls.append((list(args), open(xml_arg, encoding="utf-16").read() if xml_arg else None))
        assert kw.get("capture_output") and kw.get("text") is not None
        assert kw.get("creationflags") == getattr(subprocess, "CREATE_NO_WINDOW", 0)  # no console flash
        return subprocess.CompletedProcess(args, self.returncode, self.stdout, "ERROR: boom")


@pytest.fixture
def windows(monkeypatch):
    monkeypatch.setattr(schedule.sys, "platform", "win32")


def test_install_registers_the_task_from_xml(windows, monkeypatch):
    run = FakeSchtasks()
    monkeypatch.setattr(schedule, "command", lambda: ("C:\\a.exe", "--sync"))
    schedule.install(["06:00", "12:00"], run=run, today=date(2026, 10, 12))
    (args, xml), = run.calls
    assert args[:4] == ["schtasks", "/create", "/tn", schedule.TASK_NAME] and "/f" in args
    assert len(parse(xml).findall("t:Triggers/t:CalendarTrigger", NS)) == 2


def test_install_reports_schtasks_errors(windows):
    with pytest.raises(UlaniError, match="boom"):
        schedule.install(["06:00"], run=FakeSchtasks(returncode=1), today=date(2026, 10, 12))


def test_remove(windows):
    run = FakeSchtasks()
    assert schedule.remove(run=run) is True
    assert run.calls[0][0] == ["schtasks", "/delete", "/tn", schedule.TASK_NAME, "/f"]
    assert schedule.remove(run=FakeSchtasks(returncode=1)) is False  # not installed


def test_status_reads_back_the_times_and_command(windows):
    xml = schedule.task_xml(["06:00", "21:15"], "C:\\a.exe", "--sync", today=date(2026, 10, 12))
    st = schedule.status(run=FakeSchtasks(stdout=xml))
    assert st == {"times": ["06:00", "21:15"], "command": "C:\\a.exe", "arguments": "--sync"}
    assert schedule.status(run=FakeSchtasks(returncode=1)) is None


def test_only_on_windows(monkeypatch):
    monkeypatch.setattr(schedule.sys, "platform", "linux")
    with pytest.raises(UlaniError, match="Windows"):
        schedule.install(["06:00"], run=FakeSchtasks())
