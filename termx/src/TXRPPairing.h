// TXRPPairing.h - C interface to TermX's on-device remote pairing
// library (termx/rppairing, libtx_rppairing.a).
//
// The library is a small Rust static library wrapping idevice's
// PairableHost (MIT, jkcoxson/idevice, remote_pairing feature only):
// TermX plays the computer in iOS 27's device-initiated pairing. It
// listens on a TCP port; the app advertises that port as a
// _remotepairing-pairable-host._tcp Bonjour service (TXOnDevicePairing),
// the user taps "Pair with TermX" under Settings > Privacy & Security >
// Developer Mode and types the PIN the app shows. The result is the
// RPPairing plist StikJIT reads, as bytes.
//
// The library is built on the Mac runner (termx/rppairing,
// .github/workflows/build-rppairing.yml) and dropped into
// termx/rppairing-artifact/, so a host-only build made without it
// still links: TXOnDevicePairing resolves these at runtime with
// dlsym and reports the pairing library missing when they are not
// in the binary. Never call them without that check.
// SPDX-License-Identifier: GPL-2.0-or-later
#ifndef TX_RPPAIRING_H
#define TX_RPPAIRING_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct TXRPPairing TXRPPairing;
typedef void (*TXRPPairingPinCallback)(const char *pin, void *context);

/// New host identity and a listener on all IPv4 interfaces. NULL on
/// failure, with *error set (free with tx_rppairing_string_free).
TXRPPairing *tx_rppairing_new(const char *name, char **error);
uint16_t tx_rppairing_port(const TXRPPairing *session);
/// The Bonjour instance name to publish; owned by the session.
const char *tx_rppairing_service_name(const TXRPPairing *session);
size_t tx_rppairing_txt_count(const TXRPPairing *session);
const char *tx_rppairing_txt_key(const TXRPPairing *session, size_t index);
const char *tx_rppairing_txt_value(const TXRPPairing *session, size_t index);
/// Blocks until paired (0), failed (1, *error set) or cancelled (2).
/// On success *out_plist/*out_len hold the RPPairing plist
/// (tx_rppairing_bytes_free) and *out_device_name the device's name
/// (tx_rppairing_string_free).
int32_t tx_rppairing_accept(const TXRPPairing *session,
                            TXRPPairingPinCallback pin_callback, void *pin_context,
                            uint8_t **out_plist, size_t *out_len,
                            char **out_device_name, char **error);
/// Ends a running or future accept with 2. Any thread.
void tx_rppairing_cancel(const TXRPPairing *session);
/// Only after accept has returned (or was never called).
void tx_rppairing_free(TXRPPairing *session);
void tx_rppairing_bytes_free(uint8_t *bytes, size_t len);
void tx_rppairing_string_free(char *string);

#ifdef __cplusplus
}
#endif

#endif
