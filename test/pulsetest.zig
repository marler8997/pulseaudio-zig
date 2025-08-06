pub const std_options: std.Options = .{
    .log_level = .info,
};

pub fn main() !void {
    const stream = try connect();
    defer {
        std.posix.shutdown(stream.handle, .both) catch {};
        std.posix.close(stream.handle);
    }

    {
        const enable: c_int = 1;
        const enable_bytes = std.mem.toBytes(enable);
        try std.posix.setsockopt(
            stream.handle,
            std.posix.SOL.SOCKET,
            std.posix.SO.PASSCRED,
            &enable_bytes,
        );
    }

    var cookie: [256]u8 = undefined;
    try pulse.getCookie(&cookie);

    {
        var auth: [pulse.auth.len]u8 = undefined;
        pulse.auth.serialize(&auth, .{
            .sequence = 0,
            .supports_memfd = true,
            .supports_shm = true,
            .cookie = &cookie,
        });
        var cmsg: pulse.cmsg(pulse.Ucred) = .{
            .level = std.posix.SOL.SOCKET,
            .type = pulse.SCM.CREDENTIALS,
            .data = .{
                .pid = std.os.linux.getpid(),
                .uid = std.os.linux.getuid(),
                .gid = std.os.linux.getgid(),
            },
        };
        const iov = [_]std.posix.iovec_const{
            .{ .base = &auth, .len = auth.len },
        };
        const msg = std.posix.msghdr_const{
            .name = null,
            .namelen = 0,
            .iov = &iov,
            .iovlen = iov.len,
            .control = &cmsg,
            .controllen = @sizeOf(@TypeOf(cmsg)),
            .flags = 0,
        };
        std.log.info("sending auth {} {}", .{
            std.fmt.fmtSliceHexUpper(auth[0..pulse.header_len]),
            std.fmt.fmtSliceHexUpper(auth[pulse.header_len..]),
        });
        const len = try std.posix.sendmsg(stream.handle, &msg, 0);
        std.debug.assert(len == auth.len);
    }

    // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    // TODO: send SetClientName

    {
        var header: pulse.ReceivedHeader = undefined;
        var iov = [_]std.posix.iovec{
            .{ .base = @ptrCast(&header), .len = @sizeOf(@TypeOf(header)) },
        };
        var cmsg: pulse.cmsg(pulse.Ucred) = undefined;
        var headermsg: std.posix.msghdr = .{
            .name = null,
            .namelen = 0,
            .iov = &iov,
            .iovlen = iov.len,
            .control = &cmsg,
            .controllen = @sizeOf(@TypeOf(cmsg)),
            .flags = 0,
        };
        {
            std.log.info("receiving auth response...", .{});
            const recv_len = std.os.linux.recvmsg(stream.handle, &headermsg, 0);
            if (recv_len != pulse.header_len) std.debug.panic(
                "expecetd {} bytes but got {}",
                .{ pulse.header_len, recv_len },
            );
        }
        const body_len = header.bodyLen();
        const max_body = 1000;
        if (body_len > max_body) std.debug.panic("response too big (max {})", .{max_body});
        std.debug.assert(header.channel() == 0xffffffff);
        std.debug.assert(header.offsetHi() == 0);
        std.debug.assert(header.offsetLo() == 0);
        std.debug.assert(header.flags() == 0);
        var body_buf: [max_body]u8 = undefined;
        const body = body_buf[0..header.bodyLen()];
        const read_len = try stream.reader().readAll(body);
        std.debug.assert(read_len == body_len);

        {
            const server_cmd = switch (pulse.parsePod(body, 0) catch |err| switch (err) {
                error.Truncated => @panic("todo"),
            }) {
                .u32 => |value| value,
                .unknown => |tag| std.debug.panic("unhandled POD tag {} (0x{0x})", .{tag}),
            };
            switch (server_cmd) {
                pulse.command.reply => {},
                else => std.debug.panic("expected server reply but got {}", .{server_cmd}),
            }
        }
        {
            const status = switch (pulse.parsePod(body, 5) catch |err| switch (err) {
                error.Truncated => @panic("todo"),
            }) {
                .u32 => |value| value,
                .unknown => |tag| std.debug.panic("unhandled POD tag {} (0x{0x})", .{tag}),
            };
            if (status != 0) std.debug.panic("auth failed, status={}", .{status});
        }
        {
            const args: pulse.auth.Args = switch (pulse.parsePod(body, 10) catch |err| switch (err) {
                error.Truncated => @panic("todo"),
            }) {
                .u32 => |value| @bitCast(value),
                .unknown => |tag| std.debug.panic("unhandled POD tag {} (0x{0x})", .{tag}),
            };
            // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
            // TODO: which protocols do we support?  find a way to test older ones to
            //       verify them
            std.log.info("server protocol version {}", .{args.protocol_version});
            if (args.protocol_version < pulse.protocol_version) std.debug.panic("todo: not sure if we support server protocol version {}", .{args.protocol_version});
            if (!args.supports_memfd) @panic("server doesn't support memfd");
            if (!args.supports_shm) @panic("server doesn't support shm");
        }
    }

    std.log.info("Authentication successful", .{});

    const shmid_client: u32 = blk: {
        var seed: u64 = undefined;
        const seed_bytes = std.mem.asBytes(&seed);
        switch (std.posix.errno(std.os.linux.getrandom(seed_bytes, seed_bytes.len, 0))) {
            .SUCCESS => break :blk @truncate(seed),
            else => |errno| std.debug.panic("getrandom failed, errno={}", .{@intFromEnum(errno)}),
        }
    };
    std.log.info("client shmid is 0x{x}", .{shmid_client});

    const mem: []u8 = blk: {
        const memfd = try std.posix.memfd_createZ("pulseaudio", std.os.linux.MFD.ALLOW_SEALING);
        defer std.posix.close(memfd);

        const memfd_size = 1024 * 64;
        try std.posix.ftruncate(memfd, memfd_size);
        const mem = try std.posix.mmap(
            null,
            memfd_size,
            std.posix.PROT.READ | std.posix.PROT.WRITE,
            .{ .TYPE = .SHARED, .NORESERVE = true },
            memfd,
            0,
        );

        {
            var cmd: [pulse.register_memfd_shmid.len]u8 = undefined;
            pulse.register_memfd_shmid.serialize(&cmd, .{
                .what_is_this = 0xffffffff,
                .shmid = shmid_client,
            });
            const cmsg: pulse.cmsg(std.posix.fd_t) = .{
                .level = std.posix.SOL.SOCKET,
                .type = pulse.SCM.RIGHTS,
                .data = memfd,
            };
            const iov = [_]std.posix.iovec_const{
                .{ .base = &cmd, .len = cmd.len },
            };
            const msg = std.posix.msghdr_const{
                .name = null,
                .namelen = 0,
                .iov = &iov,
                .iovlen = iov.len,
                .control = &cmsg,
                .controllen = @sizeOf(@TypeOf(cmsg)),
                .flags = 0,
            };
            const len = try std.posix.sendmsg(stream.handle, &msg, 0);
            std.debug.assert(len == cmd.len);
        }
        break :blk mem;
    };
    _ = mem;

    {
        const header = try pulse.readHeader(stream.reader());
        const body_len = header.bodyLen();
        const max_body = 1000;
        if (body_len > max_body) std.debug.panic("response too big", .{});
        std.debug.assert(header.channel() == 0xffffffff);
        std.debug.assert(header.offsetHi() == 0);
        std.debug.assert(header.offsetLo() == 0);
        std.debug.assert(header.flags() == 0);

        var body_buf: [max_body]u8 = undefined;
        const body = body_buf[0..body_len];
        const read_len = try stream.reader().readAll(body);
        std.debug.assert(read_len == body_len);

        {
            const server_cmd = switch (pulse.parsePod(body, 0) catch |err| switch (err) {
                error.Truncated => @panic("todo"),
            }) {
                .u32 => |value| value,
                .unknown => |tag| std.debug.panic("unhandled POD tag {} (0x{0x})", .{tag}),
            };
            if (server_cmd != pulse.command.register_memfd_shmid) std.debug.panic(
                "expected server command {} but got {}",
                .{ pulse.command.register_memfd_shmid, server_cmd },
            );
        }
        {
            const what_is_this = switch (pulse.parsePod(body, 5) catch |err| switch (err) {
                error.Truncated => @panic("todo"),
            }) {
                .u32 => |value| value,
                .unknown => |tag| std.debug.panic("unhandled POD tag {} (0x{0x})", .{tag}),
            };
            if (what_is_this != 0xffffffff) std.debug.panic(
                "not sure what this is but it's usually 0xfffffff but got 0x{x}",
                .{what_is_this},
            );
        }
        const server_shmid = switch (pulse.parsePod(body, 10) catch |err| switch (err) {
            error.Truncated => @panic("todo"),
        }) {
            .u32 => |value| value,
            .unknown => |tag| std.debug.panic("unhandled POD tag {} (0x{0x})", .{tag}),
        };
        std.log.info("server shmid is 0x{x}", .{server_shmid});
    }

    // NOTE: the pulseaudio client will then send the SetClientName message

    if (true) @panic("todo: what to do next?");

    // var sequence: u32 = 1;
    var stream_index: u32 = undefined;
    {
        var stream_buf: [2048]u8 = undefined;
        const sample_spec = pulse.SampleSpec{
            .format = .f32le,
            // .channel_count = 2,
            .channel_count = 1,
            .rate = 44100,
        };

        const frame_size = sample_spec.frameSize();
        const buffer_size = frame_size * 1024; // ~23ms at 44.1kHz

        const len = try pulse.create_playback_stream.serialize(&stream_buf, .{
            .sequence = 1,
            .sample_spec = sample_spec,
            .channel_map = &[_]pulse.Channel{.mono},
            .sink_index = pulse.invalid_sink_index,
            .sink_name = null,
            .stream_name = "Zig Sine Wave Test",
            .buffer_max = buffer_size * 4,
            .corked = true,
            .buffer_target_len = buffer_size,
            .pre_buffering = buffer_size / 2,
            .min_request_len = buffer_size / 4,
            .sync_id = 0,
            .channel_volumes = &[_]pulse.Volume{.normal},
            .no_remap_channels = false,
            .no_remix_channels = false,
            .fix_format = false,
            .fix_rate = false,
            .fix_channels = false,
            .dont_move = false,
            .variable_rate = false,
            .start_muted = false,
            .adjust_latency = false,
            .props = &[_]pulse.Prop{},
            .volume_set = false,
            .early_requests = false,
            .start_muted_or_unmuted = false,
            .dont_inhibit_auto_suspend = false,
            .fail_on_suspend = false,
            .relative_volume = false,
            .stream_passthrough = false,
            .formats = &[_]pulse.Format{},
            // .formats = &[_]pulse.Format{.{ .encoding = .any, .props = &.{} }},
        });

        std.log.info("Sending CreatePlaybackStream: {} {}", .{
            std.fmt.fmtSliceHexUpper(stream_buf[0..pulse.header_len]),
            std.fmt.fmtSliceHexUpper(stream_buf[pulse.header_len..len]),
        });
        try stream.writer().writeAll(stream_buf[0..len]);

        // Read response
        const header = try pulse.readHeader(stream.reader());
        const body_len = header.bodyLen();
        const max_body = 1000;
        if (body_len > max_body) std.debug.panic("response too big", .{});
        std.debug.assert(header.channel() == 0xffffffff);
        std.debug.assert(header.offsetHi() == 0);
        std.debug.assert(header.offsetLo() == 0);
        std.debug.assert(header.flags() == 0);

        var body_buf: [max_body]u8 = undefined;
        const body = body_buf[0..body_len];
        const read_len = try stream.reader().readAll(body);
        std.debug.assert(read_len == body_len);

        // Parse stream creation response
        const server_cmd = switch (pulse.parsePod(body, 0) catch |err| switch (err) {
            error.Truncated => @panic("todo"),
        }) {
            .u32 => |value| value,
            .unknown => |tag| std.debug.panic("unhandled POD tag {}", .{tag}),
        };

        if (server_cmd != pulse.command.reply) {
            std.debug.panic("stream creation failed, got command {}", .{server_cmd});
        }

        // Get stream index from response
        stream_index = switch (pulse.parsePod(body, 10) catch |err| switch (err) {
            error.Truncated => @panic("todo"),
        }) {
            .u32 => |value| value,
            .unknown => |tag| std.debug.panic("unhandled POD tag {} (0x{0x})", .{tag}),
        };

        std.log.info("Stream created with index {}", .{stream_index});
    }

    // TODO: Now you need to:
    // 1. Uncork the stream (resume playback)
    // 2. Generate and write sine wave data
    // 3. Handle write requests from the server

    std.log.info("Stream setup complete. Next: implement sine wave generation and writing.", .{});
}

fn connect() !std.net.Stream {
    var addr: std.net.Address = undefined;
    switch (pulse.getAddress(&addr)) {
        .success => {},
        .env_var_too_big => |env| {
            std.log.err(
                "environemt variable {s} ({}) is too big",
                .{ @tagName(env.name), env.len },
            );
            return error.EnvironmentVariableTooBig;
        },
        .no_env_and_fallback_not_implemented => {
            std.log.err("no pulseaudio environment variables and fallback not implemented", .{});
            return error.NoPulseAudioEnv;
        },
    }
    std.log.info("pulseaudio socket addr '{}'", .{addr});
    const sock = try std.posix.socket(
        std.posix.AF.UNIX,
        std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC,
        0,
    );
    errdefer std.posix.close(sock);
    {
        const priority: c_int = 6; // highest priority with CAP_NET_ADMIN
        const priority_bytes = std.mem.toBytes(priority);
        try std.posix.setsockopt(
            sock,
            std.posix.SOL.SOCKET,
            std.posix.SO.PRIORITY,
            &priority_bytes,
        );
    }
    // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    // TODO: pulseaudio sets these socket options as well
    // setsockopt(6, SOL_SOCKET, SO_RCVBUF, [65472], 4) = 0
    // setsockopt(6, SOL_SOCKET, SO_SNDBUF, [65472], 4) = 0

    try std.posix.connect(sock, @ptrCast(&addr), addr.getOsSockLen());
    return .{ .handle = sock };
}

const std = @import("std");
const pulse = @import("pulse");
