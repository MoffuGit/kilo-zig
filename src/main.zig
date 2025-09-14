const std = @import("std");
const posix = std.posix;
const debug = std.debug;
const ascii = std.ascii;
const fs = std.fs;

pub fn main() !void {
    const tty_file = try fs.openFileAbsolute("/dev/tty", .{});
    defer tty_file.close();
    const tty_fd = tty_file.handle;

    const old_settings = try posix.tcgetattr(tty_fd);

    var new_settings = old_settings;
    new_settings.lflag.ECHO = false;
    new_settings.lflag.ICANON = false;
    new_settings.lflag.ISIG = false;
    new_settings.lflag.IEXTEN = false;

    new_settings.iflag.IXON = false;
    new_settings.iflag.ICRNL = false;
    new_settings.iflag.INPCK = false;
    new_settings.iflag.BRKINT = false;
    new_settings.iflag.ISTRIP = false;

    new_settings.oflag.OPOST = false;

    new_settings.cflag.CSTOPB = false;

    new_settings.cc[@intFromEnum(posix.V.MIN)] = 1;
    new_settings.cc[@intFromEnum(posix.V.TIME)] = 0;

    _ = try posix.tcsetattr(tty_fd, posix.TCSA.NOW, new_settings);

    debug.print("--- starting input --- (press 'q' to quit)\n\r", .{});

    while (true) {
        var buffer: [1]u8 = undefined;
        _ = try tty_file.read(&buffer);

        if (buffer[0] == 'q') {
            break;
        }

        if (ascii.isControl(buffer[0])) {
            debug.print("input: {}\r\n", .{
                buffer[0],
            });
        } else {
            debug.print("input: '{c}' ({d})\r\n", .{
                .c = buffer[0],
                .d = buffer[0],
            });
        }
    }

    _ = try posix.tcsetattr(tty_fd, posix.TCSA.NOW, old_settings);

    debug.print("--- ending --- \n", .{});
}
