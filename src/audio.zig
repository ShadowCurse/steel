const std = @import("std");
const log = @import("log.zig");
const stb = @import("bindings/stb.zig");
const sdl = @import("bindings/sdl.zig");
const cimgui = @import("bindings/cimgui.zig");
const memory = @import("memory.zig");

const Assets = @import("assets.zig");

pub var audio_device: *sdl.SDL_AudioStream = undefined;
pub var volume: f32 = 1.0;

pub var playing_soundtracks: [MAX_SOUNDTRACKS]PlayingSoundtrack =
    .{PlayingSoundtrack{}} ** MAX_SOUNDTRACKS;

pub var callback_mix_buffer: []align(64) u8 = undefined;
pub var callback_track_buffer: []align(64) u8 = undefined;

pub const CHANNELS = 2;
pub const FREQUENCY = 44100;

pub const PlayingSoundtrack = struct {
    type: Assets.SoundtrackType = .Background,
    progress_bytes: u32 = 0,
    total_bytes: u32 = 0,
    left_current_volume: f32 = 0.0,
    left_target_volume: f32 = 0.0,
    left_volume_delta_per_sample: f32 = 0.0,
    right_current_volume: f32 = 0.0,
    right_target_volume: f32 = 0.0,
    right_volume_delta_per_sample: f32 = 0.0,
    is_finished: bool = true,
};

pub const Soundtrack = struct {
    data: []align(64) const u8 = &.{},
};

const MAX_SOUNDTRACKS = 32;
const Self = @This();

pub fn callback(
    _: *anyopaque,
    stream: *sdl.SDL_AudioStream,
    needed_len: i32,
    total_len: i32,
) callconv(.C) void {
    _ = needed_len;

    const stream_bytes = @as(u32, @intCast(total_len));
    @memset(callback_mix_buffer[0..stream_bytes], 0);

    const stream_8 = stream_bytes / 16;
    var buffer_8_i16: []@Vector(8, i16) = undefined;
    buffer_8_i16.ptr = @alignCast(@ptrCast(callback_mix_buffer.ptr));
    // TODO: this is with assumption mix_buffer is always bigger than requested bytes. Fix this
    // by giving an audio device a separate scatch alloc.
    buffer_8_i16.len = stream_8;

    const min_i16_f32: @Vector(4, f32) = @splat(std.math.minInt(i16));
    const max_i16_f32: @Vector(4, f32) = @splat(std.math.maxInt(i16));
    for (&playing_soundtracks) |*playing_soundtrack| {
        if (playing_soundtrack.is_finished)
            continue;
        const soundtrack = Assets.soundtracks.getPtr(playing_soundtrack.type);
        const remain_bytes = soundtrack.data.len - playing_soundtrack.progress_bytes;
        const copy_bytes = @min(remain_bytes, stream_bytes);

        // Copy to tmp buffer in order to have track data be simd aligned.
        @memcpy(
            callback_track_buffer[0..copy_bytes],
            soundtrack.data[playing_soundtrack.progress_bytes..][0..copy_bytes],
        );

        const copy_8 = copy_bytes / 16;
        const copy_8_bytes = copy_8 * 16;
        const copy_rem_bytes = copy_bytes - copy_8_bytes;

        var data_8_i16: []@Vector(8, i16) = undefined;
        data_8_i16.ptr = @alignCast(@ptrCast(callback_track_buffer.ptr));
        data_8_i16.len = copy_8;

        const rem_i16 = copy_rem_bytes / 2;
        var rem_data: []i16 = undefined;
        rem_data.ptr = @alignCast(@ptrCast(callback_track_buffer[copy_8_bytes..].ptr));
        rem_data.len = rem_i16;

        var rem_buffer: []i16 = undefined;
        rem_buffer.ptr = @alignCast(@ptrCast(callback_mix_buffer[copy_8_bytes..].ptr));
        rem_buffer.len = rem_i16;

        const samples_to_reach_target_volume_left: u32 =
            if (playing_soundtrack.left_volume_delta_per_sample == 0.0)
                0
            else
                @intFromFloat(
                    @abs((playing_soundtrack.left_target_volume -
                        playing_soundtrack.left_current_volume) /
                        playing_soundtrack.left_volume_delta_per_sample),
                );

        const samples_to_reach_target_volume_right: u32 =
            if (playing_soundtrack.right_volume_delta_per_sample == 0.0)
                0
            else
                @intFromFloat(
                    @abs((playing_soundtrack.right_target_volume -
                        playing_soundtrack.right_current_volume) /
                        playing_soundtrack.right_volume_delta_per_sample),
                );

        const left_pack_volume_reach = samples_to_reach_target_volume_left / 4;
        const left_item_volume_reach = samples_to_reach_target_volume_left -
            left_pack_volume_reach * 4;

        const right_pack_volume_reach = samples_to_reach_target_volume_right / 4;
        const right_item_volume_reach = samples_to_reach_target_volume_right -
            right_pack_volume_reach * 4;

        var left_volume_f32: @Vector(4, f32) = @splat(playing_soundtrack.left_current_volume);
        if (left_pack_volume_reach <= copy_8) {
            playing_soundtrack.left_current_volume = playing_soundtrack.left_target_volume;
            playing_soundtrack.left_volume_delta_per_sample = 0.0;
        } else {
            playing_soundtrack.left_current_volume +=
                playing_soundtrack.left_volume_delta_per_sample *
                @as(f32, @floatFromInt(copy_8 * 4));
        }

        var right_volume_f32: @Vector(4, f32) = @splat(playing_soundtrack.right_current_volume);
        if (right_pack_volume_reach <= copy_8) {
            playing_soundtrack.right_current_volume = playing_soundtrack.right_target_volume;
            playing_soundtrack.right_volume_delta_per_sample = 0.0;
        } else {
            playing_soundtrack.right_current_volume +=
                playing_soundtrack.right_volume_delta_per_sample *
                @as(f32, @floatFromInt(copy_8 * 4));
        }

        const master_volume: @Vector(4, f32) = @splat(volume);

        for (0..copy_8) |i| {
            const orig_data = data_8_i16[i];
            const left_mask = @Vector(4, i32){ 0, 2, 4, 6 };
            const left_channel_i16: @Vector(4, i16) =
                @shuffle(i16, orig_data, undefined, left_mask);
            const right_mask = @Vector(4, i32){ 1, 3, 5, 7 };
            const right_channel_i16: @Vector(4, i16) =
                @shuffle(i16, orig_data, undefined, right_mask);

            var left_channel_f32: @Vector(4, f32) = .{
                @floatFromInt(left_channel_i16[0]),
                @floatFromInt(left_channel_i16[1]),
                @floatFromInt(left_channel_i16[2]),
                @floatFromInt(left_channel_i16[3]),
            };
            var right_channel_f32: @Vector(4, f32) = .{
                @floatFromInt(right_channel_i16[0]),
                @floatFromInt(right_channel_i16[1]),
                @floatFromInt(right_channel_i16[2]),
                @floatFromInt(right_channel_i16[3]),
            };

            if (left_pack_volume_reach == i) {
                switch (left_item_volume_reach) {
                    0 => {
                        // d, d, d, d
                        const d = playing_soundtrack.left_volume_delta_per_sample;
                        const a_0: @Vector(4, f32) = @splat(d);
                        left_volume_f32 += a_0;
                    },
                    1 => {
                        // d, d * 2, d * 2, d * 2
                        const d = playing_soundtrack.left_volume_delta_per_sample;
                        const a_0: @Vector(4, f32) = @splat(d);
                        const a_1 = @Vector(4, f32){ 0.0, d, d, d };
                        left_volume_f32 += a_0 + a_1;
                    },
                    2 => {
                        // d, d * 2, d * 3, d * 3
                        const d = playing_soundtrack.left_volume_delta_per_sample;
                        const a_0: @Vector(4, f32) = @splat(d);
                        const a_1 = @Vector(4, f32){ 0.0, d, d, d };
                        const a_2 = @Vector(4, f32){ 0.0, 0.0, d, d };
                        left_volume_f32 += a_0 + a_1 + a_2;
                    },
                    3 => {
                        // d, d * 2, d * 3, d * 4
                        const d = playing_soundtrack.left_volume_delta_per_sample;
                        const a_0: @Vector(4, f32) = @splat(d);
                        const a_1 = @Vector(4, f32){ 0.0, d, d, d };
                        const a_2 = @Vector(4, f32){ 0.0, 0.0, d, d };
                        const a_3 = @Vector(4, f32){ 0.0, 0.0, 0.0, d };
                        left_volume_f32 += a_0 + a_1 + a_2 + a_3;
                    },
                    else => unreachable,
                }
            } else if (left_pack_volume_reach < i) {} else {
                // d, d * 2, d * 3, d * 4
                const d = playing_soundtrack.left_volume_delta_per_sample;
                const a_0: @Vector(4, f32) = @splat(d);
                const a_1 = @Vector(4, f32){ 0.0, d, d, d };
                const a_2 = @Vector(4, f32){ 0.0, 0.0, d, d };
                const a_3 = @Vector(4, f32){ 0.0, 0.0, 0.0, d };
                left_volume_f32 += a_0 + a_1 + a_2 + a_3;
            }

            if (right_pack_volume_reach == i) {
                switch (right_item_volume_reach) {
                    0 => {
                        // d, d, d, d
                        const d = playing_soundtrack.right_volume_delta_per_sample;
                        const a_0: @Vector(4, f32) = @splat(d);
                        right_volume_f32 += a_0;
                    },
                    1 => {
                        // d, d * 2, d * 2, d * 2
                        const d = playing_soundtrack.right_volume_delta_per_sample;
                        const a_0: @Vector(4, f32) = @splat(d);
                        const a_1 = @Vector(4, f32){ 0.0, d, d, d };
                        right_volume_f32 += a_0 + a_1;
                    },
                    2 => {
                        // d, d * 2, d * 3, d * 3
                        const d = playing_soundtrack.right_volume_delta_per_sample;
                        const a_0: @Vector(4, f32) = @splat(d);
                        const a_1 = @Vector(4, f32){ 0.0, d, d, d };
                        const a_2 = @Vector(4, f32){ 0.0, 0.0, d, d };
                        right_volume_f32 += a_0 + a_1 + a_2;
                    },
                    3 => {
                        // d, d * 2, d * 3, d * 4
                        const d = playing_soundtrack.right_volume_delta_per_sample;
                        const a_0: @Vector(4, f32) = @splat(d);
                        const a_1 = @Vector(4, f32){ 0.0, d, d, d };
                        const a_2 = @Vector(4, f32){ 0.0, 0.0, d, d };
                        const a_3 = @Vector(4, f32){ 0.0, 0.0, 0.0, d };
                        right_volume_f32 += a_0 + a_1 + a_2 + a_3;
                    },
                    else => unreachable,
                }
            } else if (right_pack_volume_reach < i) {} else {
                // d, d * 2, d * 3, d * 4
                const d = playing_soundtrack.right_volume_delta_per_sample;
                const a_0: @Vector(4, f32) = @splat(d);
                const a_1 = @Vector(4, f32){ 0.0, d, d, d };
                const a_2 = @Vector(4, f32){ 0.0, 0.0, d, d };
                const a_3 = @Vector(4, f32){ 0.0, 0.0, 0.0, d };
                right_volume_f32 += a_0 + a_1 + a_2 + a_3;
            }

            left_channel_f32 *= left_volume_f32 * master_volume;
            right_channel_f32 *= right_volume_f32 * master_volume;

            // Add original to the left/right channels and clamp
            const dst_data = buffer_8_i16[i];
            const dst_left_channel_i16: @Vector(4, i16) =
                @shuffle(i16, dst_data, undefined, left_mask);
            const dst_right_channel_i16: @Vector(4, i16) =
                @shuffle(i16, dst_data, undefined, right_mask);
            const dst_left_channel_f32: @Vector(4, f32) = .{
                @floatFromInt(dst_left_channel_i16[0]),
                @floatFromInt(dst_left_channel_i16[1]),
                @floatFromInt(dst_left_channel_i16[2]),
                @floatFromInt(dst_left_channel_i16[3]),
            };
            const dst_right_channel_f32: @Vector(4, f32) = .{
                @floatFromInt(dst_right_channel_i16[0]),
                @floatFromInt(dst_right_channel_i16[1]),
                @floatFromInt(dst_right_channel_i16[2]),
                @floatFromInt(dst_right_channel_i16[3]),
            };
            left_channel_f32 += dst_left_channel_f32;
            right_channel_f32 += dst_right_channel_f32;

            left_channel_f32 = std.math.clamp(left_channel_f32, min_i16_f32, max_i16_f32);
            right_channel_f32 = std.math.clamp(right_channel_f32, min_i16_f32, max_i16_f32);

            const final_data_mask = @Vector(8, i32){ 0, -1, 1, -2, 2, -3, 3, -4 };
            const final_data_f32: @Vector(8, f32) =
                @shuffle(f32, left_channel_f32, right_channel_f32, final_data_mask);

            buffer_8_i16[i] = .{
                @intFromFloat(final_data_f32[0]),
                @intFromFloat(final_data_f32[1]),
                @intFromFloat(final_data_f32[2]),
                @intFromFloat(final_data_f32[3]),
                @intFromFloat(final_data_f32[4]),
                @intFromFloat(final_data_f32[5]),
                @intFromFloat(final_data_f32[6]),
                @intFromFloat(final_data_f32[7]),
            };
        }
        // TODO: use @Vector(2, i16) maybe
        var i: u32 = 0;
        while (i < rem_i16) : (i += 2) {
            const d_l = rem_data[i];
            var d_l_f32: f32 = @floatFromInt(d_l);
            d_l_f32 *= playing_soundtrack.left_current_volume * volume;
            const b_l = rem_buffer[i];
            var b_l_f32: f32 = @floatFromInt(b_l);
            b_l_f32 += d_l_f32;
            b_l_f32 = std.math.clamp(b_l_f32, std.math.minInt(i16), std.math.maxInt(i16));
            rem_buffer[i] = @intFromFloat(b_l_f32);

            const d_r = rem_data[i + 1];
            var d_r_f32: f32 = @floatFromInt(d_r);
            d_r_f32 *= playing_soundtrack.right_current_volume * volume;
            const b_r = rem_buffer[i + 1];
            var b_r_f32: f32 = @floatFromInt(b_r);
            b_r_f32 += d_r_f32;
            b_r_f32 = std.math.clamp(b_r_f32, std.math.minInt(i16), std.math.maxInt(i16));
            rem_buffer[i + 1] = @intFromFloat(b_r_f32);
        }

        playing_soundtrack.progress_bytes += copy_bytes;
        if (soundtrack.data.len == playing_soundtrack.progress_bytes) {
            playing_soundtrack.is_finished = true;
        }
    }

    _ = sdl.SDL_PutAudioStreamData(stream, callback_mix_buffer.ptr, total_len);
}

pub fn init() !void {
    var wanted = sdl.SDL_AudioSpec{
        .format = sdl.SDL_AUDIO_S16,
        .channels = CHANNELS,
        .freq = FREQUENCY,
    };
    if (sdl.SDL_OpenAudioDeviceStream(
        sdl.SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK,
        &wanted,
        @ptrCast(&callback),
        null,
    )) |device| {
        audio_device = device;
    } else {
        log.err(@src(), "Cannot open audio device", .{});
        return error.SDLAudioDevice;
    }

    callback_mix_buffer = try memory.page_allocator.alignedAlloc(
        u8,
        64,
        @sizeOf(i16) * 4096,
    );
    callback_track_buffer = try memory.page_allocator.alignedAlloc(
        u8,
        64,
        @sizeOf(i16) * 4096,
    );
}

pub fn pause() void {
    _ = sdl.SDL_PauseAudioStreamDevice(audio_device);
}

pub fn unpause() void {
    _ = sdl.SDL_ResumeAudioStreamDevice(audio_device);
}

pub fn is_playing(soundtrack_type: Assets.SoundtrackType) bool {
    for (&playing_soundtracks) |*ps| {
        if (ps.type == soundtrack_type) {
            return !ps.is_finished;
        }
    }
    return false;
}

pub fn play(soundtrack_type: Assets.SoundtrackType, left_volume: f32, right_volume: f32) void {
    const soundtrack = Assets.soundtracks.getPtr(soundtrack_type);
    for (&playing_soundtracks) |*ps| {
        if (ps.is_finished) {
            ps.* = .{
                .type = soundtrack_type,
                .progress_bytes = 0,
                .total_bytes = @intCast(soundtrack.data.len),
                .left_current_volume = left_volume,
                .left_target_volume = left_volume,
                .left_volume_delta_per_sample = 0.0,
                .right_current_volume = right_volume,
                .right_target_volume = right_volume,
                .right_volume_delta_per_sample = 0.0,
                .is_finished = false,
            };
            unpause();
            return;
        }
    }
    log.warn(
        @src(),
        "Trying to play soundtrack type: {any}, but the queue is full. Ignoring.",
        .{soundtrack_type},
    );
}

pub fn set_volume(
    soundtrack_type: Assets.SoundtrackType,
    left_target_volume: f32,
    left_time_seconds: f32,
    right_target_volume: f32,
    right_time_seconds: f32,
) void {
    for (&playing_soundtracks) |*ps| {
        if (ps.type == soundtrack_type) {
            ps.left_target_volume = left_target_volume;
            ps.left_volume_delta_per_sample = (left_target_volume - ps.left_current_volume) /
                (left_time_seconds * FREQUENCY);
            ps.right_target_volume = right_target_volume;
            ps.right_volume_delta_per_sample = (right_target_volume - ps.right_current_volume) /
                (right_time_seconds * FREQUENCY);
            return;
        }
    }
}

pub fn stop(soundtrack_type: Assets.SoundtrackType) void {
    for (&playing_soundtracks) |*ps| {
        if (ps.type == soundtrack_type) {
            ps.is_finished = true;
            return;
        }
    }
    log.warn(
        @src(),
        "Trying to stop soundtrack type: {any}, but there is no such soundtrack playing.",
        .{soundtrack_type},
    );
}

pub fn stop_all() void {
    for (&playing_soundtracks) |*ps| {
        ps.is_finished = true;
    }
    pause();
}

pub fn imgui_info() void {
    var cimgui_id: i32 = 1024;
    var open: bool = true;

    if (cimgui.igCollapsingHeader_BoolPtr(
        "Soundtracks",
        &open,
        0,
    )) {
        for (&playing_soundtracks) |*ps| {
            cimgui.igPushID_Int(cimgui_id);
            cimgui_id += 1;
            defer cimgui.igPopID();

            if (!ps.is_finished)
                cimgui.format(null, ps);
        }
    }
}
