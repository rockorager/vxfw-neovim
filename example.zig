const std = @import("std");
const vaxis = @import("vaxis");
const neovim = @import("neovim");

const vxfw = vaxis.vxfw;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var nvim = try neovim.Neovim.init(gpa.allocator(), &.{});
    defer nvim.deinit();

    var app = try vxfw.App.init(gpa.allocator());
    defer app.deinit();

    try app.run(nvim.widget(), .{});
}
