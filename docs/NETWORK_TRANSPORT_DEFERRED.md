# Network Transport Deferred

Wi-Fi/network control is intentionally not implemented in phase 0.

The BlackBox X32 may expose network behavior, but this repository has not yet observed:

- the actual protocol surface;
- authentication or pairing requirements;
- line-ending and streaming behavior;
- whether network status reports match USB serial behavior;
- failure modes and reconnect semantics.

Until those are confirmed from official documentation or real device transcripts, the only
implemented transport is USB serial plus mock transport for tests and previews.
