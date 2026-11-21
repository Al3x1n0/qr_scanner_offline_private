use std::io::Cursor;
use std::panic::catch_unwind;
use std::sync::atomic::{compiler_fence, Ordering};
use std::{ptr, slice, str};

const QR_DECODE_NOT_FOUND: isize = 0;
const QR_DECODE_INVALID_INPUT: isize = -1;
const QR_DECODE_CAPACITY_EXCEEDED: isize = -2;
const QR_DECODE_PANIC: isize = -3;

/// Decodes the first nonempty UTF-8 QR payload in a packed grayscale frame.
///
/// A positive return value is the number of bytes written, without a NUL
/// terminator. The other return values are defined in `qr_decoder.h`.
///
/// # Safety
///
/// For valid sizes and non-null pointers, `pixels` must point to `width * height`
/// readable, initialized bytes in a single allocation and `output` to `capacity`
/// writable bytes in a separate, non-overlapping region. The caller must keep both
/// regions valid for the call, must not mutate `pixels`, and must not access the
/// output region concurrently. A zero capacity still requires a non-null pointer.
#[no_mangle]
pub unsafe extern "C" fn qr_decode(
    pixels: *const u8,
    width: u32,
    height: u32,
    output: *mut u8,
    capacity: usize,
) -> isize {
    // A decoder panic must not unwind across the C ABI and abort the host app.
    catch_unwind(|| decode(pixels, width, height, output, capacity)).unwrap_or(QR_DECODE_PANIC)
}

fn frame_len(width: usize, height: usize) -> Option<usize> {
    width
        .checked_mul(height)
        .filter(|&size| size != 0 && size <= isize::MAX as usize)
}

struct DecodedPayload([u8; rqrr::MAX_PAYLOAD_SIZE]);

impl Drop for DecodedPayload {
    fn drop(&mut self) {
        // Volatile stores keep the wipe observable when this buffer goes out of scope.
        for byte in &mut self.0 {
            unsafe { ptr::write_volatile(byte, 0) };
        }
        compiler_fence(Ordering::SeqCst);
    }
}

unsafe fn decode(
    pixels: *const u8,
    width: u32,
    height: u32,
    output: *mut u8,
    capacity: usize,
) -> isize {
    if pixels.is_null()
        || output.is_null()
        || capacity > isize::MAX as usize
        // rqrr represents pixel coordinates as i32.
        || width > i32::MAX as u32
        || height > i32::MAX as u32
    {
        return QR_DECODE_INVALID_INPUT;
    }
    let (width, height) = (width as usize, height as usize);
    let Some(size) = frame_len(width, height) else {
        return QR_DECODE_INVALID_INPUT;
    };
    let pixels = unsafe { slice::from_raw_parts(pixels, size) };
    let mut image =
        rqrr::PreparedImage::prepare_from_greyscale(width, height, |x, y| pixels[y * width + x]);
    let grids = image.detect_grids();
    if grids.is_empty() {
        return QR_DECODE_NOT_FOUND;
    }

    // Keep failed/partial and non-UTF-8 decodes out of the caller's output.
    let mut payload = DecodedPayload([0; rqrr::MAX_PAYLOAD_SIZE]);
    for grid in grids {
        let mut writer = Cursor::new(payload.0.as_mut_slice());
        if grid.decode_to(&mut writer).is_err() {
            continue;
        }
        let length = writer.position() as usize;
        let bytes = &payload.0[..length];
        if bytes.is_empty() || str::from_utf8(bytes).is_err() {
            continue;
        }
        let Ok(result) = isize::try_from(length) else {
            return QR_DECODE_CAPACITY_EXCEEDED;
        };
        if length > capacity {
            return QR_DECODE_CAPACITY_EXCEEDED;
        }
        unsafe { ptr::copy_nonoverlapping(bytes.as_ptr(), output, length) };
        return result;
    }
    QR_DECODE_NOT_FOUND
}

#[cfg(test)]
mod tests {
    use super::*;

    const UTF8_QR: &str = include_str!("../tests/fixtures/utf8-qr.txt");
    const BINARY_QR: &str = include_str!("../tests/fixtures/binary-qr.txt");
    const EMPTY_QR: &str = include_str!("../tests/fixtures/empty-qr.txt");
    const PAYLOAD: &[u8] = "Café QR".as_bytes();

    fn render(fixture: &str, dark: u8, light: u8) -> (Vec<u8>, u32) {
        let rows: Vec<_> = fixture.lines().collect();
        let module = 4;
        let quiet_zone = 4 * module;
        let side = rows.len() * module + quiet_zone * 2;
        let mut pixels = vec![light; side * side];

        for (y, row) in rows.iter().enumerate() {
            for (x, pixel) in row.bytes().enumerate() {
                if pixel == b'#' {
                    for dy in 0..module {
                        let start = (quiet_zone + y * module + dy) * side + quiet_zone + x * module;
                        pixels[start..start + module].fill(dark);
                    }
                }
            }
        }
        (pixels, side as u32)
    }

    #[test]
    fn decodes_utf8_at_normal_and_reduced_contrast() {
        for (dark, light) in [(0, 255), (100, 145)] {
            let (pixels, side) = render(UTF8_QR, dark, light);
            let mut output = [0x55; PAYLOAD.len() + 1];
            let result = unsafe {
                qr_decode(
                    pixels.as_ptr(),
                    side,
                    side,
                    output.as_mut_ptr(),
                    PAYLOAD.len(),
                )
            };
            assert_eq!(result, PAYLOAD.len() as isize);
            assert_eq!(&output[..PAYLOAD.len()], PAYLOAD);
            assert_eq!(output[PAYLOAD.len()], 0x55);
        }
    }

    #[test]
    fn skips_binary_and_empty_qr_without_writing_output() {
        for fixture in [BINARY_QR, EMPTY_QR] {
            let (pixels, side) = render(fixture, 0, 255);
            let mut output = [0x55; 8];
            assert_eq!(
                unsafe {
                    qr_decode(
                        pixels.as_ptr(),
                        side,
                        side,
                        output.as_mut_ptr(),
                        output.len(),
                    )
                },
                QR_DECODE_NOT_FOUND
            );
            assert_eq!(output, [0x55; 8]);
        }
    }

    #[test]
    fn rejects_insufficient_output_capacity_without_writing() {
        let (pixels, side) = render(UTF8_QR, 0, 255);
        let mut output = [0x55; PAYLOAD.len()];
        for capacity in [0, PAYLOAD.len() - 1] {
            assert_eq!(
                unsafe { qr_decode(pixels.as_ptr(), side, side, output.as_mut_ptr(), capacity) },
                QR_DECODE_CAPACITY_EXCEEDED
            );
            assert_eq!(output, [0x55; PAYLOAD.len()]);
        }
    }

    #[test]
    fn rejects_null_pointers_and_invalid_dimensions() {
        let pixels = [255; 4];
        let mut output = [0x55; 8];
        for (pixels, width, height, output, capacity) in [
            (ptr::null(), 2, 2, output.as_mut_ptr(), output.len()),
            (pixels.as_ptr(), 2, 2, ptr::null_mut(), output.len()),
            (pixels.as_ptr(), 0, 2, output.as_mut_ptr(), output.len()),
            (pixels.as_ptr(), 2, 0, output.as_mut_ptr(), output.len()),
            (
                pixels.as_ptr(),
                2,
                2,
                output.as_mut_ptr(),
                isize::MAX as usize + 1,
            ),
        ] {
            assert_eq!(
                unsafe { qr_decode(pixels, width, height, output, capacity) },
                QR_DECODE_INVALID_INPUT
            );
        }
        assert_eq!(output, [0x55; 8]);
    }

    #[test]
    fn rejects_unrepresentable_frame_lengths() {
        assert_eq!(frame_len(2, 2), Some(4));
        assert_eq!(frame_len(usize::MAX, 2), None);
        assert_eq!(frame_len(isize::MAX as usize + 1, 1), None);
    }

    #[test]
    fn blank_frame_contains_no_qr() {
        let pixels = [255; 100];
        let mut output = [0x55; 8];
        assert_eq!(
            unsafe { qr_decode(pixels.as_ptr(), 10, 10, output.as_mut_ptr(), output.len()) },
            QR_DECODE_NOT_FOUND
        );
        assert_eq!(output, [0x55; 8]);
    }

    #[test]
    fn malformed_geometry_does_not_abort_the_process() {
        // Pairs of (value, u16 little-endian run length), derived from ZXing.
        let encoded = include_bytes!("../tests/fixtures/zxing-qrcode-6-7.rle");
        let mut pixels = Vec::new();
        for run in encoded.chunks_exact(3) {
            let count = u16::from_le_bytes([run[1], run[2]]) as usize;
            pixels.extend(std::iter::repeat_n(run[0], count));
        }
        assert_eq!(pixels.len(), 500 * 500);
        let mut output = [0_u8; 16384];
        let result =
            unsafe { qr_decode(pixels.as_ptr(), 500, 500, output.as_mut_ptr(), output.len()) };
        assert_eq!(result, QR_DECODE_PANIC);

        // A subsequent call still works after the caught panic.
        let blank = [255_u8; 100];
        assert_eq!(
            unsafe { qr_decode(blank.as_ptr(), 10, 10, output.as_mut_ptr(), output.len()) },
            QR_DECODE_NOT_FOUND
        );
    }
}
