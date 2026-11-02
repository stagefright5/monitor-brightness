# Monitor Brightness

A small native macOS app for controlling an external monitor’s actual backlight. Built and verified with an HP M24f FHD connected to an Apple M3 Pro.

## Use

Build the app using the instructions below, then open `build/Monitor Brightness.app`. You can also copy it to your Applications folder. Drag the slider or choose 25%, 50%, 75%, or 100%. The sun icon in the menu bar opens the same controls. Closing the window keeps the menu-bar control running; Quit or Command-Q exits. Reopening the app brings its window back.

Refresh reads the current hardware value and rescans monitors. The app also rescans after sleep and display configuration changes. It does not change brightness on launch, automatically start at login, or request Accessibility/Screen Recording permissions.

## Build

Requires Apple Silicon, macOS 14 or later, and Apple Command Line Tools. No package manager or network is required once this source tree has been downloaded.

```sh
./build.sh
"build/Monitor Brightness.app/Contents/MacOS/MonitorBrightness" --test
"build/Monitor Brightness.app/Contents/MacOS/MonitorBrightness" --check
open "build/Monitor Brightness.app"
```

`--test` checks display parsing, process failures, and process timeouts without changing brightness. `--check` reads connected monitors. The app bundles its helper, so it can run independently of the source directory. It is locally ad-hoc signed, not notarized for distribution.

## Compatibility

Uses DDC/CI; enable this in the monitor’s on-screen menu if necessary. Only monitors that respond to brightness reads are offered. Some docks, adapters, picture modes, and displays block these commands. It does not control the MacBook’s built-in screen or apply software dimming. Values are scaled against the maximum reported by each monitor.

Writes are debounced and serialized off the UI thread, targeted by display UUID, and checked by reading the monitor back. Failed communication is shown in the app, with Refresh available to reconnect. Hardware brightness remains at its last setting when the app quits.

## Third-party source

The bundled MIT-licensed [m1ddc](https://github.com/waydabber/m1ddc) helper is vendored at commit `7339ceebb03f691b1eaeb8471dca301d215d19c8`. Its license is preserved in `vendor/m1ddc/LICENSE` and included in the app bundle. The helper uses macOS display interfaces that may change in future OS releases.
