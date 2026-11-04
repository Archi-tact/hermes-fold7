---
name: fold7-phone
description: Control the user's Galaxy Fold7 (notifications, battery, clipboard, camera, location, SMS, screen taps/screenshots via ADB) through the audited `phone` bridge command.
version: 1.0.0
author: hermes-fold7
license: MIT
metadata:
  hermes:
    tags: [Android, Termux, Phone, Automation, Galaxy]
    related_skills: []
---

# Galaxy Fold7 phone bridge

The agent runs on the user's Galaxy Fold7 inside Termux (or a proot Debian inside Termux).
All phone features go through ONE command: `phone <action> [args...]`.

## Rules

- Never call `termux-*`, `adb`, or the bridge script directly. They are blocked by policy; use `phone`.
- Many actions are `confirm`: a dialog appears on the phone screen and the user must tap "yes" within 60s.
  If the result says `user did not approve`, do not retry the same request in this turn; tell the user.
- Run `phone help` first if unsure which actions exist and what their policy is.
- Output files (photos, screenshots, UI dumps) are written under `.phone/` inside the workspace;
  the JSON result gives the path relative to the workspace. Delete them when no longer needed.
- Never send SMS, place calls, or read contacts/SMS unless the user explicitly asked in this conversation.
- Text input via `adb-text` only supports ASCII. For Korean or other text: `phone clipboard-set "<text>"`,
  then long-press/paste via taps, or ask the user.

## Actions

| Action | Args | Notes |
|---|---|---|
| `help` | | lists actions and policy |
| `battery` | | JSON battery status |
| `notify` | TITLE TEXT | phone notification |
| `toast` / `tts` | TEXT | short toast / speak aloud |
| `vibrate`, `torch on\|off`, `brightness 0-255\|auto`, `volume [STREAM LEVEL]` | | device basics |
| `wifi-info` | | current Wi‑Fi info |
| `clipboard-get` / `clipboard-set` | [TEXT] | |
| `open-url` | URL | http(s) only |
| `share` | FILE | file must be inside workspace |
| `location` | | network location |
| `camera-photo` | [CAMERA_ID] | 0=back, 1=front |
| `contacts`, `sms-list [N]`, `sms-send NUMBER TEXT`, `call NUMBER` | | sensitive, confirm |
| `adb-status`, `adb-packages` | | needs Wireless debugging paired |
| `adb-launch` | PACKAGE | start an app |
| `adb-screenshot` | | PNG of current screen → inspect with vision |
| `adb-ui-dump` | | UI hierarchy XML (bounds for taps) |
| `adb-tap X Y`, `adb-swipe X1 Y1 X2 Y2 [MS]`, `adb-text TEXT`, `adb-key KEYCODE_*` | | screen control |
| `adb-setting-get` | system\|secure\|global KEY | read a setting |
| `settings` | | current values of common settings as JSON (dark, brightness, timeout, wifi, bluetooth, dnd, …) |
| `set NAME VALUE` | see below | change a setting directly — no screen taps, returns the value read back |

### Direct settings (`phone set`) — prefer this over tapping through the Settings app

| NAME | VALUE | Example |
|---|---|---|
| `dark` | on\|off | `phone set dark on` |
| `brightness` | 0-255 (turns auto off) | `phone set brightness 120` |
| `auto-brightness`, `rotate`, `stay-awake`, `dnd`, `battery-saver` | on\|off | `phone set dnd on` |
| `timeout` | seconds 15-1800 | `phone set timeout 60` |
| `font` | 0.8-1.5 | `phone set font 1.1` |
| `animations` | 0\|0.5\|1\|1.5\|2 | `phone set animations 0.5` |
| `volume` | media\|ring\|alarm\|notification\|call + 0-15 | `phone set volume media 7` |
| `wifi`, `bluetooth`, `mobile-data`, `airplane`, `location`, `nfc` | on\|off | `phone set bluetooth off` |
| `app-stop` | PACKAGE | force-stop an app (confirm) |

- `wifi`, `airplane`, `mobile-data`, `location`, `app-stop` need the user to approve on screen.
  Turning Wi‑Fi off or airplane mode on **disconnects wireless debugging**, so later `set`/`adb-*` calls fail until Wi‑Fi is back.
- Always check the returned `now` value; if it did not change, say so instead of claiming success.
- Use `phone settings` first when the user asks "what is it set to now".

## Screen automation loop

1. `phone adb-ui-dump` → read the XML, find the node's `bounds="[x1,y1][x2,y2]"`, tap its center.
2. Prefer UI dump over screenshot (cheaper, exact coordinates). Use `adb-screenshot` when the UI is a canvas/web view.
3. After each action, re-dump to verify state. Note: the Fold7 cover screen and the unfolded inner screen
   have different resolutions; always derive coordinates from a fresh dump.

## Scheduled automation

Cron jobs run headless: `confirm` actions will time out (no one taps the dialog). Only use `allow` actions in cron
jobs (e.g. `notify`, `battery`), and keep `approvals.cron_mode: deny`.
