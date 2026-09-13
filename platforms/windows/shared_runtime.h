#pragma once

// Only the installed x64 server loads Swift. x86/ARM64 TIPs remain native and
// talk to that server through the unchanged Weasel IPC boundary.
#if defined(_M_X64)
extern "C" {
__declspec(dllimport) int linnet_data_setup(
    const char* core, const char* user, const char* version, int recover, void* context,
    void (*paths)(void*, const char*, const char*, const char*, const char*),
    void (*failed)(void*, const char*));
__declspec(dllimport) void* linnet_sync_create(
    const char* directory, double last_attempt, void* context,
    int (*step)(void*, const char*), int (*attempt)(void*, double),
    void (*result)(void*, int));
__declspec(dllimport) void linnet_sync_destroy(void* handle);
__declspec(dllimport) double linnet_sync_poll(void* handle);

// Update status: -1 failed, 0 downloading, 1 verifying, 2 ready for native
// activation, 3 activating, 4 completed, 5 cancelled. Poll on the UI thread;
// release after completion or request cancellation when closing the window.
__declspec(dllimport) void* linnet_data_update_start(
    const char* core, const char* user, const char* version, int complete,
    void* context, void (*failed)(void*, const char*));
__declspec(dllimport) int linnet_data_update_poll(
    void* handle, void* context, void (*receive)(void*, double, const char*));
__declspec(dllimport) void linnet_data_update_cancel(void* handle);
__declspec(dllimport) void linnet_data_update_release(void* handle);
// Mutation actions: 0 publish, 1 commit after health success, 2 restore.
__declspec(dllimport) int linnet_data_update_mutate(
    void* handle, int action, void* context, void (*failed)(void*, const char*));
__declspec(dllimport) void linnet_data_update_finish_activation(void* handle, const char* failure);
__declspec(dllimport) void linnet_data_source_read(
    void* context, void (*receive)(void*, const char* mode, const char* mirror, const char* failure));
__declspec(dllimport) int linnet_data_source_save(
    const char* mode, const char* mirror, void* context, void (*failed)(void*, const char*));
}
#pragma comment(lib, "LinnetSharedRuntime.lib")
#endif
