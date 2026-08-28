# EZDisplay

EZDisplay is a macOS menu bar app for changing what your displays do:
resolution, refresh rate, HDR, color mode, and mirroring. It reaches modes that
**System Settings** hides, and it can add scaled resolutions a display does not
advertise at all.

![The EZDisplay menu, open in the menu bar and listing resolutions for the
attached display](etc/screenshot.png)

## What it does

- Lists every resolution each attached display supports, not the handful
  **System Settings** shows.
- Marks which resolutions are HiDPI, and which can carry HDR at the refresh
  rate you pick.
- Switches refresh rate independently of resolution.
- Turns HDR on and off per display, and switches color mode where the display
  offers a choice.
- Turns display mirroring on and off.
- Adds custom scaled resolutions by writing a display override file, and
  removes them again later.
- Reverts a change automatically if you do not confirm it, so a mode that
  leaves the screen unreadable cannot strand you.

## Requirements

- Apple silicon. The project builds for `arm64` only.
- macOS 11.0 or later to run.
- Xcode, to build. There is no binary release.

## Install

To build and install into `/Applications`, run the install script from the
project root:

```bash
./install
```

To install somewhere else, set `EZDISPLAY_PATH` first:

```bash
EZDISPLAY_PATH=~/Applications ./install
```

EZDisplay has no window and no Dock icon. After it launches, look for the
display glyph in the menu bar.

## Use it

Click the menu bar icon to get a section for each attached display. Each
section shows the mode the display is running now, its native mode, and a short
list of recommended resolutions. Below those:

- **More Resolutions** holds everything else the display supports, split into
  **Retina (HiDPI)** and **Standard**.
- **Refresh Rate** switches rate without touching resolution.
- **HDR** toggles high dynamic range.
- **Display mirroring** toggles mirroring for the set.

After a resolution, HDR, or mirroring change, EZDisplay asks you to confirm.
Ignore the prompt and the display goes back to what it was, which is what saves
you when a mode turns out to be unusable.

### Preferences

Open **Preferences…** from the menu for the full picture: a table of every mode
per display with its type, refresh rate, and HDR support; the display's color
modes; and these options:

- **Show standard (non-HiDPI) resolutions in menu**
- **Show Refresh Rate submenu**
- **Recommended list length**, which sets how many resolutions the menu shows
  before **More Resolutions**
- **Launch EZDisplay at login**

**Edit Custom Resolutions…** adds resolutions the display does not advertise.
Give the resolution you want, not twice it: to get a HiDPI 1920×1080, add
1920×1080 with the HiDPI box checked.

### Custom resolutions and how to undo them

A custom resolution is a system-wide display override file under
`/Library/Displays/Contents/Resources/Overrides`, so adding one asks for an
administrator password, and it outlives the app. Two buttons in **Preferences**
undo them:

- **Restore Defaults…** removes the override for the selected display.
- **Restore All Displays…** removes every override EZDisplay created, including
  ones for displays that are not plugged in.

Both leave override files another tool created alone, and report how many they
skipped. A display may need a reboot before it goes back to its default
resolution.

## Command line

The binary inside the bundle takes arguments, and does not start the menu bar
app when it gets them:

```bash
/Applications/EZDisplay.app/Contents/MacOS/EZDisplay --displays
```

| Option | Meaning |
| --- | --- |
| `-l`, `--displays` | List the attached displays and the mode each is running |
| `-m`, `--modes` | List the modes the selected display supports |
| `-d`, `--display` | Select a display by index, counting from 0 (default: main) |
| `-w`, `--width` | Width to switch to |
| `-h`, `--height` | Height to switch to |
| `-s`, `--scale` | Scale, where `2.0` is HiDPI (default: current) |
| `-b`, `--bits` | Color depth (default: current) |
| `-r`, `--restore-all` | Remove every resolution override EZDisplay created, and exit |

Anything you leave out comes from the mode the display is running, so `--width`
on its own changes the width and keeps the rest.

## Uninstall

```bash
./uninstall
```

The script offers to remove EZDisplay's resolution overrides first, while the
binary that knows how to undo them is still installed. It then quits the app,
deletes the bundle, and removes your preferences. Any backup it took of a
display's original settings stays in
`~/Library/Application Support/io.github.davidnoyes.ezdisplay/Backups`.

If you installed somewhere other than `/Applications`, set `EZDISPLAY_PATH` the
same way as for the install script.

## License

EZDisplay is distributed under the GNU General Public License v3.0. See
[LICENSE](LICENSE).
