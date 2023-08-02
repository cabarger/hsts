const std = @import("std");
const os = std.os;
const windows = std.os.windows;
const c = @cImport({
    @cInclude("windows.h");
});

const Self = @This();

dw_stdout_old_mode: windows.DWORD = undefined,
dw_stdin_old_mode: windows.DWORD = undefined,
stdin_handle: os.fd_t,
stdout_handle: os.fd_t,

pub fn init(console_stdin_handle: os.fd_t, console_stdout_handle: os.fd_t) Self {
    var result = Self{ .stdin_handle = console_stdin_handle, .stdout_handle = console_stdout_handle };
    _ = c.GetConsoleMode(console_stdout_handle, &result.dw_stdout_old_mode);
    _ = c.GetConsoleMode(console_stdin_handle, &result.dw_stdin_old_mode);
    _ = c.SetConsoleMode(console_stdout_handle, result.dw_stdout_old_mode | ~@as(windows.DWORD, c.ENABLE_VIRTUAL_TERMINAL_PROCESSING));
    _ = c.SetConsoleOutputCP(c.CP_UTF8);
    _ = c.SetConsoleMode(console_stdin_handle, result.dw_stdin_old_mode & ~@as(windows.DWORD, c.ENABLE_LINE_INPUT | c.ENABLE_ECHO_INPUT));

    return result;
}

pub fn deinit(self: *Self) void {
    _ = c.SetConsoleMode(self.stdout_handle, self.dw_stdout_old_mode);
    _ = c.SetConsoleMode(self.stdin_handle, self.dw_stdin_old_mode);
}
