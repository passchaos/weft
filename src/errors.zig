const std = @import("std");

/// Map a handler or middleware error to the status dispatch will emit.
///
/// Keep this in one place so middleware (for example metrics) classifies
/// failures the same way the dispatcher does.
pub fn statusForHandlerError(err: anyerror) u16 {
    if (err == error.UnsupportedMediaType or err == error.NotMultipart) {
        return 415;
    }
    if (err == error.PayloadTooLarge) return 413;
    if (err == error.BadRequest or
        err == error.InvalidJson or
        err == error.MissingBoundary or
        err == error.InvalidMultipart or
        err == error.TooManyParts)
    {
        return 400;
    }
    return 500;
}

/// True when the failure means the peer closed or reset the connection.
/// Adapters log these at debug level: a client hanging up is a normal
/// lifecycle event, not a server fault.
pub fn isPeerDisconnect(err: anyerror) bool {
    return err == error.ConnectionClosed or
        err == error.ConnectionResetByPeer or
        err == error.BrokenPipe or
        err == error.NotOpenForReading or
        err == error.NotOpenForWriting or
        err == error.UnexpectedStream;
}

test "peer disconnect classification" {
    try std.testing.expect(isPeerDisconnect(error.ConnectionClosed));
    try std.testing.expect(isPeerDisconnect(error.ConnectionResetByPeer));
    try std.testing.expect(!isPeerDisconnect(error.OutOfMemory));
}

test "handler errors map to protocol statuses" {
    try std.testing.expectEqual(@as(u16, 415), statusForHandlerError(
        error.UnsupportedMediaType,
    ));
    try std.testing.expectEqual(@as(u16, 413), statusForHandlerError(
        error.PayloadTooLarge,
    ));
    try std.testing.expectEqual(@as(u16, 400), statusForHandlerError(
        error.InvalidJson,
    ));
    try std.testing.expectEqual(@as(u16, 500), statusForHandlerError(
        error.Unexpected,
    ));
}
