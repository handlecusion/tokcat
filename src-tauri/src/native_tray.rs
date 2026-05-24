// CALayer-backed tray icon path.
//
// Background: setting `NSStatusItem.button.image` per animation tick runs the
// full AppKit redraw chain (NSStatusBarButtonCell drawWithFrame →
// NSImage drawInRect → CoreGraphics), which Instruments measured at ~5% CPU
// for a 12fps loop even after we cached NSImages and patched out the PNG
// round-trip in the vendored tray-icon crate.
//
// On macOS, RunCat-class menubar apps avoid that cost by handing the tray a
// CALayer-backed view and updating `layer.contents` directly each tick. The
// WindowServer compositor blits the new frame on the GPU and our process does
// effectively zero per-swap work.
//
// This module:
//   1. Locates Tauri's NSStatusItem at startup (KVC `statusItems` on the
//      shared NSStatusBar — see find_our_status_item).
//   2. Pre-decodes every animation frame from a build-time pre-scaled
//      premultiplied-RGBA buffer into a leaked CGImage.
//   3. Replaces the button's image with a transparent (None) image, adds a
//      single CALayer sublayer to the button's layer, and on every set_frame
//      call swaps `layer.contents` to the next cached CGImage.
//   4. Flips a TAKEOVER flag inside the vendored tray-icon crate so its
//      set_icon paths no-op after our layer is in place.

#![cfg(target_os = "macos")]

use std::ffi::c_void;
use std::ptr::NonNull;
use std::sync::OnceLock;

use objc2::msg_send;
use objc2::rc::Retained;
use objc2::runtime::AnyObject;
use objc2::AllocAnyThread;
use objc2_app_kit::{NSCellImagePosition, NSImage, NSStatusBar, NSStatusItem};
use objc2_core_foundation::{CFRetained, CGFloat, CGPoint, CGRect, CGSize};
use objc2_core_graphics::{
    CGBitmapInfo, CGColorRenderingIntent, CGColorSpace, CGDataProvider, CGImage, CGImageAlphaInfo,
};
use objc2_foundation::{MainThreadMarker, NSString};
use objc2_quartz_core::{kCAGravityCenter, CALayer, CATransaction};
use tauri::{AppHandle, Runtime};

mod frames {
    #![allow(dead_code)]
    include!(concat!(env!("OUT_DIR"), "/frames.rs"));
}
use frames::{anim_cat2_rgba, anim_parrot_rgba, ANIM_CAT2_LEN, ANIM_PARROT_LEN, TRAY_FRAME_PX};

struct NativeState {
    // Leaked Retained<CALayer> — only ever dereferenced on the main thread.
    anim_layer_ptr: usize,
    // Leaked CGImage retains, one per frame. `*const CGImage` is CF-bridged
    // so we hand it to `layer.contents` as an `AnyObject`.
    frames_cat: Vec<usize>,
    frames_parrot: Vec<usize>,
    // Skip the layer.contents write when the loop emits the same (style, idx)
    // twice in a row (level transitions can do this).
    last_set: parking_lot::Mutex<(u32, usize)>,
    // Base layer geometry. Kept here so set_y_offset can rebuild the
    // frame without re-querying the button bounds on every tick.
    icon_pt: CGFloat,
    base_x: CGFloat,
    base_y: CGFloat,
}

unsafe impl Send for NativeState {}
unsafe impl Sync for NativeState {}

static STATE: OnceLock<NativeState> = OnceLock::new();

/// Locate the tray status item and install a CALayer sublayer on its button.
/// MUST run on the main thread, after Tauri's tray has been created.
pub fn init() -> Result<(), &'static str> {
    if STATE.get().is_some() {
        return Ok(());
    }
    let mtm = MainThreadMarker::new().ok_or("init must run on main thread")?;

    let status_item_ptr = unsafe { find_our_status_item() }
        .ok_or("could not locate NSStatusItem via NSStatusBar KVC")?;
    let status_item = unsafe { &*(status_item_ptr as *const NSStatusItem) };

    let button = unsafe { status_item.button(mtm) }.ok_or("status item has no button")?;

    // Reserve the image rect with a transparent 22x22 NSImage. We can't pass
    // None here: with no image, the button cell collapses the image rect and
    // centers the title — our CALayer would then render over the title text.
    // With an image present (even empty), the cell lays out image-left + title-
    // right and our sublayer renders within the image rect at the left edge.
    // The cell still calls drawInRect for this empty image when the title or
    // hover state changes, but that's near-zero cost and infrequent.
    // Matches the icon_height the vendored tray-icon crate uses for its
    // NSImage (vendor/tray-icon/src/platform_impl/macos/mod.rs:307). Anything
    // larger leaves visible whitespace between the cat and the title.
    let icon_pt: CGFloat = 18.0;
    let placeholder = unsafe {
        let alloc = NSImage::alloc();
        let img = NSImage::initWithSize(alloc, CGSize::new(icon_pt, icon_pt));
        img.setTemplate(true);
        img
    };
    unsafe {
        button.setImage(Some(&placeholder));
        button.setImagePosition(NSCellImagePosition::ImageLeft);
        // Collapse the default image-title padding so the cat sits right next
        // to the dollar amount instead of leaving a gap.
        button.setImageHugsTitle(true);
    }

    // The button is layer-backed on modern macOS; only request a layer if it
    // doesn't already have one (re-setting wantsLayer can swap the layer
    // instance and orphan our sublayer).
    let button_layer = match unsafe { button.layer() } {
        Some(l) => l,
        None => {
            unsafe { button.setWantsLayer(true) };
            unsafe { button.layer() }.ok_or("button.layer() still nil after setWantsLayer")?
        }
    };

    // Pin to the left edge of the button at the image-rect size. The
    // button's bounds expand horizontally with the title; we don't want
    // the sublayer to stretch with it.
    // Shift horizontally so the cat sits against the title text instead
    // of leaving AppKit's default image↔title padding visible.
    const ICON_X_OFFSET: CGFloat = 8.0;
    let bh = button.bounds().size.height;
    let base_y = ((bh - icon_pt) / 2.0).max(0.0);

    let anim_layer = unsafe { CALayer::new() };
    without_implicit_layer_actions(|| unsafe {
        anim_layer.setFrame(CGRect::new(
            CGPoint::new(ICON_X_OFFSET, base_y),
            CGSize::new(icon_pt, icon_pt),
        ));
        anim_layer.setContentsScale(2.0 as CGFloat);
        anim_layer.setContentsGravity(kCAGravityCenter);
        button_layer.insertSublayer_atIndex(&anim_layer, 0);
    });

    let frames_cat = pre_decode(ANIM_CAT2_LEN, anim_cat2_rgba);
    let frames_parrot = pre_decode(ANIM_PARROT_LEN, anim_parrot_rgba);

    let _ = STATE.set(NativeState {
        anim_layer_ptr: Retained::into_raw(anim_layer) as usize,
        frames_cat,
        frames_parrot,
        last_set: parking_lot::Mutex::new((u32::MAX, usize::MAX)),
        icon_pt,
        base_x: ICON_X_OFFSET,
        base_y,
    });

    // Tell the vendored tray-icon crate to stop calling setImage on our
    // button — set_icon / set_icon_as_template / set_icon_with_as_template
    // become no-ops past this point.
    tray_icon::set_takeover(true);

    Ok(())
}

fn pre_decode(count: usize, source: fn(usize) -> &'static [u8]) -> Vec<usize> {
    let mut out = Vec::with_capacity(count);
    let px = TRAY_FRAME_PX as usize;
    for i in 0..count {
        let bytes = source(i);
        assert_eq!(
            bytes.len(),
            px * px * 4,
            "frame {} rgba length mismatch",
            i
        );
        let cg = unsafe { cgimage_from_premul_rgba(bytes, px, px) };
        // Leak the CFRetained pointer; we keep these for the app's lifetime.
        let raw = CFRetained::into_raw(cg).as_ptr() as usize;
        out.push(raw);
    }
    out
}

unsafe fn cgimage_from_premul_rgba(
    bytes: &'static [u8],
    width: usize,
    height: usize,
) -> CFRetained<CGImage> {
    let color_space =
        CGColorSpace::new_device_rgb().expect("CGColorSpaceCreateDeviceRGB returned null");

    // The bytes live in static memory (include_bytes!), so no release callback
    // is needed — we hand CG a pointer and tell it the lifetime is forever.
    unsafe extern "C-unwind" fn noop_release(_info: *mut c_void, _data: NonNull<c_void>, _size: usize) {
    }
    let provider = CGDataProvider::with_data(
        std::ptr::null_mut(),
        bytes.as_ptr() as *const c_void,
        bytes.len(),
        Some(noop_release),
    )
    .expect("CGDataProviderCreateWithData returned null");

    let bitmap_info = CGBitmapInfo(CGImageAlphaInfo::PremultipliedLast.0);

    CGImage::new(
        width,
        height,
        8,
        32,
        width * 4,
        Some(&color_space),
        bitmap_info,
        Some(&provider),
        std::ptr::null(),
        false,
        CGColorRenderingIntent::RenderingIntentDefault,
    )
    .expect("CGImageCreate returned null")
}

unsafe fn find_our_status_item() -> Option<usize> {
    let status_bar = NSStatusBar::systemStatusBar();
    // NSStatusBar responds to the `statusItems` KVC key; the underlying type
    // is NSPointerArray (not NSArray), so we have to use pointerAtIndex: not
    // objectAtIndex: — sending the wrong selector crashes.
    let key = NSString::from_str("statusItems");
    let array: *mut AnyObject = msg_send![&*status_bar, valueForKey: &*key];
    if array.is_null() {
        return None;
    }
    let count: usize = msg_send![array, count];
    if count == 0 {
        return None;
    }
    let ptr: *mut c_void = msg_send![array, pointerAtIndex: 0_usize];
    if ptr.is_null() {
        return None;
    }
    // The pointer-array storage is weak; retain so our cached pointer stays
    // valid even if Tauri ever drops its strong reference.
    let _: *mut AnyObject = msg_send![ptr as *mut AnyObject, retain];
    Some(ptr as usize)
}

/// Shift the animation layer's origin.y by `dy` (positive = up). Used by
/// the refresh bounce: caller drives a sin wave and we just push the
/// layer up/down each tick.
pub fn set_y_offset<R: Runtime>(app: &AppHandle<R>, dy: f64) {
    let Some(state) = STATE.get() else {
        return;
    };
    let _ = app.run_on_main_thread(move || unsafe {
        let layer = &*(state.anim_layer_ptr as *const CALayer);
        without_implicit_layer_actions(|| {
            layer.setFrame(CGRect::new(
                CGPoint::new(state.base_x, state.base_y + dy as CGFloat),
                CGSize::new(state.icon_pt, state.icon_pt),
            ));
        });
    });
}

pub fn set_frame<R: Runtime>(app: &AppHandle<R>, style: u32, idx: usize) {
    let Some(state) = STATE.get() else {
        return;
    };
    let _ = app.run_on_main_thread(move || {
        apply_frame(state, style, idx);
    });
}

fn apply_frame(state: &'static NativeState, style: u32, idx: usize) {
    let frames = match style {
        1 => &state.frames_parrot,
        _ => &state.frames_cat,
    };
    if frames.is_empty() {
        return;
    }
    let idx = idx % frames.len();
    {
        let mut last = state.last_set.lock();
        if *last == (style, idx) {
            return;
        }
        *last = (style, idx);
    }
    unsafe {
        let layer = &*(state.anim_layer_ptr as *const CALayer);
        let cgimg_ptr = frames[idx] as *const AnyObject;
        without_implicit_layer_actions(|| {
            layer.setContents(Some(&*cgimg_ptr));
        });
    }
}

fn without_implicit_layer_actions(f: impl FnOnce()) {
    CATransaction::begin();
    CATransaction::setDisableActions(true);
    f();
    CATransaction::commit();
}
