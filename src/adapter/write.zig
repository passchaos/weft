/// Charges one response-body write against the per-response byte budget.
pub fn consume(remaining: *usize, data: []const u8) anyerror!void {
    if (data.len > remaining.*) return error.ResponseTooLarge;
    remaining.* -= data.len;
}
