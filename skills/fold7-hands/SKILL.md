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

## Read → act → verify loop

```
phone hands-launch com.android.settings      # open an approved app
phone hands-dump                              # read the screen
phone hands-click 12                          # click node i=12 from the last dump
phone hands-dump                              # verify the screen changed as expected
```

`hands-dump` returns `nodes`: `{i, cls, text?, desc?, id?, b:[left,top,right,bottom], click?, edit?, scroll?, checked?, pw?}`.
- Pick nodes by meaning (text/desc/id), not by position. Indexes are only valid for the latest dump: dump again after every action that changes the screen.
- `phone hands-click text:디스플레이` or `phone hands-click id:com.app:id/search` also work.
- `phone hands-type <i> "텍스트"` sets text on an editable node (`edit: true`).
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
