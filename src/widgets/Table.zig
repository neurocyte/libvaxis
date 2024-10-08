const std = @import("std");
const fmt = std.fmt;
const heap = std.heap;
const mem = std.mem;
const meta = std.meta;

const vaxis = @import("../main.zig");

/// Table Context for maintaining state and drawing Tables with `drawTable()`.
pub const TableContext = struct {
    /// Current active Row of the Table.
    row: usize = 0,
    /// Current active Column of the Table.
    col: usize = 0,
    /// Starting point within the Data List.
    start: usize = 0,
    /// Selected Rows.
    sel_rows: ?[]usize = null,

    /// Active status of the Table.
    active: bool = false,
    /// Active Content Callback Function.
    /// If available, this will be called to vertically expand the active row with additional info.
    active_content_fn: ?*const fn (*vaxis.Window, *const anyopaque) anyerror!usize = null,
    /// Active Content Context
    /// This will be provided to the `active_content` callback when called.
    active_ctx: *const anyopaque = &{},
    /// Y Offset for rows beyond the Active Content.
    /// (This will be calculated automatically)
    active_y_off: usize = 0,

    /// The Background Color for the Active Row and Column Header.
    selected_bg: vaxis.Cell.Color,
    /// The Background Color for Selected Rows.
    active_bg: vaxis.Cell.Color,
    /// First Column Header Background Color
    hdr_bg_1: vaxis.Cell.Color = .{ .rgb = [_]u8{ 64, 64, 64 } },
    /// Second Column Header Background Color
    hdr_bg_2: vaxis.Cell.Color = .{ .rgb = [_]u8{ 8, 8, 24 } },
    /// First Row Background Color
    row_bg_1: vaxis.Cell.Color = .{ .rgb = [_]u8{ 32, 32, 32 } },
    /// Second Row Background Color
    row_bg_2: vaxis.Cell.Color = .{ .rgb = [_]u8{ 8, 8, 8 } },

    /// Y Offset for drawing to the parent Window.
    y_off: usize = 0,

    /// Column Width
    /// Note, if this is left `null` the Column Width will be dynamically calculated during `drawTable()`.
    //col_width: ?usize = null,
    col_width: WidthStyle = .dynamic_fill,

    // Header Names
    header_names: HeaderNames = .field_names,
    // Column Indexes
    col_indexes: ColumnIndexes = .all,
};

/// Width Styles for `col_width`.
pub const WidthStyle = union(enum) {
    /// Dynamically calculate Column Widths such that the entire (or most) of the screen is filled horizontally.
    dynamic_fill,
    /// Dynamically calculate the Column Width for each Column based on its Header Length and the provided Padding length.
    dynamic_header_len: usize,
    /// Statically set all Column Widths to the same value.
    static_all: usize,
    /// Statically set individual Column Widths to specific values.
    static_individual: []const usize,
};

/// Column Indexes
pub const ColumnIndexes = union(enum) {
    /// Use all of the Columns.
    all,
    /// Use Columns from the specified indexes.
    by_idx: []const usize,
};

/// Header Names
pub const HeaderNames = union(enum) {
    /// Use Field Names as Headers
    field_names,
    /// Custom
    custom: []const []const u8,
};

/// Draw a Table for the TUI.
pub fn drawTable(
    /// This should be an ArenaAllocator that can be deinitialized after each event call.
    /// The Allocator is only used in three cases:
    /// 1. If a cell is a non-String. (If the Allocator is not provided, those cells will show "[unsupported (TypeName)]".)
    /// 2. To show that a value is too large to fit into a cell using '...'. (If the Allocator is not provided, they'll just be cutoff.)
    /// 3. To copy a MultiArrayList into a normal slice. (Note, this is an expensive operation. Prefer to pass a Slice or ArrayList if possible.)
    alloc: ?mem.Allocator,
    /// The parent Window to draw to.
    win: vaxis.Window,
    /// This must be a Slice, ArrayList, or MultiArrayList.
    /// Note, MultiArrayList support currently requires allocation.
    data_list: anytype,
    // The Table Context for this Table.
    table_ctx: *TableContext,
) !void {
    var di_is_mal = false;
    const data_items = getData: {
        const DataListT = @TypeOf(data_list);
        const data_ti = @typeInfo(DataListT);
        switch (data_ti) {
            .Pointer => |ptr| {
                if (ptr.size != .Slice) return error.UnsupportedTableDataType;
                break :getData data_list;
            },
            .Struct => {
                const di_fields = meta.fields(DataListT);
                const al_fields = meta.fields(std.ArrayList([]const u8));
                const mal_fields = meta.fields(std.MultiArrayList(struct { a: u8 = 0, b: u32 = 0 }));
                // Probably an ArrayList
                const is_al = comptime if (mem.indexOf(u8, @typeName(DataListT), "MultiArrayList") == null and
                    mem.indexOf(u8, @typeName(DataListT), "ArrayList") != null and
                    al_fields.len == di_fields.len)
                isAL: {
                    var is = true;
                    for (al_fields, di_fields) |al_field, di_field|
                        is = is and mem.eql(u8, al_field.name, di_field.name);
                    break :isAL is;
                } else false;
                if (is_al) break :getData data_list.items;

                // Probably a MultiArrayList
                const is_mal = if (mem.indexOf(u8, @typeName(DataListT), "MultiArrayList") != null and
                    mal_fields.len == di_fields.len)
                isMAL: {
                    var is = true;
                    inline for (mal_fields, di_fields) |mal_field, di_field|
                        is = is and mem.eql(u8, mal_field.name, di_field.name);
                    break :isMAL is;
                } else false;
                if (!is_mal) return error.UnsupportedTableDataType;
                if (alloc) |_alloc| {
                    di_is_mal = true;
                    const mal_slice = data_list.slice();
                    const DataT = @TypeOf(mal_slice.get(0));
                    var data_out_list = std.ArrayList(DataT).init(_alloc);
                    for (0..mal_slice.len) |idx| try data_out_list.append(mal_slice.get(idx));
                    break :getData try data_out_list.toOwnedSlice();
                }
                return error.UnsupportedTableDataType;
            },
            else => return error.UnsupportedTableDataType,
        }
    };
    defer if (di_is_mal) alloc.?.free(data_items);

    // Headers for the Table
    var hdrs_buf: [100][]const u8 = undefined;
    const headers = hdrs: {
        switch (table_ctx.header_names) {
            .field_names => {
                const DataT = @TypeOf(data_items[0]);
                const fields = meta.fields(DataT);
                var num_hdrs: usize = 0;
                inline for (fields, 0..) |field, idx| contFields: {
                    switch (table_ctx.col_indexes) {
                        .all => {},
                        .by_idx => |idxs| {
                            if (mem.indexOfScalar(usize, idxs, idx) == null) break :contFields;
                        },
                    }
                    num_hdrs += 1;
                    hdrs_buf[idx] = field.name;
                }
                break :hdrs hdrs_buf[0..num_hdrs];
            },
            .custom => |hdrs| break :hdrs hdrs,
        }
    };

    const table_win = win.initChild(
        0,
        table_ctx.y_off,
        .{ .limit = win.width },
        .{ .limit = win.height },
    );

    if (table_ctx.col > headers.len - 1) table_ctx.col = headers.len - 1;
    var col_start: usize = 0;
    for (headers[0..], 0..) |hdr_txt, idx| {
        const col_width = try calcColWidth(
            idx,
            headers,
            table_ctx.col_width,
            table_win,
        );
        defer col_start += col_width;
        const hdr_bg =
            if (table_ctx.active and idx == table_ctx.col) table_ctx.active_bg else if (idx % 2 == 0) table_ctx.hdr_bg_1 else table_ctx.hdr_bg_2;
        const hdr_win = table_win.child(.{
            .x_off = col_start,
            .y_off = 0,
            .width = .{ .limit = col_width },
            .height = .{ .limit = 1 },
        });
        var hdr = vaxis.widgets.alignment.center(hdr_win, @min(col_width -| 1, hdr_txt.len +| 1), 1);
        hdr_win.fill(.{ .style = .{ .bg = hdr_bg } });
        var seg = [_]vaxis.Cell.Segment{.{
            .text = if (hdr_txt.len > col_width and alloc != null) try fmt.allocPrint(alloc.?, "{s}...", .{hdr_txt[0..(col_width -| 4)]}) else hdr_txt,
            .style = .{
                .bg = hdr_bg,
                .bold = true,
                .ul_style = if (idx == table_ctx.col) .single else .dotted,
            },
        }};
        _ = try hdr.print(seg[0..], .{ .wrap = .word });
    }

    if (table_ctx.active_content_fn == null) table_ctx.active_y_off = 0;
    const max_items =
        if (data_items.len > table_win.height -| 1) table_win.height -| 1 else data_items.len;
    var end = table_ctx.start + max_items;
    if (table_ctx.row + table_ctx.active_y_off >= end -| 1)
        end -|= table_ctx.active_y_off;
    if (end > data_items.len) end = data_items.len;
    table_ctx.start = tableStart: {
        if (table_ctx.row == 0)
            break :tableStart 0;
        if (table_ctx.row < table_ctx.start)
            break :tableStart table_ctx.start - (table_ctx.start - table_ctx.row);
        if (table_ctx.row >= data_items.len - 1)
            table_ctx.row = data_items.len - 1;
        if (table_ctx.row >= end)
            break :tableStart table_ctx.start + (table_ctx.row - end + 1);
        break :tableStart table_ctx.start;
    };
    end = table_ctx.start + max_items;
    if (table_ctx.row + table_ctx.active_y_off >= end -| 1)
        end -|= table_ctx.active_y_off;
    if (end > data_items.len) end = data_items.len;
    table_ctx.active_y_off = 0;
    for (data_items[table_ctx.start..end], 0..) |data, row| {
        const row_bg = rowBG: {
            if (table_ctx.active and table_ctx.start + row == table_ctx.row)
                break :rowBG table_ctx.active_bg;
            if (table_ctx.sel_rows) |rows| {
                if (mem.indexOfScalar(usize, rows, table_ctx.start + row) != null) break :rowBG table_ctx.selected_bg;
            }
            if (row % 2 == 0) break :rowBG table_ctx.row_bg_1;
            break :rowBG table_ctx.row_bg_2;
        };
        var row_win = table_win.child(.{
            .x_off = 0,
            .y_off = 1 + row + table_ctx.active_y_off,
            .width = .{ .limit = table_win.width },
            .height = .{ .limit = 1 },
        });
        if (table_ctx.start + row == table_ctx.row) {
            table_ctx.active_y_off = if (table_ctx.active_content_fn) |content| try content(&row_win, table_ctx.active_ctx) else 0;
        }
        const DataT = @TypeOf(data);
        col_start = 0;
        const item_fields = meta.fields(DataT);
        inline for (item_fields[0..], 0..) |item_field, item_idx| contFields: {
            switch (table_ctx.col_indexes) {
                .all => {},
                .by_idx => |idxs| {
                    if (mem.indexOfScalar(usize, idxs, item_idx) == null) break :contFields;
                },
            }
            const col_width = try calcColWidth(
                item_idx,
                headers,
                table_ctx.col_width,
                table_win,
            );
            defer col_start += col_width;
            const item = @field(data, item_field.name);
            const ItemT = @TypeOf(item);
            const item_win = row_win.child(.{
                .x_off = col_start,
                .y_off = 0,
                .width = .{ .limit = col_width },
                .height = .{ .limit = 1 },
            });
            const item_txt = switch (ItemT) {
                []const u8 => item,
                [][]const u8, []const []const u8 => strSlice: {
                    if (alloc) |_alloc| break :strSlice try fmt.allocPrint(_alloc, "{s}", .{item});
                    break :strSlice item;
                },
                else => nonStr: {
                    switch (@typeInfo(ItemT)) {
                        .Enum => break :nonStr @tagName(item),
                        .Optional => {
                            const opt_item = item orelse break :nonStr "-";
                            switch (@typeInfo(ItemT).Optional.child) {
                                []const u8 => break :nonStr opt_item,
                                [][]const u8, []const []const u8 => {
                                    break :nonStr if (alloc) |_alloc| try fmt.allocPrint(_alloc, "{s}", .{opt_item}) else fmt.comptimePrint("[unsupported ({s})]", .{@typeName(DataT)});
                                },
                                else => {
                                    break :nonStr if (alloc) |_alloc| try fmt.allocPrint(_alloc, "{any}", .{opt_item}) else fmt.comptimePrint("[unsupported ({s})]", .{@typeName(DataT)});
                                },
                            }
                        },
                        else => {
                            break :nonStr if (alloc) |_alloc| try fmt.allocPrint(_alloc, "{any}", .{item}) else fmt.comptimePrint("[unsupported ({s})]", .{@typeName(DataT)});
                        },
                    }
                },
            };
            item_win.fill(.{ .style = .{ .bg = row_bg } });
            var seg = [_]vaxis.Cell.Segment{.{
                .text = if (item_txt.len > col_width and alloc != null) try fmt.allocPrint(alloc.?, "{s}...", .{item_txt[0..(col_width -| 4)]}) else item_txt,
                .style = .{ .bg = row_bg },
            }};
            _ = try item_win.print(seg[0..], .{ .wrap = .word });
        }
    }
}

/// Calculate the Column Width of `col` using the provided Number of Headers (`num_hdrs`), Width Style (`style`), and Table Window (`table_win`).
pub fn calcColWidth(
    col: usize,
    headers: []const []const u8,
    style: WidthStyle,
    table_win: vaxis.Window,
) !usize {
    return switch (style) {
        .dynamic_fill => dynFill: {
            var cw = table_win.width / headers.len;
            if (cw % 2 != 0) cw +|= 1;
            while (cw * headers.len < table_win.width - 1) cw +|= 1;
            break :dynFill cw;
        },
        .dynamic_header_len => dynHdrs: {
            if (col >= headers.len) break :dynHdrs error.NotEnoughStaticWidthsProvided;
            break :dynHdrs headers[col].len + (style.dynamic_header_len * 2);
        },
        .static_all => style.static_all,
        .static_individual => statInd: {
            if (col >= headers.len) break :statInd error.NotEnoughStaticWidthsProvided;
            break :statInd style.static_individual[col];
        },
    };
}
