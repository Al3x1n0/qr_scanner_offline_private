use image::GrayImage;
use std::slice;

#[no_mangle]
pub unsafe extern "C" fn qr_decode(pixels: *const u8, width: u32, height: u32, output: *mut u8, capacity: usize) -> isize {
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
