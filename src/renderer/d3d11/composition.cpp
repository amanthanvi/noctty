/* The Windows SDK exposes DirectComposition through C++ interfaces. Keep the
 * SDK-owned ABI here, with a small C interface for the renderer bridge. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <dxgi.h>
#include <dcomp.h>
#include "composition.h"

typedef HRESULT (WINAPI *CreateCompositionDevice)(IDXGIDevice *, REFIID, void **);

static INIT_ONCE composition_library_once = INIT_ONCE_STATIC_INIT;
static CreateCompositionDevice create_composition_device;

/* Fail the load, keeping the error that FreeLibrary could overwrite. */
static BOOL fail_load(HMODULE library) {
    DWORD error = GetLastError();
    FreeLibrary(library);
    SetLastError(error);
    return FALSE;
}

static BOOL CALLBACK load_composition_library(PINIT_ONCE once, PVOID parameter,
    PVOID *context) {
    (void)once; (void)parameter; (void)context;
    HMODULE library = LoadLibraryExW(L"dcomp.dll", NULL, LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (!library) return FALSE;

    FARPROC create = GetProcAddress(library, "DCompositionCreateDevice");
    if (!create) return fail_load(library);

    /* All composition interfaces use this module's vtables. Pin the verified
     * System32 module for process lifetime before publishing its factory. */
    HMODULE pinned;
    if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_PIN |
        GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS,
        reinterpret_cast<LPCWSTR>(library), &pinned)) {
        return fail_load(library);
    }
    create_composition_device = reinterpret_cast<CreateCompositionDevice>(create);
    FreeLibrary(library);
    return TRUE;
}

struct KoretermComposition {
    IDCompositionDevice *device;
    IDCompositionTarget *target;
    IDCompositionVisual *visual;
    IUnknown *content;
    bool committed;
    bool detached;
};

static void release_composition(KoretermComposition *composition) {
    /* The HWND cannot have a second target on this layer until this reference
     * is released, including a failed candidate or a removed device. */
    if (composition->target) composition->target->Release();
    if (composition->visual) composition->visual->Release();
    if (composition->content) composition->content->Release();
    if (composition->device) composition->device->Release();
    HeapFree(GetProcessHeap(), 0, composition);
}

int32_t koreterm_composition_check_state(KoretermComposition *composition) {
    if (!composition || !composition->device) return E_INVALIDARG;
    BOOL valid = FALSE;
    HRESULT hr = composition->device->CheckDeviceState(&valid);
    if (FAILED(hr)) return hr;
    return valid ? S_OK : DXGI_ERROR_DEVICE_REMOVED;
}

int32_t koreterm_composition_create(void *dxgi_device, void *hwnd, void *swapchain,
    KoretermComposition **out) {
    if (!out) return E_POINTER;
    *out = NULL;
    if (!dxgi_device || !hwnd || !swapchain) return E_INVALIDARG;
    if (!InitOnceExecuteOnce(&composition_library_once, load_composition_library,
        NULL, NULL)) {
        DWORD error = GetLastError();
        return HRESULT_FROM_WIN32(error ? error : ERROR_MOD_NOT_FOUND);
    }

    KoretermComposition *composition = static_cast<KoretermComposition *>(
        HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, sizeof(KoretermComposition)));
    if (!composition) return E_OUTOFMEMORY;
    composition->content = static_cast<IUnknown *>(swapchain);
    composition->content->AddRef();

    HRESULT hr = create_composition_device(static_cast<IDXGIDevice *>(dxgi_device),
        __uuidof(IDCompositionDevice), reinterpret_cast<void **>(&composition->device));
    if (SUCCEEDED(hr)) hr = composition->device->CreateTargetForHwnd(
        static_cast<HWND>(hwnd), FALSE, &composition->target);
    if (SUCCEEDED(hr)) hr = composition->device->CreateVisual(&composition->visual);
    if (SUCCEEDED(hr)) hr = composition->visual->SetContent(composition->content);
    if (SUCCEEDED(hr)) hr = composition->target->SetRoot(composition->visual);
    if (SUCCEEDED(hr)) hr = koreterm_composition_check_state(composition);
    if (FAILED(hr)) {
        release_composition(composition);
        return hr;
    }

    *out = composition;
    return S_OK;
}

int32_t koreterm_composition_commit(KoretermComposition *composition) {
    HRESULT hr = koreterm_composition_check_state(composition);
    if (FAILED(hr)) return hr;
    if (composition->detached) return E_UNEXPECTED;
    if (composition->committed) return S_OK;
    hr = composition->device->Commit();
    if (SUCCEEDED(hr)) {
        composition->committed = true;
        hr = koreterm_composition_check_state(composition);
    }
    return hr;
}

static HRESULT restore_after_failed_detach(KoretermComposition *composition,
    HRESULT failure) {
    /* Keep a failed healthy handoff usable by the retained renderer. An invalid
     * graph needs reconstruction instead; it must never wait for DWM. */
    if (SUCCEEDED(koreterm_composition_check_state(composition))) {
        HRESULT hr = composition->visual->SetContent(composition->content);
        if (SUCCEEDED(hr)) hr = composition->target->SetRoot(composition->visual);
        if (SUCCEEDED(hr) && composition->committed) composition->device->Commit();
    }
    return failure;
}

int32_t koreterm_composition_detach(KoretermComposition *composition) {
    HRESULT hr = koreterm_composition_check_state(composition);
    if (FAILED(hr)) return hr;
    if (composition->detached) return S_OK;

    hr = composition->target->SetRoot(NULL);
    if (SUCCEEDED(hr)) hr = composition->visual->SetContent(NULL);
    if (FAILED(hr)) return restore_after_failed_detach(composition, hr);

    /* Detachment is asynchronous. This composition chain does not own the HWND
     * presentation path, so WGL can use its redirection surface while DWM applies
     * the checked commit. Never wait for DWM on the UI thread. */
    if (composition->committed) {
        hr = composition->device->Commit();
        if (SUCCEEDED(hr)) hr = koreterm_composition_check_state(composition);
        if (FAILED(hr)) return restore_after_failed_detach(composition, hr);
    }

    composition->committed = false;
    composition->detached = true;
    return S_OK;
}

void koreterm_composition_destroy(KoretermComposition *composition) {
    if (!composition) return;
    if (!composition->detached && composition->committed &&
        SUCCEEDED(koreterm_composition_check_state(composition))) {
        HRESULT hr = composition->target->SetRoot(NULL);
        if (SUCCEEDED(hr)) hr = composition->visual->SetContent(NULL);
        if (SUCCEEDED(hr)) composition->device->Commit();
    }
    release_composition(composition);
}
