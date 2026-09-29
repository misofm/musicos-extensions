# Event payload policy

Extension events identify the changed subject by its object ID. Composition and
Recording events have no share type parameters under the current musicos API.
Authorization uses the subject's matching admin capability, not a currency type.

Events include the affected key where applicable (language, party, genre, or
track index) and small bounded values needed to interpret the change. Large
content is read from extension storage. Capability IDs, redundant snapshots,
and transaction-input provenance are not duplicated in payloads.

Each package README lists its current events, fields, and payload sizes. Those
sizes describe BCS payload bytes, excluding the transaction and event envelope;
they are not gas or throughput measurements. Phantom type removal changes event
type identities but does not itself change the serialized field payload.

Indexers must use the event types from the newly published package and read
composition_id, recording_id, or release_id to identify the subject. Old event
types remain associated with their previous deployments. Core publication and
TrackConsent changes do not make metadata events evidence of economic ownership
or licensing.
