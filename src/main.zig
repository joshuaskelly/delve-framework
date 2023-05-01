const std = @import("std");
const lua = @import("lua.zig");
const sdl = @import("sdl.zig");
const gif = @import("gif.zig");
const debug = @import("debug.zig");

const Allocator = std.mem.Allocator;

var args_gpa = std.heap.GeneralPurposeAllocator(.{}){};
var args_allocator = args_gpa.allocator();

var isRunning = true;
var numTicks: u64 = 0;

const fallback_assets_path = "assets";
pub var assets_path: [:0]const u8 = undefined;
pub var palette: gif.GifImage = undefined;

pub fn main() !void {
    debug.init();
    defer debug.deinit();

    debug.log("Brass Emulator Starting", .{});

    // Get arguments
    const args = try std.process.argsAlloc(args_allocator);
    defer _ = args_gpa.deinit();
    defer std.process.argsFree(args_allocator, args);

    // Get the path to the assets
    assets_path = switch(args.len >= 2) {
        true => try args_allocator.dupeZ(u8, args[1]),
        else => try args_allocator.dupeZ(u8, fallback_assets_path),
    };
    defer args_allocator.free(assets_path);

    // Change the working dir to where the assets are
    debug.log("Assets Path: {s}", .{assets_path});
    try std.os.chdirZ(assets_path);

    // Load the palette
    palette = try gif.loadFile("palette.gif");
    defer palette.destroy();

    // Start up SDL2
    try sdl.init();
    defer sdl.deinit();

    // Start up Lua
    try lua.init();
    defer lua.deinit();

    // Load and run the main script
    try lua.runFile("main.lua");

    // Call the init lifecycle function
    try lua.callFunction("_init");

    // Kick off the game loop!
    while(isRunning) {
        sdl.processEvents();

        try lua.callFunction("_update");
        try lua.callFunction("_draw");

        debug.drawConsole();

        sdl.present();
        numTicks += 1;
    }

    debug.log("Brass Emulator Stopping", .{});
}

pub fn getAssetPath(file_path: []const u8, allocator: Allocator) ![:0]const u8 {
    const total_size = assets_path.len + file_path.len + 2;
    var path: []u8 = try allocator.alloc(u8, total_size);
    return try std.fmt.bufPrintZ(path, "{s}/{s}", .{ assets_path, file_path });
}

pub fn stop() void {
    isRunning = false;
}
