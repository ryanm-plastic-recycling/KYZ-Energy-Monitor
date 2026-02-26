# PLC Packed Payload Format

To keep PLC logic simple and robust, the PLC publishes a compact string payload instead of JSON:

```text
d=<pulseDelta>,c=<pulseTotal>[,r17Exclude=<0|1>,kyzInvalidAlarm=<0|1>]
```

Example:

```text
d=42,c=1234567,r17Exclude=1,kyzInvalidAlarm=0
```

## Field meanings

- `d` (`pulseDelta`): pulses accumulated since the previous publish.
- `c` (`pulseTotal`): monotonically increasing lifetime pulse total from the PLC.
- `r17Exclude` (optional): exclusion status flag from PLC (`0`/`1`).
- `kyzInvalidAlarm` (optional): KYZ invalid alarm status from PLC (`0`/`1`).

## Why this format

- Avoids JSON construction on PLC firmware.
- Reduces payload size and parsing overhead.
- Enables duplicate-message protection in the ingestor by comparing `c` (total pulses), even if the same message arrives on multiple topics.
- Supports PLC reset detection (if `c` decreases).

## Server-side behavior

The ingestor receives packed payloads and computes:

- **15-second live samples** into `dbo.KYZ_Live15s`
- **15-minute demand intervals** into `dbo.KYZ_Interval`

using bucketed server receive time and `KYZ_PULSES_PER_KWH`.

When optional flags are present, the ingestor ORs them across each bucket window (15s live, 15m interval). If any message in an interval has `r17Exclude=1` or `kyzInvalidAlarm=1`, the finalized interval row stores that flag as `1`.
