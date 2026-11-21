#ifndef QR_DECODER_H
#define QR_DECODER_H

#include <stddef.h>
#include <stdint.h>

#define QR_DECODE_NOT_FOUND 0
#define QR_DECODE_INVALID_INPUT (-1)
#define QR_DECODE_CAPACITY_EXCEEDED (-2)
#define QR_DECODE_PANIC (-3)

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Decode the first nonempty UTF-8 QR payload in a packed grayscale frame.
 * pixels must contain width * height readable bytes, and output must provide
 * capacity writable bytes. Both pointers must remain valid, non-null and
 * non-overlapping for the duration of the call. The dimensions must be positive
 * and at most INT32_MAX. The frame length and capacity must be at most
 * PTRDIFF_MAX. A zero capacity is allowed with a non-null output pointer.
 *
 * Returns the number of bytes written, without a NUL terminator, on success.
 * Returns QR_DECODE_NOT_FOUND for a frame with no supported payload,
 * QR_DECODE_INVALID_INPUT for a null pointer or invalid size,
 * QR_DECODE_CAPACITY_EXCEEDED if the payload does not fit, or QR_DECODE_PANIC
 * if the decoder panics. The output is untouched on these return paths.
 */
intptr_t qr_decode(const uint8_t *pixels, uint32_t width, uint32_t height,
                   uint8_t *output, size_t capacity);

#ifdef __cplusplus
}
#endif

#endif
