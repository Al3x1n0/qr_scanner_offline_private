use image::GrayImage;
use std::panic::catch_unwind;
use std::slice;

#[no_mangle]
pub unsafe extern "C" fn qr_decode(pixels: *const u8, width: u32, height: u32, output: *mut u8, capacity: usize) -> isize {
    // A decoder panic must not unwind across the C ABI and abort the host app.
    catch_unwind(|| decode(pixels, width, height, output, capacity)).unwrap_or(-3)
}

unsafe fn decode(pixels: *const u8, width: u32, height: u32, output: *mut u8, capacity: usize) -> isize {
    if pixels.is_null() || output.is_null() || width == 0 || height == 0 { return -1; }
    let Some(size) = (width as usize).checked_mul(height as usize) else { return -1 };
    let pixels = slice::from_raw_parts(pixels, size);
    let Some(image) = GrayImage::from_raw(width, height, pixels.to_vec()) else { return -1 };
    let mut image = rqrr::PreparedImage::prepare(image);
    for grid in image.detect_grids() {
        if let Ok((_, text)) = grid.decode() {
            let bytes = text.as_bytes();
            if bytes.len() > capacity { return -2; }
            std::ptr::copy_nonoverlapping(bytes.as_ptr(), output, bytes.len());
            return bytes.len() as isize;
        }
    }
    0
}

#[cfg(test)]
mod tests {
    use super::qr_decode;

    #[test]
    fn malformed_geometry_does_not_abort_the_process() {
        // Pairs of (value, u16 little-endian run length), derived from ZXing.
        let encoded = include_bytes!("../tests/fixtures/zxing-qrcode-6-7.rle");
        let mut pixels = Vec::new();
        for run in encoded.chunks_exact(3) {
            pixels.extend(std::iter::repeat(run[0]).take(u16::from_le_bytes([run[1], run[2]]) as usize));
        }
        assert_eq!(pixels.len(), 500 * 500);
        let mut output = [0_u8; 16384];
        let result = unsafe { qr_decode(pixels.as_ptr(), 500, 500, output.as_mut_ptr(), output.len()) };
        assert_eq!(result, -3);

        // A subsequent call still works after the caught panic.
        let blank = [255_u8; 100];
        assert_eq!(unsafe { qr_decode(blank.as_ptr(), 10, 10, output.as_mut_ptr(), output.len()) }, 0);
    }
}
