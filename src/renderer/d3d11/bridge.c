/* SDK-owned COM ABI. The generic Zig renderer owns frame preparation/pacing. */
#define WIN32_LEAN_AND_MEAN
#ifndef COBJMACROS
#define COBJMACROS
#endif
#include <windows.h>
#include <initguid.h>
#include <d3d11.h>
#include <dxgi1_2.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <limits.h>
#include "bridge.h"
#include "composition.h"
#include "terminal_bytecode.h"
#ifndef KORETERM_RENDERER_TEST_TOOLS
#define KORETERM_RENDERER_TEST_TOOLS 0
#endif

#define RELEASE(p) do { if (p) { IUnknown_Release((IUnknown *)(p)); (p) = NULL; } } while (0)

struct KoretermD3DBuffer {
    KoretermD3D *owner;
    struct KoretermD3DBuffer *next;
    ID3D11Buffer *gpu;
    ID3D11ShaderResourceView *srv;
    unsigned char *cpu;
    size_t size;
    uint32_t uniform;
};
struct KoretermD3DTexture {
    KoretermD3D *owner;
    struct KoretermD3DTexture *next;
    ID3D11Texture2D *gpu;
    ID3D11ShaderResourceView *srv;
    unsigned char *cpu;
    uint32_t width, height, pixel_size;
    DXGI_FORMAT format;
};
struct KoretermD3DTarget {
    KoretermD3D *owner;
    struct KoretermD3DTarget *next;
    ID3D11Texture2D *gpu;
    ID3D11RenderTargetView *rtv;
    /* A UNORM view of a linear (sRGB) target's texture, for a step that
     * blends with the stored bytes, in gamma space: the split dim. Null for
     * a target whose rtv is already UNORM. */
    ID3D11RenderTargetView *gamma_rtv;
    uint32_t width, height, linear, rendered;
};
/* koreterm_d3d11_draw pipeline numbers (d3d11/Pipeline.zig Kind). */
enum { PIPELINE_BG = 0, PIPELINE_CELL_BG = 1, PIPELINE_TEXT = 2, PIPELINE_SPLIT_DIM = 5 };
struct KoretermD3D {
    HWND hwnd;
    HMODULE library;
    PFN_D3D11_CREATE_DEVICE create_device_proc;
    ID3D11Device *device;
    ID3D11DeviceContext *context;
    IDXGISwapChain1 *swapchain;
    KoretermComposition *composition;
    uint32_t composition_committed;
    ID3D11Texture2D *backbuffer;
    ID3D11VertexShader *bg_vs, *text_vs;
    ID3D11PixelShader *ps[3];
    ID3D11BlendState *blend, *opaque;
    ID3D11RasterizerState *rasterizer;
    KoretermD3DBuffer *buffers;
    KoretermD3DTexture *textures;
    KoretermD3DTarget *targets;
    KoretermD3DTarget *last_rendered;
    uint32_t width, height, force_warp, occluded;
    uint64_t hardware_retry_after_ms;
    uint64_t next_present_test_ms;
#if KORETERM_RENDERER_TEST_TOOLS
    uint32_t fail_hardware, fail_device, fail_resource, test_present_status;
    HRESULT next_present_failure;
#endif
    LARGE_INTEGER frequency, frame_start;
    KoretermD3DStats stats;
};

#if KORETERM_RENDERER_TEST_TOOLS
/* readback.c: swaps RGBA to BGRA in place, saves KORETERM_RENDERER_CAPTURE_PATH
 * and draws into dc unless it is NULL; nonzero when either succeeded. */
int koreterm_renderer_blit(void *dc, unsigned char *rgba, uint32_t w, uint32_t h, int bottom_up);
static uint64_t elapsed_ns(KoretermD3D *d, LARGE_INTEGER start, LARGE_INTEGER end) {
    return (uint64_t)((end.QuadPart - start.QuadPart) * 1000000000.0 / d->frequency.QuadPart);
}
static uint64_t env_number(const char *name) {
    char value[32], *end = NULL;
    DWORD n = GetEnvironmentVariableA(name, value, sizeof(value));
    if (!n || n >= sizeof(value)) return 0;
    uint64_t result = strtoull(value, &end, 10);
    return end && *end == '\0' ? result : 0;
}
#endif

static INIT_ONCE d3d_library_once = INIT_ONCE_STATIC_INIT;
static HMODULE d3d_library;
static BOOL CALLBACK load_d3d_library(PINIT_ONCE once, PVOID parameter, PVOID *context) {
    (void)once; (void)parameter; (void)context;
    d3d_library = LoadLibraryExW(L"d3d11.dll", NULL, LOAD_LIBRARY_SEARCH_SYSTEM32);
    return d3d_library != NULL;
}

static int device_lost(HRESULT hr) {
    return hr == DXGI_ERROR_DEVICE_REMOVED || hr == DXGI_ERROR_DEVICE_RESET ||
        hr == DXGI_ERROR_DEVICE_HUNG || hr == DXGI_ERROR_DRIVER_INTERNAL_ERROR;
}
/* Recovery rebuilds every GPU resource, so no target holds a presentable frame. */
static void mark_recovery_pending(KoretermD3D *d) {
    d->stats.recovery_pending = 1;
    d->last_rendered = NULL;
    for (KoretermD3DTarget *t = d->targets; t; t = t->next) t->rendered = 0;
}
/* Resource allocations, resize, Present and Map all route failures here. Void
 * context calls are checked at frame boundaries via GetDeviceRemovedReason. */
static HRESULT record_result(KoretermD3D *d, HRESULT hr) {
    if (SUCCEEDED(hr)) return hr;
    HRESULT reason = d->device ? ID3D11Device_GetDeviceRemovedReason(d->device) : S_OK;
    d->stats.last_error = hr;
    if (device_lost(hr) || FAILED(reason)) {
        d->stats.removed_reason = FAILED(reason) ? reason : hr;
        mark_recovery_pending(d);
    } else if (hr == E_INVALIDARG || hr == DXGI_ERROR_INVALID_CALL) {
        // Bridge contract errors are not device loss or a WARP retry trigger.
        fprintf(stderr, "d3d11 contract failure hr=0x%08lx\n", (unsigned long)hr);
    } else if (!d->stats.warp && !d->force_warp) {
        /* A hardware allocation/Present failure can still succeed on WARP.
         * It gets one bounded software reconstruction before OpenGL. */
        d->hardware_retry_after_ms = GetTickCount64() + 60000;
        mark_recovery_pending(d);
    } else {
        d->stats.unavailable = 1;
    }
    return hr;
}
static HRESULT device_status(KoretermD3D *d) {
    if (d->stats.unavailable) return FAILED(d->stats.last_error) ? d->stats.last_error : E_FAIL;
    if (d->stats.recovery_pending) return DXGI_ERROR_DEVICE_REMOVED;
    if (!d->device) return record_result(d, E_FAIL);
    HRESULT hr = ID3D11Device_GetDeviceRemovedReason(d->device);
    if (SUCCEEDED(hr) && d->composition) hr = koreterm_composition_check_state(d->composition);
    return record_result(d, hr);
}
/* A pending recovery recreates GPU resources from their CPU copies, so a
 * failure now is not final. An unavailable device never recovers. */
static int recovery_will_rebuild(const KoretermD3D *d) {
    return d->stats.recovery_pending && !d->stats.unavailable;
}
static HRESULT buffer_gpu(KoretermD3DBuffer *b) {
    if (!b->owner->device) return E_FAIL;
#if KORETERM_RENDERER_TEST_TOOLS
    if (b->owner->fail_resource && !b->owner->stats.warp) return E_OUTOFMEMORY;
#endif
    ID3D11Buffer *gpu = NULL;
    ID3D11ShaderResourceView *srv = NULL;
    D3D11_BUFFER_DESC desc;
    D3D11_SUBRESOURCE_DATA initial;
    memset(&desc, 0, sizeof(desc));
    memset(&initial, 0, sizeof(initial));
    desc.ByteWidth = (UINT)b->size;
    desc.Usage = D3D11_USAGE_DEFAULT;
    desc.BindFlags = b->uniform ? D3D11_BIND_CONSTANT_BUFFER : D3D11_BIND_SHADER_RESOURCE;
    desc.MiscFlags = b->uniform ? 0 : D3D11_RESOURCE_MISC_BUFFER_ALLOW_RAW_VIEWS;
    initial.pSysMem = b->cpu;
    HRESULT hr = ID3D11Device_CreateBuffer(b->owner->device, &desc, &initial, &gpu);
    if (FAILED(hr)) return hr;
    if (!b->uniform) {
        D3D11_SHADER_RESOURCE_VIEW_DESC view;
        memset(&view, 0, sizeof(view));
        view.Format = DXGI_FORMAT_R32_TYPELESS;
        view.ViewDimension = D3D11_SRV_DIMENSION_BUFFEREX;
        view.BufferEx.NumElements = (UINT)(b->size / 4);
        view.BufferEx.Flags = D3D11_BUFFEREX_SRV_FLAG_RAW;
        hr = ID3D11Device_CreateShaderResourceView(b->owner->device, (ID3D11Resource *)gpu, &view, &srv);
        if (FAILED(hr)) { RELEASE(gpu); return hr; }
    }
    RELEASE(b->srv);
    RELEASE(b->gpu);
    b->gpu = gpu;
    b->srv = srv;
    return S_OK;
}
static HRESULT texture_gpu(KoretermD3DTexture *t) {
    if (!t->owner->device) return E_FAIL;
    ID3D11Texture2D *gpu = NULL;
    ID3D11ShaderResourceView *srv = NULL;
    D3D11_TEXTURE2D_DESC desc;
    D3D11_SUBRESOURCE_DATA initial;
    memset(&desc, 0, sizeof(desc));
    memset(&initial, 0, sizeof(initial));
    desc.Width = t->width; desc.Height = t->height;
    desc.MipLevels = 1; desc.ArraySize = 1; desc.Format = t->format;
    desc.SampleDesc.Count = 1; desc.Usage = D3D11_USAGE_DEFAULT;
    desc.BindFlags = D3D11_BIND_SHADER_RESOURCE;
    initial.pSysMem = t->cpu;
    initial.SysMemPitch = t->width * t->pixel_size;
    HRESULT hr = ID3D11Device_CreateTexture2D(t->owner->device, &desc, &initial, &gpu);
    if (FAILED(hr)) return hr;
    hr = ID3D11Device_CreateShaderResourceView(t->owner->device, (ID3D11Resource *)gpu, NULL, &srv);
    if (FAILED(hr)) { RELEASE(gpu); return hr; }
    RELEASE(t->srv); RELEASE(t->gpu);
    t->gpu = gpu; t->srv = srv;
    return S_OK;
}
static HRESULT target_gpu(KoretermD3DTarget *t) {
    if (!t->owner->device) return E_FAIL;
    if (!t->width || !t->height) return S_OK;
    ID3D11Texture2D *gpu = NULL;
    ID3D11RenderTargetView *rtv = NULL, *gamma_rtv = NULL;
    D3D11_TEXTURE2D_DESC desc;
    D3D11_RENDER_TARGET_VIEW_DESC view;
    memset(&desc, 0, sizeof(desc));
    memset(&view, 0, sizeof(view));
    desc.Width = t->width; desc.Height = t->height;
    desc.MipLevels = 1; desc.ArraySize = 1;
    desc.Format = DXGI_FORMAT_R8G8B8A8_TYPELESS;
    desc.SampleDesc.Count = 1; desc.Usage = D3D11_USAGE_DEFAULT;
    desc.BindFlags = D3D11_BIND_RENDER_TARGET;
    HRESULT hr = ID3D11Device_CreateTexture2D(t->owner->device, &desc, NULL, &gpu);
    if (FAILED(hr)) return hr;
    view.Format = t->linear ? DXGI_FORMAT_R8G8B8A8_UNORM_SRGB : DXGI_FORMAT_R8G8B8A8_UNORM;
    view.ViewDimension = D3D11_RTV_DIMENSION_TEXTURE2D;
    hr = ID3D11Device_CreateRenderTargetView(t->owner->device, (ID3D11Resource *)gpu, &view, &rtv);
    if (FAILED(hr)) { RELEASE(gpu); return hr; }
    if (t->linear) {
        view.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
        hr = ID3D11Device_CreateRenderTargetView(t->owner->device, (ID3D11Resource *)gpu, &view, &gamma_rtv);
        if (FAILED(hr)) { RELEASE(rtv); RELEASE(gpu); return hr; }
    }
    RELEASE(t->gamma_rtv); RELEASE(t->rtv); RELEASE(t->gpu);
    t->gpu = gpu; t->rtv = rtv; t->gamma_rtv = gamma_rtv; t->rendered = 0;
    return S_OK;
}
static void release_device(KoretermD3D *d) {
    if (d->context) ID3D11DeviceContext_ClearState(d->context);
    for (KoretermD3DBuffer *b = d->buffers; b; b = b->next) { RELEASE(b->srv); RELEASE(b->gpu); }
    for (KoretermD3DTexture *t = d->textures; t; t = t->next) { RELEASE(t->srv); RELEASE(t->gpu); }
    for (KoretermD3DTarget *t = d->targets; t; t = t->next) { RELEASE(t->gamma_rtv); RELEASE(t->rtv); RELEASE(t->gpu); t->rendered = 0; }
    d->last_rendered = NULL;
    koreterm_composition_destroy(d->composition);
    d->composition = NULL;
    d->composition_committed = 0;
    RELEASE(d->backbuffer);
    RELEASE(d->swapchain);
    RELEASE(d->bg_vs); RELEASE(d->text_vs);
    for (size_t i = 0; i < 3; ++i) RELEASE(d->ps[i]);
    RELEASE(d->blend); RELEASE(d->opaque); RELEASE(d->rasterizer);
    // Flush deferred destruction before another flip-model swapchain uses this HWND.
    if (d->context) ID3D11DeviceContext_Flush(d->context);
    RELEASE(d->context); RELEASE(d->device);
    d->width = d->height = 0;
    d->occluded = 0;
}
static HRESULT create_device(KoretermD3D *d, uint32_t warp) {
    D3D_FEATURE_LEVEL requested = D3D_FEATURE_LEVEL_11_0, obtained;
#if KORETERM_RENDERER_TEST_TOOLS
    if (!warp) ++d->stats.hardware_attempts;
    if (d->fail_device || (!warp && d->fail_hardware)) return E_FAIL;
#endif
    HRESULT hr = d->create_device_proc(NULL, warp ? D3D_DRIVER_TYPE_WARP : D3D_DRIVER_TYPE_HARDWARE,
        NULL, D3D11_CREATE_DEVICE_BGRA_SUPPORT, &requested, 1, D3D11_SDK_VERSION,
        &d->device, &obtained, &d->context);
    if (FAILED(hr)) return hr;
    d->stats.warp = warp; d->stats.feature_level = obtained;
    IDXGIDevice1 *latency_device = NULL;
    hr = ID3D11Device_QueryInterface(d->device, &IID_IDXGIDevice1, (void **)&latency_device);
    if (SUCCEEDED(hr)) hr = IDXGIDevice1_SetMaximumFrameLatency(latency_device, 1);
    RELEASE(latency_device);
    if (FAILED(hr)) return hr;
    {
        IDXGIDevice *dxgi_device = NULL;
        IDXGIAdapter *adapter = NULL;
        DXGI_ADAPTER_DESC description;
        HRESULT identity = ID3D11Device_QueryInterface(d->device, &IID_IDXGIDevice, (void **)&dxgi_device);
        if (SUCCEEDED(identity)) identity = IDXGIDevice_GetAdapter(dxgi_device, &adapter);
        if (SUCCEEDED(identity)) identity = IDXGIAdapter_GetDesc(adapter, &description);
        if (SUCCEEDED(identity)) {
            d->stats.vendor_id = description.VendorId;
            d->stats.device_id = description.DeviceId;
            d->stats.adapter_luid_low = description.AdapterLuid.LowPart;
            d->stats.adapter_luid_high = description.AdapterLuid.HighPart;
            memset(d->stats.adapter_name, 0, sizeof(d->stats.adapter_name));
            WideCharToMultiByte(CP_UTF8, 0, description.Description, -1,
                d->stats.adapter_name, sizeof(d->stats.adapter_name), NULL, NULL);
        }
        RELEASE(adapter); RELEASE(dxgi_device);
    }
    hr = ID3D11Device_CreateVertexShader(d->device, koreterm_bg_vs, sizeof(koreterm_bg_vs), NULL, &d->bg_vs);
    if (FAILED(hr)) return hr;
    hr = ID3D11Device_CreateVertexShader(d->device, koreterm_text_vs, sizeof(koreterm_text_vs), NULL, &d->text_vs);
    if (FAILED(hr)) return hr;
    const unsigned char *code[] = { koreterm_bg_ps, koreterm_cellbg_ps, koreterm_text_ps };
    const size_t lengths[] = { sizeof(koreterm_bg_ps), sizeof(koreterm_cellbg_ps), sizeof(koreterm_text_ps) };
    for (size_t i = 0; i < 3; ++i) {
        hr = ID3D11Device_CreatePixelShader(d->device, code[i], lengths[i], NULL, &d->ps[i]);
        if (FAILED(hr)) return hr;
    }
    D3D11_BLEND_DESC blend;
    memset(&blend, 0, sizeof(blend));
    blend.RenderTarget[0].BlendEnable = TRUE;
    blend.RenderTarget[0].SrcBlend = D3D11_BLEND_ONE;
    blend.RenderTarget[0].DestBlend = D3D11_BLEND_INV_SRC_ALPHA;
    blend.RenderTarget[0].BlendOp = D3D11_BLEND_OP_ADD;
    blend.RenderTarget[0].SrcBlendAlpha = D3D11_BLEND_ONE;
    blend.RenderTarget[0].DestBlendAlpha = D3D11_BLEND_INV_SRC_ALPHA;
    blend.RenderTarget[0].BlendOpAlpha = D3D11_BLEND_OP_ADD;
    blend.RenderTarget[0].RenderTargetWriteMask = D3D11_COLOR_WRITE_ENABLE_ALL;
    hr = ID3D11Device_CreateBlendState(d->device, &blend, &d->blend);
    if (FAILED(hr)) return hr;
    blend.RenderTarget[0].BlendEnable = FALSE;
    hr = ID3D11Device_CreateBlendState(d->device, &blend, &d->opaque);
    if (FAILED(hr)) return hr;
    D3D11_RASTERIZER_DESC rasterizer;
    memset(&rasterizer, 0, sizeof(rasterizer));
    rasterizer.FillMode = D3D11_FILL_SOLID;
    rasterizer.CullMode = D3D11_CULL_NONE;
    rasterizer.DepthClipEnable = TRUE;
    hr = ID3D11Device_CreateRasterizerState(d->device, &rasterizer, &d->rasterizer);
    if (FAILED(hr)) return hr;
    for (KoretermD3DBuffer *b = d->buffers; b; b = b->next) if (FAILED(hr = buffer_gpu(b))) return hr;
    for (KoretermD3DTexture *t = d->textures; t; t = t->next) if (FAILED(hr = texture_gpu(t))) return hr;
    for (KoretermD3DTarget *t = d->targets; t; t = t->next) if (FAILED(hr = target_gpu(t))) return hr;
    return S_OK;
}
static HRESULT resize_swapchain(KoretermD3D *d, uint32_t width, uint32_t height) {
    if (d->width == width && d->height == height && d->backbuffer) return S_OK;
    HRESULT hr;
    ID3D11DeviceContext_OMSetRenderTargets(d->context, 0, NULL, NULL);
    RELEASE(d->backbuffer);
    if (d->swapchain) {
        hr = IDXGISwapChain1_ResizeBuffers(d->swapchain, 2, width, height, DXGI_FORMAT_R8G8B8A8_UNORM, 0);
        if (FAILED(hr)) return hr;
        ++d->stats.resize_buffers;
    } else {
        IDXGIDevice *dxgi_device = NULL;
        IDXGIAdapter *adapter = NULL;
        IDXGIFactory2 *factory = NULL;
        hr = ID3D11Device_QueryInterface(d->device, &IID_IDXGIDevice, (void **)&dxgi_device);
        if (SUCCEEDED(hr)) hr = IDXGIDevice_GetAdapter(dxgi_device, &adapter);
        if (SUCCEEDED(hr)) hr = IDXGIAdapter_GetParent(adapter, &IID_IDXGIFactory2, (void **)&factory);
        if (SUCCEEDED(hr)) {
            DXGI_SWAP_CHAIN_DESC1 desc;
            memset(&desc, 0, sizeof(desc));
            desc.Width = width; desc.Height = height;
            desc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
            desc.SampleDesc.Count = 1;
            desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
            desc.BufferCount = 2;
            desc.Scaling = DXGI_SCALING_STRETCH;
            desc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL;
            desc.AlphaMode = DXGI_ALPHA_MODE_IGNORE;
            hr = IDXGIFactory2_CreateSwapChainForComposition(factory, (IUnknown *)d->device,
                &desc, NULL, &d->swapchain);
            if (SUCCEEDED(hr)) hr = koreterm_composition_create(dxgi_device, d->hwnd,
                d->swapchain, &d->composition);
        }
        RELEASE(factory); RELEASE(adapter); RELEASE(dxgi_device);
        if (FAILED(hr)) return hr;
    }
    hr = IDXGISwapChain1_GetBuffer(d->swapchain, 0, &IID_ID3D11Texture2D, (void **)&d->backbuffer);
    if (SUCCEEDED(hr)) {
        d->width = width; d->height = height;
        d->stats.swapchain_width = width; d->stats.swapchain_height = height;
    }
    return hr;
}

/* Keep a failed candidate's diagnosis, then release everything it made. */
static void discard_candidate(KoretermD3D *d, HRESULT hr) {
    d->stats.last_error = hr;
    if (d->device) {
        HRESULT reason = ID3D11Device_GetDeviceRemovedReason(d->device);
        if (FAILED(reason)) d->stats.removed_reason = reason;
    }
    release_device(d);
}
/* Each candidate owns every resource or none. Hardware recovery has a bounded
 * retry window; an explicit software preference never probes hardware. */
static HRESULT create_candidates(KoretermD3D *d, uint32_t try_hardware) {
    HRESULT hr;
    if (try_hardware) {
        hr = create_device(d, 0);
        if (SUCCEEDED(hr)) return hr;
        discard_candidate(d, hr);
    }
    hr = create_device(d, 1);
    if (FAILED(hr)) discard_candidate(d, hr);
    return hr;
}
KoretermD3D *koreterm_d3d11_create(void *hwnd, uint32_t force_warp) {
    if (!hwnd || !IsWindow((HWND)hwnd)) return NULL;
    KoretermD3D *d = (KoretermD3D *)calloc(1, sizeof(*d));
    if (!d) return NULL;
    d->hwnd = (HWND)hwnd;
    /* Only opted-in surfaces load graphics support. Missing D3D11 must never
     * prevent the OpenGL-default executable from reaching its fallback. */
#if KORETERM_RENDERER_TEST_TOOLS
    if (env_number("KORETERM_RENDERER_FAIL_LIBRARY")) { free(d); return NULL; }
#endif
    if (!InitOnceExecuteOnce(&d3d_library_once, load_d3d_library, NULL, NULL)) { free(d); return NULL; }
    d->library = d3d_library;
    if (!d->library) { free(d); return NULL; }
    d->create_device_proc = (PFN_D3D11_CREATE_DEVICE)(void *)GetProcAddress(d->library, "D3D11CreateDevice");
    if (!d->create_device_proc) { free(d); return NULL; }
    d->force_warp = force_warp != 0;
    d->stats.last_present_status = S_FALSE;
#if KORETERM_RENDERER_TEST_TOOLS
    d->fail_hardware = env_number("KORETERM_RENDERER_FAIL_HARDWARE") != 0;
    d->fail_device = env_number("KORETERM_RENDERER_FAIL_DEVICE") != 0;
    d->fail_resource = env_number("KORETERM_RENDERER_FAIL_RESOURCE") != 0;
    d->test_present_status = env_number("KORETERM_RENDERER_TEST_PRESENT_STATUS") != 0;
    QueryPerformanceFrequency(&d->frequency);
#endif
    HRESULT hr = create_device(d, d->force_warp);
    if (FAILED(hr)) {
        fprintf(stderr, "d3d11 initialization_failed hr=0x%08lx\n", (unsigned long)hr);
        koreterm_d3d11_destroy(d);
        return NULL;
    }
    d->stats.generation = 1;
    return d;
}
void koreterm_d3d11_set_recovery_preference(KoretermD3D *d, uint32_t force_warp) {
    if (d->force_warp && !force_warp && d->stats.warp) {
        /* Startup just failed its hardware candidate. Do not immediately probe
         * again on loss; later recovery may retry after the normal window. */
        d->hardware_retry_after_ms = GetTickCount64() + 60000;
    }
    d->force_warp = force_warp != 0;
}
void koreterm_d3d11_destroy(KoretermD3D *d) {
    if (!d) return;
    release_device(d);
    // Renderer normally destroys resources first. Drain on failed initialization too.
    while (d->buffers) koreterm_d3d11_buffer_destroy(d->buffers);
    while (d->textures) koreterm_d3d11_texture_destroy(d->textures);
    while (d->targets) koreterm_d3d11_target_destroy(d->targets);
    // The process pins the runtime; drivers may finish worker teardown later.
    free(d);
}
int32_t koreterm_d3d11_recover(KoretermD3D *d) {
    if (d->stats.unavailable) return device_status(d);
    (void)device_status(d);
    if (!d->stats.recovery_pending) return device_status(d);
    uint64_t now = GetTickCount64();
    uint32_t hardware = !d->force_warp && now >= d->hardware_retry_after_ms;
    if (hardware) d->hardware_retry_after_ms = now + 60000;
    release_device(d);
    HRESULT hr = create_candidates(d, hardware);
    if (FAILED(hr)) {
        d->stats.last_error = hr;
        d->stats.unavailable = 1;
        fprintf(stderr, "d3d11 recovery_failed hr=0x%08lx removed_reason=0x%08lx\n",
            (unsigned long)hr, (unsigned long)d->stats.removed_reason);
        return hr;
    }
    d->stats.recovery_pending = 0;
    ++d->stats.recoveries;
    ++d->stats.generation;
    fprintf(stderr, "d3d11 recovered generation=%llu driver=%s removed_reason=0x%08lx\n",
        (unsigned long long)d->stats.generation, d->stats.warp ? "WARP" : "hardware",
        (unsigned long)d->stats.removed_reason);
    return S_OK;
}
int32_t koreterm_d3d11_begin(KoretermD3D *d) {
    HRESULT hr = koreterm_d3d11_recover(d);
    if (FAILED(hr)) return hr;
#if KORETERM_RENDERER_TEST_TOOLS
    QueryPerformanceCounter(&d->frame_start);
#endif
    return S_OK;
}
static HRESULT present_target(KoretermD3D *d, KoretermD3DTarget *target, uint32_t vsync, int encoded) {
    HRESULT hr = device_status(d);
    if (FAILED(hr)) return hr;
#if KORETERM_RENDERER_TEST_TOOLS
    if (FAILED(d->next_present_failure)) {
        hr = d->next_present_failure;
        d->next_present_failure = S_OK;
        return record_result(d, hr);
    }
#endif
    if (!target || target->owner != d || !target->gpu) return record_result(d, E_INVALIDARG);
    if (encoded) {
        ++d->stats.frames;
        target->rendered = 1;
        d->last_rendered = target;
#if KORETERM_RENDERER_TEST_TOOLS
        LARGE_INTEGER encoded_at;
        QueryPerformanceCounter(&encoded_at);
        d->stats.encode_ns += elapsed_ns(d, d->frame_start, encoded_at);
#endif
    }
    if (!target->rendered) return S_FALSE;
    /* Targets are physical pixels from the runtime. A zero client area (for
     * example a minimized pane) never resizes DXGI to its implicit HWND size. */
    RECT client;
    if (!GetClientRect(d->hwnd, &client)) return record_result(d, HRESULT_FROM_WIN32(GetLastError()));
    if (client.right <= client.left || client.bottom <= client.top) return S_FALSE;
    // Resize is a lifecycle operation even while occluded. Keep the back
    // buffer synchronized with the retained target before any Present(TEST).
    hr = resize_swapchain(d, target->width, target->height);
    if (FAILED(hr)) return record_result(d, hr);
    if (d->occluded) {
        uint64_t now = GetTickCount64();
        if (now < d->next_present_test_ms) return DXGI_STATUS_OCCLUDED;
        d->next_present_test_ms = now + 250;
        ++d->stats.present_tests;
        hr = IDXGISwapChain1_Present(d->swapchain, 0, DXGI_PRESENT_TEST);
        d->stats.last_present_status = hr;
        if (hr == DXGI_STATUS_OCCLUDED) { ++d->stats.occluded_presents; return hr; }
        if (FAILED(hr)) return record_result(d, hr);
        d->occluded = 0;
    }
    ID3D11DeviceContext_OMSetRenderTargets(d->context, 0, NULL, NULL);
    ID3D11DeviceContext_CopyResource(d->context, (ID3D11Resource *)d->backbuffer, (ID3D11Resource *)target->gpu);
#if KORETERM_RENDERER_TEST_TOOLS
    LARGE_INTEGER before, after;
    QueryPerformanceCounter(&before);
#endif
    hr = IDXGISwapChain1_Present(d->swapchain, vsync ? 1 : 0, 0);
#if KORETERM_RENDERER_TEST_TOOLS
    /* Exercise post-Present success classification on hidden desktops too.
     * This test-only substitution preserves real failures, but may replace
     * occlusion; it proves classification, not visible presentation. */
    if (SUCCEEDED(hr) && d->test_present_status) hr = DXGI_STATUS_MODE_CHANGED;
#endif
    d->stats.last_present_status = hr;
#if KORETERM_RENDERER_TEST_TOOLS
    QueryPerformanceCounter(&after);
    d->stats.present_ns += elapsed_ns(d, before, after);
#endif
    if (FAILED(hr)) return record_result(d, hr);
    if (hr == DXGI_STATUS_OCCLUDED) {
        d->occluded = 1;
        d->next_present_test_ms = GetTickCount64() + 250;
        ++d->stats.occluded_presents;
    } else {
        // Attach only initialized pixels. A failed DComp commit is a failed
        // submission, so it cannot signal the app's first-frame handshake.
        if (!d->composition_committed) {
            hr = koreterm_composition_commit(d->composition);
            if (FAILED(hr)) return record_result(d, hr);
            d->composition_committed = 1;
            ++d->stats.composition_commits;
        }
        ++d->stats.presents;
        hr = S_OK;
    }
    return hr;
}
int32_t koreterm_d3d11_present(KoretermD3D *d, KoretermD3DTarget *target, uint32_t vsync) {
    return present_target(d, target, vsync, 1);
}
void koreterm_d3d11_stats(KoretermD3D *d, KoretermD3DStats *stats) { *stats = d->stats; }
uint32_t koreterm_d3d11_needs_redraw(KoretermD3D *d) {
    return d->stats.recovery_pending || !d->last_rendered;
}
uint32_t koreterm_d3d11_occluded(KoretermD3D *d) { return d->occluded; }
uint32_t koreterm_d3d11_recovery_pending(KoretermD3D *d) { return d->stats.recovery_pending; }
uint32_t koreterm_d3d11_unavailable(KoretermD3D *d) { return d->stats.unavailable; }
int32_t koreterm_d3d11_last_error(KoretermD3D *d) { return d->stats.last_error; }
int32_t koreterm_d3d11_request_device_loss(KoretermD3D *d) {
#if KORETERM_RENDERER_TEST_TOOLS
    /* Deterministically inject the HRESULT into the real loss classifier. This
     * is not a system-wide driver reset and is not evidence of TDR behavior. */
    (void)record_result(d, DXGI_ERROR_DEVICE_REMOVED);
    return S_OK;
#else
    (void)d;
    return E_NOTIMPL;
#endif
}
int32_t koreterm_d3d11_present_last(KoretermD3D *d, uint32_t vsync) {
    return d->last_rendered ? present_target(d, d->last_rendered, vsync, 0) : S_FALSE;
}
int32_t koreterm_d3d11_set_test_failures(KoretermD3D *d, uint32_t hardware, uint32_t device) {
#if KORETERM_RENDERER_TEST_TOOLS
    d->fail_hardware = hardware != 0;
    d->fail_device = device != 0;
    /* Clearing injected failures also expires the retry window, so canaries
     * can exercise a later recovery without waiting a minute. Test builds only. */
    if (!hardware && !device) {
        d->fail_resource = 0;
        d->hardware_retry_after_ms = 0;
    }
    return S_OK;
#else
    (void)d; (void)hardware; (void)device;
    return E_NOTIMPL;
#endif
}

int32_t koreterm_d3d11_fail_next_present(KoretermD3D *d) {
#if KORETERM_RENDERER_TEST_TOOLS
    d->next_present_failure = E_OUTOFMEMORY;
    return S_OK;
#else
    (void)d;
    return E_NOTIMPL;
#endif
}

#if KORETERM_RENDERER_TEST_TOOLS
static HRESULT readback(KoretermD3D *d, unsigned char **pixels, uint32_t *width, uint32_t *height) {
    KoretermD3DTarget *target = d->last_rendered;
    if (!target || !target->gpu || !d->context) return E_FAIL;
    HRESULT hr = device_status(d);
    if (FAILED(hr)) return hr;
    D3D11_TEXTURE2D_DESC desc;
    ID3D11Texture2D_GetDesc(target->gpu, &desc);
    desc.Usage = D3D11_USAGE_STAGING;
    desc.BindFlags = 0;
    desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    desc.MiscFlags = 0;
    ID3D11Texture2D *staging = NULL;
    hr = ID3D11Device_CreateTexture2D(d->device, &desc, NULL, &staging);
    if (FAILED(hr)) return record_result(d, hr);
    ID3D11DeviceContext_CopyResource(d->context, (ID3D11Resource *)staging, (ID3D11Resource *)target->gpu);
    D3D11_MAPPED_SUBRESOURCE mapped;
    memset(&mapped, 0, sizeof(mapped));
    hr = ID3D11DeviceContext_Map(d->context, (ID3D11Resource *)staging, 0, D3D11_MAP_READ, 0, &mapped);
    if (FAILED(hr)) { RELEASE(staging); return record_result(d, hr); }
    /* Tightly packed RGBA rows, top row first. */
    size_t row_size = (size_t)desc.Width * 4;
    unsigned char *rgba = (unsigned char *)malloc(row_size * desc.Height);
    if (!rgba) {
        ID3D11DeviceContext_Unmap(d->context, (ID3D11Resource *)staging, 0);
        RELEASE(staging);
        return E_OUTOFMEMORY;
    }
    for (UINT y = 0; y < desc.Height; ++y) {
        memcpy(rgba + (size_t)y * row_size, (const unsigned char *)mapped.pData + (size_t)y * mapped.RowPitch, row_size);
    }
    ID3D11DeviceContext_Unmap(d->context, (ID3D11Resource *)staging, 0);
    RELEASE(staging);
    *pixels = rgba; *width = desc.Width; *height = desc.Height;
    return S_OK;
}
#endif
int32_t koreterm_d3d11_capture(KoretermD3D *d, void *hdc) {
#if KORETERM_RENDERER_TEST_TOOLS
    unsigned char *rgba = NULL;
    uint32_t width, height;
    HRESULT hr = readback(d, &rgba, &width, &height);
    if (FAILED(hr)) return hr;
    int captured = koreterm_renderer_blit(hdc, rgba, width, height, 0);
    free(rgba);
    return captured ? S_OK : E_FAIL;
#else
    (void)d; (void)hdc;
    return E_NOTIMPL;
#endif
}

KoretermD3DBuffer *koreterm_d3d11_buffer_create(KoretermD3D *d, size_t size, uint32_t uniform) {
    KoretermD3DBuffer *b = (KoretermD3DBuffer *)calloc(1, sizeof(*b));
    if (!b) { (void)record_result(d, E_OUTOFMEMORY); return NULL; }
    b->owner = d; b->uniform = uniform;
    if (FAILED(koreterm_d3d11_buffer_reserve(b, size))) { free(b->cpu); free(b); return NULL; }
    b->next = d->buffers; d->buffers = b;
    return b;
}
void koreterm_d3d11_buffer_destroy(KoretermD3DBuffer *b) {
    KoretermD3DBuffer **link = &b->owner->buffers;
    while (*link && *link != b) link = &(*link)->next;
    if (*link) *link = b->next;
    RELEASE(b->srv); RELEASE(b->gpu); free(b->cpu); free(b);
}
int32_t koreterm_d3d11_buffer_reserve(KoretermD3DBuffer *b, size_t size) {
    size_t align = b->uniform ? 16 : 4;
    if (size > UINT_MAX - align || (b->uniform && size > 65536)) return record_result(b->owner, E_INVALIDARG);
    size = (size + align - 1) & ~(align - 1);
    if (size < align) size = align;
    if (size <= b->size) return S_OK;
    unsigned char *cpu = (unsigned char *)calloc(1, size);
    if (!cpu) return record_result(b->owner, E_OUTOFMEMORY);
    if (b->cpu) memcpy(cpu, b->cpu, b->size);
    unsigned char *old_cpu = b->cpu;
    size_t old_size = b->size;
    b->cpu = cpu; b->size = size;
    HRESULT hr = device_status(b->owner);
    if (SUCCEEDED(hr)) hr = record_result(b->owner, buffer_gpu(b));
    if (FAILED(hr) && !recovery_will_rebuild(b->owner)) {
        free(cpu); b->cpu = old_cpu; b->size = old_size; return hr;
    }
    /* Keep the enlarged CPU copy during loss. Recovery creates the GPU buffer
     * with its new size, so dirty ranges already consumed by preparation survive. */
    free(old_cpu);
    return S_OK;
}
int32_t koreterm_d3d11_buffer_write(KoretermD3DBuffer *b, size_t offset, const void *data, size_t size) {
    if (offset > b->size || size > b->size - offset) return record_result(b->owner, E_INVALIDARG);
    if (!size) return S_OK;
    memcpy(b->cpu + offset, data, size);
    // A failed device recreation must still retain subsequent CPU preparation;
    // begin() retries recovery before anything is drawn with these resources.
    HRESULT hr = device_status(b->owner);
    if (FAILED(hr)) return recovery_will_rebuild(b->owner) ? S_OK : hr;
    if (!b->owner->context || !b->gpu) return record_result(b->owner, E_FAIL);
    if (b->uniform) {
        ID3D11DeviceContext_UpdateSubresource(b->owner->context, (ID3D11Resource *)b->gpu, 0, NULL, b->cpu, 0, 0);
    } else {
        D3D11_BOX box = { (UINT)offset, 0, 0, (UINT)(offset + size), 1, 1 };
        ID3D11DeviceContext_UpdateSubresource(b->owner->context, (ID3D11Resource *)b->gpu, 0, &box, b->cpu + offset, 0, 0);
    }
    b->owner->stats.upload_bytes += size;
    return S_OK;
}
KoretermD3DTexture *koreterm_d3d11_texture_create(KoretermD3D *d, uint32_t width, uint32_t height, uint32_t format, uint32_t srgb, const void *data) {
    if (!width || !height || width > D3D11_REQ_TEXTURE2D_U_OR_V_DIMENSION || height > D3D11_REQ_TEXTURE2D_U_OR_V_DIMENSION || format > 2) {
        (void)record_result(d, E_INVALIDARG); return NULL;
    }
    KoretermD3DTexture *t = (KoretermD3DTexture *)calloc(1, sizeof(*t));
    if (!t) { (void)record_result(d, E_OUTOFMEMORY); return NULL; }
    t->owner = d; t->width = width; t->height = height;
    t->pixel_size = format == 0 ? 1 : 4;
    switch (format) {
    case 0: t->format = DXGI_FORMAT_R8_UNORM; break;
    case 1: t->format = srgb ? DXGI_FORMAT_R8G8B8A8_UNORM_SRGB : DXGI_FORMAT_R8G8B8A8_UNORM; break;
    default: t->format = srgb ? DXGI_FORMAT_B8G8R8A8_UNORM_SRGB : DXGI_FORMAT_B8G8R8A8_UNORM; break;
    }
    size_t bytes = (size_t)width * height * t->pixel_size;
    t->cpu = (unsigned char *)calloc(1, bytes);
    if (!t->cpu) { free(t); (void)record_result(d, E_OUTOFMEMORY); return NULL; }
    if (data) memcpy(t->cpu, data, bytes);
    HRESULT hr = device_status(d);
    if (SUCCEEDED(hr)) hr = record_result(d, texture_gpu(t));
    if (FAILED(hr) && !recovery_will_rebuild(d)) { RELEASE(t->srv); RELEASE(t->gpu); free(t->cpu); free(t); return NULL; }
    t->next = d->textures; d->textures = t;
    d->stats.upload_bytes += data ? bytes : 0;
    return t;
}
void koreterm_d3d11_texture_destroy(KoretermD3DTexture *t) {
    KoretermD3DTexture **link = &t->owner->textures;
    while (*link && *link != t) link = &(*link)->next;
    if (*link) *link = t->next;
    RELEASE(t->srv); RELEASE(t->gpu); free(t->cpu); free(t);
}
int32_t koreterm_d3d11_texture_write(KoretermD3DTexture *t, uint32_t x, uint32_t y, uint32_t width, uint32_t height, const void *data) {
    if (x > t->width || width > t->width - x || y > t->height || height > t->height - y) return record_result(t->owner, E_INVALIDARG);
    if (!width || !height) return S_OK;
    size_t pitch = (size_t)width * t->pixel_size;
    for (uint32_t row = 0; row < height; ++row) memcpy(t->cpu + ((size_t)(y + row) * t->width + x) * t->pixel_size, (const unsigned char *)data + row * pitch, pitch);
    HRESULT hr = device_status(t->owner);
    if (FAILED(hr)) return recovery_will_rebuild(t->owner) ? S_OK : hr;
    if (!t->owner->context || !t->gpu) return record_result(t->owner, E_FAIL);
    D3D11_BOX box = { x, y, 0, x + width, y + height, 1 };
    /* Upload from the mirror recovery rebuilds from, as buffer writes do. */
    const unsigned char *src = t->cpu + ((size_t)y * t->width + x) * t->pixel_size;
    ID3D11DeviceContext_UpdateSubresource(t->owner->context, (ID3D11Resource *)t->gpu, 0, &box, src, (UINT)((size_t)t->width * t->pixel_size), 0);
    t->owner->stats.upload_bytes += pitch * height;
    return S_OK;
}
KoretermD3DTarget *koreterm_d3d11_target_create(KoretermD3D *d, uint32_t width, uint32_t height, uint32_t linear) {
    if (width > D3D11_REQ_TEXTURE2D_U_OR_V_DIMENSION || height > D3D11_REQ_TEXTURE2D_U_OR_V_DIMENSION) {
        (void)record_result(d, E_INVALIDARG); return NULL;
    }
    KoretermD3DTarget *t = (KoretermD3DTarget *)calloc(1, sizeof(*t));
    if (!t) { (void)record_result(d, E_OUTOFMEMORY); return NULL; }
    t->owner = d; t->width = width; t->height = height; t->linear = linear;
    HRESULT hr = device_status(d);
    if (SUCCEEDED(hr)) hr = record_result(d, target_gpu(t));
    if (FAILED(hr) && !recovery_will_rebuild(d)) { RELEASE(t->gamma_rtv); RELEASE(t->rtv); RELEASE(t->gpu); free(t); return NULL; }
    t->next = d->targets; d->targets = t;
    return t;
}
void koreterm_d3d11_target_destroy(KoretermD3DTarget *t) {
    KoretermD3DTarget **link = &t->owner->targets;
    while (*link && *link != t) link = &(*link)->next;
    if (*link) *link = t->next;
    if (t->owner->last_rendered == t) t->owner->last_rendered = NULL;
    RELEASE(t->gamma_rtv); RELEASE(t->rtv); RELEASE(t->gpu); free(t);
}
int32_t koreterm_d3d11_clear(KoretermD3DTarget *t, const float *color) {
    HRESULT hr = device_status(t->owner);
    if (FAILED(hr)) return hr;
    if (!t->rtv) return record_result(t->owner, E_FAIL);
    t->rendered = 0;
    if (t->owner->last_rendered == t) t->owner->last_rendered = NULL;
    ID3D11DeviceContext_ClearRenderTargetView(t->owner->context, t->rtv, color);
    return S_OK;
}
int32_t koreterm_d3d11_draw(KoretermD3DTarget *target, uint32_t pipeline, KoretermD3DBuffer *uniforms,
    KoretermD3DBuffer *text, KoretermD3DBuffer *backgrounds, KoretermD3DTexture *gray,
    KoretermD3DTexture *color, uint32_t vertices, uint32_t instances) {
    KoretermD3D *d = target->owner;
    HRESULT hr = device_status(d);
    if (FAILED(hr)) return hr;
    if ((pipeline > PIPELINE_TEXT && pipeline != PIPELINE_SPLIT_DIM) || !target->rtv || !uniforms || uniforms->owner != d || !uniforms->gpu) return record_result(d, E_INVALIDARG);
    if (((pipeline == PIPELINE_CELL_BG || pipeline == PIPELINE_TEXT) && (!backgrounds || !backgrounds->srv)) ||
        (pipeline == PIPELINE_TEXT && (!text || !text->srv || !gray || !gray->srv || !color || !color->srv))) return record_result(d, E_INVALIDARG);
    if ((text && text->owner != d) || (backgrounds && backgrounds->owner != d) ||
        (gray && gray->owner != d) || (color && color->owner != d)) return record_result(d, E_INVALIDARG);
    /* The split dim is the background shader fed the fill (bg_ps does not
     * linearize it), blended over the finished frame through a UNORM view,
     * so on the stored sRGB bytes, as upstream's overlay blends. */
    const int split_dim = pipeline == PIPELINE_SPLIT_DIM;
    ID3D11RenderTargetView *rtv = split_dim && target->gamma_rtv ? target->gamma_rtv : target->rtv;
    D3D11_VIEWPORT viewport = { 0, 0, (float)target->width, (float)target->height, 0, 1 };
    ID3D11DeviceContext_RSSetViewports(d->context, 1, &viewport);
    ID3D11DeviceContext_RSSetState(d->context, d->rasterizer);
    ID3D11DeviceContext_OMSetRenderTargets(d->context, 1, &rtv, NULL);
    ID3D11DeviceContext_OMSetBlendState(d->context, pipeline == PIPELINE_BG ? d->opaque : d->blend, NULL, UINT_MAX);
    ID3D11DeviceContext_IASetInputLayout(d->context, NULL);
    ID3D11DeviceContext_IASetPrimitiveTopology(d->context, pipeline == PIPELINE_TEXT ? D3D11_PRIMITIVE_TOPOLOGY_TRIANGLESTRIP : D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    ID3D11DeviceContext_VSSetShader(d->context, pipeline == PIPELINE_TEXT ? d->text_vs : d->bg_vs, NULL, 0);
    ID3D11DeviceContext_PSSetShader(d->context, d->ps[split_dim ? PIPELINE_BG : pipeline], NULL, 0);
    ID3D11DeviceContext_VSSetConstantBuffers(d->context, 0, 1, &uniforms->gpu);
    ID3D11DeviceContext_PSSetConstantBuffers(d->context, 0, 1, &uniforms->gpu);
    ID3D11ShaderResourceView *resources[4] = {
        gray ? gray->srv : NULL, color ? color->srv : NULL,
        text ? text->srv : NULL, backgrounds ? backgrounds->srv : NULL
    };
    ID3D11DeviceContext_VSSetShaderResources(d->context, 0, 4, resources);
    ID3D11DeviceContext_PSSetShaderResources(d->context, 0, 4, resources);
    ID3D11DeviceContext_DrawInstanced(d->context, vertices, instances, 0, 0);
    ++d->stats.draw_calls;
    return device_status(d);
}

int32_t koreterm_d3d11_suspend_presentation(KoretermD3D *d) {
    // Strict healthy handoff: detach must complete before WGL can present.
    // Invalid composition graphs have no usable content to keep attached.
    if (d->composition) {
        HRESULT hr = koreterm_composition_check_state(d->composition);
        if (SUCCEEDED(hr)) {
            hr = koreterm_composition_detach(d->composition);
            if (FAILED(hr)) return hr;
        }
        koreterm_composition_destroy(d->composition);
        d->composition = NULL;
    }
    d->composition_committed = 0;
    if (d->context) ID3D11DeviceContext_OMSetRenderTargets(d->context, 0, NULL, NULL);
    RELEASE(d->backbuffer);
    RELEASE(d->swapchain);
    if (d->context) ID3D11DeviceContext_Flush(d->context);
    d->width = d->height = d->occluded = 0;
    return S_OK;
}
