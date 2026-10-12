"""PyInstaller entry point for the desktop app (Paperhue.exe).

``Paperhue.exe --sync`` runs one calendar sync without a window; the
scheduled task (``ulani schedule install`` or 每日排程…) uses it.
``Paperhue.exe --selftest`` checks the bundle (fonts, calendar pages, iCal,
credential store) without Bluetooth or network and exits with 0 or 1; the
build script runs it.
"""

import sys

if __name__ == "__main__":
    if sys.argv[1:2] == ["--sync"]:
        from ulani_epaper.syncjob import main as sync_main

        sys.exit(sync_main())
    if sys.argv[1:2] == ["--selftest"]:
        from ulani_epaper.cli import main as cli_main

        sys.exit(cli_main(["selftest"]))
    from ulani_epaper.gui import main

    main()
