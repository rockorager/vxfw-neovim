// Modules
const std = @import("std");
const vaxis = @import("vaxis");

// Local files
const Client = @import("Client.zig");

pub const AutocmdEvent = Client.AutocmdEvent;

// Type namespaces
const Allocator = std.mem.Allocator;

// Namespaces
const vxfw = vaxis.vxfw;

// Function aliases
const assert = std.debug.assert;
const stringWidth = vxfw.DrawContext.stringWidth;

const log = std.log.scoped(.neovim);

const Grid = struct {
    id: usize,
    offset_x: i17 = 0,
    offset_y: i17 = 0,
    screen: vaxis.AllocatingScreen,

    cursor: ?struct {
        row: u16,
        col: u16,
    } = null,

    fn create(allocator: std.mem.Allocator, id: usize, width: u16, height: u16) std.mem.Allocator.Error!*Grid {
        const grid = try allocator.create(Grid);
        const screen = try vaxis.AllocatingScreen.init(allocator, width, height);
        grid.* = .{
            .id = id,
            .screen = screen,
        };
        return grid;
    }

    fn destroy(self: *Grid, allocator: std.mem.Allocator) void {
        self.screen.deinit(allocator);
        allocator.destroy(self);
    }

    fn resize(self: *Grid, allocator: std.mem.Allocator, width: u16, height: u16) std.mem.Allocator.Error!void {
        self.screen.deinit(allocator);
        self.screen = try vaxis.AllocatingScreen.init(allocator, width, height);
    }

    /// Scroll down. This moves rows *up*
    fn scrollDown(self: *Grid, top: u16, bot: u16, left: u16, right: u16, rows: u16) void {
        // If we are scrolling 1 row, we are moving row 1 into row 0
        var row: u16 = top + rows;
        while (row < bot) : (row += 1) {
            const dst_row = row - rows;
            var col: u16 = left;
            while (col < right) : (col += 1) {
                const cell = self.screen.readCell(col, row) orelse continue;
                self.screen.writeCell(col, dst_row, cell);
            }
        }
    }

    /// Scroll up. This moves rows *down*
    fn scrollUp(self: *Grid, top: u16, bot: u16, left: u16, right: u16, rows: u16) void {
        // If we are scrolling 1 row, we are moving row 0 into row 1
        var row: u16 = (bot - 1) - rows;
        while (row >= top) : (row -= 1) {
            const dst_row = row + rows;
            var col: u16 = left;
            while (col < right) : (col += 1) {
                const cell = self.screen.readCell(col, row) orelse continue;
                self.screen.writeCell(col, dst_row, cell);
            }
            if (row == top) break;
        }
    }

    fn draw(self: *Grid, surface: *vxfw.Surface) void {
        assert(self.offset_x == 0 and self.offset_y == 0);
        assert(self.screen.width == surface.size.width and self.screen.height == surface.size.height);
        surface.focusable = true;
        var row: u16 = 0;
        while (row < self.screen.height) : (row += 1) {
            var col: u16 = 0;
            while (col < self.screen.width) : (col += 1) {
                const cell = self.screen.readCell(col, row) orelse @panic("invalid col + row");
                surface.writeCell(col, row, cell);
            }
        }
        if (self.cursor) |cursor| {
            surface.cursor = .{
                .row = cursor.row,
                .col = cursor.col,
                .shape = .default,
            };
        }
    }
};

const HlAttr = struct {
    id: usize,
    attr: Client.Attribute,
};

pub const Neovim = struct {
    gpa: std.mem.Allocator,

    client: Client,
    spawned: bool,

    size: vxfw.Size = .{},
    hl_attrs: std.ArrayList(HlAttr),
    grids: std.ArrayList(*Grid),
    modes: []Client.ModeInfo = &.{},
    mode: usize = 0,

    notifications: vaxis.Queue(Client.Notification, 256) = .{},

    surface_arena: std.heap.ArenaAllocator,
    surface: ?vxfw.Surface = null,

    has_quit: std.atomic.Value(bool),

    userdata: ?*anyopaque = null,
    onQuit: ?*const fn (?*anyopaque, *vxfw.EventContext, std.process.Child.Term) anyerror!void = null,
    onAutocmd: ?*const fn (?*anyopaque, *vxfw.EventContext, Client.AutocmdEvent) anyerror!void = null,

    /// args will be appended to `nvim --embed`
    pub fn init(gpa: std.mem.Allocator, args: []const []const u8) Allocator.Error!Neovim {
        const base_args = &.{ "nvim", "--embed" };
        var arg_list = try std.ArrayList([]const u8).initCapacity(gpa, base_args.len + args.len);
        defer arg_list.deinit();
        try arg_list.appendSlice(base_args);
        try arg_list.appendSlice(args);
        var process = std.process.Child.init(try arg_list.toOwnedSlice(), gpa);
        process.stdin_behavior = .Pipe;
        process.stdout_behavior = .Pipe;
        process.stderr_behavior = .Ignore;
        return .{
            .gpa = gpa,
            .client = Client.init(gpa, process),
            .hl_attrs = std.ArrayList(HlAttr).init(gpa),
            .grids = std.ArrayList(*Grid).init(gpa),
            .surface_arena = std.heap.ArenaAllocator.init(gpa),
            .has_quit = std.atomic.Value(bool).init(false),
            .spawned = false,
        };
    }

    pub fn deinit(self: *Neovim) void {
        const gpa = self.gpa;
        for (self.grids.items) |grid| {
            grid.screen.deinit(gpa);
            gpa.destroy(grid);
        }
        for (self.modes) |mode| {
            mode.deinit(gpa);
        }
        gpa.free(self.modes);

        gpa.free(self.client.process.argv);
        self.grids.deinit();
        self.hl_attrs.deinit();
        self.client.deinit();
        self.surface_arena.deinit();
    }

    pub fn widget(self: *Neovim) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = Neovim.typeErasedEventHandler,
            .drawFn = Neovim.typeErasedDrawFn,
        };
    }

    fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *Neovim = @ptrCast(@alignCast(ptr));
        return self.handleEvent(ctx, event);
    }

    /// Pushes neovim notifications into the main thread
    fn handleNeovimNotification(ptr: ?*anyopaque, notif: Client.Notification) void {
        const self: *Neovim = @ptrCast(@alignCast(ptr));
        self.notifications.push(notif);
    }

    pub fn createAutocmd(self: *Neovim, event: []const u8) !void {
        try self.client.createAutocmd(self.gpa, event);
    }

    pub fn spawn(self: *Neovim) anyerror!void {
        if (self.spawned) return;

        self.spawned = true;
        try self.client.spawn(self, Neovim.handleNeovimNotification);
    }

    /// Handle events from the vxfw runtime
    pub fn handleEvent(self: *Neovim, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        switch (event) {
            .init => {
                try self.spawn();
                try ctx.tick(8, self.widget());
            },
            .tick => {
                try ctx.tick(8, self.widget());
                while (self.notifications.tryPop()) |notif| {
                    switch (notif) {
                        .redraw => |ui_events| {
                            defer self.gpa.free(ui_events);
                            for (ui_events) |ui_event| {
                                try self.handleUiEvent(ctx, ui_event);
                            }
                        },
                        .quit => {
                            const term = try self.client.process.wait();
                            if (self.onQuit) |onQuit| {
                                try onQuit(self.userdata, ctx, term);
                            }
                        },
                        .autocmd => |au_event| {
                            defer au_event.deinit(self.gpa);
                            if (self.onAutocmd) |onAutocmd| {
                                try onAutocmd(self.userdata, ctx, au_event);
                            }
                        },
                        else => {},
                    }
                }
            },
            .key_press => |key| try self.handleKeyPress(ctx, key),
            .mouse => |mouse| {
                const nvim_button: Client.MouseButton = switch (mouse.button) {
                    .left => .left,
                    .right => .right,
                    .middle => .middle,
                    .wheel_up,
                    .wheel_down,
                    .wheel_left,
                    .wheel_right,
                    => .wheel,
                    .none => .move,
                    else => return,
                };

                const action: Client.MouseAction = if (nvim_button == .wheel) switch (mouse.button) {
                    .wheel_up => .up,
                    .wheel_down => .down,
                    .wheel_left => .left,
                    .wheel_right => .right,
                    else => unreachable,
                } else switch (mouse.type) {
                    .press => .press,
                    .drag => .drag,
                    .release => .release,
                    .motion => .release, // This gets ignored

                };

                var buf: [8]u8 = undefined;
                var fbs = std.io.fixedBufferStream(&buf);
                if (mouse.mods.ctrl) try fbs.writer().writeByte('C');
                if (mouse.mods.alt) try fbs.writer().writeByte('A');
                if (mouse.mods.shift) try fbs.writer().writeByte('S');

                const mods = fbs.getWritten();

                try self.client.inputMouse(nvim_button, action, mods, mouse.row, mouse.col);
            },
            else => {},
        }
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const self: *Neovim = @ptrCast(@alignCast(ptr));
        return self.draw(ctx);
    }

    /// Draw the widget. Neovim will consume the maximum size given to it. If no constraints are
    /// given, neovim will panic
    pub fn draw(self: *Neovim, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        if (ctx.max.width == null or ctx.max.height == null)
            @panic("Neovim requires a maximum size");
        const max = ctx.max.size();
        const surface = self.surface orelse {
            self.client.uiAttach(max.width, max.height, .{ .ext_linegrid = true }) catch |err| {
                log.err("couldn't attach to UI: {}", .{err});
            };
            return .{
                .size = ctx.min,
                .widget = self.widget(),
                .buffer = &.{},
                .children = &.{},
            };
        };

        if (max.width != self.size.width or
            max.height != self.size.height)
        {
            self.client.tryResize(max.width, max.height) catch |err| {
                log.err("couldn't resize: {}", .{err});
                @panic("resize failure");
            };
            return .{
                .size = ctx.min,
                .widget = self.widget(),
                .buffer = &.{},
                .children = &.{},
            };
        }
        return surface;
    }

    fn handleUiEvent(self: *Neovim, ctx: *vxfw.EventContext, event: Client.UiEvent) anyerror!void {
        var style: vaxis.Style = .{};
        defer event.deinit(self.gpa);
        switch (event) {
            .flush => {
                const grid = self.getGrid(1) orelse unreachable;
                if (self.surface) |*surface| {
                    grid.draw(surface);
                    ctx.redraw = true;
                    if (surface.cursor) |_| {
                        if (self.getMode(self.mode)) |mode| {
                            surface.cursor.?.shape = mode.cursor_shape;
                        }
                    }
                }
                grid.cursor = null;
            },
            .hl_attr_define => |attr| {
                for (self.hl_attrs.items, 0..) |exist_attr, i| {
                    if (attr.id == exist_attr.id) {
                        self.hl_attrs.items[i] = .{ .id = attr.id, .attr = attr.rgb_attrs };
                        return;
                    }
                }
                try self.hl_attrs.append(.{ .id = attr.id, .attr = attr.rgb_attrs });
            },
            .grid_resize => |gr| {
                log.debug("grid_resize: w={d}, h={d}, grid={d}", .{ gr.width, gr.height, gr.grid });
                if (self.getGrid(gr.grid)) |grid| {
                    try grid.resize(self.gpa, gr.width, gr.height);
                } else {
                    const grid = try Grid.create(self.gpa, gr.grid, gr.width, gr.height);
                    try self.grids.append(grid);
                }
                if (gr.grid != 1) {
                    @panic("unknown grid");
                }
                _ = self.surface_arena.reset(.retain_capacity);
                self.size = .{
                    .width = gr.width,
                    .height = gr.height,
                };
                self.surface = try vxfw.Surface.init(
                    self.surface_arena.allocator(),
                    self.widget(),
                    self.size,
                );
            },
            .grid_line => |gl| {
                const grid = self.getGrid(gl.grid) orelse {
                    log.err("no grid: {d}", .{gl.grid});
                    return;
                };
                var col = gl.col_start;
                for (gl.cells) |cell| {
                    if (cell.hl_id) |id|
                        style = self.attrToStyle(id);
                    const repeat = if (cell.repeat) |repeat| repeat else 1;
                    for (0..repeat) |_| {
                        const content: []const u8 = if (cell.content.len == 0) " " else cell.content;
                        grid.screen.writeCell(col, gl.row, .{
                            .char = .{
                                .grapheme = content,
                                // Let the renderer measure the glyph
                                .width = 0,
                            },
                            .style = style,
                        });
                        col += 1;
                    }
                }
            },
            .grid_scroll => |gs| {
                const grid = self.getGrid(gs.grid) orelse return;
                if (gs.rows > 0) {
                    grid.scrollDown(gs.top, gs.bot, gs.left, gs.right, @intCast(gs.rows));
                } else {
                    grid.scrollUp(gs.top, gs.bot, gs.left, gs.right, @intCast(-gs.rows));
                }
            },
            .grid_cursor_goto => |gcg| {
                if (self.getGrid(gcg.grid)) |grid| {
                    grid.cursor = .{
                        .row = gcg.row,
                        .col = gcg.col,
                    };
                }
            },
            .mode_info_set => |set| {
                for (self.modes) |mode| {
                    mode.deinit(self.gpa);
                }
                self.gpa.free(self.modes);
                self.modes = try self.gpa.alloc(Client.ModeInfo, set.mode_infos.len);
                for (set.mode_infos, 0..) |mode_info, i| {
                    self.modes[i] = try mode_info.clone(self.gpa);
                }
            },
            .mode_change => |chg| {
                self.mode = chg.mode_idx;
            },
            else => {},
        }
    }

    fn handleKeyPress(self: *Neovim, ctx: *vxfw.EventContext, key: vaxis.Key) anyerror!void {
        ctx.consume_event = true;

        // Ignore modifier only keys
        if (key.isModifier())
            return;

        if (key.text) |text| {
            if (std.mem.eql(u8, text, "<"))
                return self.client.input("<lt>")
            else
                return self.client.input(text);
        }
        var buf: [128]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        const writer = fbs.writer();

        const mods: u8 = @bitCast(key.mods);
        if (mods > 0) try writer.writeByte('<');
        // mods
        {
            if (key.mods.super) try writer.writeAll("D-");
            if (key.mods.alt) try writer.writeAll("A-");
            if (key.mods.meta) try writer.writeAll("M-");
            if (key.mods.ctrl) try writer.writeAll("C-");
            if (key.mods.shift) try writer.writeAll("S-");
        }
        switch (key.codepoint) {
            vaxis.Key.backspace => {
                if (mods == 0) try writer.writeByte('<');
                try writer.writeAll("BS>");
            },
            vaxis.Key.delete => {
                if (mods == 0) try writer.writeByte('<');
                try writer.writeAll("Del>");
            },
            vaxis.Key.down => {
                if (mods == 0) try writer.writeByte('<');
                try writer.writeAll("Down>");
            },
            vaxis.Key.end => {
                if (mods == 0) try writer.writeByte('<');
                try writer.writeAll("End>");
            },
            vaxis.Key.enter => {
                if (mods == 0) try writer.writeByte('<');
                try writer.writeAll("CR>");
            },
            vaxis.Key.escape => {
                if (mods == 0) try writer.writeByte('<');
                try writer.writeAll("ESC>");
            },
            vaxis.Key.f1 => {
                if (mods == 0) try writer.writeByte('<');
                try writer.writeAll("F1>");
            },
            vaxis.Key.f2 => {
                if (mods == 0) try writer.writeByte('<');
                try writer.writeAll("F2>");
            },
            vaxis.Key.f3 => {
                if (mods == 0) try writer.writeByte('<');
                try writer.writeAll("F3>");
            },
            vaxis.Key.f4 => {
                if (mods == 0) try writer.writeByte('<');
                try writer.writeAll("F4>");
            },
            vaxis.Key.f5 => {
                if (mods == 0) try writer.writeByte('<');
                try writer.writeAll("F5>");
            },
            vaxis.Key.f6 => {
                if (mods == 0) try writer.writeByte('<');
                try writer.writeAll("F6>");
            },
            vaxis.Key.f7 => {
                if (mods == 0) try writer.writeByte('<');
                try writer.writeAll("F7>");
            },
            vaxis.Key.f8 => {
                if (mods == 0) try writer.writeByte('<');
                try writer.writeAll("F8>");
            },
            vaxis.Key.f9 => {
                if (mods == 0) try writer.writeByte('<');
                try writer.writeAll("F9>");
            },
            vaxis.Key.f10 => {
                if (mods == 0) try writer.writeByte('<');
                try writer.writeAll("F10>");
            },
            vaxis.Key.f11 => {
                if (mods == 0) try writer.writeByte('<');
                try writer.writeAll("F11>");
            },
            vaxis.Key.f12 => {
                if (mods == 0) try writer.writeByte('<');
                try writer.writeAll("F12>");
            },
            vaxis.Key.home => {
                if (mods == 0) try writer.writeByte('<');
                try writer.writeAll("Home>");
            },
            vaxis.Key.insert => {
                if (mods == 0) try writer.writeByte('<');
                try writer.writeAll("Insert>");
            },
            vaxis.Key.left => {
                if (mods == 0) try writer.writeByte('<');
                try writer.writeAll("Left>");
            },
            vaxis.Key.kp_up => {
                if (mods == 0) try writer.writeByte('<');
                try writer.writeAll("kUp>");
            },
            vaxis.Key.kp_down => {
                if (mods == 0) try writer.writeByte('<');
                try writer.writeAll("kDown>");
            },
            vaxis.Key.kp_left => {
                if (mods == 0) try writer.writeByte('<');
                try writer.writeAll("kLeft>");
            },
            vaxis.Key.kp_right => {
                if (mods == 0) try writer.writeByte('<');
                try writer.writeAll("kRight>");
            },
            vaxis.Key.page_up => {
                if (mods == 0) try writer.writeByte('<');
                try writer.writeAll("PageUp>");
            },
            vaxis.Key.page_down => {
                if (mods == 0) try writer.writeByte('<');
                try writer.writeAll("PageDown>");
            },
            vaxis.Key.right => {
                if (mods == 0) try writer.writeByte('<');
                try writer.writeAll("Right>");
            },
            vaxis.Key.tab => {
                if (mods == 0) try writer.writeByte('<');
                try writer.writeAll("Tab>");
            },
            vaxis.Key.up => {
                if (mods == 0) try writer.writeByte('<');
                try writer.writeAll("Up>");
            },
            '<' => {
                if (mods == 0) try writer.writeByte('<');
                try writer.writeAll("lt>");
            },
            else => {
                var u_buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(key.codepoint, &u_buf) catch {
                    std.log.err("invalid unicode codepoint: {d}", .{key.codepoint});
                    return;
                };
                try writer.writeAll(u_buf[0..n]);
                if (mods > 0) try writer.writeByte('>');
            },
        }
        try self.client.input(fbs.getWritten());
    }

    fn getGrid(self: Neovim, id: usize) ?*Grid {
        for (self.grids.items) |grid| {
            if (grid.id == id) return grid;
        }
        return null;
    }

    fn getMode(self: Neovim, idx: usize) ?Client.ModeInfo {
        if (idx >= self.modes.len) return null;
        return self.modes[idx];
    }

    fn attrToStyle(self: Neovim, attr_id: usize) vaxis.Style {
        for (self.hl_attrs.items) |attr| {
            if (attr.id != attr_id) continue;
            return .{
                .fg = if (attr.attr.fg) |val| vaxis.Color.rgbFromUint(val) else .default,
                .bg = if (attr.attr.bg) |val| vaxis.Color.rgbFromUint(val) else .default,
                .ul = if (attr.attr.sp) |val| vaxis.Color.rgbFromUint(val) else .default,
                .ul_style = if (attr.attr.underline)
                    .single
                else if (attr.attr.undercurl)
                    .curly
                else if (attr.attr.underdouble)
                    .double
                else if (attr.attr.underdotted)
                    .dotted
                else if (attr.attr.underdashed)
                    .dashed
                else
                    .off,
                .bold = attr.attr.bold,
                .reverse = attr.attr.reverse,
                .italic = attr.attr.italic,
                .strikethrough = attr.attr.strikethrough,
            };
        }
        return .{};
    }
};

test {
    _ = @import("msgpack.zig");
    _ = @import("Client.zig");
}
