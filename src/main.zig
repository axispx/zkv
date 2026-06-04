const std = @import("std");

const zkv = @import("zkv");

pub fn main(ctx: std.process.Init) !void {
    var engine = zkv.Engine.init(ctx.gpa);
    defer engine.deinit();

    var log = try zkv.Log.open(ctx.io, "zkv.log");
    defer log.deinit();

    try log.replay(&engine);

    try zkv.repl.run(&engine, &log, ctx.io);
}
