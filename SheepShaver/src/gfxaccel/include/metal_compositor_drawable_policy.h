/*
 *  metal_compositor_drawable_policy.h - Metal compositor drawable size helpers.
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 */

#ifndef METAL_COMPOSITOR_DRAWABLE_POLICY_H
#define METAL_COMPOSITOR_DRAWABLE_POLICY_H

struct MetalCompositorDrawableSize {
	int width;
	int height;
};

/*
 * Drawable-size policy: the CAMetalLayer drawable is presented 1:1 into
 * the layer backing store (no auto-upscale), so drawableSize must match
 * the view's backing size (view points x contentsScale). A
 * framebuffer-sized drawable in a larger view presents as a small
 * bottom-left quad with the rest of the window blank (the fullscreen
 * 1/4-size symptom). Prefer the live view size; fall back to the
 * framebuffer size when no view size is known yet (== windowed, where
 * the window is resized to the guest so both agree).
 */
static inline MetalCompositorDrawableSize MetalCompositorTargetDrawableSize(
	int framebuffer_width,
	int framebuffer_height,
	int view_width,
	int view_height)
{
	MetalCompositorDrawableSize size;
	if (view_width > 0 && view_height > 0) {
		size.width = view_width;
		size.height = view_height;
	} else {
		size.width = framebuffer_width;
		size.height = framebuffer_height;
	}
	return size;
}

#endif /* METAL_COMPOSITOR_DRAWABLE_POLICY_H */
