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
#ifndef NOCTTY_RENDERER_TEST_TOOLS
#define NOCTTY_RENDERER_TEST_TOOLS 0
#endif

#define RELEASE(p) do { if (p) { IUnknown_Release((IUnknown *)(p)); (p) = NULL; } } while (0)

struct NocttyD3DBuffer {
    NocttyD3D *owner;
    struct NocttyD3DBuffer *next;
    ID3D11Buffer *gpu;
    ID3D11ShaderResourceView *srv;
    unsigned char *cpu;
    size_t size;
    uint32_t uniform;
};
struct NocttyD3DTexture {
    NocttyD3D *owner;
    struct NocttyD3DTexture *next;
    ID3D11Texture2D *gpu;
    ID3D11ShaderResourceView *srv;
    unsigned char *cpu;
    uint32_t width, height, pixel_size;
    DXGI_FORMAT format;
};
struct NocttyD3DTarget {
    NocttyD3D *owner;
    struct NocttyD3DTarget *next;
    ID3D11Texture2D *gpu;
    ID3D11RenderTargetView *rtv;
    uint32_t width, height, linear, rendered;
};
struct NocttyD3D {
    HWND hwnd;
    HMODULE library;
    PFN_D3D11_CREATE_DEVICE create_device_proc;
    ID3D11Device *device;
    ID3D11DeviceContext *context;
    IDXGISwapChain1 *swapchain;
    NocttyComposition *composition;
    uint32_t composition_committed;
    ID3D11Texture2D *backbuffer;
    ID3D11VertexShader *bg_vs, *text_vs;
    ID3D11PixelShader *ps[3];
    ID3D11BlendState *blend, *opaque;
    ID3D11RasterizerState *rasterizer;
    NocttyD3DBuffer *buffers;
    NocttyD3DTexture *textures;
    NocttyD3DTarget *targets;
    NocttyD3DTarget *last_rendered;
    uint32_t width, height, force_warp, occluded;
    uint64_t hardware_retry_after_ms;
    uint64_t next_present_test_ms;
#if NOCTTY_RENDERER_TEST_TOOLS
    uint32_t fail_hardware, fail_device, fail_resource;
    HRESULT next_present_failure;
#endif
    LARGE_INTEGER frequency, frame_start;
    NocttyD3DStats stats;
};

#if NOCTTY_RENDERER_TEST_TOOLS
static uint64_t elapsed_ns(NocttyD3D *d, LARGE_INTEGER start, LARGE_INTEGER end) {
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
/* Resource allocations, resize, Present and Map all route failures here. Void
 * context calls are checked at frame boundaries via GetDeviceRemovedReason. */
static HRESULT record_result(NocttyD3D *d, HRESULT hr) {
    if (SUCCEEDED(hr)) return hr;
    HRESULT reason = d->device ? ID3D11Device_GetDeviceRemovedReason(d->device) : S_OK;
    d->stats.last_error = hr;
    if (device_lost(hr) || FAILED(reason)) {
        d->stats.removed_reason = FAILED(reason) ? reason : hr;
        d->stats.recovery_pending = 1;
        d->last_rendered = NULL;
        for (NocttyD3DTarget *t = d->targets; t; t = t->next) t->rendered = 0;
    } else if (hr == E_INVALIDARG || hr == DXGI_ERROR_INVALID_CALL) {
        // Bridge contract errors are not device loss or a WARP retry trigger.
        fprintf(stderr, "d3d11 contract failure hr=0x%08lx\n", (unsigned long)hr);
    } else if (!d->stats.warp && !d->force_warp) {
        /* A hardware allocation/Present failure can still succeed on WARP.
         * It gets one bounded software reconstruction before OpenGL. */
        d->hardware_retry_after_ms = GetTickCount64() + 60000;
        d->stats.recovery_pending = 1;
        d->last_rendered = NULL;
        for (NocttyD3DTarget *t = d->targets; t; t = t->next) t->rendered = 0;
    } else {
        d->stats.unavailable = 1;
    }
    return hr;
}
static HRESULT device_status(NocttyD3D *d) {
    if (d->stats.unavailable) return FAILED(d->stats.last_error) ? d->stats.last_error : E_FAIL;
    if (d->stats.recovery_pending) return DXGI_ERROR_DEVICE_REMOVED;
    if (!d->device) return record_result(d, E_FAIL);
    HRESULT hr = ID3D11Device_GetDeviceRemovedReason(d->device);
    if (SUCCEEDED(hr) && d->composition) hr = noctty_composition_check_state(d->composition);
    return record_result(d, hr);
}
static HRESULT buffer_gpu(NocttyD3DBuffer *b) {
    if (!b->owner->device) return E_FAIL;
#if NOCTTY_RENDERER_TEST_TOOLS
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
static HRESULT texture_gpu(NocttyD3DTexture *t) {
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
static HRESULT target_gpu(NocttyD3DTarget *t) {
    if (!t->owner->device) return E_FAIL;
    if (!t->width || !t->height) return S_OK;
    ID3D11Texture2D *gpu = NULL;
    ID3D11RenderTargetView *rtv = NULL;
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
    RELEASE(t->rtv); RELEASE(t->gpu);
    t->gpu = gpu; t->rtv = rtv; t->rendered = 0;
    return S_OK;
}
static void release_device(NocttyD3D *d) {
    if (d->context) ID3D11DeviceContext_ClearState(d->context);
    for (NocttyD3DBuffer *b = d->buffers; b; b = b->next) { RELEASE(b->srv); RELEASE(b->gpu); }
    for (NocttyD3DTexture *t = d->textures; t; t = t->next) { RELEASE(t->srv); RELEASE(t->gpu); }
    for (NocttyD3DTarget *t = d->targets; t; t = t->next) { RELEASE(t->rtv); RELEASE(t->gpu); t->rendered = 0; }
    d->last_rendered = NULL;
    noctty_composition_destroy(d->composition);
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
static HRESULT create_device(NocttyD3D *d, uint32_t warp) {
    D3D_FEATURE_LEVEL requested = D3D_FEATURE_LEVEL_11_0, obtained;
#if NOCTTY_RENDERER_TEST_TOOLS
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
    hr = ID3D11Device_CreateVertexShader(d->device, noctty_bg_vs, sizeof(noctty_bg_vs), NULL, &d->bg_vs);
    if (FAILED(hr)) return hr;
    hr = ID3D11Device_CreateVertexShader(d->device, noctty_text_vs, sizeof(noctty_text_vs), NULL, &d->text_vs);
    if (FAILED(hr)) return hr;
    const unsigned char *code[] = { noctty_bg_ps, noctty_cellbg_ps, noctty_text_ps };
    const size_t lengths[] = { sizeof(noctty_bg_ps), sizeof(noctty_cellbg_ps), sizeof(noctty_text_ps) };
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
    for (NocttyD3DBuffer *b = d->buffers; b; b = b->next) if (FAILED(hr = buffer_gpu(b))) return hr;
    for (NocttyD3DTexture *t = d->textures; t; t = t->next) if (FAILED(hr = texture_gpu(t))) return hr;
    for (NocttyD3DTarget *t = d->targets; t; t = t->next) if (FAILED(hr = target_gpu(t))) return hr;
    return S_OK;
}
static HRESULT resize_swapchain(NocttyD3D *d, uint32_t width, uint32_t height) {
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
            if (SUCCEEDED(hr)) hr = noctty_composition_create(dxgi_device, d->hwnd,
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

/* Each candidate owns every resource or none. One hardware retry is allowed
 * across this backend's lifetime; WARP remains selected after escalation. */
static HRESULT create_candidates(NocttyD3D *d, uint32_t try_hardware) {
    HRESULT hr = E_FAIL;
    if (try_hardware) {
        hr = create_device(d, 0);
        if (SUCCEEDED(hr)) return hr;
        d->stats.last_error = hr;
        if (d->device) {
            HRESULT reason = ID3D11Device_GetDeviceRemovedReason(d->device);
            if (FAILED(reason)) d->stats.removed_reason = reason;
        }
        release_device(d);
    }
    hr = create_device(d, 1);
    if (FAILED(hr)) {
        d->stats.last_error = hr;
        if (d->device) {
            HRESULT reason = ID3D11Device_GetDeviceRemovedReason(d->device);
            if (FAILED(reason)) d->stats.removed_reason = reason;
        }
        release_device(d);
    }
    return hr;
}
NocttyD3D *noctty_d3d11_create(void *hwnd, uint32_t force_warp) {
    if (!hwnd || !IsWindow((HWND)hwnd)) return NULL;
    NocttyD3D *d = (NocttyD3D *)calloc(1, sizeof(*d));
    if (!d) return NULL;
    d->hwnd = (HWND)hwnd;
    /* Only opted-in surfaces load graphics support. Missing D3D11 must never
     * prevent the OpenGL-default executable from reaching its fallback. */
#if NOCTTY_RENDERER_TEST_TOOLS
    if (env_number("NOCTTY_RENDERER_FAIL_LIBRARY")) { free(d); return NULL; }
#endif
    if (!InitOnceExecuteOnce(&d3d_library_once, load_d3d_library, NULL, NULL)) { free(d); return NULL; }
    d->library = d3d_library;
    if (!d->library) { free(d); return NULL; }
    d->create_device_proc = (PFN_D3D11_CREATE_DEVICE)(void *)GetProcAddress(d->library, "D3D11CreateDevice");
    if (!d->create_device_proc) { free(d); return NULL; }
    d->force_warp = force_warp != 0;
    d->stats.last_present_status = S_FALSE;
#if NOCTTY_RENDERER_TEST_TOOLS
    d->fail_hardware = env_number("NOCTTY_RENDERER_FAIL_HARDWARE") != 0;
    d->fail_device = env_number("NOCTTY_RENDERER_FAIL_DEVICE") != 0;
    d->fail_resource = env_number("NOCTTY_RENDERER_FAIL_RESOURCE") != 0;
    QueryPerformanceFrequency(&d->frequency);
#endif
    HRESULT hr = create_device(d, d->force_warp);
    if (FAILED(hr)) {
        fprintf(stderr, "d3d11 initialization_failed hr=0x%08lx\n", (unsigned long)hr);
        noctty_d3d11_destroy(d);
        return NULL;
    }
    d->stats.generation = 1;
    return d;
}
void noctty_d3d11_destroy(NocttyD3D *d) {
    if (!d) return;
    release_device(d);
    // Renderer normally destroys resources first. Drain on failed initialization too.
    while (d->buffers) noctty_d3d11_buffer_destroy(d->buffers);
    while (d->textures) noctty_d3d11_texture_destroy(d->textures);
    while (d->targets) noctty_d3d11_target_destroy(d->targets);
    // The process pins the runtime; drivers may finish worker teardown later.
    free(d);
}
int32_t noctty_d3d11_recover(NocttyD3D *d) {
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
int32_t noctty_d3d11_begin(NocttyD3D *d) {
    HRESULT hr = noctty_d3d11_recover(d);
    if (FAILED(hr)) return hr;
#if NOCTTY_RENDERER_TEST_TOOLS
    QueryPerformanceCounter(&d->frame_start);
#endif
    return S_OK;
}
static HRESULT present_target(NocttyD3D *d, NocttyD3DTarget *target, uint32_t vsync, int encoded) {
    HRESULT hr = device_status(d);
    if (FAILED(hr)) return hr;
#if NOCTTY_RENDERER_TEST_TOOLS
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
#if NOCTTY_RENDERER_TEST_TOOLS
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
#if NOCTTY_RENDERER_TEST_TOOLS
    LARGE_INTEGER before, after;
    QueryPerformanceCounter(&before);
#endif
    hr = IDXGISwapChain1_Present(d->swapchain, vsync ? 1 : 0, 0);
    d->stats.last_present_status = hr;
#if NOCTTY_RENDERER_TEST_TOOLS
    QueryPerformanceCounter(&after);
    d->stats.present_ns += elapsed_ns(d, before, after);
#endif
    if (FAILED(hr)) return record_result(d, hr);
    if (hr == DXGI_STATUS_OCCLUDED) {
        d->occluded = 1;
        d->next_present_test_ms = GetTickCount64() + 250;
        ++d->stats.occluded_presents;
    } else if (hr == S_OK) {
        // Attach only initialized pixels. A failed DComp commit is a failed
        // submission, so it cannot signal the app's first-frame handshake.
        if (!d->composition_committed) {
            hr = noctty_composition_commit(d->composition);
            if (FAILED(hr)) return record_result(d, hr);
            d->composition_committed = 1;
            ++d->stats.composition_commits;
        }
        ++d->stats.presents;
    }
    return hr;
}
int32_t noctty_d3d11_present(NocttyD3D *d, NocttyD3DTarget *target, uint32_t vsync) {
    return present_target(d, target, vsync, 1);
}
void noctty_d3d11_stats(NocttyD3D *d, NocttyD3DStats *stats) { *stats = d->stats; }
uint32_t noctty_d3d11_needs_redraw(NocttyD3D *d) {
    return d->stats.recovery_pending || !d->last_rendered;
}
uint32_t noctty_d3d11_occluded(NocttyD3D *d) { return d->occluded; }
uint32_t noctty_d3d11_recovery_pending(NocttyD3D *d) { return d->stats.recovery_pending; }
uint32_t noctty_d3d11_unavailable(NocttyD3D *d) { return d->stats.unavailable; }
int32_t noctty_d3d11_last_error(NocttyD3D *d) { return d->stats.last_error; }
int32_t noctty_d3d11_request_device_loss(NocttyD3D *d) {
#if NOCTTY_RENDERER_TEST_TOOLS
    /* Deterministically inject the HRESULT into the real loss classifier. This
     * is not a system-wide driver reset and is not evidence of TDR behavior. */
    (void)record_result(d, DXGI_ERROR_DEVICE_REMOVED);
    return S_OK;
#else
    (void)d;
    return E_NOTIMPL;
#endif
}
int32_t noctty_d3d11_present_last(NocttyD3D *d, uint32_t vsync) {
    return d->last_rendered ? present_target(d, d->last_rendered, vsync, 0) : S_FALSE;
}
int32_t noctty_d3d11_set_test_failures(NocttyD3D *d, uint32_t hardware, uint32_t device) {
#if NOCTTY_RENDERER_TEST_TOOLS
    d->fail_hardware = hardware != 0;
    d->fail_device = device != 0;
    return S_OK;
#else
    (void)d; (void)hardware; (void)device;
    return E_NOTIMPL;
#endif
}

int32_t noctty_d3d11_fail_next_present(NocttyD3D *d) {
#if NOCTTY_RENDERER_TEST_TOOLS
    d->next_present_failure = E_OUTOFMEMORY;
    return S_OK;
#else
    (void)d;
    return E_NOTIMPL;
#endif
}

#if NOCTTY_RENDERER_TEST_TOOLS
static HRESULT readback(NocttyD3D *d, unsigned char **pixels, uint32_t *width, uint32_t *height) {
    NocttyD3DTarget *target = d->last_rendered;
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
    size_t row_size = (size_t)desc.Width * 4;
    unsigned char *bgra = (unsigned char *)malloc(row_size * desc.Height);
    if (!bgra) {
        ID3D11DeviceContext_Unmap(d->context, (ID3D11Resource *)staging, 0);
        RELEASE(staging);
        return E_OUTOFMEMORY;
    }
    for (UINT y = 0; y < desc.Height; ++y) {
        const unsigned char *source = (const unsigned char *)mapped.pData + (size_t)y * mapped.RowPitch;
        unsigned char *dest = bgra + (size_t)y * row_size;
        for (UINT x = 0; x < desc.Width; ++x) {
            dest[x * 4 + 0] = source[x * 4 + 2];
            dest[x * 4 + 1] = source[x * 4 + 1];
            dest[x * 4 + 2] = source[x * 4 + 0];
            dest[x * 4 + 3] = 255;
        }
    }
    ID3D11DeviceContext_Unmap(d->context, (ID3D11Resource *)staging, 0);
    RELEASE(staging);
    *pixels = bgra; *width = desc.Width; *height = desc.Height;
    return S_OK;
}
static HRESULT save_bmp(const uint16_t *path, const unsigned char *pixels, uint32_t width, uint32_t height) {
    if (!path || !*path) return E_INVALIDARG;
    BITMAPFILEHEADER file;
    BITMAPINFOHEADER image;
    memset(&file, 0, sizeof(file)); memset(&image, 0, sizeof(image));
    image.biSize = sizeof(image); image.biWidth = (LONG)width; image.biHeight = -(LONG)height;
    image.biPlanes = 1; image.biBitCount = 32; image.biCompression = BI_RGB;
    image.biSizeImage = width * height * 4;
    file.bfType = 0x4d42; file.bfOffBits = sizeof(file) + sizeof(image);
    file.bfSize = file.bfOffBits + image.biSizeImage;
    HANDLE handle = CreateFileW((const WCHAR *)path, GENERIC_WRITE, FILE_SHARE_READ, NULL,
        CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (handle == INVALID_HANDLE_VALUE) return HRESULT_FROM_WIN32(GetLastError());
    DWORD written;
    HRESULT hr = S_OK;
    if (!WriteFile(handle, &file, sizeof(file), &written, NULL) || written != sizeof(file) ||
        !WriteFile(handle, &image, sizeof(image), &written, NULL) || written != sizeof(image) ||
        !WriteFile(handle, pixels, image.biSizeImage, &written, NULL) || written != image.biSizeImage) hr = E_FAIL;
    CloseHandle(handle);
    return hr;
}
#endif
int32_t noctty_d3d11_capture(NocttyD3D *d, void *hdc) {
#if NOCTTY_RENDERER_TEST_TOOLS
    unsigned char *bgra = NULL;
    uint32_t width, height;
    HRESULT hr = readback(d, &bgra, &width, &height);
    if (FAILED(hr)) return hr;
    BITMAPINFO info;
    memset(&info, 0, sizeof(info));
    info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    info.bmiHeader.biWidth = (LONG)width;
    info.bmiHeader.biHeight = -(LONG)height;
    info.bmiHeader.biPlanes = 1;
    info.bmiHeader.biBitCount = 32;
    info.bmiHeader.biCompression = BI_RGB;
    WCHAR path[32768];
    DWORD count = GetEnvironmentVariableW(L"NOCTTY_RENDERER_CAPTURE_PATH", path, ARRAYSIZE(path));
    HRESULT saved = count && count < ARRAYSIZE(path) ? save_bmp((const uint16_t *)path, bgra, width, height) : E_FAIL;
    int rows = hdc ? StretchDIBits((HDC)hdc, 0, 0, (int)width, (int)height,
        0, 0, (int)width, (int)height, bgra, &info, DIB_RGB_COLORS, SRCCOPY) : 0;
    free(bgra);
    return SUCCEEDED(saved) || (rows != 0 && rows != GDI_ERROR) ? S_OK : E_FAIL;
#else
    (void)d; (void)hdc;
    return E_NOTIMPL;
#endif
}

NocttyD3DBuffer *noctty_d3d11_buffer_create(NocttyD3D *d, size_t size, uint32_t uniform) {
    NocttyD3DBuffer *b = (NocttyD3DBuffer *)calloc(1, sizeof(*b));
    if (!b) { (void)record_result(d, E_OUTOFMEMORY); return NULL; }
    b->owner = d; b->uniform = uniform;
    if (FAILED(noctty_d3d11_buffer_reserve(b, size))) { free(b->cpu); free(b); return NULL; }
    b->next = d->buffers; d->buffers = b;
    return b;
}
void noctty_d3d11_buffer_destroy(NocttyD3DBuffer *b) {
    NocttyD3DBuffer **link = &b->owner->buffers;
    while (*link && *link != b) link = &(*link)->next;
    if (*link) *link = b->next;
    RELEASE(b->srv); RELEASE(b->gpu); free(b->cpu); free(b);
}
int32_t noctty_d3d11_buffer_reserve(NocttyD3DBuffer *b, size_t size) {
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
    if (FAILED(hr) && (!b->owner->stats.recovery_pending || b->owner->stats.unavailable)) {
        free(cpu); b->cpu = old_cpu; b->size = old_size; return hr;
    }
    /* Keep the enlarged CPU copy during loss. Recovery creates the GPU buffer
     * with its new size, so dirty ranges already consumed by preparation survive. */
    free(old_cpu);
    return S_OK;
}
int32_t noctty_d3d11_buffer_write(NocttyD3DBuffer *b, size_t offset, const void *data, size_t size) {
    if (offset > b->size || size > b->size - offset) return record_result(b->owner, E_INVALIDARG);
    if (!size) return S_OK;
    memcpy(b->cpu + offset, data, size);
    // A failed device recreation must still retain subsequent CPU preparation;
    // begin() retries recovery before anything is drawn with these resources.
    HRESULT hr = device_status(b->owner);
    if (FAILED(hr)) return b->owner->stats.recovery_pending && !b->owner->stats.unavailable ? S_OK : hr;
    if (!b->owner->context || !b->gpu) return record_result(b->owner, E_FAIL);
    if (b->uniform) {
        ID3D11DeviceContext_UpdateSubresource(b->owner->context, (ID3D11Resource *)b->gpu, 0, NULL, b->cpu, 0, 0);
    } else {
        D3D11_BOX box = { (UINT)offset, 0, 0, (UINT)(offset + size), 1, 1 };
        ID3D11DeviceContext_UpdateSubresource(b->owner->context, (ID3D11Resource *)b->gpu, 0, &box, data, 0, 0);
    }
    b->owner->stats.upload_bytes += size;
    return S_OK;
}
NocttyD3DTexture *noctty_d3d11_texture_create(NocttyD3D *d, uint32_t width, uint32_t height, uint32_t format, uint32_t srgb, const void *data) {
    if (!width || !height || width > D3D11_REQ_TEXTURE2D_U_OR_V_DIMENSION || height > D3D11_REQ_TEXTURE2D_U_OR_V_DIMENSION || format > 2) {
        (void)record_result(d, E_INVALIDARG); return NULL;
    }
    NocttyD3DTexture *t = (NocttyD3DTexture *)calloc(1, sizeof(*t));
    if (!t) { (void)record_result(d, E_OUTOFMEMORY); return NULL; }
    t->owner = d; t->width = width; t->height = height;
    t->pixel_size = format == 0 ? 1 : 4;
    t->format = format == 0 ? DXGI_FORMAT_R8_UNORM : format == 1
        ? (srgb ? DXGI_FORMAT_R8G8B8A8_UNORM_SRGB : DXGI_FORMAT_R8G8B8A8_UNORM)
        : (srgb ? DXGI_FORMAT_B8G8R8A8_UNORM_SRGB : DXGI_FORMAT_B8G8R8A8_UNORM);
    size_t bytes = (size_t)width * height * t->pixel_size;
    t->cpu = (unsigned char *)calloc(1, bytes);
    if (!t->cpu) { free(t); (void)record_result(d, E_OUTOFMEMORY); return NULL; }
    if (data) memcpy(t->cpu, data, bytes);
    HRESULT hr = device_status(d);
    if (SUCCEEDED(hr)) hr = record_result(d, texture_gpu(t));
    if (FAILED(hr) && (!d->stats.recovery_pending || d->stats.unavailable)) { RELEASE(t->srv); RELEASE(t->gpu); free(t->cpu); free(t); return NULL; }
    t->next = d->textures; d->textures = t;
    d->stats.upload_bytes += data ? bytes : 0;
    return t;
}
void noctty_d3d11_texture_destroy(NocttyD3DTexture *t) {
    NocttyD3DTexture **link = &t->owner->textures;
    while (*link && *link != t) link = &(*link)->next;
    if (*link) *link = t->next;
    RELEASE(t->srv); RELEASE(t->gpu); free(t->cpu); free(t);
}
int32_t noctty_d3d11_texture_write(NocttyD3DTexture *t, uint32_t x, uint32_t y, uint32_t width, uint32_t height, const void *data) {
    if (x > t->width || width > t->width - x || y > t->height || height > t->height - y) return record_result(t->owner, E_INVALIDARG);
    if (!width || !height) return S_OK;
    size_t pitch = (size_t)width * t->pixel_size;
    for (uint32_t row = 0; row < height; ++row) memcpy(t->cpu + ((size_t)(y + row) * t->width + x) * t->pixel_size, (const unsigned char *)data + row * pitch, pitch);
    HRESULT hr = device_status(t->owner);
    if (FAILED(hr)) return t->owner->stats.recovery_pending && !t->owner->stats.unavailable ? S_OK : hr;
    if (!t->owner->context || !t->gpu) return record_result(t->owner, E_FAIL);
    D3D11_BOX box = { x, y, 0, x + width, y + height, 1 };
    ID3D11DeviceContext_UpdateSubresource(t->owner->context, (ID3D11Resource *)t->gpu, 0, &box, data, (UINT)pitch, 0);
    t->owner->stats.upload_bytes += pitch * height;
    return S_OK;
}
NocttyD3DTarget *noctty_d3d11_target_create(NocttyD3D *d, uint32_t width, uint32_t height, uint32_t linear) {
    if (width > D3D11_REQ_TEXTURE2D_U_OR_V_DIMENSION || height > D3D11_REQ_TEXTURE2D_U_OR_V_DIMENSION) {
        (void)record_result(d, E_INVALIDARG); return NULL;
    }
    NocttyD3DTarget *t = (NocttyD3DTarget *)calloc(1, sizeof(*t));
    if (!t) { (void)record_result(d, E_OUTOFMEMORY); return NULL; }
    t->owner = d; t->width = width; t->height = height; t->linear = linear;
    HRESULT hr = device_status(d);
    if (SUCCEEDED(hr)) hr = record_result(d, target_gpu(t));
    if (FAILED(hr) && (!d->stats.recovery_pending || d->stats.unavailable)) { RELEASE(t->rtv); RELEASE(t->gpu); free(t); return NULL; }
    t->next = d->targets; d->targets = t;
    return t;
}
void noctty_d3d11_target_destroy(NocttyD3DTarget *t) {
    NocttyD3DTarget **link = &t->owner->targets;
    while (*link && *link != t) link = &(*link)->next;
    if (*link) *link = t->next;
    if (t->owner->last_rendered == t) t->owner->last_rendered = NULL;
    RELEASE(t->rtv); RELEASE(t->gpu); free(t);
}
int32_t noctty_d3d11_clear(NocttyD3DTarget *t, const float *color) {
    HRESULT hr = device_status(t->owner);
    if (FAILED(hr)) return hr;
    if (!t->rtv) return record_result(t->owner, E_FAIL);
    t->rendered = 0;
    if (t->owner->last_rendered == t) t->owner->last_rendered = NULL;
    ID3D11DeviceContext_ClearRenderTargetView(t->owner->context, t->rtv, color);
    return S_OK;
}
int32_t noctty_d3d11_draw(NocttyD3DTarget *target, uint32_t pipeline, NocttyD3DBuffer *uniforms,
    NocttyD3DBuffer *text, NocttyD3DBuffer *backgrounds, NocttyD3DTexture *gray,
    NocttyD3DTexture *color, uint32_t vertices, uint32_t instances) {
    NocttyD3D *d = target->owner;
    HRESULT hr = device_status(d);
    if (FAILED(hr)) return hr;
    if (pipeline > 2 || !target->rtv || !uniforms || uniforms->owner != d || !uniforms->gpu) return record_result(d, E_INVALIDARG);
    if ((pipeline != 0 && (!backgrounds || !backgrounds->srv)) ||
        (pipeline == 2 && (!text || !text->srv || !gray || !gray->srv || !color || !color->srv))) return record_result(d, E_INVALIDARG);
    if ((text && text->owner != d) || (backgrounds && backgrounds->owner != d) ||
        (gray && gray->owner != d) || (color && color->owner != d)) return record_result(d, E_INVALIDARG);
    D3D11_VIEWPORT viewport = { 0, 0, (float)target->width, (float)target->height, 0, 1 };
    ID3D11DeviceContext_RSSetViewports(d->context, 1, &viewport);
    ID3D11DeviceContext_RSSetState(d->context, d->rasterizer);
    ID3D11DeviceContext_OMSetRenderTargets(d->context, 1, &target->rtv, NULL);
    ID3D11DeviceContext_OMSetBlendState(d->context, pipeline == 0 ? d->opaque : d->blend, NULL, UINT_MAX);
    ID3D11DeviceContext_IASetInputLayout(d->context, NULL);
    ID3D11DeviceContext_IASetPrimitiveTopology(d->context, pipeline == 2 ? D3D11_PRIMITIVE_TOPOLOGY_TRIANGLESTRIP : D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    ID3D11DeviceContext_VSSetShader(d->context, pipeline == 2 ? d->text_vs : d->bg_vs, NULL, 0);
    ID3D11DeviceContext_PSSetShader(d->context, d->ps[pipeline], NULL, 0);
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

int32_t noctty_d3d11_suspend_presentation(NocttyD3D *d) {
    // Strict healthy handoff: detach must complete before WGL can present.
    // Invalid composition graphs have no usable content to keep attached.
    if (d->composition) {
        HRESULT hr = noctty_composition_check_state(d->composition);
        if (SUCCEEDED(hr)) {
            hr = noctty_composition_detach(d->composition);
            if (FAILED(hr)) return hr;
        }
        noctty_composition_destroy(d->composition);
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
