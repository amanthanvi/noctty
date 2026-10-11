//! Narrow C ABI boundary. Windows SDK headers own every COM declaration.
pub const Device = opaque {};
pub const Buffer = opaque {};
pub const Texture = opaque {};
pub const Target = opaque {};
pub const Stats = extern struct {
    frames: u64,
    presents: u64,
    recoveries: u64,
    draw_calls: u64,
    upload_bytes: u64,
    encode_ns: u64,
    present_ns: u64,
    occluded_presents: u64,
    present_tests: u64,
    generation: u64,
    hardware_attempts: u64,
    resize_buffers: u64,
    composition_commits: u64,
    swapchain_width: u32,
    swapchain_height: u32,
    warp: u32,
    feature_level: u32,
    recovery_pending: u32,
    unavailable: u32,
    last_error: i32,
    removed_reason: i32,
    last_present_status: i32,
    vendor_id: u32,
    device_id: u32,
    adapter_luid_low: u32,
    adapter_luid_high: i32,
    adapter_name: [512]u8,
};
pub extern fn noctty_d3d11_create(hwnd: *anyopaque, force_warp: u32) ?*Device;
pub extern fn noctty_d3d11_set_recovery_preference(d: *Device, force_warp: u32) void;
pub extern fn noctty_d3d11_destroy(d: *Device) void;
pub extern fn noctty_d3d11_begin(d: *Device) i32;
pub extern fn noctty_d3d11_recover(d: *Device) i32;
pub extern fn noctty_d3d11_present(d: *Device, target: *Target, vsync: u32) i32;
pub extern fn noctty_d3d11_present_last(d: *Device, vsync: u32) i32;
pub extern fn noctty_d3d11_stats(d: *Device, stats: *Stats) void;
pub extern fn noctty_d3d11_needs_redraw(d: *Device) u32;
pub extern fn noctty_d3d11_occluded(d: *Device) u32;
pub extern fn noctty_d3d11_recovery_pending(d: *Device) u32;
pub extern fn noctty_d3d11_unavailable(d: *Device) u32;
pub extern fn noctty_d3d11_last_error(d: *Device) i32;
pub extern fn noctty_d3d11_request_device_loss(d: *Device) i32;
pub extern fn noctty_d3d11_set_test_failures(d: *Device, hardware: u32, device: u32) i32;
pub extern fn noctty_d3d11_fail_next_present(d: *Device) i32;
pub extern fn noctty_d3d11_capture(d: *Device, hdc: *anyopaque) i32;
pub extern fn noctty_d3d11_suspend_presentation(d: *Device) i32;
pub extern fn noctty_d3d11_buffer_create(d: *Device, size: usize, uniform: u32) ?*Buffer;
pub extern fn noctty_d3d11_buffer_destroy(b: *Buffer) void;
pub extern fn noctty_d3d11_buffer_reserve(b: *Buffer, size: usize) i32;
pub extern fn noctty_d3d11_buffer_write(b: *Buffer, offset: usize, data: [*]const u8, size: usize) i32;
pub extern fn noctty_d3d11_texture_create(d: *Device, width: u32, height: u32, format: u32, srgb: u32, data: ?[*]const u8) ?*Texture;
pub extern fn noctty_d3d11_texture_destroy(t: *Texture) void;
pub extern fn noctty_d3d11_texture_write(t: *Texture, x: u32, y: u32, width: u32, height: u32, data: [*]const u8) i32;
pub extern fn noctty_d3d11_target_create(d: *Device, width: u32, height: u32, linear: u32) ?*Target;
pub extern fn noctty_d3d11_target_destroy(t: *Target) void;
pub extern fn noctty_d3d11_clear(t: *Target, color: *const [4]f32) i32;
pub extern fn noctty_d3d11_draw(t: *Target, pipeline: u32, uniforms: ?*Buffer, text: ?*Buffer, backgrounds: ?*Buffer, gray: ?*Texture, color: ?*Texture, vertices: u32, instances: u32) i32;

pub const Error = error{ Direct3D11Failed, Direct3D11DeviceLost, Direct3D11Unavailable };
pub fn check(hr: i32) Error!void {
    switch (@as(u32, @bitCast(hr))) {
        0x887a0005, 0x887a0006, 0x887a0007, 0x887a0020 => return error.Direct3D11DeviceLost,
        else => {},
    }
    if (hr < 0) return error.Direct3D11Failed;
}

/// Pointer-returning allocation APIs retain the last HRESULT on the device.
pub fn allocationError(device: *Device) Error {
    if (noctty_d3d11_unavailable(device) != 0) return error.Direct3D11Unavailable;
    check(noctty_d3d11_last_error(device)) catch |err| return err;
    return error.Direct3D11Failed;
}

test "D3D11 HRESULT success and device loss classification" {
    const testing = @import("std").testing;
    try check(0);
    try check(1);
    try check(0x087a0001); // DXGI_STATUS_OCCLUDED is not a failure.
    try testing.expectError(error.Direct3D11DeviceLost, check(@bitCast(@as(u32, 0x887a0005))));
    try testing.expectError(error.Direct3D11DeviceLost, check(@bitCast(@as(u32, 0x887a0007))));
    try testing.expectError(error.Direct3D11Failed, check(@bitCast(@as(u32, 0x8007000e))));
}
