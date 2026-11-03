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
