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
- Turns Night Shift and True Tone on and off, and sets how warm Night Shift
  gets, without opening **System Settings**.
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

The script then offers to link the command line to `/usr/local/bin/ezdisplay`,
which needs an administrator password. Say no and everything still works: the
binary inside the bundle takes the same arguments. If something else already
owns that name, the script says so and leaves it alone.

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
- **Night Shift** and **True Tone** toggle those two settings. They sit below
  the per-display sections because they belong to the machine rather than to
  one display, and each appears only where the hardware offers it, so **True
  Tone** is absent unless a display has the sensor for it.

Change either from **System Settings** and the menu follows, so the tick always
matches the setting.

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
- **Warmth**, a slider for how warm Night Shift makes the screen. The tint
  follows the slider as you drag it, so you can see what you are choosing.
  Warmth is separate from the toggle, as it is in **System Settings**: setting
  it does not turn Night Shift on.

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
app when it gets them. The install script offers to link it to
`/usr/local/bin/ezdisplay`, so both of these run the same tool:

```bash
ezdisplay list
/Applications/EZDisplay.app/Contents/MacOS/EZDisplay list
```

| Command | What it does |
| --- | --- |
| `list` | List the attached displays and the mode each is running |
| `modes` | List the modes a display supports, narrowed by the `set` filters |
| `set` | Change resolution, scale, or refresh rate |
| `hdr on\|off` | Turn HDR on or off for one display |
| `mirror on\|off` | Turn mirroring on or off for the whole set of displays |
| `color list\|set <id>` | List the display's color modes, or apply one |
| `nightshift [on\|off\|warmth <0-100>]` | Show Night Shift, turn it on or off, or set its warmth |
| `truetone [on\|off]` | Show True Tone, or turn it on or off |
| `custom list\|add\|remove` | List, add, or remove a custom resolution |
| `restore` | Remove the display overrides EZDisplay created |
| `prefs [set <name> <value>]` | Show the app's settings, or change one |
| `help [command]` | Explain one command, or list them all |

Every command that takes a display works on the main one unless you name
another. `restore` is the exception: because it removes a system-wide file, it
insists you say which, so a bare `restore` is an error rather than a restore of
the main display. Give it `--display` or `--all`.

The options `set` and `modes` take:

| Option | Meaning |
| --- | --- |
| `-w`, `--width` | Width to switch to |
| `--height` | Height to switch to. No short form, because `-h` is help |
| `-s`, `--scale` | Scale, where `2.0` is HiDPI (default: current) |
| `-z`, `--hz` | Refresh rate (default: keep the current one) |

The options the other commands take, and where each one is accepted:

| Option | Meaning | Commands |
| --- | --- | --- |
| `-d`, `--display` | A display index, as `list` prints it, or a `vendor:product` pair | `modes`, `set`, `hdr`, `color`, `custom`, `restore` |
| `-f`, `--force` | Apply without asking for confirmation | `set`, `hdr`, `mirror`, `color` |
| `--all` | Every display EZDisplay has touched — disconnected ones included | `restore` |
| `--hidpi` | Add the resolution as a HiDPI mode | `custom add` |
| `--json` | Print what the command reports as JSON instead of as text | `list`, `modes`, `color list`, `custom list`, `prefs`, `nightshift`, `truetone` |

An option a command does not take is an error, not something ignored, so a
misplaced flag tells you rather than quietly changing nothing.

Anything you leave out of `set` comes from the mode the display is running, so
`--width` on its own changes the width and keeps the rest. Refresh rate is the
exception: ask for one and the switch fails when no mode offers it, leave it out
and the rate in force is kept where the new geometry supports it, and the
highest it does support is taken where it does not.

```bash
ezdisplay set --width 3008 --height 1692 --hz 120
ezdisplay hdr on --display 0x410c:0xc29f
ezdisplay modes --scale 2.0
```

### Custom resolutions

`custom` edits the same display-override file the Preferences window edits, so a
resolution added from either shows up in both. Adding or removing one needs an
administrator password, and the display picks the change up when it next
reconnects or when the machine restarts:

```bash
ezdisplay custom list
ezdisplay custom add --width 3008 --height 1692 --hidpi
ezdisplay custom remove --width 3008 --height 1692
```

A display can carry both a HiDPI and a standard entry at one size, and `remove`
drops both. That is why it takes no `--hidpi`: the flag would narrow nothing,
and a flag that looks like it filters and does not is worse than no flag.

To undo every custom resolution at once, use `restore` instead.

### Settings

`prefs` reads and writes the settings the menu bar app keeps:

| Preference | Value | What it does |
| --- | --- | --- |
| `show-standard` | `on`, `off` | Show standard (non-HiDPI) resolutions in the menu |
| `show-refresh-menu` | `on`, `off` | Show the **Refresh Rate** submenu |
| `curated-count` | A whole number, at least 1 | How many resolutions the menu lists before **More Resolutions** |
| `launch-at-login` | `on`, `off` | Start EZDisplay when you log in |

```bash
ezdisplay prefs
ezdisplay prefs set curated-count 8
ezdisplay prefs set show-standard off
```

A truth value can be written `on`, `off`, `true`, `false`, `yes`, `no`, `1`, or
`0`. Anything else is a typo, and is refused rather than read as `off`.

A running app reads the new value the next time it rebuilds its menu, which may
not be until the display set changes or the app restarts.

### Night Shift and True Tone

Both settings belong to the machine rather than to a display, which is why
neither command takes `--display`. macOS offers no way to warm one screen and
not another, so a flag that looked like it picked one would be a lie.

Called bare, each reports the state and exits `0`:

```bash
ezdisplay nightshift              # Night Shift is off, warmth 50%.
ezdisplay truetone                # True Tone is on.
ezdisplay nightshift on
ezdisplay truetone off
ezdisplay nightshift warmth 70
```

Warmth runs from `0`, the coolest, to `100`, the warmest, matching the slider
in **System Settings**. It is separate from the toggle, so setting it while
Night Shift is off changes how it looks the next time it comes on rather than
turning it on now — and the command says so.

A whole number outside `0` to `100` is refused rather than clamped, because
`warmth 700` is a typo for `70`, and clamping it would set the warmest there is
while reporting a change nobody asked for.

Not every machine has both. Where a setting is missing, the command says which
and exits `1`, so a script can tell "off" from "not here":

```text
True Tone is not available: no attached display has the sensor for it.
```

### Machine-readable output

Every command that reports something takes `--json`, which prints that one
value and nothing else on stdout. A command that lists prints an array of
objects:

```bash
ezdisplay list --json | jq -r '.[] | select(.hdrCapable) | .selector'
```

A command that reports a single state prints a single object instead, because
wrapping one state in an array would make every caller reach past an index that
is always `0`:

```bash
ezdisplay nightshift --json | jq -r .warmth
```

Either way the output is valid JSON, an empty list included, and the exit
status is the same one the text would have given: `ezdisplay modes --json` with
filters nothing matches prints `[]`, says why on stderr, and exits `1`.

`--json` is refused by the commands that change something, because there would
be no listing to render and taking the flag would promise output that never
arrives.

### Confirming a change

A change that can black out the screen is applied first and confirmed after,
because a display you cannot read is one you cannot answer a question on:

```text
2752x1152 @ 100Hz, scale 2.0. Keep it? [y/N] reverting in 14s
```

Only a deliberate `y` keeps it. The timeout, an empty line, Ctrl-C, and the
terminal going away all put the display back. Piped or redirected, where nobody
can answer, the change is applied and kept — so is `--force`.

The exit status says which happened: `0` the change was kept, `1` it failed, `2`
it was reverted.

## Uninstall

```bash
./uninstall
```

The script offers to remove EZDisplay's resolution overrides first, while the
binary that knows how to undo them is still installed. It then quits the app,
deletes the bundle, removes your preferences, and takes away the
`/usr/local/bin/ezdisplay` link if the install script put it there. Any backup
it took of a display's original settings stays in
`~/Library/Application Support/io.github.davidnoyes.ezdisplay/Backups`.

If you installed somewhere other than `/Applications`, set `EZDISPLAY_PATH` the
same way as for the install script.

## License

EZDisplay is distributed under the GNU General Public License v3.0. See
[LICENSE](LICENSE).
