/*
 * Thin wrappers around OpenVINO's variadic compile_model / set_property APIs.
 *
 * OpenVINO's C entry points accept property pairs through `...`. On Windows
 * x64 the OpenVINO DLL is built with MSVC, while Nim projects are commonly
 * built with MinGW/TDM-GCC. Variadic calls crossing those ABIs are fragile.
 *
 * We resolve the original symbols with the platform loader and expose stable,
 * non-variadic wrappers that Nim can call safely.
 *
 * ---------------------------------------------------------------------------
 * Why the property count is switched over instead of forwarded dynamically
 * ---------------------------------------------------------------------------
 *
 * Standard C provides no way to construct a variadic call whose argument count
 * is only known at run time. There is no portable `apply(fn, argv)`.
 * The usual workaround, and the one used here, is to enumerate the supported
 * counts explicitly. Eight pairs is well beyond what any current call site
 * needs; exceeding it returns INVALID_C_PARAM rather than silently dropping
 * properties, because a silently ignored property (say CACHE_DIR) would look
 * like a puzzling performance problem rather than an error.
 */

#include <stddef.h>

#ifdef _WIN32
#define NV_ABI __attribute__((ms_abi))
#define NV_EXPORT __declspec(dllexport)
#define NV_CALL __cdecl
#else
#include <dlfcn.h>
#define NV_ABI
#define NV_EXPORT
#define NV_CALL
#endif

typedef struct ov_core ov_core_t;
typedef struct ov_model ov_model_t;
typedef struct ov_compiled_model ov_compiled_model_t;
typedef int ov_status_e;

/* Mirrors ov_status_e; only the values this file returns directly. */
#define NV_OK               0
#define NV_GENERAL_ERROR   -1
#define NV_INVALID_C_PARAM -14

/* Maximum number of key/value pairs the switch below can forward. */
#define NV_MAX_PROPERTY_PAIRS 8

typedef NV_ABI ov_status_e (*nv_compile_model_fn)(
    const ov_core_t*, const ov_model_t*, const char*, size_t, ...);
typedef NV_ABI ov_status_e (*nv_compiled_set_property_fn)(
    ov_compiled_model_t*, ...);
typedef NV_ABI ov_status_e (*nv_core_set_property_fn)(
    const ov_core_t*, const char*, ...);

static nv_compile_model_fn g_compile_model = NULL;
static nv_compiled_set_property_fn g_compiled_set_property = NULL;
static nv_core_set_property_fn g_core_set_property = NULL;
static int g_resolved = 0;

#ifdef _WIN32
typedef struct HINSTANCE__* HINSTANCE;
__declspec(dllimport) HINSTANCE __stdcall LoadLibraryA(const char*);
__declspec(dllimport) void* __stdcall GetProcAddress(HINSTANCE, const char*);
#endif

static int nv_resolve_symbols(void)
{
    if (g_resolved) return 1;
#ifdef _WIN32
    HINSTANCE mod = LoadLibraryA("openvino_c.dll");
#define NV_SYMBOL(handle, name) GetProcAddress(handle, name)
#else
    void* mod = dlopen("libopenvino_c.so", RTLD_LAZY | RTLD_LOCAL);
#define NV_SYMBOL(handle, name) dlsym(handle, name)
#endif
    if (!mod) return 0;
    g_compile_model = (nv_compile_model_fn)NV_SYMBOL(mod, "ov_core_compile_model");
    g_compiled_set_property =
        (nv_compiled_set_property_fn)NV_SYMBOL(mod, "ov_compiled_model_set_property");
    g_core_set_property =
        (nv_core_set_property_fn)NV_SYMBOL(mod, "ov_core_set_property");
    /* Only the two symbols the legacy entry points need are required for
     * g_resolved; ov_core_set_property is checked per call so that an older
     * runtime missing it degrades to an error instead of failing everything. */
    g_resolved = (g_compile_model != NULL && g_compiled_set_property != NULL);
    return g_resolved;
}

NV_EXPORT int NV_CALL nv_max_property_pairs(void)
{
    return NV_MAX_PROPERTY_PAIRS;
}

/* ------------------------------------------------------------------------- */
/* Legacy entry points (kept so existing callers keep working)               */
/* ------------------------------------------------------------------------- */

NV_EXPORT ov_status_e NV_CALL nv_compile_model_with_perf_count(
    const ov_core_t* core,
    const ov_model_t* model,
    const char* device_name,
    ov_compiled_model_t** compiled_model)
{
    if (!nv_resolve_symbols() || g_compile_model == NULL) return NV_GENERAL_ERROR;
    return g_compile_model(core, model, device_name, 2, compiled_model, "PERF_COUNT", "YES");
}

NV_EXPORT ov_status_e NV_CALL nv_enable_perf_count(
    ov_compiled_model_t* compiled_model)
{
    if (!nv_resolve_symbols() || g_compiled_set_property == NULL) return NV_GENERAL_ERROR;
    return g_compiled_set_property(compiled_model, "PERF_COUNT", "YES");
}

/* ------------------------------------------------------------------------- */
/* Generalized entry points                                                  */
/* ------------------------------------------------------------------------- */

/*
 * Note on property_args_size: the OpenVINO documentation states it is the
 * number of *arguments*, and each property contributes two (key and value).
 * So n pairs must be passed as 2*n. The legacy wrapper above passes 2 for its
 * single pair, which confirms the convention.
 */
NV_EXPORT ov_status_e NV_CALL nv_compile_model_with_properties(
    const ov_core_t* core,
    const ov_model_t* model,
    const char* device_name,
    const char** keys,
    const char** values,
    size_t pair_count,
    ov_compiled_model_t** compiled_model)
{
    if (!nv_resolve_symbols() || g_compile_model == NULL) return NV_GENERAL_ERROR;
    if (compiled_model == NULL) return NV_INVALID_C_PARAM;
    if (pair_count > 0 && (keys == NULL || values == NULL)) return NV_INVALID_C_PARAM;
    if (pair_count > NV_MAX_PROPERTY_PAIRS) return NV_INVALID_C_PARAM;

    const size_t args = pair_count * 2;

    switch (pair_count) {
    case 0:
        return g_compile_model(core, model, device_name, 0, compiled_model);
    case 1:
        return g_compile_model(core, model, device_name, args, compiled_model,
                               keys[0], values[0]);
    case 2:
        return g_compile_model(core, model, device_name, args, compiled_model,
                               keys[0], values[0],
                               keys[1], values[1]);
    case 3:
        return g_compile_model(core, model, device_name, args, compiled_model,
                               keys[0], values[0],
                               keys[1], values[1],
                               keys[2], values[2]);
    case 4:
        return g_compile_model(core, model, device_name, args, compiled_model,
                               keys[0], values[0],
                               keys[1], values[1],
                               keys[2], values[2],
                               keys[3], values[3]);
    case 5:
        return g_compile_model(core, model, device_name, args, compiled_model,
                               keys[0], values[0],
                               keys[1], values[1],
                               keys[2], values[2],
                               keys[3], values[3],
                               keys[4], values[4]);
    case 6:
        return g_compile_model(core, model, device_name, args, compiled_model,
                               keys[0], values[0],
                               keys[1], values[1],
                               keys[2], values[2],
                               keys[3], values[3],
                               keys[4], values[4],
                               keys[5], values[5]);
    case 7:
        return g_compile_model(core, model, device_name, args, compiled_model,
                               keys[0], values[0],
                               keys[1], values[1],
                               keys[2], values[2],
                               keys[3], values[3],
                               keys[4], values[4],
                               keys[5], values[5],
                               keys[6], values[6]);
    case 8:
        return g_compile_model(core, model, device_name, args, compiled_model,
                               keys[0], values[0],
                               keys[1], values[1],
                               keys[2], values[2],
                               keys[3], values[3],
                               keys[4], values[4],
                               keys[5], values[5],
                               keys[6], values[6],
                               keys[7], values[7]);
    default:
        return NV_INVALID_C_PARAM;
    }
}

NV_EXPORT ov_status_e NV_CALL nv_core_set_property(
    const ov_core_t* core,
    const char* device_name,
    const char* key,
    const char* value)
{
    if (!nv_resolve_symbols()) return NV_GENERAL_ERROR;
    if (g_core_set_property == NULL) return NV_GENERAL_ERROR;
    if (key == NULL || value == NULL) return NV_INVALID_C_PARAM;
    return g_core_set_property(core, device_name, key, value);
}
