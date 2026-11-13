# Locksee

> Coffee break. Lunch break. Sutta break. Your build keeps running.

A tiny macOS menu bar app that does two things: locks your screen when you step away, and
keeps your Mac awake so long jobs don't die because the machine dozed off.

One Swift file, no dependencies, 51 KB.

**[Download](https://github.com/tejaskh3/Locksee/raw/main/Locksee.zip)** ·
**[Website](https://tejaskh3.github.io/Locksee/)**

---

## Install

1. Download and unzip `Locksee.zip`, then drag **Locksee** to your Applications folder.
2. **First launch:** macOS will refuse to open it, because it's signed with a self-signed
   certificate rather than a paid Apple developer ID. Open **System Settings ▸ Privacy &
   Security**, scroll to **Security**, and click **Open Anyway**.
   Control-clicking ▸ Open no longer works — Apple removed that in macOS 15. The button only
   appears for about an hour after a blocked launch; if it isn't there, try opening the app
   again.
3. Grant **Accessibility** when asked. See [Permissions](#permissions) — it's the only one,
   and only the lock needs it.

Requires macOS 13 or newer. Universal (Apple silicon and Intel).

## Use

| | |
|---|---|
| **Lock** | `⌃⌘L`, double-click the menu bar icon, or **Lock Screen** in the menu |
| **Unlock** | Touch ID. The shield stays up and input stays blocked for the whole prompt |
| **Keep awake** | **Keep Awake** to toggle, or **Start For** to pick a duration |
| **Icon** | a lock when idle, an eye while a keep-awake session is running |

Single-click the icon for the menu, double-click to lock. The menu waits out a quarter second
before appearing, because an open `NSMenu` runs its own tracking loop and would swallow the
second click of a double-click.

### Menu

| Item | What it does |
|---|---|
| **Lock Screen** | Puts the shield up on every display |
| **Lock Shortcut** | `⌃⌘L`, `⌥⌘L`, `⌃⇧L`, `⌃⌥⌘L`, or off |
| **Block Trackpad Gestures** | Also swallow scroll, pinch, rotate and swipe while locked, not just clicks. On by default |
| **Keep Awake** | Toggle a session, with the countdown shown below it |
| **Start For** | 5 / 15 / 60 / 120 / 300 minutes, or no time limit |
| **Low Battery Cutoff** | Off, or end the session at 10–40%. Shows the current charge |
| **Also Keep Display On** | Off by default — work keeps running with the screen dark |
| **Keep Awake With Lid Closed** | Keep running after you shut the lid, on battery too. One-time admin password; see [Closed lid](#closed-lid) |
| **Sleep Now** | Shown during a lid-closed session: ends it, turns sleep back on and sleeps the Mac |
| **Remove Lid Helper…** | Uninstalls everything the option above put on the system |
| **Keep Awake On Launch** | Start caffeinated |
| **Launch at Login** | Register as a login item |

## Permissions

**Accessibility is the only permission Locksee ever requests, and only the lock needs it.**
Keep-awake works with no permissions at all, so you can skip the grant entirely if that's all
you want.

The reason it's Accessibility and not Input Monitoring is one line: the event tap is created
with `.defaultTap`, which can discard events and is gated behind Accessibility. A
`.listenOnly` tap would need Input Monitoring instead. Accessibility supersedes Input
Monitoring, so there's no second prompt.

Nothing else is used — no Input Monitoring, no Screen Recording, no network access. Locksee
makes no network requests at all.

The one exception is opt-in: **Keep Awake With Lid Closed** asks for your admin password once,
to install a small root helper. It's not a permission in the System Settings sense, and nothing
is installed unless you turn that option on. See [Closed lid](#closed-lid).

## When it works

| Situation | Locksee | `caffeinate` |
|---|---|---|
| You lock the screen and walk away | works | works |
| You close the lid | works with **Keep Awake With Lid Closed** | sleeps |
| Lid closed, on power, external display + keyboard | works | works |
| You choose Sleep from the Apple menu | sleeps | sleeps |
| Battery drops to 15% while unattended | stops itself | runs it flat |
| You want input blocked while away from the desk | works | n/a |

**Locking does not stop keep-awake.** Power assertions belong to the process, not to your
session's UI, so a keep-awake session keeps running behind the lock — including behind the
real macOS lock screen.

### Closed lid

Lid-close sleep isn't arbitrated by power assertions, so no assertion-based tool survives it —
not plain keep-awake, not `caffeinate`, and not KeepingYouAwake, whose own FAQ says it "will
only prevent sleep on desktop Macs and portable Macs with an open lid."

What lid-close sleep *does* honour is the system power setting `SleepDisabled` — the one
`sudo pmset -a disablesleep 1` writes. That's the mechanism behind Amphetamine's closed-display
mode, and it's what **Keep Awake With Lid Closed** uses. It needs root, so turning the option on
the first time installs, behind one admin password prompt:

| File | What it is |
|---|---|
| `/Library/PrivilegedHelperTools/com.tejas.locksee.lidctl` | Root-owned shell script. `on` / `off` set and clear `SleepDisabled`; `failsafe` is for the daemon |
| `/etc/sudoers.d/locksee` | Lets your user (by uid) run `lidctl on` and `lidctl off` without a password — those two exact commands, nothing else. Validated with `visudo` before it's installed |
| `/Library/LaunchDaemons/com.tejas.locksee.lidsafe.plist` | **Fail-safe.** Every 10 seconds, and at boot: if Locksee disabled sleep and Locksee isn't running, turn sleep back on |

`SleepDisabled` survives quits, crashes and reboots, which is why the fail-safe exists — a crash
mid-session would otherwise leave a laptop that never sleeps, lid shut, in a bag. Locksee also
clears it itself on every exit path it can see: ending the session, quitting, `SIGTERM`, and on
the next launch. A marker file (`/var/db/com.tejas.locksee.lidsleep`) records that Locksee made
the change, so the fail-safe never overrides a `pmset` you ran yourself.

A sealed laptop can't shed heat the way an open one can. The session ends itself if macOS
reports *critical* thermal pressure, and the low-battery cutoff applies as usual.

**Remove Lid Helper…** deletes all three files and turns sleep back on. To do it by hand:

```bash
sudo launchctl bootout system/com.tejas.locksee.lidsafe; sudo pmset -a disablesleep 0; sudo rm -f /etc/sudoers.d/locksee /Library/LaunchDaemons/com.tejas.locksee.lidsafe.plist /Library/PrivilegedHelperTools/com.tejas.locksee.lidctl /var/db/com.tejas.locksee.lidsleep
```

While it's on, **all** system sleep is off, not just lid sleep — *Sleep* from the Apple menu
won't sleep the Mac either until the session ends. Use **Sleep Now** in Locksee's menu instead:
it ends the session, turns sleep back on and sleeps the Mac in one step.

**The lock is not a security boundary.** It's a *don't touch my machine* guard for when you
step away from your desk. It's a window and an event tap, so anyone who can reach the machine
over SSH can end it, and displays are shielded as they were at the moment you locked — a
monitor plugged in mid-lock isn't covered until you unlock and lock again. For a real
boundary, use `⌃⌘Q`.

## Build from source

```bash
git clone https://github.com/tejaskh3/Locksee.git
cd Locksee
./build.sh
open Locksee.app
```

### A note on signing

`build.sh` prefers a stable self-signed identity, defaulting to one named `Locker Dev`.
Override it with `LOCKSEE_SIGN_ID`.

This matters more than it looks. An ad-hoc signature (`codesign --sign -`) has no certificate,
so the app's designated requirement becomes a hash of the exact binary — every rebuild
produces a new hash, which **silently invalidates the Accessibility grant while System
Settings still shows the toggle as ON**. Signing with a real identity keys the requirement to
the certificate instead, so the grant survives rebuilds.

To create one: Keychain Access ▸ Certificate Assistant ▸ Create a Certificate, name it
`Locker Dev`, type **Code Signing**, self-signed. `build.sh` falls back to ad-hoc signing with
a warning if it can't find one.

## How it works

**Locking** puts a borderless window per `NSScreen` at `CGShieldingWindowLevel()`, then
installs a `CGEvent` tap (`.cgSessionEventTap`, `.headInsertEventTap`, `.defaultTap`) that
swallows keys, clicks, drags and — optionally — trackpad gestures. Gesture events have no
`CGEventType` cases, so they're matched by their `NSEvent.EventType` raw values. Cursor
movement is deliberately let through so the screen doesn't look frozen.

If the tap can't be installed, the lock **fails closed**: it beeps and unlocks rather than
showing a shield that blocks nothing.

Authentication uses `.deviceOwnerAuthenticationWithBiometrics`, not `.deviceOwnerAuthentication`.
The latter silently falls back to a password field, which would need the very keyboard the tap
is swallowing — the biometrics-only policy means no code path can deadlock on that. On Macs
without Touch ID there's an explicit password fallback that stands the tap down, guarded by a
30-second watchdog that re-arms the lock if nobody answers.

**Keeping awake** holds an `IOPMAssertion` — `NoIdleSleep`, plus `NoDisplaySleep` when *Also
Keep Display On* is set. Timed sessions release on expiry; the battery cutoff enforces
immediately when you change it rather than waiting for the next minute tick.

**The global hot key** uses Carbon's `RegisterEventHotKey`, which needs no permission at all —
an `NSEvent` global monitor would have required Accessibility before you'd ever locked
anything, and only observes, leaving the keystroke to fall through to the frontmost app. It
must be registered on `GetEventDispatcherTarget()`; under `NSApplication`'s run loop a handler
installed on the application target never receives the press, even though registration
reports success.

## License

Not yet specified. Add one before anyone builds on this.
