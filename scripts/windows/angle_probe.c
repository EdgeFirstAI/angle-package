/*
 * angle_probe.c — runtime probe for the packaged Windows ANGLE DLLs.
 *
 * Built two ways by verify-windows.ps1:
 *   default             LoadLibraryExA(<dir>\libEGL.dll) + GetProcAddress —
 *                       the same dlopen-style path the EdgeFirst HAL uses.
 *   -DPROBE_STATIC_LINK links lib\libEGL.dll.lib (validates the import
 *                       library and the shipped headers).
 *
 * Brings up an ANGLE Direct3D 11 display (hardware, or WARP with --warp),
 * an OpenGL ES 3 context on a 16x16 pbuffer, and prints EGL_VERSION,
 * GL_VENDOR, GL_RENDERER and GL_VERSION.
 *
 * Usage: angle_probe.exe <dir-containing-libEGL.dll> [--warp]
 * Exit codes: 0 ok; 1 load; 2 export missing; 3 no eglGetPlatformDisplayEXT;
 *             4 eglInitialize; 5 no config; 6 context/surface.
 */
#include <windows.h>
#include <stdio.h>
#include <string.h>

#include <EGL/egl.h>
#include <EGL/eglext.h>   /* ANGLE's eglext.h pulls in EGL/eglext_angle.h */
#include <GLES3/gl3.h>

#ifndef PROBE_STATIC_LINK
#define EGLFN(ret, name, args) \
    typedef ret(EGLAPIENTRY *PFN_##name) args; \
    static PFN_##name p_##name;
EGLFN(EGLBoolean, eglInitialize, (EGLDisplay, EGLint *, EGLint *))
EGLFN(EGLBoolean, eglTerminate, (EGLDisplay))
EGLFN(EGLBoolean, eglBindAPI, (EGLenum))
EGLFN(EGLBoolean, eglChooseConfig, (EGLDisplay, const EGLint *, EGLConfig *, EGLint, EGLint *))
EGLFN(EGLSurface, eglCreatePbufferSurface, (EGLDisplay, EGLConfig, const EGLint *))
EGLFN(EGLBoolean, eglDestroySurface, (EGLDisplay, EGLSurface))
EGLFN(EGLContext, eglCreateContext, (EGLDisplay, EGLConfig, EGLContext, const EGLint *))
EGLFN(EGLBoolean, eglDestroyContext, (EGLDisplay, EGLContext))
EGLFN(EGLBoolean, eglMakeCurrent, (EGLDisplay, EGLSurface, EGLSurface, EGLContext))
EGLFN(const char *, eglQueryString, (EGLDisplay, EGLint))
EGLFN(EGLint, eglGetError, (void))
EGLFN(__eglMustCastToProperFunctionPointerType, eglGetProcAddress, (const char *))
#define LOADFN(mod, name)                                            \
    p_##name = (PFN_##name)GetProcAddress(mod, #name);               \
    if (!p_##name) {                                                 \
        fprintf(stderr, "libEGL.dll is missing export %s\n", #name); \
        return 2;                                                    \
    }
#define CALL(name) p_##name
#else
#define CALL(name) name
#endif

int main(int argc, char **argv)
{
    const char *dir = argc > 1 ? argv[1] : ".";
    int warp = 0;
    for (int i = 2; i < argc; ++i)
        if (!strcmp(argv[i], "--warp"))
            warp = 1;

#ifndef PROBE_STATIC_LINK
    char path[MAX_PATH];
    snprintf(path, sizeof path, "%s\\libEGL.dll", dir);
    /* LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR: libEGL.dll resolves its sibling
     * libGLESv2.dll from its own directory; DEFAULT_DIRS covers System32
     * (d3d11.dll, dxgi.dll, d3dcompiler_47.dll). */
    HMODULE egl = LoadLibraryExA(path, NULL,
                                 LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
    if (!egl) {
        fprintf(stderr, "LoadLibraryEx(%s) failed: error %lu\n", path, GetLastError());
        return 1;
    }
    LOADFN(egl, eglGetProcAddress)
    LOADFN(egl, eglInitialize)
    LOADFN(egl, eglTerminate)
    LOADFN(egl, eglBindAPI)
    LOADFN(egl, eglChooseConfig)
    LOADFN(egl, eglCreatePbufferSurface)
    LOADFN(egl, eglDestroySurface)
    LOADFN(egl, eglCreateContext)
    LOADFN(egl, eglDestroyContext)
    LOADFN(egl, eglMakeCurrent)
    LOADFN(egl, eglQueryString)
    LOADFN(egl, eglGetError)
#else
    (void)dir;
#endif

    PFNEGLGETPLATFORMDISPLAYEXTPROC getPlatformDisplay =
        (PFNEGLGETPLATFORMDISPLAYEXTPROC)CALL(eglGetProcAddress)("eglGetPlatformDisplayEXT");
    if (!getPlatformDisplay) {
        fprintf(stderr, "eglGetPlatformDisplayEXT not available\n");
        return 3;
    }

    const EGLint dattr[] = {
        EGL_PLATFORM_ANGLE_TYPE_ANGLE, EGL_PLATFORM_ANGLE_TYPE_D3D11_ANGLE,
        EGL_PLATFORM_ANGLE_DEVICE_TYPE_ANGLE,
        warp ? EGL_PLATFORM_ANGLE_DEVICE_TYPE_D3D_WARP_ANGLE
             : EGL_PLATFORM_ANGLE_DEVICE_TYPE_HARDWARE_ANGLE,
        EGL_NONE,
    };
    EGLDisplay dpy = getPlatformDisplay(EGL_PLATFORM_ANGLE_ANGLE, (void *)EGL_DEFAULT_DISPLAY, dattr);
    EGLint maj = 0, min = 0;
    if (dpy == EGL_NO_DISPLAY || !CALL(eglInitialize)(dpy, &maj, &min)) {
        fprintf(stderr, "eglInitialize failed: EGL error 0x%x\n", CALL(eglGetError)());
        return 4;
    }
    CALL(eglBindAPI)(EGL_OPENGL_ES_API);

    const EGLint cattr[] = {
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
        EGL_SURFACE_TYPE,    EGL_PBUFFER_BIT,
        EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
        EGL_NONE,
    };
    EGLConfig cfg;
    EGLint n = 0;
    if (!CALL(eglChooseConfig)(dpy, cattr, &cfg, 1, &n) || n < 1) {
        fprintf(stderr, "no OpenGL ES 3 pbuffer config (EGL error 0x%x)\n", CALL(eglGetError)());
        return 5;
    }
    const EGLint pattr[] = {EGL_WIDTH, 16, EGL_HEIGHT, 16, EGL_NONE};
    EGLSurface pb = CALL(eglCreatePbufferSurface)(dpy, cfg, pattr);
    const EGLint xattr[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};
    EGLContext ctx = CALL(eglCreateContext)(dpy, cfg, EGL_NO_CONTEXT, xattr);
    if (pb == EGL_NO_SURFACE || ctx == EGL_NO_CONTEXT || !CALL(eglMakeCurrent)(dpy, pb, pb, ctx)) {
        fprintf(stderr, "context bring-up failed: EGL error 0x%x\n", CALL(eglGetError)());
        return 6;
    }

    typedef const GLubyte *(GL_APIENTRY * PFN_glGetString)(GLenum);
    PFN_glGetString gs = (PFN_glGetString)CALL(eglGetProcAddress)("glGetString");
    if (!gs) {
        fprintf(stderr, "eglGetProcAddress(glGetString) returned NULL\n");
        return 6;
    }
    printf("EGL_VERSION=%s\n", CALL(eglQueryString)(dpy, EGL_VERSION));
    printf("EGL_VENDOR=%s\n", CALL(eglQueryString)(dpy, EGL_VENDOR));
    printf("GL_VENDOR=%s\n", (const char *)gs(GL_VENDOR));
    printf("GL_RENDERER=%s\n", (const char *)gs(GL_RENDERER));
    printf("GL_VERSION=%s\n", (const char *)gs(GL_VERSION));

    CALL(eglMakeCurrent)(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    CALL(eglDestroyContext)(dpy, ctx);
    CALL(eglDestroySurface)(dpy, pb);
    CALL(eglTerminate)(dpy);
    return 0;
}
