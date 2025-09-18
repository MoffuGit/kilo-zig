const Editor = @import("editor");
const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    var editor = try Editor.init(alloc);
    defer editor.deinit();
    var args = std.process.args();
    _ = args.next();
    if (args.next()) |filename_bytes| {
        const filename: []const u8 = filename_bytes;

        var file: std.fs.File = undefined;
        var file_opened_or_created = false;

        const open_result = std.fs.cwd().openFile(filename, .{ .mode = .read_write });

        if (open_result) |f| {
            file = f;
            file_opened_or_created = true;
        } else |err| switch (err) {
            error.FileNotFound => {
                file = try std.fs.cwd().createFile(filename, .{});
                file_opened_or_created = true;
            },
            else => return err,
        }

        if (file_opened_or_created) {
            defer file.close();
            try editor.open(file, filename);
        }
    }
    try editor.run();
}
