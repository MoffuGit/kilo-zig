const Editor = @This();
const std = @import("std");
const posix = std.posix;
const ascii = std.ascii;

const stdin = std.fs.File.stdin();
const stdout = std.fs.File.stdout();
const Allocator = std.mem.Allocator;
const Instant = std.time.Instant;

alloc: Allocator,
stdin_fs_reader: std.fs.File.Reader = undefined,
stdout_fs_writer: std.fs.File.Writer = undefined,
reader: *std.io.Reader,
writer: *std.io.Writer,
origTermios: ?posix.termios = null,
winSize: posix.winsize = .{
    .row = 0,
    .col = 0,
    .xpixel = 0,
    .ypixel = 0,
},
cursorPosition: CursorPosition = CursorPosition{ .x = 0, .y = 0 },
renderPosition: CursorPosition = CursorPosition{ .x = 8, .y = 0 },
numRows: usize = 0,
rows: std.ArrayList(Row),
rowsOff: usize = 0,
colsOff: usize = 0,
stdin_buffer: [4096]u8,
stdout_buffer: [4096]u8,
fileName: []u8,
statusMsg: []u8,
statusMsgTimer: Instant,

const CursorPosition = struct { x: usize, y: usize };
const Row = struct {
    chars: []u8,
    render: []u8,
};

const EditorKey = union(enum) {
    cursor: CursorKey,
    notImpl: void,
    quit: void,
    esc: void,
    none: void,
    delete_key: void,
};

const CursorKey = enum(u8) {
    up = 'k',
    down = 'j',
    left = 'h',
    right = 'l',
    page_up,
    page_down,
    home_key,
    end_key,
};

pub fn init(alloc: Allocator) !Editor {
    var editor = Editor{
        .alloc = alloc,
        .origTermios = null,
        .winSize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 },
        .cursorPosition = CursorPosition{ .x = 0, .y = 0 },
        .numRows = 0,
        .fileName = try alloc.dupe(u8, "[No Name]"),
        .statusMsgTimer = try Instant.now(),
        .statusMsg = try alloc.alloc(u8, 0),
        .rows = try std.ArrayList(Row).initCapacity(alloc, 0),
        .stdin_buffer = undefined,
        .stdout_buffer = undefined,
        .reader = undefined,
        .writer = undefined,
    };

    editor.stdin_fs_reader = std.fs.File.stdin().reader(&editor.stdin_buffer);
    editor.stdout_fs_writer = std.fs.File.stdout().writer(&editor.stdout_buffer);

    editor.reader = &editor.stdin_fs_reader.interface;
    editor.writer = &editor.stdout_fs_writer.interface;

    return editor;
}

pub fn deinit(self: *Editor) void {
    for (self.rows.items) |row| {
        if (row.chars.len > 0) {
            self.alloc.free(row.chars);
        }
        if (row.render.len > 0 or row.render.ptr != "".ptr) {
            self.alloc.free(row.render);
        }
    }
    self.alloc.free(self.fileName);
    self.alloc.free(self.statusMsg);
    self.rows.deinit(self.alloc);
}

pub fn setStatusName(self: *Editor, msg: []const u8) !void {
    if (self.statusMsg.len > 0) {
        self.alloc.free(self.statusMsg);
    }
    self.statusMsg = try self.alloc.dupe(u8, msg);
    self.statusMsgTimer = try Instant.now();
}

pub fn open(self: *Editor, file: std.fs.File, name: []const u8) !void {
    var file_buf: [4096]u8 = undefined;
    var file_reader = file.reader(&file_buf);
    const reader = &file_reader.interface;

    if (self.fileName.len > 0) {
        self.alloc.free(self.fileName);
    }
    self.fileName = try self.alloc.dupe(u8, name);

    while (reader.takeDelimiterExclusive('\n')) |line| {
        const new_row_chars = try self.alloc.dupe(u8, line);
        try self.rows.append(self.alloc, Row{ .chars = new_row_chars, .render = "" });
    } else |err| switch (err) {
        error.EndOfStream,
        error.StreamTooLong,
        error.ReadFailed,
        => {},
    }

    if (self.rows.items.len == 0) {
        try self.rows.append(self.alloc, Row{ .chars = "", .render = "" });
    }

    self.numRows = self.rows.items.len;
    for (self.rows.items) |*row_ptr| {
        try self.updateRow(row_ptr);
    }
}

fn updateRow(self: *Editor, row: *Row) !void {
    var builder = try std.ArrayList(u8).initCapacity(self.alloc, 0);
    defer builder.deinit(self.alloc);

    var current_col: usize = 0;
    for (row.chars) |char_byte| {
        if (char_byte == '\t') {
            const spaces_to_add = 8 - (current_col % 8);
            for (0..spaces_to_add) |_| {
                try builder.append(self.alloc, ' ');
            }
            current_col += spaces_to_add;
        } else {
            try builder.append(self.alloc, char_byte);
            current_col += 1;
        }
    }

    if (row.render.len > 0) {
        self.alloc.free(row.render);
    }

    row.render = try self.alloc.dupe(u8, builder.items);
}

fn ctrlKey(char: u8) u8 {
    return (char) & 0x1f;
}

pub fn run(self: *Editor) !void {
    try self.enableRawMode();
    try self.updateWindowSize();

    try self.setStatusName("HELP: Ctrl-Q = quit");

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
    const currentRowLen = if (self.cursorPosition.y >= self.numRows) 0 else self.rows.items[self.cursorPosition.y].chars.len;
    switch (key) {
        .left => {
            if (self.cursorPosition.x != 0) {
                self.cursorPosition.x = self.cursorPosition.x - 1;
            } else if (self.cursorPosition.y > 0) {
                self.cursorPosition.y = self.cursorPosition.y - 1;
                self.cursorPosition.x = self.rows.items[self.cursorPosition.y].chars.len;
            }
        },
        .right => {
            if (self.cursorPosition.x < currentRowLen) {
                self.cursorPosition.x = self.cursorPosition.x + 1;
            } else if (self.cursorPosition.x == currentRowLen) {
                self.cursorPosition.y = self.cursorPosition.y + 1;
                self.cursorPosition.x = 0;
            }
        },
        .up => {
            if (self.cursorPosition.y != 0) {
                self.cursorPosition.y = self.cursorPosition.y - 1;
            }
        },
        .down => {
            if (self.numRows > self.cursorPosition.y) {
                self.cursorPosition.y = self.cursorPosition.y + 1;
            }
        },
        .page_up => {
            self.cursorPosition.y = self.rowsOff;
            var times = self.winSize.row;
            while (times >= 0) : (times -= 1) {
                self.processCursorKey(CursorKey.up);
            }
        },
        .page_down => {
            self.cursorPosition.y = self.rowsOff + self.winSize.row - 1;
            if (self.cursorPosition.y > self.numRows) {
                self.cursorPosition.y = self.numRows;
            }
            var times = self.winSize.row;
            while (times >= 0) : (times -= 1) {
                self.processCursorKey(CursorKey.down);
            }
        },
        .end_key => {
            if (self.cursorPosition.y < self.numRows) {
                self.cursorPosition.x = self.rows.items[self.cursorPosition.y].chars.len;
            }
        },
        .home_key => {
            self.cursorPosition.x = 0;
        },
    }
    const newLen = if (self.cursorPosition.y >= self.numRows) 0 else self.rows.items[self.cursorPosition.y].chars.len;
    if (self.cursorPosition.x > newLen) {
        self.cursorPosition.x = newLen;
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

fn cursorPositionToRenderPosition(row: *Row, cx: usize) usize {
    var rx: usize = 0;
    var j: usize = 0;
    while (j < cx) : (j += 1) {
        if (row.chars[j] == '\t') {
            rx += (8 - 1) - (rx % 8);
        }
        rx += 1;
    }
    return rx;
}

pub fn refreshScreen(self: *Editor) !void {
    self.scroll();
    try self.write("\x1b[?25l");
    try self.write("\x1b[H");
    try self.drawRows();
    try self.drawStatusBar();
    try self.writer.print("\x1b[{};{}H", .{ (self.cursorPosition.y - self.rowsOff) + 1, (self.renderPosition.x - self.colsOff) + 1 });
    try self.write("\x1b[?25h");
    try self.flush();
}

pub fn drawStatusBar(self: *Editor) !void {
    try self.write("\x1b[7m");

    const now = try std.time.Instant.now();
    const elapsed_ns = now.since(self.statusMsgTimer);
    const display_timed_status_msg = (self.statusMsg.len > 0 and elapsed_ns < 5 * std.time.ns_per_s);

    var right_status_buffer: [32]u8 = undefined;
    const right_status_slice = try std.fmt.bufPrint(
        right_status_buffer[0..],
        "{}/{}",
        .{ self.cursorPosition.y + 1, self.numRows },
    );
    const right_status_len: usize = right_status_slice.len;

    var status_line_builder = try std.ArrayList(u8).initCapacity(self.alloc, 0);
    defer status_line_builder.deinit(self.alloc);

    var current_width: usize = 0;

    var left_status_buffer: [256]u8 = undefined;
    const left_status_slice = try std.fmt.bufPrint(
        left_status_buffer[0..],
        "{s} - {} lines",
        .{ self.fileName, self.numRows },
    );
    const left_status_len: usize = left_status_slice.len;

    const max_left_content_width = if (self.winSize.col > right_status_len) self.winSize.col - right_status_len else 0;
    const actual_left_content_len = @min(left_status_len, max_left_content_width);

    try status_line_builder.appendSlice(self.alloc, left_status_slice[0..actual_left_content_len]);
    current_width += actual_left_content_len;

    if (display_timed_status_msg) {
        const msg_to_display = self.statusMsg;
        const msg_len = msg_to_display.len;

        const available_for_msg_and_padding = if (self.winSize.col > current_width + right_status_len)
            self.winSize.col - current_width - right_status_len
        else
            0;

        const actual_msg_len = @min(msg_len, available_for_msg_and_padding);

        if (actual_msg_len > 0) {
            var padding_left: usize = 0;
            if (actual_msg_len < available_for_msg_and_padding) {
                padding_left = (available_for_msg_and_padding - actual_msg_len) / 2;
            }

            for (0..padding_left) |_| try status_line_builder.append(self.alloc, ' ');
            current_width += padding_left;

            try status_line_builder.appendSlice(self.alloc, msg_to_display[0..actual_msg_len]);
            current_width += actual_msg_len;
        }

        while (current_width < self.winSize.col - right_status_len) : (current_width += 1) {
            try status_line_builder.append(self.alloc, ' ');
        }
    } else {
        while (current_width < self.winSize.col - right_status_len) : (current_width += 1) {
            try status_line_builder.append(self.alloc, ' ');
        }
    }

    if (self.winSize.col >= right_status_len) {
        try status_line_builder.appendSlice(self.alloc, right_status_slice);
        current_width += right_status_len;
    }

    while (current_width < self.winSize.col) : (current_width += 1) {
        try status_line_builder.append(self.alloc, ' ');
    }

    try self.writer.writeAll(status_line_builder.items);
    try self.write("\x1b[m");
}

pub fn drawRows(self: *Editor) !void {
    var y: usize = 0;
    while (y < self.winSize.row) : (y += 1) {
        const fileRow = y + self.rowsOff;
        if (fileRow >= self.numRows) {
            if (self.numRows == 0 and y == self.winSize.row / 3) {
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
        } else {
            const currentRow = self.rows.items[fileRow];
            const start_idx = self.colsOff;
            if (start_idx < currentRow.chars.len) {
                const remaining_row_chars = currentRow.render.len - start_idx;
                const window_display_limit = self.winSize.col;
                const actual_display_length = @min(remaining_row_chars, window_display_limit);
                const end_idx = start_idx + actual_display_length;
                try self.write(currentRow.render[start_idx..end_idx]);
            }
        }
        try self.write("\x1b[K");
        try self.write("\r\n");
    }
}

fn scroll(self: *Editor) void {
    const position = self.cursorPosition;
    self.renderPosition.x = 0;
    if (position.y < self.numRows) {
        self.renderPosition.x = cursorPositionToRenderPosition(&self.rows.items[position.y], self.cursorPosition.x);
    }
    if (position.y < self.rowsOff) {
        self.rowsOff = position.y;
    }
    if (position.y >= self.rowsOff + self.winSize.row) {
        self.rowsOff = position.y - self.winSize.row + 1;
    }

    if (self.renderPosition.x < self.colsOff) {
        self.colsOff = self.renderPosition.x;
    }

    if (self.renderPosition.x >= self.colsOff + self.winSize.col) {
        self.colsOff = self.renderPosition.x - self.winSize.col + 1;
    }
}

pub fn updateWindowSize(self: *Editor) !void {
    var winSize: posix.winsize = undefined;
    const rc = posix.system.ioctl(stdin.handle, posix.T.IOCGWINSZ, @intFromPtr(&winSize));
    if (std.posix.errno(rc) == .SUCCESS) {
        self.winSize = winSize;
    }
    self.winSize.row -= 1;
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
                    'H' => key = EditorKey{ .cursor = CursorKey.home_key },
                    'F' => key = EditorKey{ .cursor = CursorKey.end_key },
                    '1', '2', '3', '4', '5', '6' => {
                        const fourth_char_result = self.reader.takeByte();
                        if (fourth_char_result == error.EndOfStream) {
                            return EditorKey{ .notImpl = {} };
                        }
                        const fourth_char = try fourth_char_result;

                        if (fourth_char == '~') {
                            switch (third_char) {
                                '1' => key = EditorKey{ .cursor = CursorKey.home_key },
                                '3' => key = EditorKey{ .delete_key = {} },
                                '4' => key = EditorKey{ .cursor = CursorKey.end_key },
                                '5' => key = EditorKey{ .cursor = CursorKey.page_up },
                                '6' => key = EditorKey{ .cursor = CursorKey.page_down },
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
