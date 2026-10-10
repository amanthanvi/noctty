#ifndef NOCTTY_D3D11_BRIDGE_H
#define NOCTTY_D3D11_BRIDGE_H
#include <stddef.h>
#include <stdint.h>

typedef struct NocttyD3D NocttyD3D;
typedef struct NocttyD3DBuffer NocttyD3DBuffer;
typedef struct NocttyD3DTexture NocttyD3DTexture;
typedef struct NocttyD3DTarget NocttyD3DTarget;

typedef struct NocttyD3DStats {
    uint64_t frames, presents, recoveries, draw_calls, upload_bytes;
    uint64_t encode_ns, present_ns;
    uint64_t occluded_presents, present_tests, generation;
    uint64_t hardware_attempts;
    uint64_t resize_buffers, composition_commits;
    uint32_t swapchain_width, swapchain_height;
    uint32_t warp, feature_level, recovery_pending, unavailable;
    int32_t last_error, removed_reason, last_present_status;
    uint32_t vendor_id, device_id, adapter_luid_low;
    int32_t adapter_luid_high;
    char adapter_name[512];
} NocttyD3DStats;

/* force_warp selects the startup candidate. Restore the user's policy after
 * whole-renderer initialization succeeds, before publishing the renderer. */
NocttyD3D *noctty_d3d11_create(void *hwnd, uint32_t force_warp);
void noctty_d3d11_set_recovery_preference(NocttyD3D *d, uint32_t force_warp);
void noctty_d3d11_destroy(NocttyD3D *d);
int32_t noctty_d3d11_begin(NocttyD3D *d);
int32_t noctty_d3d11_recover(NocttyD3D *d);
int32_t noctty_d3d11_present(NocttyD3D *d, NocttyD3DTarget *target, uint32_t vsync);
int32_t noctty_d3d11_present_last(NocttyD3D *d, uint32_t vsync);
void noctty_d3d11_stats(NocttyD3D *d, NocttyD3DStats *stats);
uint32_t noctty_d3d11_needs_redraw(NocttyD3D *d);
uint32_t noctty_d3d11_occluded(NocttyD3D *d);
uint32_t noctty_d3d11_recovery_pending(NocttyD3D *d);
uint32_t noctty_d3d11_unavailable(NocttyD3D *d);
int32_t noctty_d3d11_last_error(NocttyD3D *d);
/* All test hooks return E_NOTIMPL in production builds. */
int32_t noctty_d3d11_request_device_loss(NocttyD3D *d);
int32_t noctty_d3d11_set_test_failures(NocttyD3D *d, uint32_t hardware, uint32_t device);
int32_t noctty_d3d11_fail_next_present(NocttyD3D *d);
int32_t noctty_d3d11_capture(NocttyD3D *d, void *hdc);
int32_t noctty_d3d11_suspend_presentation(NocttyD3D *d);

NocttyD3DBuffer *noctty_d3d11_buffer_create(NocttyD3D *d, size_t size, uint32_t uniform);
void noctty_d3d11_buffer_destroy(NocttyD3DBuffer *b);
int32_t noctty_d3d11_buffer_reserve(NocttyD3DBuffer *b, size_t size);
int32_t noctty_d3d11_buffer_write(NocttyD3DBuffer *b, size_t offset, const void *data, size_t size);

/* format: 0=R8, 1=RGBA8, 2=BGRA8. sRGB decoding applies to color atlases. */
NocttyD3DTexture *noctty_d3d11_texture_create(NocttyD3D *d, uint32_t width, uint32_t height,
    uint32_t format, uint32_t srgb, const void *data);
void noctty_d3d11_texture_destroy(NocttyD3DTexture *t);
int32_t noctty_d3d11_texture_write(NocttyD3DTexture *t, uint32_t x, uint32_t y,
    uint32_t width, uint32_t height, const void *data);

NocttyD3DTarget *noctty_d3d11_target_create(NocttyD3D *d, uint32_t width, uint32_t height, uint32_t linear);
void noctty_d3d11_target_destroy(NocttyD3DTarget *t);
int32_t noctty_d3d11_clear(NocttyD3DTarget *t, const float *color);
/* pipeline: 0=global background, 1=cell backgrounds, 2=cell text. */
int32_t noctty_d3d11_draw(NocttyD3DTarget *target, uint32_t pipeline,
    NocttyD3DBuffer *uniforms, NocttyD3DBuffer *text, NocttyD3DBuffer *backgrounds,
    NocttyD3DTexture *gray, NocttyD3DTexture *color, uint32_t vertices, uint32_t instances);
#endif
