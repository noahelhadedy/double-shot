# Contributing

Pull requests are welcome, especially new agents in `Sources/DoubleShot/Agents/AgentKind.swift`. Add their command lines to `Tests/DoubleShotTests/AgentKindTests.swift` too.

## Where things live

- `Core/AwakeEngine.swift` makes every decision: your own sessions, agents, the lid hold and the heat and battery cutoffs.
- `Core/LidHold.swift` installs and removes the sudoers rule, runs pmset, and starts the watchdog that turns sleep back on if the app dies.
- `Agents/AgentMonitor.swift` judges each agent session; `AgentKind.swift` is the catalog; `ProcessTable.swift` reads the process list with libproc.
- `UI/PanelView.swift` is the panel, `UI/SettingsView.swift` the Settings window, `UI/StatusItemController.swift` the menu bar mug.

## Two rules

- `Shell.run` waits on a semaphore, never `Process.waitUntilExit()`. That one spins the run loop, so timers fire in the middle of a state change and pmset gets called twice.
- Anything that disables sleep must be undone on every exit path: quit, signals (routed through `NSApp.terminate` in `main.swift`), and crashes (the watchdog plus the cleanup at launch).

## Build and test

`swift test` runs the unit tests. They need no password and never change how the Mac sleeps.

`scripts/build-app.sh` builds the universal app into `dist/`. Quit the installed copy first. Test the lid paths on battery with no external display: close the lid while an agent works, open it, let the agent finish, and check `pmset -g | grep -i sleepdisabled` reads 0 afterwards.

User-facing text is plain and human, with no em dashes.
