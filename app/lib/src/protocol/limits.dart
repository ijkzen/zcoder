/// Hard protocol limits, mirrored from the desktop app's shared schema bundle
/// (`out/main/chunk-L5EAZUIY.js`, `wn`/`ae` constants). See
/// docs/protocol/README.md "Hard limits".
library;

class ProtocolLimits {
  ProtocolLimits._();

  // Layer 1/2 — relay WebSocket + app payloads.
  static const int maxPhysicalFrameBytes = 1024 * 1024; // 1 MiB per relay frame
  static const int heartbeatIntervalMs = 10000;
  static const int heartbeatAckTimeoutMs = 30000;

  // Layer 3 — acknowledged rpc-frame transport.
  static const int maxMessageBytes = 16 * 1024 * 1024;
  static const int maxFragments = 64;
  static const int assemblyTimeoutMs = 30000;
  static const int replayBufferMaxBytes = 8 * 1024 * 1024;
  static const int replayGraceMs = 45000;
  static const int saturationHighWaterMarkBytes = 1024 * 1024;
  static const int saturationLowWaterMarkBytes = 256 * 1024;

  // Layer 5 — V4 data plane.
  static const int rowsRangeMaxLimit = 200;
  static const int snapshotTailWindowRows = 60;
  static const int attachmentMaxBytes = 20 * 1024 * 1024;
  static const int attachmentChunkMaxBytes = 512 * 1024;
  static const int attachmentUploadMaxChunks = 64;

  /// Wire version of topic frames delivered by `onDynamic*Frame` events
  /// (`Tb = 3` in `out/host/chunk-XRHTBW6U.js`).
  static const int topicWireVersion = 3;

  /// Protocol version sent in `initializeConversationV4` (clientHello).
  static const int conversationProtocolVersion = 3;
}
