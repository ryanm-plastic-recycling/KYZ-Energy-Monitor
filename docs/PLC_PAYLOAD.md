# PLC Packed Payload Format

To keep PLC logic simple and robust, the PLC publishes a compact string payload instead of JSON:

```text
d=<pulseDelta>,c=<pulseTotal>
```

Example:

```text
d=42,c=1234567
```

## Field meanings

- `d` (`pulseDelta`): pulses accumulated since the previous publish.
- `c` (`pulseTotal`): monotonically increasing lifetime pulse total from the PLC.

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
