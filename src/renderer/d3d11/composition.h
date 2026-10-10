#ifndef NOCTTY_D3D11_COMPOSITION_H
#define NOCTTY_D3D11_COMPOSITION_H
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct NocttyComposition NocttyComposition;

/* Borrows an IDXGIDevice, HWND and IDXGISwapChain. On success, the wrapper
 * retains the swapchain and owns its composition interfaces. The visual tree
 * is staged but not committed, so an uninitialized backbuffer stays hidden.
 * Failure always leaves *out NULL and releases any partially created target. */
int32_t noctty_composition_create(void *dxgi_device, void *hwnd, void *swapchain,
    NocttyComposition **out);

/* Call only after the swapchain's first successful Present. This submits the
 * staged tree without waiting for scanout; later calls only check validity. */
int32_t noctty_composition_commit(NocttyComposition *composition);

/* CheckDeviceState(FALSE) is reported as DXGI_ERROR_DEVICE_REMOVED. */
int32_t noctty_composition_check_state(NocttyComposition *composition);

/* Healthy renderer handoff: detach root/content, Commit, then wait for that
 * commit to be processed. A failed detach keeps the object owned by the caller
 * and attempts to restore a healthy tree. Do not construct a replacement
 * renderer unless this succeeds. Destroy before creating another target for
 * the same HWND; the detached wrapper still owns its target and swapchain. */
int32_t noctty_composition_detach(NocttyComposition *composition);

/* Best-effort teardown, including partial or invalid devices. Never waits for
 * commit completion. Accepts NULL and releases the HWND target first. */
void noctty_composition_destroy(NocttyComposition *composition);

#ifdef __cplusplus
}
#endif
#endif
