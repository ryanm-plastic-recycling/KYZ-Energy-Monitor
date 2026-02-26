# PLC Packed Payload Format

To keep PLC logic simple and robust, the PLC publishes a compact string payload instead of JSON:

```text
[d=<pulseDelta>][,c=<pulseTotal>][,r17Exclude=<0|1>,kyzInvalidAlarm=<0|1>]
```

At least one of `d` or `c` must be present.

Example:

```text
d=42,c=1234567,r17Exclude=1,kyzInvalidAlarm=0
```

## Field meanings

- `d` (`pulseDelta`): pulses accumulated since the previous publish (fallback/diagnostic signal).
- `c` (`pulseTotal`): monotonically increasing lifetime pulse total from the PLC (preferred source of truth).
- `r17Exclude` (optional): exclusion status flag from PLC (`0`/`1`).
- `kyzInvalidAlarm` (optional): KYZ invalid alarm status from PLC (`0`/`1`).

## Why this format

- Avoids JSON construction on PLC firmware.
- Reduces payload size and parsing overhead.
- Enables robust pulse accumulation by deriving `Δc = current_total - previous_total` when `c` is present.
- Enables duplicate-message protection and PLC reset detection (if `c` decreases).

## Server-side behavior

The ingestor receives packed payloads and computes:

- **15-second live samples** into `dbo.KYZ_Live15s`
- **15-minute demand intervals** into `dbo.KYZ_Interval`

using bucketed server receive time and `KYZ_PULSES_PER_KWH`.

When `c` is present, the ingestor derives the effective pulse delta from `Δc` and uses that for bucket accumulation.

- Effective delta: `max(c - last_c, 0)`
- If `c` decreases, the ingestor treats it as a PLC reset and uses `0` for that message.
- If `c` is missing, the ingestor falls back to `d` (clamped to `>= 0`).
- If both `c` and `d` are missing, the message is dropped with warning logging.

When both `d` and `c` are present, `d` is treated as diagnostic/fallback. The ingestor logs sustained mismatches where `d != Δc` with rate limiting.

## Units

- `KYZ_PULSES_PER_KWH` must be configured as **pulses per kWh** (not kWh per pulse).
- Conversion used by the ingestor: `kWh = pulseCount / KYZ_PULSES_PER_KWH`.
- Example: if PLC logic is `1 pulse = 1.7 kWh`, set `KYZ_PULSES_PER_KWH=0.5882352941` (`1 / 1.7`).
- A pulse represents an energy quantum (kWh).
- kW is derived over each bucket duration from energy (`kW = kWh * 3600 / bucket_seconds`).

When optional flags are present, the ingestor ORs them across each bucket window (15s live, 15m interval). If any message in an interval has `r17Exclude=1` or `kyzInvalidAlarm=1`, the finalized interval row stores that flag as `1`.
