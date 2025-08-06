pub const SampleFormat = enum(u8) {
    u8 = 0,
    alaw = 1,
    ulaw = 2,
    s16le = 3,
    s16be = 4,
    f32le = 5,
    f32be = 6,
    s32le = 7,
    s32be = 8,
    s24le = 9,
    s24be = 10,
    s24_32le = 11,
    s24_32be = 12,
};

pub const SampleSpec = packed struct {
    format: SampleFormat,
    channel_count: u8,
    rate: u32,
    pub fn frameSize(self: SampleSpec) u32 {
        const sample_size: u32 = switch (self.format) {
            .u8, .alaw, .ulaw => 1,
            .s16le, .s16be => 2,
            .f32le, .f32be, .s32le, .s32be, .s24_32le, .s24_32be => 4,
            .s24le, .s24be => 3,
        };
        return sample_size * self.channel_count;
    }
};

pub const max_channel_count = 32;
pub const Channel = enum(u8) {
    mono = 0,
    front_left = 1,
    front_right = 2,
    front_center = 3,
    rear_center = 4,
    rear_left = 5,
    rear_right = 6,
    subwoofer = 7,
    front_left_of_center = 8,
    front_right_of_center = 9,
    side_left = 10,
    side_right = 11,
    aux1 = 12,
    aux2 = 13,
    aux3 = 14,
    aux4 = 15,
    aux5 = 16,
    aux6 = 17,
    aux7 = 18,
    aux8 = 19,
    aux9 = 20,
    aux10 = 21,
    aux11 = 22,
    aux12 = 23,
    aux13 = 24,
    aux14 = 25,
    aux15 = 26,
    aux16 = 27,
    aux17 = 28,
    aux18 = 29,
    aux19 = 30,
    aux20 = 31,
    aux21 = 32,
    aux22 = 33,
    aux23 = 34,
    aux24 = 35,
    aux25 = 36,
    aux26 = 37,
    aux27 = 38,
    aux28 = 39,
    aux29 = 40,
    aux30 = 41,
    aux31 = 42,
    top_center = 43,
    top_front_left = 44,
    top_front_right = 45,
    top_front_center = 46,
    top_rear_left = 47,
    top_rear_right = 48,
    top_rear_center = 49,
    invalid = 255,
    _,
};
const ChannelMap = std.BoundedArray(Channel, max_channel_count);
const ChannelVolumes = std.BoundedArray(Volume, max_channel_count);
pub const Prop = struct { name: []const u8, value: []const u8 };

pub const Volume = enum(u32) {
    zero = 0,
    normal = 0x10_000,
    max = 0x7fffffff,
    invalid = 0xffffffff,
    _,
};

pub const Encoding = enum {
    any,
    pcm,
    ac3_iec61937,
    eac3_iec61937,
    mpeg_iec61937,
    dts_iec61937,
    mpeg2_aac_iec61937,
    truehd_iec61937,
    dtshd_iec61937,
};

pub const Format = struct {
    encoding: Encoding,
    props: []const Prop,
};

pub const PulseRuntimeDirEnv = enum {
    PULSE_RUNTIME_PATH,
    XDG_RUNTIME_DIR,
};

pub fn getAddress(out_addr: *std.net.Address) union(enum) {
    success,
    env_var_too_big: struct {
        name: PulseRuntimeDirEnv,
        len: usize,
    },
    no_env_and_fallback_not_implemented,
} {
    if (builtin.os.tag == .windows) @compileError("todo: getPath on windows");

    const env, const env_name: PulseRuntimeDirEnv, const suffix = blk: {
        if (std.posix.getenv("PULSE_RUNTIME_PATH")) |env| break :blk .{
            env, .PULSE_RUNTIME_PATH, "/native",
        };
        if (std.posix.getenv("XDG_RUNTIME_DIR")) |env| break :blk .{
            env, .XDG_RUNTIME_DIR, "/pulse/native",
        };
        return .no_env_and_fallback_not_implemented;
    };

    const path_len = env.len + suffix.len;
    out_addr.* = .{ .un = .{ .path = undefined } };
    if (path_len > out_addr.un.path.len) return .{ .env_var_too_big = .{ .name = env_name, .len = env.len } };
    @memcpy(out_addr.un.path[0..env.len], env);
    @memcpy(out_addr.un.path[env.len..][0..suffix.len], suffix);
    return .success;
}

pub const cookie_len = 256;

pub fn getCookie(out_cookie_buf: *[cookie_len]u8) !void {
    // TODO: try XDG_CONFIG_HOME first, but if it fails, use HOME as a fallback
    if (std.posix.getenv("XDG_CONFIG_HOME")) |xdg_config_home| {
        _ = xdg_config_home;
        @panic("todo: check XDG_CONFIG_HOME/pulse/cookie");
    }

    const home = std.posix.getenv("HOME") orelse return error.NoHomeEnvironmentVariable;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "{s}/.config/pulse/cookie", .{home}) catch return error.HomeEnvironmentVariableTooBig;
    const file = try std.fs.openFileAbsoluteZ(path, .{});
    defer file.close();
    const read_len = try file.reader().readAll(out_cookie_buf);
    if (read_len != cookie_len) return error.CookieFileTruncated;

    // Ensure we're at the end of the file by trying to read one more byte
    var extra_byte: [1]u8 = undefined;
    const extra_read = try file.reader().readAll(&extra_byte);
    if (extra_read > 0) return error.CookieFileTooLong;
}

pub const protocol_version = 32;

pub const header_len = 20; // 5 x 4-bytes value
pub const ReceivedHeader = struct {
    array: [header_len]u8,
    pub fn bodyLen(self: *const ReceivedHeader) usize {
        return std.mem.readInt(u32, self.array[0..4], .big);
    }
    pub fn channel(self: *const ReceivedHeader) usize {
        return std.mem.readInt(u32, self.array[4..8], .big);
    }
    pub fn offsetHi(self: *const ReceivedHeader) usize {
        return std.mem.readInt(u32, self.array[8..12], .big);
    }
    pub fn offsetLo(self: *const ReceivedHeader) usize {
        return std.mem.readInt(u32, self.array[12..16], .big);
    }
    pub fn flags(self: *const ReceivedHeader) usize {
        return std.mem.readInt(u32, self.array[16..20], .big);
    }
};

pub fn readHeader(reader: anytype) !ReceivedHeader {
    var result: ReceivedHeader = undefined;
    const len = try reader.readAll(&result.array);
    if (len != result.array.len) return error.GracefulClose;
    return result;
}

pub const tag_invalid = 0;
pub const tag_string = 't';
pub const tag_string_null = 'N';
pub const tag_u32 = 'L';
pub const tag_u8 = 'B';
pub const tag_u64 = 'R';
pub const tag_s64 = 'r';
pub const tag_sample_spec = 'a';
pub const tag_arbitrary = 'x';
pub const tag_true = '1';
pub const tag_false = '0';
pub const tag_time = 'T';
pub const tag_usec = 'U';
pub const tag_channel_map = 'm';
pub const tag_cvolume = 'v';
pub const tag_prop_list = 'P';
pub const tag_volume = 'V';
pub const tag_format_info = 'f';

pub const invalid_channel: u32 = 0xffffffff;
pub const invalid_sink_index: u32 = 0xffffffff;

pub const auth = struct {
    pub const len =
        header_len +
        5 + // command
        5 + // sequence
        5 + // options
        5 + // cookie len
        cookie_len;
    pub const Args = packed struct(u32) {
        protocol_version: u16 = protocol_version,
        _unused: u14 = 0,
        supports_memfd: bool,
        supports_shm: bool,
    };
    pub fn serialize(buf: [*]u8, args: struct {
        sequence: u32,
        supports_memfd: bool,
        supports_shm: bool,
        cookie: *const [cookie_len]u8,
    }) void {
        writeHeader(buf, .{
            .body_len = len - header_len,
            .channel = invalid_channel,
            .offset_hi = 0,
            .offset_lo = 0,
            .flags = 0,
        });

        buf[20] = tag_u32;
        std.mem.writeInt(u32, buf[21..25], command.auth, .big);
        buf[25] = tag_u32;
        std.mem.writeInt(u32, buf[26..30], args.sequence, .big);
        buf[30] = tag_u32;
        std.mem.writeInt(u32, buf[31..35], @bitCast(Args{
            .supports_memfd = args.supports_memfd,
            .supports_shm = args.supports_shm,
        }), .big);
        buf[35] = tag_arbitrary;
        std.mem.writeInt(u32, buf[36..40], 256, .big);
        @memcpy(buf[40..296], args.cookie);
    }
};
pub const register_memfd_shmid = struct {
    pub const len = header_len + 15;
    pub fn serialize(buf: [*]u8, args: struct {
        what_is_this: u32,
        shmid: u32,
    }) void {
        writeHeader(buf, .{
            .body_len = len - header_len,
            .channel = invalid_channel,
            .offset_hi = 0,
            .offset_lo = 0,
            .flags = 0,
        });
        buf[20] = tag_u32;
        std.mem.writeInt(u32, buf[21..25], command.register_memfd_shmid, .big);
        buf[25] = tag_u32;
        std.mem.writeInt(u32, buf[26..30], 0xffffffff, .big); // TODO: what is this?
        buf[30] = tag_u32;
        std.mem.writeInt(u32, buf[31..35], args.shmid, .big);
    }
};

pub const create_playback_stream = struct {
    pub fn getLen(
        channel_count: usize,
        sink_name: ?[]const u8,
    ) usize {
        _ = channel_count;
        _ = sink_name;
        @panic("todo");
    }
    pub fn serialize(
        buf: []u8,
        args: struct {
            sequence: u32,
            sample_spec: SampleSpec,
            channel_map: []const Channel,
            sink_index: u32,
            sink_name: ?[]const u8,
            stream_name: []const u8,
            buffer_max: u32,
            corked: bool,
            buffer_target_len: u32,
            pre_buffering: u32,
            min_request_len: u32,
            sync_id: u32,
            channel_volumes: []const Volume,
            no_remap_channels: bool,
            no_remix_channels: bool,
            fix_format: bool,
            fix_rate: bool,
            fix_channels: bool,
            dont_move: bool,
            variable_rate: bool,
            start_muted: bool,
            adjust_latency: bool,
            props: []const Prop,
            volume_set: bool,
            early_requests: bool,
            start_muted_or_unmuted: bool,
            dont_inhibit_auto_suspend: bool,
            fail_on_suspend: bool,
            relative_volume: bool,
            stream_passthrough: bool,
            formats: []const Format,
        },
    ) !usize {
        std.debug.assert(args.channel_map.len == args.sample_spec.channel_count);
        std.debug.assert(args.channel_volumes.len == args.sample_spec.channel_count);

        // Header (filled in at the end)
        // 0-19: header

        buf[20] = tag_u32;
        std.mem.writeInt(u32, buf[21..25], command.create_playback_stream, .big);
        buf[25] = tag_u32;
        std.mem.writeInt(u32, buf[26..30], args.sequence, .big);
        buf[30] = tag_sample_spec;
        buf[31] = @intFromEnum(args.sample_spec.format);
        buf[32] = args.sample_spec.channel_count;
        std.mem.writeInt(u32, buf[33..37], args.sample_spec.rate, .big);
        buf[37] = tag_channel_map;
        buf[38] = @intCast(args.channel_map.len);
        for (buf[39..][0..args.channel_map.len], args.channel_map) |*b, channel| {
            b.* = @intFromEnum(channel);
        }

        const after_map = 39 + args.channel_map.len;
        buf[after_map + 0] = tag_u32;
        std.mem.writeInt(u32, buf[after_map + 1 ..][0..4], args.sink_index, .big);

        const after_sink = blk: {
            if (args.sink_name) |name| {
                _ = name;
                @panic("todo");
            } else {
                buf[after_map + 5] = tag_string_null;
                break :blk after_map + 6;
            }
        };

        buf[after_sink] = tag_u32;
        std.mem.writeInt(u32, buf[after_sink + 1 ..][0..4], args.buffer_max, .big);
        buf[after_sink + 5] = if (args.corked) tag_true else tag_false;
        buf[after_sink + 6] = tag_u32;
        std.mem.writeInt(u32, buf[after_sink + 7 ..][0..4], args.buffer_target_len, .big);
        buf[after_sink + 12] = tag_u32;
        std.mem.writeInt(u32, buf[after_sink + 13 ..][0..4], args.pre_buffering, .big);
        buf[after_sink + 17] = tag_u32;
        std.mem.writeInt(u32, buf[after_sink + 18 ..][0..4], args.min_request_len, .big);
        buf[after_sink + 22] = tag_u32;
        std.mem.writeInt(u32, buf[after_sink + 23 ..][0..4], args.sync_id, .big);

        buf[after_sink + 27] = tag_cvolume;
        buf[after_sink + 28] = @intCast(args.channel_volumes.len);
        for (args.channel_volumes, 0..) |volume, i| {
            std.mem.writeInt(u32, buf[after_sink + 29 + 4 * i ..][0..4], @intFromEnum(volume), .big);
        }
        const after_volumes = after_sink + 29 + 4 * args.channel_volumes.len;

        buf[after_volumes] = if (args.no_remap_channels) tag_true else tag_false;
        buf[after_volumes + 1] = if (args.no_remix_channels) tag_true else tag_false;
        buf[after_volumes + 2] = if (args.fix_format) tag_true else tag_false;
        buf[after_volumes + 3] = if (args.fix_rate) tag_true else tag_false;
        buf[after_volumes + 4] = if (args.fix_channels) tag_true else tag_false;
        buf[after_volumes + 5] = if (args.dont_move) tag_true else tag_false;
        buf[after_volumes + 6] = if (args.variable_rate) tag_true else tag_false;
        buf[after_volumes + 7] = if (args.start_muted) tag_true else tag_false;
        buf[after_volumes + 8] = if (args.adjust_latency) tag_true else tag_false;
        writeProps(buf, after_volumes + 9, args.props);
        const after_props = after_volumes + 9 + writePropsLen(args.props);
        buf[after_props + 0] = if (args.volume_set) tag_true else tag_false;
        buf[after_props + 1] = if (args.early_requests) tag_true else tag_false;
        buf[after_props + 2] = if (args.start_muted_or_unmuted) tag_true else tag_false;
        buf[after_props + 3] = if (args.dont_inhibit_auto_suspend) tag_true else tag_false;
        buf[after_props + 4] = if (args.fail_on_suspend) tag_true else tag_false;
        buf[after_props + 5] = if (args.relative_volume) tag_true else tag_false;
        buf[after_props + 6] = if (args.stream_passthrough) tag_true else tag_false;

        // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
        // TODO: does this have to be a u8? can it just be any integer type?
        buf[after_props + 7] = tag_u8;
        buf[after_props + 8] = @intCast(args.formats.len);
        const after_formats = blk: {
            var offset = after_props + 9;
            for (args.formats) |format| {
                buf[offset] = tag_format_info;
                buf[offset + 1] = @intFromEnum(format.encoding);
                writeProps(buf, offset + 2, format.props);
                offset += 2 + writePropsLen(format.props);
            }
            break :blk offset;
        };
        writeHeader(buf.ptr, .{
            .body_len = @intCast(after_formats - header_len),
            .channel = invalid_channel,
            .offset_hi = 0,
            .offset_lo = 0,
            .flags = 0,
        });
        return after_formats;
    }
};

pub fn writeHeader(
    buf: [*]u8,
    args: struct {
        body_len: u32,
        channel: u32,
        offset_hi: u32,
        offset_lo: u32,
        flags: u32,
    },
) void {
    std.mem.writeInt(u32, buf[0..4], args.body_len, .big);
    std.mem.writeInt(u32, buf[4..8], args.channel, .big);
    std.mem.writeInt(u32, buf[8..12], args.offset_hi, .big);
    std.mem.writeInt(u32, buf[12..16], args.offset_lo, .big);
    std.mem.writeInt(u32, buf[16..20], args.flags, .big);
}

fn writeStringLen(str: []const u8) usize {
    return 1 + str.len + 1; // tag, content, null-terminator
}
fn writeString(buf: []u8, index: usize, str: []const u8) void {
    buf[index] = tag_string;
    @memcpy(buf[index + 1 ..][0..str.len], str);
    buf[index + 1 + str.len] = 0;
}

fn writeArbitraryLen(data: []const u8, opt: struct { append_null: bool = false }) usize {
    return 1 + 4 + data.len + @as(usize, if (opt.append_null) 1 else 0); // tag, size, content, null
}
fn writeArbitrary(buf: []u8, index: usize, data: []const u8, opt: struct { append_null: bool = false }) void {
    buf[index] = tag_string;
    const data_len = data.len + @as(usize, if (opt.append_null) 1 else 0);
    std.mem.writeInt(u32, buf[index + 1 ..][0..4], @intCast(data_len), .big);
    @memcpy(buf[index + 5 ..][0..data.len], data);
    if (opt.append_null) buf[index + 5 + data.len] = 0;
}

fn writePropsLen(props: []const Prop) usize {
    var len: usize = 2 + props.len * 13;
    for (props) |prop| {
        len += prop.name.len + prop.value.len;
    }
    return len;
}
fn writeProps(buf: []u8, start: usize, props: []const Prop) void {
    buf[start] = tag_prop_list;
    var index: usize = start + 1;
    for (props) |prop| {
        writeString(buf, index, prop.name);
        index += writeStringLen(prop.name);

        buf[index] = tag_u32;
        std.mem.writeInt(u32, buf[index + 1 ..][0..4], @intCast(prop.value.len + 1), .big);
        index += 5;

        writeArbitrary(buf, index, prop.value, .{ .append_null = true });
        index += writeArbitraryLen(prop.value, .{ .append_null = true });
    }
    buf[index] = tag_string_null;
    index += 1;
    // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    std.log.info(
        "start={} index={} (len={}) writePropsLen={}",
        .{ start, index, index - start, writePropsLen(props) },
    );
    std.debug.assert(writePropsLen(props) == index - start);
}

pub const Pod = union(enum) {
    u32: u32,
    unknown: u8,
};
pub fn parsePod(data: []const u8, offset: usize) error{Truncated}!Pod {
    if (offset >= data.len) return error.Truncated;
    return switch (data[offset]) {
        tag_u32 => {
            if (offset + 4 >= data.len) return error.Truncated;
            return .{ .u32 = std.mem.readInt(u32, data[offset + 1 ..][0..4], .big) };
        },
        else => |tag| .{ .unknown = tag },
    };
}

pub const command = struct {
    // generic comments (both server to client and client to server)
    pub const err = 0;
    pub const timeout = 1;
    pub const reply = 2;

    // requests (client to server)
    pub const create_playback_stream = 3; // payload changed in v9, v12 (0.9.0, 0.9.8)
    pub const delete_playback_stream = 4;
    pub const create_record_stream = 5; // payload changed in v9, v12 (0.9.0, 0.9.8)
    pub const delete_record_stream = 6;
    pub const exit = 7;
    pub const auth = 8;
    pub const set_client_name = 9;
    pub const lookup_sink = 10;
    pub const lookup_source = 11;
    pub const drain_playback_stream = 12;
    pub const stat = 13;
    pub const get_playback_latency = 14;
    pub const create_upload_stream = 15;
    pub const delete_upload_stream = 16;
    pub const finish_upload_stream = 17;
    pub const play_sample = 18;
    pub const remove_sample = 19;

    pub const get_server_info = 20;
    pub const get_sink_info = 21;
    pub const get_sink_info_list = 22;
    pub const get_source_info = 23;
    pub const get_source_info_list = 24;
    pub const get_module_info = 25;
    pub const get_module_info_list = 26;
    pub const get_client_info = 27;
    pub const get_client_info_list = 28;
    pub const get_sink_input_info = 29; // payload changed in v11 (0.9.7)
    pub const get_sink_input_info_list = 30; // payload changed in v11 (0.9.7)
    pub const get_source_output_info = 31;
    pub const get_source_output_info_list = 32;
    pub const get_sample_info = 33;
    pub const get_sample_info_list = 34;
    pub const subscribe = 35;

    pub const set_sink_volume = 36;
    pub const set_sink_input_volume = 37;
    pub const set_source_volume = 38;

    pub const set_sink_mute = 39;
    pub const set_source_mute = 40;

    pub const cork_playback_stream = 41;
    pub const flush_playback_stream = 42;
    pub const trigger_playback_stream = 43;

    pub const set_default_sink = 44;
    pub const set_default_source = 45;

    pub const set_playback_stream_name = 46;
    pub const set_record_stream_name = 47;

    pub const kill_client = 48;
    pub const kill_sink_input = 49;
    pub const kill_source_output = 50;

    pub const load_module = 51;
    pub const unload_module = 52;

    // obsolete
    pub const add_autoload___obsolete = 53;
    pub const remove_autoload___obsolete = 54;
    pub const get_autoload_info___obsolete = 55;
    pub const get_autoload_info_list___obsolete = 56;

    pub const get_record_latency = 57;
    pub const cork_record_stream = 58;
    pub const flush_record_stream = 59;
    pub const prebuf_playback_stream = 60;

    // --------------------------------------------------------------------------------
    // responses (server to client)
    // --------------------------------------------------------------------------------
    pub const request = 61;
    pub const overflow = 62;
    pub const underflow = 63;
    pub const playback_stream_killed = 64;
    pub const record_stream_killed = 65;
    pub const subscribe_event = 66;

    // --------------------------------------------------------------------------------
    // a few more requests (client to server)
    // --------------------------------------------------------------------------------

    // supported since protocol v10 (0.9.5)
    pub const move_sink_input = 67;
    pub const move_source_output = 68;

    // supported since protocol v11 (0.9.7)
    pub const set_sink_input_mute = 69;

    pub const suspend_sink = 70;
    pub const suspend_source = 71;

    // supported since protocol v12 (0.9.8)
    pub const set_playback_stream_buffer_attr = 72;
    pub const set_record_stream_buffer_attr = 73;

    pub const update_playback_stream_sample_rate = 74;
    pub const update_record_stream_sample_rate = 75;

    // responses (server to client)
    pub const playback_stream_suspended = 76;
    pub const record_stream_suspended = 77;
    pub const playback_stream_moved = 78;
    pub const record_stream_moved = 79;

    // supported since protocol v13 (0.9.11)
    pub const update_record_stream_proplist = 80;
    pub const update_playback_stream_proplist = 81;
    pub const update_client_proplist = 82;
    pub const remove_record_stream_proplist = 83;
    pub const remove_playback_stream_proplist = 84;
    pub const remove_client_proplist = 85;

    pub const started = 86;

    // supported since protocol v14 (0.9.12)
    pub const extension = 87;

    // supported since protocol v15 (0.9.15)
    pub const get_card_info = 88;
    pub const get_card_info_list = 89;
    pub const set_card_profile = 90;

    pub const client_event = 91;
    pub const playback_stream_event = 92;
    pub const record_stream_event = 93;

    // responses (server to client)
    pub const playback_buffer_attr_changed = 94;
    pub const record_buffer_attr_changed = 95;

    // supported since protocol v16 (0.9.16)
    pub const set_sink_port = 96;
    pub const set_source_port = 97;

    // supported since protocol v22 (1.0)
    pub const set_source_output_volume = 98;
    pub const set_source_output_mute = 99;

    // supported since protocol v27 (3.0)
    pub const set_port_latency_offset = 100;

    // supported since protocol v30 (6.0)
    // both directions
    pub const enable_srbchannel = 101;
    pub const disable_srbchannel = 102;

    // supported since protocol v31 (9.0)
    // both directions
    pub const register_memfd_shmid = 103;

    // supported since protocol v34 (14.0)
    pub const send_object_message = 104;

    pub const max = 105;
};

pub const Ucred = extern struct {
    /// Process ID of the sending process
    pid: std.posix.pid_t,
    /// User ID of the sending process
    uid: std.posix.uid_t,
    /// Group ID of the sending process
    gid: std.posix.gid_t,
};

pub const cmsghdr = extern struct {
    len: usize, // Data byte count, including header
    level: c_int, // Originating protocol (i.e. SOL_SOCKET)
    type: c_int, // Protocol-specific type (i.e. SCM_CREDENTIALS)
    data: [0]u8,
};

pub fn cmsg(comptime T: type) type {
    return extern struct {
        len: usize = @sizeOf(cmsghdr) + @sizeOf(T),
        level: c_int,
        type: c_int,
        data: T,
    };
}

pub const SCM = struct {
    pub const RIGHTS = 1;
    pub const CREDENTIALS = 2;

    pub const MAX_FD = 255;
};

const builtin = @import("builtin");
const std = @import("std");
const log = std.log.scoped(.pulse);
