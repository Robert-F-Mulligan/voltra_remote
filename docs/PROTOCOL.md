# Voltra BLE protocol notes

What Voltra Remote knows about the Beyond Power Voltra I's Bluetooth protocol, and how it
was established. It builds on community reverse-engineering (see
[Credits](../README.md#credits)); everything marked *captured* was confirmed against a
real Voltra I with this project's diagnostic build.

## Transport

The Voltra exposes one GATT service, `E4DADA34-0867-8783-9F70-2CA29216C7E4`.

| Characteristic | Use |
|---|---|
| `A010891D-F50F-44F0-901F-9A2421A9E050` | commands are written here (it also notifies) |
| `55CA1E52-7354-25DE-6AFC-B7DF1E8816AC` | responses and telemetry (notify) |
| `CA94658C-0525-5046-E78B-5391B65F47AD` | notify |

Devices advertise as `VTR-…`. Every frame is:

```
55 | len | type | crc8 | AA 10 | seq(2) | 20 00 | cmd | payload | crc16(2)
```

- `crc8` covers the first three bytes: init `0xEE`, poly `0x31`, reflected.
- `crc16` covers everything before it: init `0x496C`, poly `0x1021`, reflected.
- `AA 10` is sender (app) and receiver (Voltra); `20 00` is the protocol id.
- Frames can arrive split across notifications, or several to one notification.

On connect the app must send its "app hello" (command `0x4F`) within a short window,
followed by the bootstrap sequence captured from the official app. Only then does the
Voltra answer reads and accept writes.

| Command | Meaning |
|---|---|
| `0x0F` | read parameters: `count(2)` then ids; the reply carries `(id, value)` pairs |
| `0x10` | asynchronous push from the Voltra, same `(id, value)` layout |
| `0x11` | write one parameter: `01 00 id(2) value` |
| `0x4F` | app hello |
| `0xAA` | vendor channel: app → Voltra sub-commands, Voltra → app workout telemetry |

Values are little-endian. A parameter's width comes from the vendor dictionary
(`paramInfo.csv` in the Android port); ids missing from it have to be inferred.

## Parameters

| Setting | Parameter | Value |
|---|---|---|
| Target weight | `0x3E86` | u16 lb, 5 to the ceiling below |
| Max weight setting | `0x5314` | u16 lb (`EP_MAX_ALLOWED_FORCE`), the Voltra's own limit, up to 250 (see below) |
| Load / unload | `0x3E89` | u16: write `5` to load, `4` to unload (see [Loading](#loading)) |
| Enter weight training | `0x4FB0` | u8 `1` |
| Chains amount | `0x54DA` / `0x3E87` | i32 percent of base × 100 / u16 lb (see [Units](#chains-and-eccentric-units)) |
| Eccentric amount | `0x53D0` / `0x3E88` | i32 percent of base × 100 / i16 lb |
| Chains / eccentric limits | `0x54D4` / `0x5319` | u8 percent (100 / 60 on current firmware) |
| Inverse chains | `0x53B0` | u8 `0` / `1` |
| Mountain | `0x556F` | u8 `1` = mountain, `0` = plain chains (undocumented) |
| Accessory unit | `0x5569` | u8 `1` = percent, `0` = pounds (undocumented) |
| Battery | `0x4E2D` | u8 percent |
| Cable length setting | `0x506A` | u16 cm (`MC_DEFAULT_OFFLEN_CM`) |
| Cable position | `0x3E82` | i16 cm from fully retracted, valid while unloaded too |
| Auto load | command `0xAA`, payload `12` | then poll `0x53C7` and `0x53C8` (see [Auto load](#auto-load)) |

Chains, inverse chains and mountain are one accessory in three styles. They share one
amount (`0x54DA`), and the two flags pick the style, so only one can be on at a time.
Toggling Mountain on the Voltra itself moves `0x54DA`, which is what shows the amount is
shared rather than held per style. The knob writes the flags before the amount, so the
Voltra never briefly applies a new amount in the old style.

`0x556F`, `0x5569`, `0x53C7` and `0x5314` are never pushed asynchronously, so they have
to be polled.

The Voltra's max-weight setting is `0x5314`. *Captured* while changing it on the Voltra,
it read 250, 180, 220 and 250 in turn. The vendor dictionary gives its range as 10–200,
which is out of date: 250 lb firmware stores 250 there. `OVERDRIVE_USER_CFG_FORCE_MAX`
(`0x541E`), which sounds like the limit and is what the Android port reads, is not
answered at all on current firmware. Until `0x5314` has been read, the knob assumes
230 lb.

## Loading

`0x3E89` does not jump straight to the value written. *Captured* read-backs have three
values:

| Read | Meaning |
|---|---|
| `0` | unloaded |
| `1` | loaded, idle: just loaded, or resting between sets |
| `5` | loaded, set active |

`1` is easy to mistake for "unloaded", but the Voltra holds the weight there. Loading from
`0` steps through `1` first, so the knob re-issues the write every 600 ms (up to four
times) until it reads `5`. Unloading (writing `4`) lands on `0`.

Quirks handled alongside:

- After a settings write, and after reps, the Voltra echoes its whole settings block
  asynchronously, and the fitness mode in that echo is stale. *Captured* 100 ms apart
  while loaded: a direct read said `5`, the echo said `1`. A single-parameter push is a
  genuine change and is honoured; a multi-parameter one is an echo and its mode ignored.
- Changing the weight or an accessory during an active set drops the mode from `5` to
  `1`. The knob then re-asserts `5` so the change applies to the set in progress. It does
  not do this at `1` (resting), so a change between sets does not end the rest.

### Loading with the cable pulled out (direct load)

The Voltra's own **direct load** loads with the cable already out. Over BLE, a plain load
(`5`) written while the cable is out is refused. *Captured*: the mode reaches `4` and drops
back to `0` about 0.3 s later, and the workout status never leaves `0`. Writing `4` first
and `5` 90 ms later, inside that window, is refused the same way.

What works is auto load with its safety check bypassed: send the auto-load trigger, and as
soon as `0x53C7` reports `11` (waiting) or `12` (counting down), write `2` to
`DIRECT_LOAD_SAFETY_CHECK_CTRL` (`0x53C9`). *Captured*, each written once during an auto
load with the cable out:

| `0x53C9` | Effect |
|---|---|
| `1` | cancels the auto load; nothing loads |
| `2` | skips the countdown: loaded about 0.5 s after the trigger, mode `1`, `0x53C7` = `14` |
| `3` | no effect: the normal 3 s countdown |

With the cable in, the bypass also loads, but slower than a plain load and via the
Voltra's auto-load screen. So the knob picks by cable position. `BP_RUNTIME_POSITION_CM`
(`0x3E82`) counts from fully retracted, so a resting cable reads the Voltra's cable length
setting, `MC_DEFAULT_OFFLEN_CM` (`0x506A`). *Captured* with the handle resting: length 0
read 0/0, 20 in read 50/50 cm, 15 in read 37/38 cm. At the tap the knob reads both fresh,
then does a plain load unless the cable is at least 10 cm past its set length, and a direct
load if it is. If a plain load is refused anyway (the cable moved after
the reading), it switches to a direct load. A refused load is told apart by the workout
status staying `0`: the mode alone can read `0` for a load that worked, when its push fell
inside the echo guard window.

These frames go to the front of the send queue. Queued behind polls and read-backs, a load
went out up to 1 s after the tap, and a retry timer started before the write was sent
mistook a working load for a refused one.

## Workout telemetry

The Voltra pushes workout telemetry on command `0xAA`. Two frames matter here:

- **Rep telemetry** `81 2B phase set rep_hi rep_lo …`: `phase` is `0` idle, `1` pull,
  `2` transition, `3` return; `set` is the Voltra's set counter; the rep count is
  big-endian. It streams about ten times a second while the cable moves.

  Offset 11 (u16 LE) is the **live resistance in 0.1 lb**, including the accessories:
  what the Voltra and the Beyond+ app show as the live weight. *Captured* at a 20 lb
  base: with 50% chains it rose from 20.5 at the bottom of the pull to 30.0 at the top
  (the Voltra showed 30); with +20% eccentric it read about 20 on the way up and 24.3 on
  the way down (the Voltra showed 24). Between reps, as the cable goes slack, it falls
  towards 0. Offset 13 (u16 LE) tracks cable position.
- **Workout status** `80 25 01 00 SS …`, pushed the moment it changes (*captured*):

  | `SS` | Meaning |
  |---|---|
  | `0` | unloaded |
  | `1` | loading |
  | `2` | set in progress (also right after loading, before any rep) |
  | `3` | resting, about 3.5 s after the last rep |
  | `4` | unloading |

The fitness mode cannot separate a set from a rest: after the first set it stays at `1`
through every later set, and through all of them when the Voltra was loaded from its own
screen. The knob's set screen therefore keys off status `2` plus cable movement from the
rep telemetry, and ends on any other status.

## Auto load

The Voltra's own auto load ("direct load" in the Android port) is started with vendor
command `0xAA`, payload `12`, after making sure weight training is active (`0x4FB0`).
The Voltra then waits for the cable to be pulled out and held, counts down, and loads.

*Captured* on current firmware, the fitness mode goes to `0x23` (`35`) and **stays there
after loading**, so the mode alone cannot say whether the weight is on.
`DIRECT_LOAD_SAFETY_CHECK_ST` (`0x53C7`) does:

| `0x53C7` | Meaning |
|---|---|
| `11` | waiting for the cable to be pulled out |
| `12` | held: counting down (`0x53C8`, 3000 ms to 0, restarting if the cable moves) |
| `13` | countdown done, weight coming on |
| `14` | loaded |

The knob counts `0x23` with `13` or `14` as loaded. Writing `4` (unload) during the wait
cancels it. The Android port lists fitness modes `0x26` / `0x27` for this on its
firmware; those are treated the same way.

## Chains and eccentric units

The Voltra keeps chains and eccentric in both pounds and percent, but only one pair is
authoritative: whichever its own accessory lb/% setting (`0x5569`) selects. The other pair
is derived from it and the base weight, and a write to the derived pair is ignored or
reverted. *Captured* in percent mode, with a 40 lb base:

```
41.9s  tx write 3E87 = 0b00      write chains = 11 lb
42.2s  rx 10  0100873e0b00       Voltra acknowledges 11
42.4s  rx 0f  ... 873e0a00 ...   read back: 10 again (25% of 40 lb)
```

So the knob reads `0x5569`, dials and writes in that unit, and shows the other alongside.

Two traps from the vendor dictionary:

- It lists 16-bit percent variants (`0x5189` / `0x518A`). They stay `0`; the signed 32-bit
  pair (`0x54DA` / `0x53D0`) is live.
- `WEIGHT_TRAINING_EXTRA_MODE` (`0x53C6`) sounds like the unit selector but is not: it
  stayed `0` in both modes.

## Finding undocumented registers

Mountain, the accessory unit and parts of auto load are newer than the vendor
dictionary. The dictionary's highest id is `0x5522`, yet reading the *unlisted* ids in
`0x5300`–`0x57FF` turns up 38 live registers.

The diagnostic build finds them:

```bash
pio run -e remote_diag -t upload
```

It logs every parameter read and write and all workout telemetry, and periodically sweeps
the registers listed in `src/voltra/sweep_params.cpp`. `tools/gen_sweep_params.py`
generates that list from the vendor dictionary, in one of three modes:

- `documented`: every BP/MC id.
- `undocumented`: the unlisted ids in `0x5300`–`0x57FF`.
- `settings`: the BP ids followed by the undocumented range.

The method:

1. Capture the serial log while holding each device state long enough for a full sweep.
   A sweep takes about 50 s.
2. Diff the snapshots. Undocumented registers have unknown widths, so they are read in
   small batches and the widths inferred from where each next id falls in the response.
3. **Confirm what each value means by writing it** and watching the Voltra's own screen.
   The diff only identifies the register: Mountain's polarity was first read backwards.

Flash the release build (`pio run -e remote -t upload`) afterwards; it carries none of this.
