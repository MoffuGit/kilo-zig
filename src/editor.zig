const Editor = @This();
const std = @import("std");
const posix = std.posix;
const ascii = std.ascii;

const stdin = std.fs.File.stdin();
const stdout = std.fs.File.stdout();

reader: *std.io.Reader = undefined,
writer: *std.io.Writer = undefined,
origTermios: ?posix.termios = null,
winSize: posix.winsize = .{
    .row = 0,
    .col = 0,
    .xpixel = 0,
    .ypixel = 0,
},
cursorPosition: CursorPosition = CursorPosition{ .x = 0, .y = 0 },

const CursorPosition = struct { x: usize, y: usize };

const EditorKey = union(enum) {
    cursor: CursorKey,
    notImpl: void,
    quit: void,
    esc: void,
    none: void,
    page_up: void,
    page_down: void,
    home_key: void,
    end_key: void,
    delete_key: void,
};

const CursorKey = enum(u8) {
    up = 'k',
    down = 'j',
    left = 'h',
    right = 'l',
};

pub fn init() Editor {
    var stdin_buf: [4096]u8 = undefined;
    var stdin_reader = stdin.reader(&stdin_buf);
    const reader = &stdin_reader.interface;

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = stdout.writer(&stdout_buf);
    const writer = &stdout_writer.interface;

    return .{
        .origTermios = null,
        .reader = reader,
        .writer = writer,
        .winSize = .{
            .row = 0,
            .col = 0,
            .xpixel = 0,
            .ypixel = 0,
        },
    };
}

fn ctrlKey(char: u8) u8 {
    return (char) & 0x1f;
}

pub fn run(self: *Editor) !void {
    try self.enableRawMode();
    try self.updateWindowSize();

    while (true) {
        try self.refreshScreen();
        var key: EditorKey = undefined;

        key = self.readKey() catch EditorKey{ .none = {} };
        if (key == .none) {
            continue;
        }
        if (key == .quit) {
            break;
        }
        self.processKey(key);
    }

    try self.write("\x1b[2J");
    try self.write("\x1b[H");

    try self.disableRawMode();
}

fn processKey(self: *Editor, key: EditorKey) void {
    switch (key) {
        .cursor => |cursor| self.processCursorKey(cursor),
        else => {},
    }
}

fn processCursorKey(self: *Editor, key: CursorKey) void {
    switch (key) {
        .left => {
            if (self.cursorPosition.x != 0) {
                self.cursorPosition.x = self.cursorPosition.x - 1;
            }
        },
        .right => {
            if (self.winSize.col - 1 != self.cursorPosition.x) {
                self.cursorPosition.x = self.cursorPosition.x + 1;
            }
        },
        .up => {
            if (self.cursorPosition.y != 0) {
                self.cursorPosition.y = self.cursorPosition.y - 1;
            }
        },
        .down => {
            if (self.winSize.row - 1 != self.cursorPosition.y) {
                self.cursorPosition.y = self.cursorPosition.y + 1;
            }
        },
    }
}

pub fn enableRawMode(self: *Editor) !void {
    var termios: posix.termios = undefined;
    termios = try posix.tcgetattr(stdin.handle);
    self.origTermios = termios;

    termios.iflag.BRKINT = false;
    termios.iflag.ICRNL = false;
    termios.iflag.INPCK = false;
    termios.iflag.ISTRIP = false;
    termios.iflag.IXON = false;
    termios.iflag.IUTF8 = false;

    termios.oflag.OPOST = false;

    termios.cflag.CSIZE = std.posix.CSIZE.CS8;

    termios.lflag.ECHO = false;
    termios.lflag.ICANON = false;
    termios.lflag.IEXTEN = false;
    termios.lflag.ISIG = false;

    termios.cc[@intFromEnum(posix.V.MIN)] = 0;
    termios.cc[@intFromEnum(posix.V.TIME)] = 1;

    try posix.tcsetattr(stdin.handle, posix.TCSA.NOW, termios);
}

pub fn disableRawMode(self: *Editor) !void {
    if (self.origTermios) |termios| {
        try self.flush();
        try posix.tcsetattr(stdin.handle, posix.TCSA.NOW, termios);
    }
}

pub fn write(self: *Editor, bytes: []const u8) !void {
    try self.writer.writeAll(bytes);
}

pub fn flush(self: *Editor) !void {
    try self.writer.flush();
}

pub fn refreshScreen(self: *Editor) !void {
    try self.write("\x1b[?25l");
    try self.write("\x1b[H");
    try self.drawRows();
    try self.writer.print("\x1b[{};{}H", .{ self.cursorPosition.y + 1, self.cursorPosition.x + 1 });
    try self.write("\x1b[?25h");
    try self.flush();
}

pub fn drawRows(self: *Editor) !void {
    var y: usize = 0;
    while (y < self.winSize.row) : (y += 1) {
        if (y == self.winSize.row / 3) {
            const welcome = "Welcome to Kilo editor";
            var padding = (self.winSize.col - welcome.len) / 2;
            try self.write("~");
            padding = padding - 1;
            while (padding > 0) {
                try self.write(" ");
                padding = padding - 1;
            }
            try self.write(welcome);
        } else {
            try self.write("~");
        }
        try self.write("\x1b[K");
        if (y < self.winSize.row - 1) {
            try self.write("\r\n");
        }
    }
}

pub fn updateWindowSize(self: *Editor) !void {
    var winSize: posix.winsize = undefined;
    const rc = posix.system.ioctl(stdin.handle, posix.T.IOCGWINSZ, @intFromPtr(&winSize));
    if (std.posix.errno(rc) == .SUCCESS) {
        self.winSize = winSize;
    }
}

pub fn readKey(self: *Editor) !EditorKey {
    const char: u8 = try self.reader.takeByte();
    var key: EditorKey = undefined;

    switch (char) {
        'k', 'j', 'h', 'l' => key = EditorKey{ .cursor = @enumFromInt(char) },
        '\x1b' => {
            const next_char_result = self.reader.takeByte();

            if (next_char_result == error.EndOfStream) {
                return EditorKey{ .quit = {} };
            }

            const next_char = try next_char_result;

            if (next_char == '[') {
                const third_char_result = self.reader.takeByte();
                if (third_char_result == error.EndOfStream) {
                    return EditorKey{ .notImpl = {} };
                }
                const third_char = try third_char_result;

                switch (third_char) {
                    'A' => key = EditorKey{ .cursor = CursorKey.up },
                    'B' => key = EditorKey{ .cursor = CursorKey.down },
                    'C' => key = EditorKey{ .cursor = CursorKey.right },
                    'D' => key = EditorKey{ .cursor = CursorKey.left },
                    'H' => key = EditorKey{ .home_key = {} },
                    'F' => key = EditorKey{ .end_key = {} },
                    '1', '2', '3', '4', '5', '6' => {
                        const fourth_char_result = self.reader.takeByte();
                        if (fourth_char_result == error.EndOfStream) {
                            return EditorKey{ .notImpl = {} };
                        }
                        const fourth_char = try fourth_char_result;

                        if (fourth_char == '~') {
                            switch (third_char) {
                                '1' => key = EditorKey{ .home_key = {} },
                                '3' => key = EditorKey{ .delete_key = {} },
                                '4' => key = EditorKey{ .end_key = {} },
                                '5' => key = EditorKey{ .page_up = {} },
                                '6' => key = EditorKey{ .page_down = {} },
                                else => key = EditorKey{ .notImpl = {} },
                            }
                        } else {
                            key = EditorKey{ .notImpl = {} };
                        }
                    },
                    else => key = EditorKey{ .notImpl = {} },
                }
            } else {
                key = EditorKey{ .quit = {} };
            }
        },
        else => {
            if (char == ctrlKey('q')) {
                key = EditorKey{ .quit = {} };
            } else {
                key = EditorKey{ .notImpl = {} };
            }
        },
    }
    return key;
}
