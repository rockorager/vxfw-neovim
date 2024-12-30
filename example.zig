const neovim = @import("neovim");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const std = @import("std");
var global_term: ?std.process.Child.Term = null;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var nvim = try neovim.Neovim.init(gpa.allocator(), &.{});
    defer nvim.deinit();
    try nvim.spawn();
    try nvim.createAutocmd("BufWritePost");
    nvim.onQuit = onQuit;
    nvim.onAutocmd = onAutocmd;

    var app = try vxfw.App.init(gpa.allocator());
    defer app.deinit();

    try app.run(nvim.widget(), .{});
    if (global_term) |term| {
        switch (term) {
            .Exited => |code| {
                if (code > 0)
                    std.log.err("error: {d}", .{code});
            },
            else => {},
        }
    }
}

fn onQuit(ptr: ?*anyopaque, ctx: *vxfw.EventContext, term: std.process.Child.Term) anyerror!void {
    _ = ptr;
    ctx.quit = true;
    global_term = term;
}

fn onAutocmd(ptr: ?*anyopaque, ctx: *vxfw.EventContext, event: neovim.AutocmdEvent) anyerror!void {
    _ = ctx; // autofix
    _ = ptr; // autofix
    std.log.debug("autocmd: {s}, file: {s}", .{ event.event, event.file });
}
