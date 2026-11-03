const std = @import("std");

const Race = union(enum) {
    group: void,
    timeout: void,
};

fn awaitTask(group: *std.Io.Group, io: std.Io) void {
    group.await(io) catch {};
}

fn sleepTask(io: std.Io, duration: std.Io.Duration) void {
    std.Io.sleep(io, duration, .awake) catch {};
}

/// Wait for group members to finish, optionally cancelling them after
/// `timeout`.
///
/// The timeout is cooperative for the same reason handler cancellation is:
/// tasks without a cancellation point cannot be preempted. On expiry the group
/// is cancelled and `awaitGroup` returns after members observe cancellation.
pub fn awaitGroup(
    io: std.Io,
    group: *std.Io.Group,
    timeout: ?std.Io.Duration,
) !void {
    const duration = timeout orelse {
        try group.await(io);
        return;
    };

    var race_buffer: [2]Race = undefined;
    var select = std.Io.Select(Race).init(io, &race_buffer);
    defer select.cancelDiscard();

    select.concurrent(.group, awaitTask, .{ group, io }) catch {
        try group.await(io);
        return;
    };
    select.concurrent(.timeout, sleepTask, .{ io, duration }) catch {
        select.cancelDiscard();
        group.cancel(io);
        return;
    };

    const winner = select.await() catch |err| {
        select.cancelDiscard();
        group.cancel(io);
        return err;
    };
    switch (winner) {
        .group => {},
        .timeout => {
            select.cancelDiscard();
            group.cancel(io);
        },
    }
}

test "drain cancels a group after the timeout" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const Task = struct {
        fn run(task_io: std.Io) std.Io.Cancelable!void {
            std.Io.sleep(task_io, .fromSeconds(1), .awake) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
            };
        }
    };

    var group: std.Io.Group = .init;
    try group.concurrent(io, Task.run, .{io});

    const started = std.Io.Timestamp.now(io, .awake);
    try awaitGroup(io, &group, .fromMilliseconds(50));
    const elapsed = started.untilNow(io, .awake);

    try std.testing.expect(elapsed.nanoseconds < std.time.ns_per_s);
}
