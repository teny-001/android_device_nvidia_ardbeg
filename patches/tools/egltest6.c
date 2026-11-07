/*
 * egltest6.c —— 验证 NVIDIA tegra EGL 驱动对「重复 eglGetDisplay」的行为
 *
 * 背景：
 *   frameworks/native/opengl/libs/EGL/egl_display.cpp 的
 *   egl_display_t::getDisplay() 原本有 disp.dpy == EGL_NO_DISPLAY 的进程级缓存，
 *   我们把它改成每次都真调驱动。改完之后 SurfaceFlinger 每 16 秒 SIGSEGV 一次
 *   （崩在 RefBase::decStrong，说明对象被踩坏）。
 *
 *   怀疑：驱动的 eglGetDisplay 第二次调用返回 EGL_NO_DISPLAY，
 *   于是 egl_display.cpp 走 loader.close(cnx->dso) 把 libEGL_tegra.so
 *   dlclose 掉，进程里所有指向驱动的函数指针/数据全部失效。
 *
 * 本程序绕过 libEGL.so 的 loader，直接 dlopen 驱动来验证：
 *   mode 1 : 同一线程连续 3 次 eglGetDisplay，打印每次的返回值
 *   mode 2 : eglGetDisplay + eglInitialize 之后再 eglGetDisplay，看是否变 NO_DISPLAY
 *   mode 3 : 检查 libEGL_tegra_impl.so 在 /proc/self/maps 里是否还在
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dlfcn.h>

typedef void *EGLDisplay_t;
typedef void *EGLConfig_t;
typedef int EGLint_t;
typedef unsigned int EGLBoolean_t;

#define EGL_DEFAULT_DISPLAY ((void *)0)
#define EGL_NO_DISPLAY ((void *)0)
#define EGL_TRUE 1
#define EGL_FALSE 0

typedef EGLDisplay_t (*fn_getdisplay)(void *);
typedef EGLBoolean_t (*fn_initialize)(EGLDisplay_t, EGLint_t *, EGLint_t *);
typedef EGLint_t (*fn_geterror)(void);
typedef EGLBoolean_t (*fn_chooseconfig)(EGLDisplay_t, const EGLint_t *, EGLConfig_t *, EGLint_t, EGLint_t *);

static fn_getdisplay p_getdisplay;
static fn_initialize p_initialize;
static fn_geterror p_geterror;
static fn_chooseconfig p_chooseconfig;

static void show_maps(const char *needle) {
    FILE *f = fopen("/proc/self/maps", "r");
    char line[512];
    int n = 0;
    if (!f) return;
    while (fgets(line, sizeof(line), f)) {
        if (strstr(line, needle)) {
            if (n == 0) printf("    [maps] %s 仍然映射:\n", needle);
            /* 只打印第一段和最后一段，避免刷屏 */
            if (n < 1 || 1) printf("      %s", line);
            n++;
            if (n > 6) { printf("      ... (共 %d 段)\n", n); break; }
        }
    }
    fclose(f);
    if (n == 0) printf("    [maps] !! %s 已经不在映射表里（被 dlclose 了）\n", needle);
}

int main(int argc, char **argv) {
    int mode = (argc > 1) ? atoi(argv[1]) : 1;

    void *h = dlopen("/system/lib/egl/libEGL_tegra.so", RTLD_NOW | RTLD_LOCAL);
    if (!h) { printf("dlopen libEGL_tegra.so 失败: %s\n", dlerror()); return 1; }
    p_getdisplay   = (fn_getdisplay)  dlsym(h, "eglGetDisplay");
    p_initialize   = (fn_initialize)  dlsym(h, "eglInitialize");
    p_geterror     = (fn_geterror)    dlsym(h, "eglGetError");
    p_chooseconfig = (fn_chooseconfig)dlsym(h, "eglChooseConfig");
    if (!p_getdisplay || !p_initialize) { printf("dlsym 失败\n"); return 1; }

    printf("=== mode %d ===\n", mode);

    if (mode == 1) {
        for (int i = 1; i <= 3; i++) {
            EGLDisplay_t d = p_getdisplay(EGL_DEFAULT_DISPLAY);
            printf("  第 %d 次 eglGetDisplay -> %p   err=0x%x\n", i, d,
                   p_geterror ? p_geterror() : 0);
        }
    } else if (mode == 2) {
        EGLDisplay_t d1 = p_getdisplay(EGL_DEFAULT_DISPLAY);
        printf("  1st eglGetDisplay -> %p\n", d1);
        EGLint_t mj = -1, mn = -1;
        EGLBoolean_t ok = p_initialize(d1, &mj, &mn);
        printf("  eglInitialize -> %d (%d.%d) err=0x%x\n", ok, mj, mn,
               p_geterror ? p_geterror() : 0);
        show_maps("libEGL_tegra_impl");
        for (int i = 2; i <= 4; i++) {
            EGLDisplay_t d = p_getdisplay(EGL_DEFAULT_DISPLAY);
            printf("  第 %d 次 eglGetDisplay -> %p   err=0x%x\n", i, d,
                   p_geterror ? p_geterror() : 0);
        }
        show_maps("libEGL_tegra_impl");
    } else if (mode == 3) {
        EGLDisplay_t d = p_getdisplay(EGL_DEFAULT_DISPLAY);
        EGLint_t mj = -1, mn = -1;
        p_initialize(d, &mj, &mn);
        EGLint_t attrs[] = {
            0x3040 /*EGL_SURFACE_TYPE*/, 0x0004 /*EGL_WINDOW_BIT*/,
            0x3040 + 0, 0,
            0x3033 /*EGL_RENDERABLE_TYPE*/, 0x0004 /*EGL_OPENGL_ES2_BIT*/,
            0x3038 /*EGL_NONE*/
        };
        attrs[2] = 0x3040; attrs[3] = 0x0004;
        EGLConfig_t cfg = 0; EGLint_t n = 0;
        EGLBoolean_t ok = p_chooseconfig ? p_chooseconfig(d, attrs, &cfg, 1, &n) : 0;
        printf("  eglChooseConfig -> %d n=%d cfg=%p err=0x%x\n", ok, n, cfg,
               p_geterror ? p_geterror() : 0);
    }
    return 0;
}
