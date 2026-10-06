// Copyright (c) 2026 Håkan Nilsson
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const c = @import("emacs_module");

comptime {
    if (!@hasField(c.emacs_env, "canvas_data"))
        @compileError("emacs-module.h must provide the Emacs 32 canvas_data API");
}

export var plugin_is_GPL_compatible: c_int = 1;

const background: u32 = 0xFF4D4D4D;
const marker_black: u32 = 0xFF000000;
const marker_white: u32 = 0xFFFFFFFF;
fn nil(env: [*c]c.emacs_env) c.emacs_value {
    return env.*.intern.?(env, "nil");
}

fn truth(env: [*c]c.emacs_env) c.emacs_value {
    return env.*.intern.?(env, "t");
}

fn defalias(env: [*c]c.emacs_env, name: [*:0]const u8, function: c.emacs_value) void {
    var args = [_]c.emacs_value{
        env.*.intern.?(env, name),
        function,
    };
    _ = env.*.funcall.?(env, env.*.intern.?(env, "defalias"), args.len, &args);
}

fn imagePropertyInteger(env: [*c]c.emacs_env, image: c.emacs_value, property: [*:0]const u8) ?c.intmax_t {
    var args = [_]c.emacs_value{
        image,
        env.*.intern.?(env, property),
    };
    const value = env.*.funcall.?(env, env.*.intern.?(env, "image-property"), args.len, &args);
    if (env.*.non_local_exit_check.?(env) != c.emacs_funcall_exit_return) {
        return null;
    }
    const integer = env.*.extract_integer.?(env, value);
    if (env.*.non_local_exit_check.?(env) != c.emacs_funcall_exit_return) {
        return null;
    }
    return integer;
}

fn clamp01(value: f64) f64 {
    if (value < 0.0) return 0.0;
    if (value > 1.0) return 1.0;
    return value;
}

fn byteFromUnit(value: f64) u8 {
    const clamped = clamp01(value);
    return @intFromFloat(@round(clamped * 255.0));
}

fn argb(red: u8, green: u8, blue: u8) u32 {
    return 0xFF000000 | (@as(u32, red) << 16) | (@as(u32, green) << 8) | @as(u32, blue);
}

fn hsvToRgb(hue_raw: f64, saturation_raw: f64, value_raw: f64) u32 {
    const hue = @mod(hue_raw, 1.0);
    const saturation = clamp01(saturation_raw);
    const value = clamp01(value_raw);
    const sector = hue * 6.0;
    const sector_index_float = @floor(sector);
    const sector_index: i32 = @intFromFloat(sector_index_float);
    const fraction = sector - sector_index_float;
    const p = value * (1.0 - saturation);
    const q = value * (1.0 - saturation * fraction);
    const t = value * (1.0 - saturation * (1.0 - fraction));

    return switch (@mod(sector_index, 6)) {
        0 => argb(byteFromUnit(value), byteFromUnit(t), byteFromUnit(p)),
        1 => argb(byteFromUnit(q), byteFromUnit(value), byteFromUnit(p)),
        2 => argb(byteFromUnit(p), byteFromUnit(value), byteFromUnit(t)),
        3 => argb(byteFromUnit(p), byteFromUnit(q), byteFromUnit(value)),
        4 => argb(byteFromUnit(t), byteFromUnit(p), byteFromUnit(value)),
        else => argb(byteFromUnit(value), byteFromUnit(p), byteFromUnit(q)),
    };
}

fn blendChannel(base: u8, white_factor: u32, black_factor: u32) u8 {
    const toward_white = @as(u32, base) + (((255 - @as(u32, base)) * white_factor) / 255);
    return @intCast((toward_white * black_factor) / 255);
}

fn setPixel(pixels: []u32, width: usize, height: usize, x: isize, y: isize, color: u32) void {
    if (x < 0 or y < 0) return;
    const ux: usize = @intCast(x);
    const uy: usize = @intCast(y);
    if (ux >= width or uy >= height) return;
    pixels[uy * width + ux] = color;
}

fn drawHorizontalLine(pixels: []u32, width: usize, height: usize, x1: isize, x2: isize, y: isize, color: u32) void {
    const start = @min(x1, x2);
    const end = @max(x1, x2);
    var x = start;
    while (x <= end) : (x += 1) {
        setPixel(pixels, width, height, x, y, color);
    }
}

fn drawFocusPixel(pixels: []u32, width: usize, height: usize, x: isize, y: isize, color: u32, layout: Layout) void {
    if (x < 0 or y < 0) return;
    const ux: usize = @intCast(x);
    const uy: usize = @intCast(y);
    if (ux >= width or uy >= height) return;
    const sv_width = width - layout.padding * 2 - layout.gap - layout.hue_width;
    const sv_height = height - layout.padding * 3 - layout.swatch_height;
    const hue_left = layout.padding + sv_width + layout.gap;
    // Narrow gaps must not put focus inside either interactive region.
    if (uy >= layout.padding and uy < layout.padding + sv_height and
        ((ux >= layout.padding and ux < layout.padding + sv_width) or
            (ux >= hue_left and ux < hue_left + layout.hue_width))) return;
    const swatch_top = height - layout.padding - layout.swatch_height;
    if (uy >= swatch_top and uy < swatch_top + layout.swatch_height and
        ((ux >= layout.padding and ux < layout.padding + layout.swatch_width) or
            (ux >= layout.padding + layout.swatch_width + layout.swatch_gap and
                ux < layout.padding + layout.swatch_width * 2 + layout.swatch_gap))) return;
    pixels[uy * width + ux] = color;
}

fn drawFocusRect(pixels: []u32, width: usize, height: usize, left: isize, top: isize, right: isize, bottom: isize, color: u32, layout: Layout) void {
    var x = left;
    while (x <= right) : (x += 1) {
        drawFocusPixel(pixels, width, height, x, top, color, layout);
        drawFocusPixel(pixels, width, height, x, bottom, color, layout);
    }
    var y = top;
    while (y <= bottom) : (y += 1) {
        drawFocusPixel(pixels, width, height, left, y, color, layout);
        drawFocusPixel(pixels, width, height, right, y, color, layout);
    }
}

fn renderFocus(pixels: []u32, width: usize, height: usize, layout: Layout, focus: c.intmax_t) void {
    const padding = layout.padding;
    if (width <= padding * 2 + layout.gap + layout.hue_width or height <= padding * 3 + layout.swatch_height) return;
    const sv_width = width - padding * 2 - layout.gap - layout.hue_width;
    const sv_height = height - padding * 3 - layout.swatch_height;
    const left: isize = @intCast(if (focus == 1) padding + sv_width + layout.gap else padding);
    const top: isize = @intCast(padding);
    const right: isize = @intCast(if (focus == 1) padding + sv_width + layout.gap + layout.hue_width - 1 else padding + sv_width - 1);
    const bottom = top + @as(isize, @intCast(sv_height)) - 1;
    drawFocusRect(pixels, width, height, left - 2, top - 2, right + 2, bottom + 2, marker_black, layout);
    drawFocusRect(pixels, width, height, left - 1, top - 1, right + 1, bottom + 1, marker_white, layout);
}

fn drawCircleOutline(pixels: []u32, width: usize, height: usize, cx: isize, cy: isize, radius: isize, color: u32) void {
    const radius2 = radius * radius;
    const inner_radius = @max(@as(isize, 0), radius - 1);
    const inner2 = inner_radius * inner_radius;
    var dy: isize = -radius;
    while (dy <= radius) : (dy += 1) {
        var dx: isize = -radius;
        while (dx <= radius) : (dx += 1) {
            const distance2 = dx * dx + dy * dy;
            if (distance2 <= radius2 and distance2 > inner2) {
                setPixel(pixels, width, height, cx + dx, cy + dy, color);
            }
        }
    }
}

fn fillRect(pixels: []u32, width: usize, height: usize, left: usize, top: usize, rect_width: usize, rect_height: usize, color: u32) void {
    var y: usize = 0;
    while (y < rect_height) : (y += 1) {
        var x: usize = 0;
        while (x < rect_width) : (x += 1) {
            setPixel(pixels, width, height, @intCast(left + x), @intCast(top + y), color);
        }
    }
}

const Layout = struct {
    padding: usize,
    gap: usize,
    hue_width: usize,
    swatch_width: usize,
    swatch_height: usize,
    swatch_gap: usize,
    marker_radius: usize,
};

fn extractLayout(env: [*c]c.emacs_env, args: [*c]c.emacs_value, offset: usize) ?Layout {
    const padding_int = env.*.extract_integer.?(env, args[offset]);
    const gap_int = env.*.extract_integer.?(env, args[offset + 1]);
    const hue_width_int = env.*.extract_integer.?(env, args[offset + 2]);
    const swatch_width_int = env.*.extract_integer.?(env, args[offset + 3]);
    const swatch_height_int = env.*.extract_integer.?(env, args[offset + 4]);
    const swatch_gap_int = env.*.extract_integer.?(env, args[offset + 5]);
    const marker_radius_int = env.*.extract_integer.?(env, args[offset + 6]);
    if (env.*.non_local_exit_check.?(env) != c.emacs_funcall_exit_return) return null;
    if (padding_int < 0 or gap_int < 0 or hue_width_int <= 0 or swatch_width_int <= 0 or swatch_height_int <= 0 or swatch_gap_int < 0 or marker_radius_int <= 0) return null;
    return .{
        .padding = @intCast(padding_int),
        .gap = @intCast(gap_int),
        .hue_width = @intCast(hue_width_int),
        .swatch_width = @intCast(swatch_width_int),
        .swatch_height = @intCast(swatch_height_int),
        .swatch_gap = @intCast(swatch_gap_int),
        .marker_radius = @intCast(marker_radius_int),
    };
}

fn renderBase(pixels: []u32, width: usize, height: usize, hue: f64, layout: Layout) void {
    @memset(pixels, background);
    if (width == 0 or height == 0) return;

    const padding = layout.padding;
    const gap = layout.gap;
    const hue_width = layout.hue_width;
    if (width <= padding * 2 + gap + hue_width or height <= padding * 3 + layout.swatch_height) return;

    const sv_left = padding;
    const sv_top = padding;
    const sv_width = width - padding * 2 - gap - hue_width;
    const sv_height = height - padding * 3 - layout.swatch_height;
    const hue_left = sv_left + sv_width + gap;
    const hue_top = padding;
    const hue_height = sv_height;

    const hue_pixel = hsvToRgb(hue, 1.0, 1.0);
    const hue_red: u8 = @intCast((hue_pixel >> 16) & 0xFF);
    const hue_green: u8 = @intCast((hue_pixel >> 8) & 0xFF);
    const hue_blue: u8 = @intCast(hue_pixel & 0xFF);

    var y: usize = 0;
    while (y < sv_height) : (y += 1) {
        const black_factor: u32 = if (sv_height <= 1) 255 else 255 - @as(u32, @intCast((y * 255) / (sv_height - 1)));
        var x: usize = 0;
        while (x < sv_width) : (x += 1) {
            const white_factor: u32 = if (sv_width <= 1) 0 else 255 - @as(u32, @intCast((x * 255) / (sv_width - 1)));
            const red = blendChannel(hue_red, white_factor, black_factor);
            const green = blendChannel(hue_green, white_factor, black_factor);
            const blue = blendChannel(hue_blue, white_factor, black_factor);
            pixels[(sv_top + y) * width + sv_left + x] = argb(red, green, blue);
        }
    }

    y = 0;
    while (y < hue_height) : (y += 1) {
        const strip_hue = if (hue_height <= 1) 0.0 else @as(f64, @floatFromInt(y)) / @as(f64, @floatFromInt(hue_height - 1));
        const pixel = hsvToRgb(strip_hue, 1.0, 1.0);
        var x: usize = 0;
        while (x < hue_width) : (x += 1) {
            pixels[(hue_top + y) * width + hue_left + x] = pixel;
        }
    }
}

fn renderMarkers(pixels: []u32, width: usize, height: usize, hue: f64, saturation_raw: f64, value_raw: f64, layout: Layout) void {
    if (width == 0 or height == 0) return;

    const padding = layout.padding;
    const gap = layout.gap;
    const hue_width = layout.hue_width;
    if (width <= padding * 2 + gap + hue_width or height <= padding * 3 + layout.swatch_height) return;

    const sv_left = padding;
    const sv_top = padding;
    const sv_width = width - padding * 2 - gap - hue_width;
    const sv_height = height - padding * 3 - layout.swatch_height;
    const hue_left = sv_left + sv_width + gap;
    const hue_top = padding;
    const hue_height = sv_height;
    const saturation = clamp01(saturation_raw);
    const value = clamp01(value_raw);

    const sv_x = @as(isize, @intCast(sv_left)) + @as(isize, @intFromFloat(@round(saturation * @as(f64, @floatFromInt(@max(@as(usize, 1), sv_width) - 1)))));
    const sv_y = @as(isize, @intCast(sv_top)) + @as(isize, @intFromFloat(@round((1.0 - value) * @as(f64, @floatFromInt(@max(@as(usize, 1), sv_height) - 1)))));
    const hue_y = @as(isize, @intCast(hue_top)) + @as(isize, @intFromFloat(@round(clamp01(hue) * @as(f64, @floatFromInt(@max(@as(usize, 1), hue_height) - 1)))));

    const radius: isize = @intCast(layout.marker_radius);
    drawCircleOutline(pixels, width, height, sv_x, sv_y, radius, marker_black);
    drawCircleOutline(pixels, width, height, sv_x, sv_y, @max(0, radius - 1), marker_white);
    drawHorizontalLine(pixels, width, height, @as(isize, @intCast(hue_left)) - 1, @as(isize, @intCast(hue_left + hue_width)), hue_y, marker_black);
    drawHorizontalLine(pixels, width, height, @as(isize, @intCast(hue_left)), @as(isize, @intCast(hue_left + hue_width)) - 1, hue_y, marker_white);
}

fn renderSwatches(pixels: []u32, width: usize, height: usize, hue: f64, saturation: f64, value: f64, initial_hue: f64, initial_saturation: f64, initial_value: f64, layout: Layout) void {
    if (width == 0 or height == 0) return;

    const padding = layout.padding;
    if (height <= padding * 2 + layout.swatch_height) return;

    const swatch_top = height - padding - layout.swatch_height;
    const new_swatch_left = padding;
    const current_swatch_left = new_swatch_left + layout.swatch_width + layout.swatch_gap;

    fillRect(pixels, width, height, new_swatch_left, swatch_top, layout.swatch_width, layout.swatch_height, hsvToRgb(hue, saturation, value));
    fillRect(pixels, width, height, current_swatch_left, swatch_top, layout.swatch_width, layout.swatch_height, hsvToRgb(initial_hue, initial_saturation, initial_value));
}

fn extractCanvas(env: [*c]c.emacs_env, args: [*c]c.emacs_value, width_arg: usize, height_arg: usize) ?struct { pixels: []u32, width: usize, height: usize } {
    const width_int = env.*.extract_integer.?(env, args[width_arg]);
    const height_int = env.*.extract_integer.?(env, args[height_arg]);
    if (env.*.non_local_exit_check.?(env) != c.emacs_funcall_exit_return) return null;
    if (width_int <= 0 or height_int <= 0) return null;

    const canvas_width_int = imagePropertyInteger(env, args[0], ":data-width") orelse return null;
    const canvas_height_int = imagePropertyInteger(env, args[0], ":data-height") orelse return null;
    if (canvas_width_int != width_int or canvas_height_int != height_int) return null;

    const width: usize = @intCast(width_int);
    const height: usize = @intCast(height_int);
    if (height != 0 and width > std.math.maxInt(usize) / height) return null;

    const canvas_data = env.*.canvas_data.?(env, args[0]);
    if (canvas_data == null) return null;
    return .{ .pixels = canvas_data[0 .. width * height], .width = width, .height = height };
}

fn nativeRenderBase(env: [*c]c.emacs_env, nargs: c.ptrdiff_t, args: [*c]c.emacs_value, data: ?*anyopaque) callconv(.c) c.emacs_value {
    _ = nargs;
    _ = data;
    const canvas = extractCanvas(env, args, 1, 2) orelse return nil(env);
    const hue = env.*.extract_float.?(env, args[3]);
    const layout = extractLayout(env, args, 4) orelse return nil(env);
    if (env.*.non_local_exit_check.?(env) != c.emacs_funcall_exit_return) return nil(env);
    renderBase(canvas.pixels, canvas.width, canvas.height, hue, layout);
    return truth(env);
}

fn nativeRenderMarkers(env: [*c]c.emacs_env, nargs: c.ptrdiff_t, args: [*c]c.emacs_value, data: ?*anyopaque) callconv(.c) c.emacs_value {
    _ = nargs;
    _ = data;
    const canvas = extractCanvas(env, args, 1, 2) orelse return nil(env);
    const hue = env.*.extract_float.?(env, args[3]);
    const saturation = env.*.extract_float.?(env, args[4]);
    const value = env.*.extract_float.?(env, args[5]);
    const layout = extractLayout(env, args, 6) orelse return nil(env);
    if (env.*.non_local_exit_check.?(env) != c.emacs_funcall_exit_return) return nil(env);
    renderMarkers(canvas.pixels, canvas.width, canvas.height, hue, saturation, value, layout);
    return truth(env);
}

fn nativeRenderFull(env: [*c]c.emacs_env, nargs: c.ptrdiff_t, args: [*c]c.emacs_value, data: ?*anyopaque) callconv(.c) c.emacs_value {
    _ = nargs;
    _ = data;
    const canvas = extractCanvas(env, args, 1, 2) orelse return nil(env);
    const hue = env.*.extract_float.?(env, args[3]);
    const saturation = env.*.extract_float.?(env, args[4]);
    const value = env.*.extract_float.?(env, args[5]);
    const layout = extractLayout(env, args, 6) orelse return nil(env);
    const initial_hue = env.*.extract_float.?(env, args[13]);
    const initial_saturation = env.*.extract_float.?(env, args[14]);
    const initial_value = env.*.extract_float.?(env, args[15]);
    const focus = env.*.extract_integer.?(env, args[16]);
    if (env.*.non_local_exit_check.?(env) != c.emacs_funcall_exit_return) return nil(env);
    renderBase(canvas.pixels, canvas.width, canvas.height, hue, layout);
    renderFocus(canvas.pixels, canvas.width, canvas.height, layout, focus);
    renderMarkers(canvas.pixels, canvas.width, canvas.height, hue, saturation, value, layout);
    renderSwatches(canvas.pixels, canvas.width, canvas.height, hue, saturation, value, initial_hue, initial_saturation, initial_value, layout);
    return truth(env);
}

fn nativeApiVersion(env: [*c]c.emacs_env, nargs: c.ptrdiff_t, args: [*c]c.emacs_value, data: ?*anyopaque) callconv(.c) c.emacs_value {
    _ = nargs;
    _ = args;
    _ = data;
    return env.*.make_integer.?(env, 2);
}

export fn emacs_module_init(runtime: [*c]c.struct_emacs_runtime) c_int {
    if (runtime.*.size < @as(c.ptrdiff_t, @intCast(@sizeOf(c.struct_emacs_runtime)))) {
        return 1;
    }
    const env = runtime.*.get_environment.?(runtime);
    if (env.*.size < @as(c.ptrdiff_t, @intCast(@sizeOf(c.emacs_env)))) {
        return 2;
    }

    const api_version_fn = env.*.make_function.?(env, 0, 0, nativeApiVersion, "Return the native color picker API version.", null);
    defalias(env, "canvas-color-picker-native-api-version", api_version_fn);

    const render_base_fn = env.*.make_function.?(env, 11, 11, nativeRenderBase, "Render the color picker base palette into a canvas.", null);
    defalias(env, "canvas-color-picker-native-render-base", render_base_fn);

    const render_markers_fn = env.*.make_function.?(env, 13, 13, nativeRenderMarkers, "Render color picker markers into a canvas.", null);
    defalias(env, "canvas-color-picker-native-render-markers", render_markers_fn);

    const render_full_fn = env.*.make_function.?(env, 17, 17, nativeRenderFull, "Render the full color picker palette into a canvas.", null);
    defalias(env, "canvas-color-picker-native-render-full", render_full_fn);

    return 0;
}
