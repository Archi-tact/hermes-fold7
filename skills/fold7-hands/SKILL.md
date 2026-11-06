---
name: fold7-hands
description: Operate apps on the user's Galaxy Fold7 like a human assistant — read the on-screen UI tree and click, type, scroll, and launch apps through the Hermes Hands accessibility app, inside a user-approved, time-limited automation session.
version: 0.1.0
author: hermes-fold7
license: MIT
metadata:
  hermes:
    tags: [Android, Automation, Accessibility, Assistant, Galaxy]
    related_skills: [fold7-phone]
---

# Fold7 Hands — app automation

You control apps on the user's phone through `phone hands-*` commands. The Hermes Hands app
shows a blue frame over the screen during a session, blocks the user's touches except a center
⏸ button, highlights each target before acting, and acts slowly enough for the user to watch.

## Session rules

1. **Start a session first** with the exact apps you need:
   `phone hands-start <minutes> <pkg1,pkg2> "<short title in Korean>"`
   - The user approves it on the phone screen. If the result says `did not approve`, stop and tell the user.
   - Ask for the fewest apps and the shortest time that fit the task (max 60 min).
   - Banking, payment and authenticator apps are always refused. Do not try to work around it.
2. **Always end** with `phone hands-stop`, also when the task fails.
3. If a result says `"paused": true`, the user pressed ⏸. Do not retry actions in a loop:
   call `phone hands-status` every ~10 s (up to a few minutes). When `paused` is false, continue.
   If `session` is false, the user stopped the session: report what was done and stop.
4. If a result says `foreground app not in session`, the app you need was not approved:
   `phone hands-back` / `phone hands-launch <approved pkg>`, or ask the user to start a new session.
5. Never type passwords, OTPs or card numbers. Password fields are hidden (`"pw": true`) and refused.
   Ask the user to enter them during a pause.

## Finding and opening apps (do this first — never hunt through the home screen)

```
phone hands-apps 카카오        # → {"apps":[{"name":"카카오톡","package":"com.kakao.talk"}, …]}
phone hands-apps               # all launchable apps (name + package, up to 80)
phone hands-open com.kakao.talk   # just open it (no screen-control session needed)
```
- The user says an app's **name** ("유튜브 열어줘") → `hands-apps <name>` → pick the matching `package` → `hands-open <package>`.
- Try the Korean name, then the English name, then a shorter part ("네이버 지도" → "지도" → "map").
- `"blocked": true` apps (bank/pay/auth) cannot be opened or controlled — tell the user.
- To **operate** inside the app afterwards, start a session that includes that package: `hands-start 5 <package> "제목"`.

## Choose the cheapest way first

1. **No screen at all** — a setting? use `phone set …` (see fold7-phone). A web page's data? use web search/fetch.
2. **A saved recipe** — `ls ~/work/recipes/` ; if one fits, `phone hands-run @name`.
3. **Read the screen as code, then run a script** — `phone hands-read`, write the whole flow as steps, `phone hands-run '<json>'`.
4. **Step by step** (below) only when you can't predict the next screen.

## Read the screen as code (`hands-read`)

```
$ phone hands-read
app: org.fossify.math  nodes: 24
[0] TextView "0" #result
  [16] TextView "1" #btn_1 {click}
  [19] TextView "+" #btn_plus {click}
```
Indented outline: `[i] class "text" (description) #view-id {click,edit,scroll,checked=…}`. Much shorter than `hands-dump`;
use `hands-dump` only when you need bounds (`b`) for tap/swipe coordinates.

## Run many steps at once (`hands-run`)

Send the whole flow; the app runs it at the same visible speed (highlight → act → pause), stops at the first failed
step and returns a per-step `report`. Selectors use `match` = regex over text / description / view id.

```
phone hands-run '[
  {"do":"launch","package":"org.fossify.math"},
  {"do":"click","match":"^(OK|Got it)$","optional":true},
  {"do":"click","match":"^C$"},
  {"do":"click","match":"btn_7$"}, {"do":"click","match":"^×$"}, {"do":"click","match":"btn_8$"},
  {"do":"click","match":"^=$"},
  {"do":"assert","match":"^56$"}
]'
```

| do | fields | |
|---|---|---|
| `launch` | `package` | app must be in the session |
| `click` | `match` (or `i`/`id`/`text`), `scroll`: N | `scroll` = scroll down up to N times looking for it |
| `type` | `value`, `enter`: true, optional `match` | no `match` = first input box |
| `scroll` | `dir`: down/up | |
| `back`, `home` | | |
| `wait` | `ms` ≤ 10000 | |
| `wait_for` | `match`, `ms` ≤ 30000 | wait until it appears (page load) |
| `assert` | `match` | fail the run if not on screen — end every script with one |
| `tap`, `swipe` | `x`,`y` / `x1`,`y1`,`x2`,`y2`,`ms` | last resort |

Any step can have `"optional": true` (skip if it fails — e.g. closing a popup that may not appear). Max 60 steps.
If the result says `paused`, the user pressed ⏸ — poll `hands-status` and resume from `done`.

## Save working flows as recipes

When a `hands-run` succeeds, save the same JSON to `~/work/recipes/<name>.json` (letters, digits, `-`, `_`) and
mention it in memory. Next time run `phone hands-run @<name>`. Recipes use text/id regexes, never coordinates, so
they survive layout changes; if one fails, read the screen, fix the step, and overwrite the recipe.

## Read → act → verify loop (step by step)

```
phone hands-launch com.android.settings      # open an approved app
phone hands-dump                              # read the screen
phone hands-click 12                          # click node i=12 from the last dump
phone hands-dump                              # verify the screen changed as expected
```

If the user is watching the **Hermes chat app**, `hands-launch` / `hands-open` open the app *beside* the chat
(split screen, result has `"split":true`), so the user can follow your progress. The protective cover then sits only
over the controlled app. Prefer `hands-click` / `hands-run` over `hands-back` in split screen (Back goes to whichever
half the user touched last).

`hands-dump` returns `nodes`: `{i, cls, text?, desc?, id?, b:[left,top,right,bottom], click?, edit?, scroll?, checked?, pw?}`.
- Pick nodes by meaning (text/desc/id), not by position. Indexes are only valid for the latest dump: dump again after every action that changes the screen.
- `phone hands-click text:디스플레이` or `phone hands-click id:com.app:id/search` also work.
- `phone hands-type <i> "텍스트"` sets text on an editable node (`edit: true`). Add `enter` as a third argument to submit (address bar, search box): `phone hands-type 3 "날씨" enter`.
- `phone hands-scroll down [i]` / `up` scrolls a list; dump again to see new items.
- `phone hands-back`, `phone hands-home`, `phone hands-wait 1500` (let content load).
- `phone hands-tap X Y` / `phone hands-swipe X1 Y1 X2 Y2 [ms]` only when no suitable node exists
  (canvas, web views). Coordinates come from node bounds.

## Finding package names

Common: Settings `com.android.settings`, Chrome `com.android.chrome`, Samsung Internet
`com.sec.android.app.sbrowser`, Calendar `com.samsung.android.calendar`, Clock `com.sec.android.app.clockpackage`,
Calculator `com.sec.android.app.popupcalculator`, Gallery `com.sec.android.gallery3d`,
YouTube `com.google.android.youtube`, KakaoTalk `com.kakao.talk`, Naver `com.nhn.android.search`.
If unsure, ask the user, or start a session that includes the launcher and read it with `hands-dump`.

## Saving what you learn

When a multi-step flow works (e.g. "turn on dark mode"), save it as a skill with `skill_manage`
so next time you can follow it directly. Describe steps by visible text/desc/id, not coordinates.
