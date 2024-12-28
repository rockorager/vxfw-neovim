const Client = @This();

const std = @import("std");
const msgpack = @import("msgpack.zig");
const vaxis = @import("vaxis");

const assert = std.debug.assert;

const log = std.log.scoped(.nvim);

const PacketType = enum {
    request,
    response,
    notification,
};

pub const Event = union(enum) {
    response,
    notification,
};

pub const UiOptions = struct {
    rgb: bool = true,
    /// Externalize the cmdline
    ext_cmdline: bool = false,
    /// Externalize popupmenu completion and wildmenu popup completion
    ext_popupmenu: bool = false,
    /// Externalize the tabline
    ext_tabline: bool = false,
    /// Externalize the wildmenu
    ext_wildmenu: bool = false,
    /// Externalize messages
    ext_messages: bool = false,
    /// Line-based grid events
    ext_linegrid: bool = true,
    /// Per window grid events
    ext_multigrid: bool = false,
    /// Detailed highlight state
    ext_hlstate: bool = false,
    /// Use external default colors
    ext_termcolors: bool = false,
};

const NotificationType = enum {
    redraw,
    quit,
    unknown,
};

pub const Notification = union(NotificationType) {
    redraw: []UiEvent,
    quit,
    unknown: msgpack.Value,
};

pub const ModeInfo = struct {
    cursor_shape: vaxis.Cell.CursorShape = .block,
    attr_id: u32 = 0,
    short_name: []const u8,
    name: []const u8,

    pub fn deinit(self: ModeInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.short_name);
        allocator.free(self.name);
    }

    pub fn clone(self: ModeInfo, gpa: std.mem.Allocator) std.mem.Allocator.Error!ModeInfo {
        return .{
            .cursor_shape = self.cursor_shape,
            .attr_id = self.attr_id,
            .short_name = try gpa.dupe(u8, self.short_name),
            .name = try gpa.dupe(u8, self.name),
        };
    }
};

pub const Cell = struct {
    content: []const u8,
    hl_id: ?usize = null,
    repeat: ?usize = null,
};

pub const Attribute = struct {
    fg: ?u24 = null,
    bg: ?u24 = null,
    sp: ?u24 = null, // underline color
    reverse: bool = false,
    italic: bool = false,
    bold: bool = false,
    strikethrough: bool = false,
    underline: bool = false,
    undercurl: bool = false,
    underdouble: bool = false,
    underdotted: bool = false,
    underdashed: bool = false,
    url: ?[]const u8 = null,

    pub fn msgpackUnpackFromValue(value: msgpack.Value) anyerror!Attribute {
        assert(value == .map);
        const map = value.map;
        return .{
            .fg = if (map.get("foreground")) |val| try msgpack.unpackFromValue(u24, val) else null,
            .bg = if (map.get("background")) |val| try msgpack.unpackFromValue(u24, val) else null,
            .sp = if (map.get("special")) |val| try msgpack.unpackFromValue(u24, val) else null,
            .reverse = if (map.get("reverse")) |val| try msgpack.unpackFromValue(bool, val) else false,
            .italic = if (map.get("italic")) |val| try msgpack.unpackFromValue(bool, val) else false,
            .bold = if (map.get("bold")) |val| try msgpack.unpackFromValue(bool, val) else false,
            .strikethrough = if (map.get("strikethrough")) |val| try msgpack.unpackFromValue(bool, val) else false,
            .underline = if (map.get("underline")) |val| try msgpack.unpackFromValue(bool, val) else false,
            .undercurl = if (map.get("undercurl")) |val| try msgpack.unpackFromValue(bool, val) else false,
            .underdouble = if (map.get("underdouble")) |val| try msgpack.unpackFromValue(bool, val) else false,
            .underdotted = if (map.get("underdotted")) |val| try msgpack.unpackFromValue(bool, val) else false,
            .underdashed = if (map.get("underdashed")) |val| try msgpack.unpackFromValue(bool, val) else false,
        };
    }
};

pub const UiEventType = enum {
    mode_info_set,
    update_menu,
    busy_start,
    busy_stop,
    mouse_on,
    mouse_off,
    mode_change,
    bell,
    visual_bell,
    flush,
    @"suspend",
    set_title,
    set_icon,
    screenshot,
    option_set,
    chdir,
    update_fg,
    update_bg,
    update_sp,
    resize,
    clear,
    eol_clear,
    cursor_goto,
    highlight_set,
    put,
    set_scroll_region,
    scroll,
    default_colors_set,
    hl_attr_define,
    hl_group_set,
    grid_resize,
    grid_clear,
    grid_cursor_goto,
    grid_line,
    grid_scroll,
    grid_destroy,

    unknown,
};

pub const UiEvent = union(UiEventType) {
    mode_info_set: struct {
        cursor_style_enabled: bool,
        mode_infos: []ModeInfo,
    },
    update_menu,
    busy_start,
    busy_stop,
    mouse_on,
    mouse_off,
    mode_change: struct {
        mode: []const u8,
        mode_idx: usize,
    },
    bell,
    visual_bell,
    flush,
    @"suspend",
    set_title: []const u8,
    set_icon: []const u8,
    screenshot: []const u8,
    option_set: struct {
        name: []const u8,
        value: struct {},
    },
    chdir: []const u8,
    update_fg: u32,
    update_bg: u32,
    update_sp: u32,
    resize: struct {
        width: usize,
        height: usize,
    },
    clear,
    eol_clear,
    cursor_goto: struct {
        row: usize,
        col: usize,
    },
    highlight_set: std.StringHashMap(msgpack.Value),
    put: []const u8,
    set_scroll_region: struct {
        top: usize,
        bot: usize,
        left: usize,
        right: usize,
    },
    scroll: usize,
    default_colors_set: struct {
        rgb_fg: u24,
        rgb_bg: u24,
        rgb_sp: u24,
        cterm_fg: u24,
        cterm_bg: u24,
    },
    hl_attr_define: struct {
        id: usize,
        rgb_attrs: Attribute,
        cterm_attrs: Attribute,
        info: struct {}, // array
    },
    hl_group_set: struct {
        name: []const u8,
        id: usize,
    },
    grid_resize: struct {
        grid: usize,
        width: u16,
        height: u16,
    },
    grid_clear: usize,
    grid_cursor_goto: struct {
        grid: usize,
        row: u16,
        col: u16,
    },
    grid_line: struct {
        grid: usize,
        row: u16,
        col_start: u16,
        cells: []Cell,
        wrap: bool,
    },
    grid_scroll: struct {
        grid: usize,
        top: u16,
        bot: u16,
        left: u16,
        right: u16,
        rows: i17,
        cols: i17,
    },
    grid_destroy: usize,

    unknown,

    fn decodeAlloc(allocator: std.mem.Allocator, name: []const u8, args: []msgpack.Value) anyerror!UiEvent {
        if (std.meta.stringToEnum(UiEventType, name)) |kind| {
            switch (kind) {
                .mode_info_set => {
                    // std.log.debug("mode_info_set: {s}", .{args});
                    assert(args.len == 2); // mode_info_set: 2 parameters
                    assert(args[0] == .bool); // cursor_style_enabled: Boolean
                    assert(args[1] == .array); // info: Array
                    const info_sets = args[1].array;
                    const infos = try allocator.alloc(ModeInfo, info_sets.len);
                    for (info_sets, 0..) |set, i| {
                        const shape: vaxis.Cell.CursorShape = blk: {
                            if (set.map.get("cursor_shape")) |shape| {
                                if (std.mem.eql(u8, shape.str, "block"))
                                    break :blk .block;
                                if (std.mem.eql(u8, shape.str, "horizontal"))
                                    break :blk .underline;
                                if (std.mem.eql(u8, shape.str, "vertical"))
                                    break :blk .beam;
                            }
                            break :blk .block;
                        };

                        const attr: u32 = if (set.map.get("attr_id")) |attr_id|
                            @intCast(attr_id.u64)
                        else
                            0;

                        const short = if (set.map.get("short_name")) |sn|
                            sn.str
                        else
                            "";

                        const long = if (set.map.get("name")) |ln|
                            ln.str
                        else
                            "";

                        const mode: ModeInfo = .{
                            .cursor_shape = shape,
                            .attr_id = attr,
                            .short_name = try allocator.dupe(u8, short),
                            .name = try allocator.dupe(u8, long),
                        };
                        infos[i] = mode;
                    }
                    return .{
                        .mode_info_set = .{
                            .cursor_style_enabled = args[0].bool,
                            .mode_infos = infos,
                        },
                    };
                },
                .update_menu => return .update_menu,
                .busy_start => return .busy_start,
                .busy_stop => return .busy_stop,
                .mouse_on => return .mouse_on,
                .mouse_off => return .mouse_off,
                .mode_change => {
                    assert(args.len == 2); // mode_change: 2 parameters
                    assert(args[0] == .str); // mode: String
                    assert(args[1] == .u64); // mode_idx: Integer
                    return .{ .mode_change = .{
                        .mode = try allocator.dupe(u8, args[0].str),
                        .mode_idx = args[1].u64,
                    } };
                },
                .bell => return .bell,
                .visual_bell => return .visual_bell,
                .flush => return .flush,
                .@"suspend" => return .@"suspend",
                .set_title => {
                    assert(args.len == 1); // set_title: 1 parameter
                    assert(args[0] == .str); // title: String
                    return .{ .set_title = try allocator.dupe(u8, args[0].str) };
                },
                .set_icon => {
                    assert(args.len == 1); // set_icon: 1 parameter
                    assert(args[0] == .str); // title: String
                    return .{ .set_icon = try allocator.dupe(u8, args[0].str) };
                },
                .screenshot => {
                    assert(args.len == 1); // screenshot: 1 parameter
                    assert(args[0] == .str); // title: String
                    return .{ .screenshot = try allocator.dupe(u8, args[0].str) };
                },
                .option_set => {
                    std.log.debug("option_set: {s}", .{args});
                    assert(args.len == 2); // option_set: 2 parameters
                    assert(args[0] == .str); // name: string
                    // Second param depends on value
                    return .unknown;
                },
                .chdir => {
                    assert(args.len == 1); // chdir: 1 parameter
                    assert(args[0] == .str); // chdir: String
                    return .{ .chdir = try allocator.dupe(u8, args[0].str) };
                },
                .update_fg => {
                    assert(args.len == 1); // update_fg: 1 parameter
                    assert(args[0] == .u64); // update_fg: u64
                    return .{ .update_fg = @intCast(args[0].u64) };
                },
                .update_bg => {
                    assert(args.len == 1); // update_bg: 1 parameter
                    assert(args[0] == .u64); // update_bg: u64
                    return .{ .update_bg = @intCast(args[0].u64) };
                },
                .update_sp => {
                    assert(args.len == 1); // update_sp: 1 parameter
                    assert(args[0] == .u64); // update_sp: u64
                    return .{ .update_sp = @intCast(args[0].u64) };
                },
                .resize => {
                    assert(args.len == 2); // resize: 2 parameters
                    return .{ .resize = .{
                        .width = try msgpack.unpackFromValue(usize, args[0]),
                        .height = try msgpack.unpackFromValue(usize, args[1]),
                    } };
                },
                .clear => return .clear,
                .eol_clear => return .eol_clear,
                .cursor_goto => {
                    assert(args.len == 2); // cursor_goto: 2 parameters
                    return .{ .cursor_goto = .{
                        .row = try msgpack.unpackFromValue(usize, args[0]),
                        .col = try msgpack.unpackFromValue(usize, args[1]),
                    } };
                },
                .highlight_set => {
                    std.log.debug("highlight_set: {s}", .{args});
                    assert(args.len == 2); // option_set: 2 parameters
                    assert(args[0] == .str); // name: string
                    // Second param depends on value
                    return .unknown;
                },
                .put => {
                    assert(args.len == 1); // put: 1 parameter
                    assert(args[0] == .str); // put: String
                    return .{ .put = try allocator.dupe(u8, args[0].str) };
                },
                .set_scroll_region => {
                    assert(args.len == 4); // set_scroll_region: 4 parameter
                    assert(args[0] == .u64); // set_scroll_region: u64
                    assert(args[1] == .u64); // set_scroll_region: u64
                    assert(args[2] == .u64); // set_scroll_region: u64
                    assert(args[3] == .u64); // set_scroll_region: u64
                    return .{ .set_scroll_region = .{
                        .top = args[0].u64,
                        .bot = args[1].u64,
                        .left = args[2].u64,
                        .right = args[3].u64,
                    } };
                },
                .scroll => {
                    assert(args.len == 1); // scroll: 1 parameter
                    assert(args[0] == .u64); // scroll: u64
                    return .{ .scroll = @intCast(args[0].u64) };
                },
                .default_colors_set => {
                    assert(args.len == 5); // default_colors_set: 4 parameter
                    assert(args[0] == .u64); // default_colors_set: u64
                    assert(args[1] == .u64); // default_colors_set: u64
                    assert(args[2] == .u64); // default_colors_set: u64
                    assert(args[3] == .u64); // default_colors_set: u64
                    assert(args[4] == .u64); // default_colors_set: u64
                    return .{ .default_colors_set = .{
                        .rgb_fg = @intCast(args[0].u64),
                        .rgb_bg = @intCast(args[1].u64),
                        .rgb_sp = @intCast(args[2].u64),
                        .cterm_fg = @intCast(args[3].u64),
                        .cterm_bg = @intCast(args[4].u64),
                    } };
                },
                .hl_attr_define => {
                    assert(args.len == 4); // hl_attr_define: 4 parameter
                    assert(args[0] == .u64); // id: u64
                    assert(args[1] == .map); // rgb_attrs: map
                    assert(args[2] == .map); // cterm_attrs: map
                    assert(args[3] == .array); // info: array
                    return .{ .hl_attr_define = .{
                        .id = try msgpack.unpackFromValue(u32, args[0]),
                        .rgb_attrs = try msgpack.unpackFromValue(Attribute, args[1]),
                        .cterm_attrs = try msgpack.unpackFromValue(Attribute, args[2]),
                        .info = .{},
                    } };
                },
                .hl_group_set => {
                    assert(args.len == 2); // hl_group_set: 2 parameters
                    assert(args[0] == .str); // name: string
                    assert(args[1] == .u64); // id: u64
                    return .{ .hl_group_set = .{
                        .name = try allocator.dupe(u8, args[0].str),
                        .id = @intCast(args[1].u64),
                    } };
                },
                .grid_resize => {
                    assert(args.len == 3); // grid_resize: 4 parameter
                    assert(args[0] == .u64); // grid: u64
                    assert(args[1] == .u64); // width: u64
                    assert(args[2] == .u64); // height: u64
                    return .{ .grid_resize = .{
                        .grid = @intCast(args[0].u64),
                        .width = @intCast(args[1].u64),
                        .height = @intCast(args[2].u64),
                    } };
                },
                .grid_clear => {
                    assert(args.len == 1); // grid_clear: 1 parameter
                    assert(args[0] == .u64); // grid: u64
                    return .{ .grid_clear = @intCast(args[0].u64) };
                },
                .grid_cursor_goto => {
                    assert(args.len == 3); // grid_cursor_goto: 4 parameter
                    assert(args[0] == .u64); // grid: u64
                    assert(args[1] == .u64); // row: u64
                    assert(args[2] == .u64); // col: u64
                    return .{ .grid_cursor_goto = .{
                        .grid = @intCast(args[0].u64),
                        .row = @intCast(args[1].u64),
                        .col = @intCast(args[2].u64),
                    } };
                },
                .grid_line => {
                    assert(args.len == 5); // grid_cursor_goto: 4 parameter
                    assert(args[0] == .u64); // grid: u64
                    assert(args[1] == .u64); // row: u64
                    assert(args[2] == .u64); // col_start: u64
                    assert(args[3] == .array); // cells: array
                    assert(args[4] == .bool); // wrap: array
                    const cells = try allocator.alloc(Cell, args[3].array.len);
                    for (args[3].array, 0..) |item, i| {
                        assert(item == .array);
                        assert(item.array.len > 0);
                        assert(item.array[0] == .str);
                        const cell: Cell = switch (item.array.len) {
                            1 => .{
                                .content = try allocator.dupe(u8, item.array[0].str),
                            },
                            2 => blk: {
                                assert(item.array[1] == .u64);
                                break :blk .{
                                    .content = try allocator.dupe(u8, item.array[0].str),
                                    .hl_id = @intCast(item.array[1].u64),
                                };
                            },
                            3 => blk: {
                                assert(item.array[1] == .u64);
                                assert(item.array[2] == .u64);
                                break :blk .{
                                    .content = try allocator.dupe(u8, item.array[0].str),
                                    .hl_id = @intCast(item.array[1].u64),
                                    .repeat = @intCast(item.array[2].u64),
                                };
                            },
                            else => unreachable, // cell always 1-3 long
                        };
                        cells[i] = cell;
                    }
                    return .{ .grid_line = .{
                        .grid = @intCast(args[0].u64),
                        .row = @intCast(args[1].u64),
                        .col_start = @intCast(args[2].u64),
                        .cells = cells,
                        .wrap = args[4].bool,
                    } };
                },
                .grid_scroll => {
                    assert(args.len == 7); // grid_scroll: 4 parameter
                    assert(args[0] == .u64); // grid: u64
                    assert(args[1] == .u64); // top: u64
                    assert(args[2] == .u64); // bot: u64
                    assert(args[3] == .u64); // left: u64
                    assert(args[4] == .u64); // right: u64
                    const rows = msgpack.unpackFromValue(i17, args[5]) catch
                        unreachable; // rows: i64 or u64
                    const cols = msgpack.unpackFromValue(i17, args[6]) catch
                        unreachable; // cols: i64 or u64
                    return .{ .grid_scroll = .{
                        .grid = @intCast(args[0].u64),
                        .top = @intCast(args[1].u64),
                        .bot = @intCast(args[2].u64),
                        .left = @intCast(args[3].u64),
                        .right = @intCast(args[4].u64),
                        .rows = rows,
                        .cols = cols,
                    } };
                },
                .grid_destroy => {
                    assert(args.len == 1); // grid_destroy: 1 parameter
                    assert(args[0] == .u64); // grid: u64
                    return .{ .grid_destroy = @intCast(args[0].u64) };
                },
                else => {},
            }
        }
        log.debug("unknown event: {s}\r", .{name});
        return .unknown;
    }

    pub fn deinit(self: UiEvent, allocator: std.mem.Allocator) void {
        switch (self) {
            .mode_info_set => |set| {
                for (set.mode_infos) |info| {
                    info.deinit(allocator);
                }
                allocator.free(set.mode_infos);
            },
            .mode_change => |change| {
                allocator.free(change.mode);
            },
            .set_title => |title| {
                allocator.free(title);
            },
            .set_icon => |icon| {
                allocator.free(icon);
            },
            .screenshot => |screenshot| {
                allocator.free(screenshot);
            },
            .put => |put| {
                allocator.free(put);
            },
            .chdir => |chdir| {
                allocator.free(chdir);
            },
            .hl_group_set => |group| {
                allocator.free(group.name);
            },
            .grid_line => |line| {
                for (line.cells) |cell| {
                    allocator.free(cell.content);
                }
                allocator.free(line.cells);
            },
            else => {},
        }
    }
};

const Request = struct {
    id: u32,
    cond: std.Thread.Condition,
    response: ?Response = null,
};

pub const Response = struct {
    value: msgpack.Value,

    pub fn errorMsg(self: Response) ?[]const u8 {
        assert(self.value == .array);
        assert(self.value.array.len == 4);
        switch (self.value.array[2]) {
            .array => |arr| {
                assert(arr.len == 2);
                assert(arr[1] == .str);
                return arr[1].str;
            },
            .str => |err| return err,
            else => return null,
        }
    }

    pub fn result(self: Response) msgpack.Value {
        assert(self.value == .array);
        assert(self.value.array.len == 4);
        return self.value.array[3];
    }

    pub fn deinit(self: Response, allocator: std.mem.Allocator) void {
        self.value.deinit(allocator);
    }
};

allocator: std.mem.Allocator,
id: std.atomic.Value(u32),
process: std.process.Child,

response_mut: std.Thread.Mutex = .{},
responses: std.ArrayList(*Request),

pub fn init(allocator: std.mem.Allocator, process: std.process.Child) Client {
    assert(process.stdout_behavior == .Pipe);
    assert(process.stdin_behavior == .Pipe);
    return .{
        .allocator = allocator,
        .id = std.atomic.Value(u32).init(0),
        .process = process,
        .responses = std.ArrayList(*Request).init(allocator),
    };
}

pub fn deinit(self: *Client) void {
    self.responses.deinit();
}

pub fn spawn(self: *Client, userdata: ?*anyopaque, callback: ?*const fn (?*anyopaque, Notification) void) !void {
    try self.process.spawn();
    // TODO: handle thread
    _ = try std.Thread.spawn(.{}, Client.readEvents, .{ self, userdata, callback });
}

fn nextId(self: *Client) u32 {
    const id = self.id.load(.unordered);
    // wraparound just in case
    self.id.store(id +% 1, .unordered);
    return id;
}

/// Call a function and wait for the response
pub fn callAndWait(self: *Client, method: []const u8, args: anytype) !Response {
    const id = self.nextId();

    var response: Request = .{
        .id = id,
        .cond = .{},
    };

    // grab the lock
    self.response_mut.lock();
    defer self.response_mut.unlock();

    // add our response
    try self.responses.append(&response);

    // make the call
    const stdin = self.process.stdin orelse return error.NoStdin;
    try msgpack.pack(stdin.writer().any(), .{
        0, // request
        id,
        method,
        args,
    }, .{});

    // wait for the response
    while (response.response == null) {
        response.cond.wait(&self.response_mut);
    }

    errdefer response.response.?.deinit(self.allocator);
    if (response.response.?.errorMsg()) |err| {
        log.err("{s}", .{err});
        return error.NvimError;
    }
    return response.response.?;
}

fn readEvents(self: *Client, userdata: ?*anyopaque, maybe_callback: ?*const fn (?*anyopaque, Notification) void) void {
    const stdout = self.process.stdout orelse return;
    defer {
        if (maybe_callback) |callback| {
            callback(userdata, .quit);
        }
    }
    while (true) {
        const value = msgpack.unpackValue(self.allocator, stdout.reader().any()) catch return;
        assert(value == .array); // neovim only returns arrays
        const array = value.array;

        assert(array[0] == .u64); // index 0 is message type as a positive integer
        const packet_type: PacketType = @enumFromInt(array[0].u64);
        switch (packet_type) {
            .request => {
                log.debug("request: {}", .{value});
            },
            .response => {
                assert(array.len == 4); // responses have 4 elements
                assert(array[1] == .u64); // index 1 is the request id
                const id = array[1].u64;
                self.response_mut.lock();
                defer self.response_mut.unlock();
                for (self.responses.items, 0..) |resp, i| {
                    if (id != resp.id) continue;
                    _ = self.responses.orderedRemove(i);
                    resp.response = .{ .value = value };
                    resp.cond.signal();
                    break;
                }
            },
            .notification => {
                assert(array.len == 3); // notifications have 3 elements
                assert(array[1] == .str);
                if (maybe_callback) |callback| {
                    const kind = if (std.meta.stringToEnum(NotificationType, array[1].str)) |k|
                        k
                    else
                        .unknown;
                    switch (kind) {
                        .redraw => {
                            // [Integer, "redraw", Array]
                            assert(array[2] == .array);
                            defer array[2].deinit(self.allocator);
                            var events = std.ArrayList(UiEvent).initCapacity(self.allocator, array[2].array.len) catch {
                                log.err("out of memory", .{});
                                return;
                            };
                            for (array[2].array) |item| {
                                assert(item == .array);
                                assert(item.array.len > 0);
                                assert(item.array[0] == .str); // redraw event: first element is string
                                const name = item.array[0].str;

                                for (item.array[1..]) |args| {
                                    assert(args == .array);
                                    const event = UiEvent.decodeAlloc(self.allocator, name, args.array) catch return;
                                    events.append(event) catch {
                                        log.err("out of memory", .{});
                                        return;
                                    };
                                }
                            }
                            const events_slice = events.toOwnedSlice() catch {
                                log.err("out of memory", .{});
                                return;
                            };
                            callback(userdata, .{ .redraw = events_slice });
                        },
                        .unknown => callback(userdata, .{ .unknown = array[2] }),
                        .quit => unreachable,
                    }
                    // Clean up the parts we didn't use
                    self.allocator.free(array[1].str);
                    self.allocator.free(array);
                } else {
                    value.deinit(self.allocator);
                }
            },
        }
    }
}

pub fn getApiInfo(self: *Client) !msgpack.Value {
    const resp = try callAndWait(self, "nvim_get_api_info", .{});
    return resp.value;
}

pub fn uiAttach(self: *Client, width: usize, height: usize, opts: UiOptions) !void {
    const resp = try callAndWait(self, "nvim_ui_attach", .{ width, height, opts });
    defer resp.deinit(self.allocator);
}

pub fn tryResize(self: *Client, width: usize, height: usize) !void {
    const resp = try callAndWait(self, "nvim_ui_try_resize", .{ width, height });
    defer resp.deinit(self.allocator);
}

pub fn input(self: *Client, keys: []const u8) !void {
    const resp = try callAndWait(self, "nvim_input", .{keys});
    defer resp.deinit(self.allocator);
}

pub fn setVar(self: *Client, name: []const u8, value: anytype) !void {
    const resp = try callAndWait(self, "nvim_set_var", .{ name, value });
    defer resp.deinit(self.allocator);
}
