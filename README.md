# Monitor Brightness

Control your HP M24f FHD monitor's brightness from a Mac app or the menu bar. Drag the slider or choose a preset. The app changes the monitor's hardware backlight.

Coworkers with the same monitor can follow the steps below to build and install their own copy. The app detects each monitor, so no device IDs or code changes are needed.

## Before you start

You need:

- An Apple Silicon Mac, such as an M1, M2, or M3, running macOS 14 or later.
- An external monitor connected to the Mac. This app has been tested with an HP M24f FHD on an M3 Pro.
- Apple's Command Line Tools to build the app.

Check your Mac's chip and macOS version in Apple menu > About This Mac. Intel Macs, Windows, and Linux are not supported.

The same monitor can behave differently through a dock or adapter. The connection must support DDC/CI, the protocol the app uses to change brightness.

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

Your monitor's name and current brightness appear when it connects. Move the slider or click 25%, 50%, 75%, or 100%. If multiple compatible monitors are connected, select the one you want to adjust.

Click the sun icon in the menu bar to open the same controls. Closing the window leaves the menu-bar control running. Click Quit or press Command-Q while the app is active to exit.

Refresh rescans monitors and reads their current brightness. The app also reconnects after sleep or display changes. It does not change brightness on launch or start automatically at login. The monitor keeps its last brightness setting after you quit.

The app controls external monitors. It does not control the MacBook's built-in screen or request Accessibility or Screen Recording access.

## Update your copy

Quit the app first. Closing its window is not enough. Then run:

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

The software checks cover display parsing, failed commands, and command timeouts. They do not prove that a particular monitor connection supports brightness control.

## Uninstall

Quit the app, then move `~/Applications/Monitor Brightness.app` to Trash in Finder. You can also move `~/Developer/monitor-brightness` to Trash if you no longer need the source.

## Third-party source

The app bundles the MIT-licensed [m1ddc](https://github.com/waydabber/m1ddc) helper at commit `7339ceebb03f691b1eaeb8471dca301d215d19c8`. Its license is in `vendor/m1ddc/LICENSE` and in the app bundle. The helper uses macOS display interfaces that may change in future OS releases.
