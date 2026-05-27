#pragma once

#ifdef __cplusplus
extern "C" {
#endif

#ifdef __GNUC__
#define LW_API __attribute__((visibility("default")))
#else
#define LW_API
#endif

LW_API void* lw_renderer_create();
LW_API void* lw_renderer_create_with_assets(const char* assetsPath);
LW_API void lw_renderer_load(void* renderer, const char* wallpaperPath, int width, int height);
LW_API void lw_renderer_set_assets_path(void* renderer, const char* assetsPath);
LW_API void lw_renderer_tick(void* renderer);
LW_API void lw_renderer_resize(void* renderer, int width, int height);
LW_API void lw_renderer_set_mouse(void* renderer, double x, double y, int clicked);
LW_API void lw_renderer_set_property(void* renderer, const char* name, const char* value);
LW_API void lw_renderer_show_window(void* renderer);
LW_API void lw_renderer_hide_window(void* renderer);
LW_API void lw_renderer_set_desktop_window(void* renderer, int desktop);
LW_API int lw_renderer_close_requested(void* renderer);
LW_API unsigned int lw_renderer_get_texture(void* renderer);
LW_API int lw_renderer_get_width(void* renderer);
LW_API int lw_renderer_get_height(void* renderer);
LW_API int lw_renderer_capture_frame(void* renderer, unsigned char** outBuffer, int* outWidth, int* outHeight);
LW_API void lw_renderer_free_buffer(void* buffer);
LW_API void lw_renderer_set_screen(void* renderer, int screenIndex);
LW_API void lw_renderer_destroy(void* renderer);

/// 获取所有动态文本对象的当前状态 JSON 字符串。
/// 返回值需调用 lw_renderer_free_buffer() 释放。
/// 若渲染器未实现此功能，返回 NULL。
LW_API char* lw_renderer_get_dynamic_texts_json(void* renderer);

// --- Baking API ---
typedef void (*lw_bake_progress_cb)(float progress, void* userData);

LW_API int lw_renderer_start_bake(void* renderer, const char* outputPath,
                                   int duration, int fps, int bitRate,
                                   int width, int height,
                                   lw_bake_progress_cb callback, void* userData);
LW_API void lw_renderer_cancel_bake(void* renderer);
LW_API int lw_renderer_is_baking(void* renderer);
LW_API float lw_renderer_get_bake_progress(void* renderer);

#ifdef __cplusplus
}
#endif
