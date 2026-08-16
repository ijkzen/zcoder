/// The web remote-control protocol module: everything that formats, sends,
/// receives, and reassembles messages between the terminal (this app) and a
/// ZCode desktop device. Layered per docs/protocol/ — import this barrel, not
/// the individual files.
///
/// Layer 1  relay WebSocket (auth/pairing/heartbeats)
/// Layer 2  app payloads (zcode_type request/response + push)
/// Layer 3  acknowledged rpc-frame transport (fragment/ack/replay)
/// Layer 4  binary RPC channel (calls + events)
/// Layer 5  V4 data plane (topics, commands, reads) + service wrappers
library;

// Layer 1 — relay transport.
export 'relay/relay_frame.dart';
export 'relay/relay_client.dart';

// Layer 2 — app payloads.
export 'payload/app_payload.dart';

// Layer 3 — acknowledged rpc-frame transport.
export 'transport/rpc_frame_transport.dart';

// Layer 4 — binary RPC channel.
export 'rpc/channel_client.dart';

// Layer 5 — topics, conversation data models, services.
export 'topics/wire_frame.dart';
export 'topics/topic_session.dart';
export 'topics/topic_models.dart';
export 'services/services.dart';

// Shared constants.
export 'limits.dart';
