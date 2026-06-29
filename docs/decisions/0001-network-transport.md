# 0001 Network Transport

Status: Accepted

## Context

The BlackBox X32 may expose network behavior, but this repository has not
verified:

- the actual protocol surface;
- authentication or pairing requirements;
- line-ending and streaming behavior;
- whether network status reports match USB serial behavior;
- failure modes and reconnect semantics.

Guessing network protocol behavior would weaken the controller safety model and
create an unverified transport path around the existing transcript-based USB
serial implementation.

## Decision

Wi-Fi/network control is intentionally not implemented. The implemented
transports are USB serial and mock transport for tests and previews.

Network transport may be added only after official documentation or real device
transcripts define the protocol, authentication, streaming semantics, and
failure behavior.

## Consequences

- USB serial remains the production hardware transport.
- Mock transport remains the preview/test transport.
- Any future network transport must preserve the same safety gates, typed
  controller abstraction, transcript/evidence behavior, and runbook procedures
  as serial transport.
