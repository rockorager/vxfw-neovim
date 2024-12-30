const std = @import("std");
const vaxis = @import("vaxis");
const neovim = @import("neovim");

const vxfw = vaxis.vxfw;

var global_term: ?std.process.Child.Term = null;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var nvim = try neovim.Neovim.init(gpa.allocator(), &.{});
    defer nvim.deinit();
    nvim.onQuit = onQuit;

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
