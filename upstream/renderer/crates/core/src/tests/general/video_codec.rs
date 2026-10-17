use crate::media::video::{VideoFrame, VideoFrameUploadFormat};

#[test]
pub fn case_video_frame_exposes_dimensions() {
    let frame = VideoFrame::software_for_testing(64, 32);
    assert_eq!(frame.width(), 64);
    assert_eq!(frame.height(), 32);
}

#[test]
pub fn case_video_frame_exposes_software_upload() {
    let frame = VideoFrame::software_for_testing(64, 32);
    assert_eq!(frame.upload_format(), Some(VideoFrameUploadFormat::Bgra8));
    assert_eq!(frame.bytes_per_row(), Some(64 * 4));
    assert_eq!(frame.as_bytes().map(<[u8]>::len), Some(64 * 32 * 4));

    assert_eq!(frame.io_surface_id(), None);
}
