"""Sync the calendar pages at fixed times every day (Windows Task Scheduler).

The task runs as the signed-in user, only while they are signed in: the
sync needs their Bluetooth pairing and their calendar addresses in the
credential store. Runs missed while the PC was off or asleep are made up
when it is back ("start when available"). Remove it with ``ulani schedule
remove`` or in Task Scheduler (task "Paperhue Sync").
"""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from datetime import date
from pathlib import Path
from xml.sax.saxutils import escape

from .protocol import UlaniError

TASK_NAME = "Paperhue Sync"
_NS = {"t": "http://schemas.microsoft.com/windows/2004/02/mit/task"}


def command() -> tuple[str, str]:
    """(program, arguments) that run one sync, without a window where possible."""
    if getattr(sys, "frozen", False):
        # A packaged ulani.exe accepts --sync too, but prefer the windowed app
        # next to it: a console exe would flash a window at every scheduled time.
        app = Path(sys.executable).with_name("Paperhue.exe")
        return (str(app) if app.exists() else sys.executable), "--sync"
    exe = Path(sys.executable)
    pythonw = exe.with_name("pythonw.exe")
    return str(pythonw if pythonw.exists() else exe), "-m ulani_epaper.syncjob"


def task_xml(times: list[str], program: str, arguments: str, today: date | None = None) -> str:
    start = (today or date.today()).isoformat()
    triggers = "".join(
        f"<CalendarTrigger><StartBoundary>{start}T{t}:00</StartBoundary><Enabled>true</Enabled>"
        f"<ScheduleByDay><DaysInterval>1</DaysInterval></ScheduleByDay></CalendarTrigger>" for t in times)
    return f"""<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="{_NS['t']}">
  <RegistrationInfo><Description>Paperhue: updates the device's calendar and to-do pages from your calendar sources.</Description></RegistrationInfo>
  <Triggers>{triggers}</Triggers>
  <Principals><Principal id="Author"><LogonType>InteractiveToken</LogonType><RunLevel>LeastPrivilege</RunLevel></Principal></Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings><StopOnIdleEnd>false</StopOnIdleEnd><RestartOnIdle>false</RestartOnIdle></IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT30M</ExecutionTimeLimit>
  </Settings>
  <Actions Context="Author"><Exec><Command>{escape(program)}</Command><Arguments>{escape(arguments)}</Arguments></Exec></Actions>
</Task>
"""


def _schtasks(args: list[str], run) -> subprocess.CompletedProcess:
    if sys.platform != "win32":
        raise UlaniError("scheduled sync is only available on Windows (use cron or launchd elsewhere)")
    # CREATE_NO_WINDOW: no console flashes up from the desktop app, and
    # schtasks then writes in the OEM code page whatever the parent console uses.
    return run(["schtasks", *args], capture_output=True, text=True, errors="replace",
               encoding="oem" if os.name == "nt" else None,
               creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))


def install(times: list[str], run=subprocess.run, today: date | None = None) -> None:
    """Create or replace the task with one daily trigger per time ("HH:MM")."""
    program, arguments = command()
    fd, path = tempfile.mkstemp(suffix=".xml")
    try:
        with os.fdopen(fd, "w", encoding="utf-16") as f:
            f.write(task_xml(times, program, arguments, today))
        r = _schtasks(["/create", "/tn", TASK_NAME, "/xml", path, "/f"], run)
    finally:
        os.unlink(path)
    if r.returncode != 0:
        raise UlaniError(f"could not create the scheduled task: {(r.stderr or r.stdout).strip()}")


def remove(run=subprocess.run) -> bool:
    """Delete the task; False if there was none."""
    return _schtasks(["/delete", "/tn", TASK_NAME, "/f"], run).returncode == 0


def status(run=subprocess.run) -> dict | None:
    """{"times", "command", "arguments"} of the installed task, or None."""
    r = _schtasks(["/query", "/tn", TASK_NAME, "/xml"], run)
    if r.returncode != 0:
        return None
    root = ET.fromstring(r.stdout.lstrip("﻿").split("?>", 1)[-1])  # drop the UTF-16 declaration
    times = sorted(e.text[11:16] for e in root.findall("t:Triggers/t:CalendarTrigger/t:StartBoundary", _NS))
    exe = root.find("t:Actions/t:Exec", _NS)
    return {"times": times, "command": exe.findtext("t:Command", "", _NS),
            "arguments": exe.findtext("t:Arguments", "", _NS)}
