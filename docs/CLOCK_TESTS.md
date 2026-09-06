# Clock and recovery simulation coverage

`tests/ClockSimulation.c` runs the real `DeckRoutePush` / `DeckRoutePull` processing kernel against deterministic sample and callback schedules. It creates no Core Audio devices, opens no audio hardware, and emits no sound. These are software results, not proof of actual USB clock behavior or Xbox electrical compatibility.

## Healthy schedules

The seven original two-minute cases cover 44.1/48 kHz in both conversion directions, clock offsets from -1000 to +1000 ppm, and fixed buffers from 32 to 512 frames. They assert zero underruns, overruns and resyncs; bounded occupancy; final-minute mean clock correction within 40 ppm of the imposed offset; 1 kHz frequency error below 0.15 Hz; RMS amplitude within 0.003 of the reference; and no signal in the silent right channel.

Three additional schedules exercise changing conditions:

| Input → output | Simulated duration | Seed |
| --- | --- | --- |
| 48 → 48 kHz | 3 minutes | `58424431` |
| 44.1 → 48 kHz | 3 minutes | `58424432` |
| 48 → 44.1 kHz | 10 minutes | `58424433` |

Each uses all four callback sizes, 32/64/128/256 frames, independently for capture and render. Both schedules use separate seeded random sequences and bounded timestamp jitter of ±75 microseconds. Jitter offsets the ideal callback time rather than accumulating into artificial clock drift. Input clock offset starts at +600 ppm, ramps to -600 ppm between seconds 40 and 60, holds through second 90, then changes to +350 ppm for the rest of the session.

Every healthy variable schedule must satisfy:

- Zero underruns, overruns and resyncs throughout; no additional dropped frames after startup priming. Priming may discard part of the initial block to establish the target queue depth.
- Occupancy never exceeds twice the target. Final-minute mean occupancy is within 10% of target. In the ten-minute run, its change from the earlier settled minute is also less than 10% of target. This checks that buffering and latency do not continue growing during the longer run.
- Positive and negative clock segments produce corrections of the corresponding sign and at least 300 ppm magnitude. Final-minute time-weighted mean correction is within 40 ppm of +350 ppm. Time weighting avoids bias from variable callback sizes.
- Finite output within the configured ceiling, reference RMS and frequency tolerances, and exactly silent right-channel output.

## Deliberate faults and recovery

Two separate cases inject conditions that should increment error counters. Their failures are intentional and must not be counted as healthy zero-xrun passes.

| Fault | Required behavior |
| --- | --- |
| Capture pause: 64 output callbacks without input | Exactly one underrun and resync; no overrun. Further empty callbacks wait for priming instead of repeatedly counting the same starvation. |
| Render stall and capture burst: 256 input callbacks without output | One queue resync, positive overrun count and dropped frames; no underrun. The finite ring drops excess input rather than growing. |

Both cases begin with a running calibration tone. Recovery must cancel the tone and latch mute, keep every output sample finite and below the safe software ceiling, then resume only after an explicit unmute. Re-priming and observable audio must take fewer than 16 resumed callbacks (under 43 ms for this simulated 128-frame / 48 kHz schedule). This is a simulation recovery bound, not a hardware latency guarantee.

Each case continues for 90 simulated seconds after recovery. It must produce no further xruns, resyncs or dropped frames. Mean correction over the final 30 seconds must be within 40 ppm of zero, with mean queue depth within 10% of target.

## Concurrency and sanitizers

The two existing thread scenarios remain separate:

- 20,000 producer blocks alongside consumer renders and 20,000 tone/gain/mute control cycles, checking finite bounded output.
- 2,000 concurrent tone cancellation/bypass render cycles, checking that cancellation cannot substitute louder live microphone audio.

`--threads-only` runs only these two short scenarios, preserving the focused AddressSanitizer/UndefinedBehaviorSanitizer and ThreadSanitizer runs in `scripts/test.sh`.

## Running

Run the full project tests, twelve schedule/recovery cases and sanitizer checks:

```bash
bash scripts/test.sh
```

For just the clock and recovery suite, without rebuilding the application:

```bash
source scripts/xcode_environment.sh
mkdir -p build/readiness-clock
xcrun clang -O2 -g -std=gnu11 -Wall -Wextra -Werror \
  -I XboxVoiceDeck/Audio/Realtime \
  XboxVoiceDeck/Audio/Realtime/DeckAudio.c tests/ClockSimulation.c \
  -framework AudioToolbox -framework CoreAudio \
  -o build/readiness-clock/clock-simulation
build/readiness-clock/clock-simulation
```

The twelve schedule cases represent approximately 33 simulated minutes, including ten healthy schedules and two forced faults. The longest individual session is ten simulated minutes. Simulated time advances from frame counts, so these are not real-time hardware soak tests. Physical adapter callback behavior, scheduler load on the M1, device unplug/reconnect, sleep, and audible fidelity still need actual hardware acceptance.
