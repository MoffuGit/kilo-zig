const Editor = @import("editor");

pub fn main() !void {
    var editor = Editor.init();
    try editor.run();
}
