#ifndef KORETERM_D3D11_BRIDGE_H
#define KORETERM_D3D11_BRIDGE_H
#include <stddef.h>
#include <stdint.h>

typedef struct KoretermD3D KoretermD3D;
typedef struct KoretermD3DBuffer KoretermD3DBuffer;
typedef struct KoretermD3DTexture KoretermD3DTexture;
typedef struct KoretermD3DTarget KoretermD3DTarget;

typedef struct KoretermD3DStats {
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
} KoretermD3DStats;

/* force_warp selects the startup candidate. Restore the user's policy after
 * whole-renderer initialization succeeds, before publishing the renderer. */
KoretermD3D *koreterm_d3d11_create(void *hwnd, uint32_t force_warp);
void koreterm_d3d11_set_recovery_preference(KoretermD3D *d, uint32_t force_warp);
void koreterm_d3d11_destroy(KoretermD3D *d);
int32_t koreterm_d3d11_begin(KoretermD3D *d);
int32_t koreterm_d3d11_recover(KoretermD3D *d);
int32_t koreterm_d3d11_present(KoretermD3D *d, KoretermD3DTarget *target, uint32_t vsync);
int32_t koreterm_d3d11_present_last(KoretermD3D *d, uint32_t vsync);
void koreterm_d3d11_stats(KoretermD3D *d, KoretermD3DStats *stats);
uint32_t koreterm_d3d11_needs_redraw(KoretermD3D *d);
uint32_t koreterm_d3d11_occluded(KoretermD3D *d);
uint32_t koreterm_d3d11_recovery_pending(KoretermD3D *d);
uint32_t koreterm_d3d11_unavailable(KoretermD3D *d);
int32_t koreterm_d3d11_last_error(KoretermD3D *d);
/* All test hooks return E_NOTIMPL in production builds. */
int32_t koreterm_d3d11_request_device_loss(KoretermD3D *d);
int32_t koreterm_d3d11_set_test_failures(KoretermD3D *d, uint32_t hardware, uint32_t device);
int32_t koreterm_d3d11_fail_next_present(KoretermD3D *d);
int32_t koreterm_d3d11_capture(KoretermD3D *d, void *hdc);
int32_t koreterm_d3d11_suspend_presentation(KoretermD3D *d);

KoretermD3DBuffer *koreterm_d3d11_buffer_create(KoretermD3D *d, size_t size, uint32_t uniform);
void koreterm_d3d11_buffer_destroy(KoretermD3DBuffer *b);
int32_t koreterm_d3d11_buffer_reserve(KoretermD3DBuffer *b, size_t size);
int32_t koreterm_d3d11_buffer_write(KoretermD3DBuffer *b, size_t offset, const void *data, size_t size);

/* format: 0=R8, 1=RGBA8, 2=BGRA8. sRGB decoding applies to color atlases. */
KoretermD3DTexture *koreterm_d3d11_texture_create(KoretermD3D *d, uint32_t width, uint32_t height,
    uint32_t format, uint32_t srgb, const void *data);
void koreterm_d3d11_texture_destroy(KoretermD3DTexture *t);
int32_t koreterm_d3d11_texture_write(KoretermD3DTexture *t, uint32_t x, uint32_t y,
    uint32_t width, uint32_t height, const void *data);

KoretermD3DTarget *koreterm_d3d11_target_create(KoretermD3D *d, uint32_t width, uint32_t height, uint32_t linear);
void koreterm_d3d11_target_destroy(KoretermD3DTarget *t);
int32_t koreterm_d3d11_clear(KoretermD3DTarget *t, const float *color);
/* pipeline: 0=global background, 1=cell backgrounds, 2=cell text, 5=split dim
 * (the background shader blended over the frame in gamma space). */
int32_t koreterm_d3d11_draw(KoretermD3DTarget *target, uint32_t pipeline,
    KoretermD3DBuffer *uniforms, KoretermD3DBuffer *text, KoretermD3DBuffer *backgrounds,
    KoretermD3DTexture *gray, KoretermD3DTexture *color, uint32_t vertices, uint32_t instances);
#endif
