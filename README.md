# Monitor Brightness

Control your external monitor's brightness from the Mac menu bar with a slider in a Control Center–style glass panel. The app changes the monitor's hardware backlight.

Coworkers with the same monitor can follow the steps below to build and install their own copy. The app detects each monitor, so no device IDs or code changes are needed.

## Before you start

You need:

- An Apple Silicon Mac, such as an M1, M2, or M3, running macOS 14 or later.
- An external monitor connected to the Mac. This app has been tested with an HP M24f FHD on an M3 Pro.
- Apple's Command Line Tools to build the app.

Check your Mac's chip and macOS version in Apple menu > About This Mac. Intel Macs, Windows, and Linux are not supported.

Other monitor brands can work too if they support brightness control over DDC/CI. The app checks each connected monitor; it does not depend on an HP model or a fixed device ID. The same monitor can behave differently through a dock or adapter. The connection must support DDC/CI, the protocol the app uses to change brightness.

## Build and install

### 1. Install Apple's Command Line Tools

Open Terminal and run:

```sh
xcode-select --install
```

Finish the installer before continuing. If Terminal says the tools are already installed, move to the next step. You do not need Homebrew or the full Xcode app. See [Apple's installation instructions](https://developer.apple.com/documentation/xcode/installing-the-command-line-tools/) if the installer fails.

### 2. Clone and build

Run these commands in Terminal:

```sh
mkdir -p "$HOME/Developer"
cd "$HOME/Developer"
git clone https://github.com/stagefright5/monitor-brightness.git
cd monitor-brightness
./build.sh
```

Wait for the command to finish. It prints `Built` followed by the path to `Monitor Brightness.app` when it succeeds. If the build reports an error, resolve it before continuing.

The repository includes the monitor-control helper's source. The build does not download dependencies.

### 3. Install and open

From the same Terminal window, run:

```sh
mkdir -p "$HOME/Applications"
ditto "build/Monitor Brightness.app" "$HOME/Applications/Monitor Brightness.app"
open "$HOME/Applications/Monitor Brightness.app"
```

This installs the app in your own Applications folder without `sudo`. Later, open Finder, choose Go > Go to Folder, enter `~/Applications`, and open Monitor Brightness.

Build on the Mac where you plan to use the app. The build signs the app locally. It does not produce a notarized installer for company-wide distribution.

## Use the app

Click the sun icon at the top right of your screen. A glass panel opens just below the menu bar and shows your monitor's name, its current brightness, and a slider. Click or drag the slider, scroll over it, or press the arrow keys to change brightness in 5% steps. Hold Option with an arrow key for 1% steps.

Press Escape, click outside the panel, or click the sun icon again to close it. Opening the panel does not switch apps, so the app you are using stays active. The app stays in the menu bar and does not appear in the Dock.

Click the ⋯ button in the panel for more options: choose a monitor when more than one compatible monitor is connected, Refresh, Launch at Login, and Quit.

Refresh rescans monitors and reads their current brightness. The app also reconnects after sleep or display changes. It does not change brightness on launch. The monitor keeps its last brightness setting after you quit.

The app controls external monitors. It does not control the MacBook's built-in screen or request Accessibility or Screen Recording access.

## Launch at login

The installed app enables Launch at login the first time you open it. After you sign in to your Mac, the sun icon appears in the menu bar. The panel stays closed until you click it.

Choose Launch at Login from the panel's ⋯ menu to turn this off or on. If macOS needs approval, the panel shows a link to Login Items settings. Allow Monitor Brightness there to finish setup.

Install the app in `~/Applications` before enabling this setting. The app does not register a temporary build copy for automatic startup.

## Resource use

The app uses native macOS controls. It creates the panel when you open it and releases the panel and its mouse listeners when you close it. It does not poll monitors or run a background timer. The monitor-control helper runs only when a read or adjustment is needed.

The panel uses Liquid Glass on macOS 26 and later, and a translucent material on earlier versions. Like Control Center, the glass materializes when the panel opens and dissolves when it closes, on spring timing measured from Control Center. Clicking the sun icon while the panel dissolves brings it back. The slider eases to new values. The panel shows the last known brightness right away while it re-reads the monitor. If Reduce Motion is enabled in macOS, the panel fades without movement and the slider changes without animation.

## Update your copy

Click the sun icon, then choose Quit from the ⋯ menu first. Closing the panel is not enough. Then run:

```sh
cd "$HOME/Developer/monitor-brightness"
git pull --ff-only
./build.sh
```

After the build succeeds, install and reopen it:

```sh
ditto "build/Monitor Brightness.app" "$HOME/Applications/Monitor Brightness.app"
open "$HOME/Applications/Monitor Brightness.app"
```

## Troubleshooting

If the app cannot find your monitor:

1. Check that the monitor is powered on and connected.
2. Use the monitor's physical buttons to open its settings. Enable DDC/CI if that option is available.
3. Try connecting the monitor directly to the Mac if you use a dock or adapter.
4. Click Refresh in the app.

If brightness does not change, check whether the monitor's picture mode locks brightness. The app reads the value back after each adjustment and reports communication failures.

If the build cannot find `swiftc`, `clang`, or `make`, check the Command Line Tools installation in step 1.

To run software checks without changing brightness:

```sh
cd "$HOME/Developer/monitor-brightness"
"build/Monitor Brightness.app/Contents/MacOS/MonitorBrightness" --test
```

To read the connected monitors' brightness from Terminal:

```sh
"build/Monitor Brightness.app/Contents/MacOS/MonitorBrightness" --check
```

The software checks cover display parsing, failed commands, command timeouts, and panel placement on multiple screen layouts. They do not prove that a particular monitor connection supports brightness control.

## Uninstall

Turn off Launch at Login in the panel's ⋯ menu and quit the app, then move `~/Applications/Monitor Brightness.app` to Trash in Finder. You can also move `~/Developer/monitor-brightness` to Trash if you no longer need the source.

## Third-party source

The app bundles the MIT-licensed [m1ddc](https://github.com/waydabber/m1ddc) helper at commit `7339ceebb03f691b1eaeb8471dca301d215d19c8`. Its license is in `vendor/m1ddc/LICENSE` and in the app bundle. The helper uses macOS display interfaces that may change in future OS releases.

The build draws the app icon at each required size using `Tools/generate-icon.swift`. The menu bar uses a monochrome sun symbol that follows the system appearance.
