enum RoutingProbeValidation {
    static func hasUnexpectedBufferEvents(_ snapshot: DeckSnapshot) -> Bool {
        // Initial priming deliberately trims excess queued capture frames to
        // the target latency. Keep those visible without failing a healthy run.
        snapshot.underruns != 0 || snapshot.overruns != 0 || snapshot.resyncs != 0 ||
            snapshot.droppedFrames > snapshot.primingDroppedFrames
    }
}
