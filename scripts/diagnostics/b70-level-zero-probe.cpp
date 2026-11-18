#include <level_zero/ze_api.h>
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

static void check(ze_result_t result, const char *step) {
    std::printf("%s: 0x%x\n", step, result);
    std::fflush(stdout);
    if (result != ZE_RESULT_SUCCESS) std::exit(1);
}
#define ZE(call) check(call, #call)

int main(int argc, char **argv) {
    const bool copy = argc == 2 && std::strcmp(argv[1], "copy") == 0;
    ZE(zeInit(ZE_INIT_FLAG_GPU_ONLY));
    uint32_t count = 0;
    ZE(zeDriverGet(&count, nullptr));
    std::vector<ze_driver_handle_t> drivers(count);
    ZE(zeDriverGet(&count, drivers.data()));
    ze_driver_handle_t driver = nullptr;
    std::vector<ze_device_handle_t> devices;
    for (auto candidate : drivers) {
        count = 0;
        ZE(zeDeviceGet(candidate, &count, nullptr));
        if (count == 2) {
            driver = candidate;
            devices.resize(count);
            ZE(zeDeviceGet(driver, &count, devices.data()));
            break;
        }
    }
    if (!driver) { std::fprintf(stderr, "Expected one driver exposing exactly two GPUs\n"); return 2; }
    bool peer[2][2] = {};
    for (int i = 0; i < 2; ++i) {
        ze_device_properties_t props = {};
        props.stype = ZE_STRUCTURE_TYPE_DEVICE_PROPERTIES;
        ZE(zeDeviceGetProperties(devices[i], &props));
        std::printf("device=%d name=%s vendor=%x deviceId=%x\n", i, props.name, props.vendorId, props.deviceId);
        for (int j = 0; j < 2; ++j) {
            ze_bool_t accessible = 0;
            ZE(zeDeviceCanAccessPeer(devices[i], devices[j], &accessible));
            peer[i][j] = accessible;
            std::printf("peer accessor=%d allocation_owner=%d accessible=%u\n", i, j, accessible);
        }
    }
    std::fflush(stdout);
    if (!copy) return 0;
    ze_context_desc_t cd = {};
    cd.stype = ZE_STRUCTURE_TYPE_CONTEXT_DESC;
    ze_context_handle_t context;
    ZE(zeContextCreate(driver, &cd, &context));
    ze_command_list_handle_t lists[2];
    void *buffers[2];
    constexpr size_t bytes = 4 * 1024 * 1024;
    for (int i = 0; i < 2; ++i) {
        uint32_t groups = 0;
        ZE(zeDeviceGetCommandQueueGroupProperties(devices[i], &groups, nullptr));
        std::vector<ze_command_queue_group_properties_t> properties(groups);
        for (auto &p : properties) p.stype = ZE_STRUCTURE_TYPE_COMMAND_QUEUE_GROUP_PROPERTIES;
        ZE(zeDeviceGetCommandQueueGroupProperties(devices[i], &groups, properties.data()));
        uint32_t ordinal = 0;
        while (ordinal < groups && !(properties[ordinal].flags & ZE_COMMAND_QUEUE_GROUP_PROPERTY_FLAG_COPY)) ++ordinal;
        if (ordinal == groups) return 3;
        ze_command_queue_desc_t qd = {};
        qd.stype = ZE_STRUCTURE_TYPE_COMMAND_QUEUE_DESC;
        qd.ordinal = ordinal;
        qd.mode = ZE_COMMAND_QUEUE_MODE_SYNCHRONOUS;
        ZE(zeCommandListCreateImmediate(context, devices[i], &qd, &lists[i]));
        ze_device_mem_alloc_desc_t md = {};
        md.stype = ZE_STRUCTURE_TYPE_DEVICE_MEM_ALLOC_DESC;
        ZE(zeMemAllocDevice(context, &md, bytes, 1, devices[i], &buffers[i]));
    }
    std::vector<unsigned char> expected(bytes), actual(bytes), zero(bytes);
    int failures = 0;
    for (int src = 0; src < 2; ++src) {
        int dst = 1 - src;
        for (size_t n : {size_t(4096), bytes}) {
            for (size_t k = 0; k < n; ++k) expected[k] = (k * 17 + src * 53 + k / 251) % 256;
            ZE(zeCommandListAppendMemoryCopy(lists[src], buffers[src], expected.data(), n, nullptr, 0, nullptr));
            ZE(zeCommandListAppendMemoryCopy(lists[src], actual.data(), buffers[src], n, nullptr, 0, nullptr));
            if (!std::equal(expected.begin(), expected.begin() + n, actual.begin())) return 4;
            std::printf("local roundtrip device=%d bytes=%zu PASS\n", src, n);
            if (!peer[dst][src]) { std::puts("peer copy SKIP: access unsupported"); continue; }
            ZE(zeCommandListAppendMemoryCopy(lists[dst], buffers[dst], zero.data(), n, nullptr, 0, nullptr));
            std::printf("peer copy src=%d dst=%d bytes=%zu BEGIN\n", src, dst, n);
            std::fflush(stdout);
            ZE(zeCommandListAppendMemoryCopy(lists[dst], buffers[dst], buffers[src], n, nullptr, 0, nullptr));
            ZE(zeCommandListAppendMemoryCopy(lists[dst], actual.data(), buffers[dst], n, nullptr, 0, nullptr));
            if (!std::equal(expected.begin(), expected.begin() + n, actual.begin())) {
                size_t mismatches = 0;
                for (size_t k = 0; k < n; ++k) {
                    if (expected[k] != actual[k]) {
                        if (mismatches < 8) std::printf("index=%zu expected=%u actual=%u\n", k, expected[k], actual[k]);
                        ++mismatches;
                    }
                }
                std::printf("peer integrity FAIL mismatches=%zu/%zu\n", mismatches, n);
                ++failures;
            } else {
                std::puts("peer integrity PASS");
            }
        }
    }
    for (int i = 0; i < 2; ++i) {
        ZE(zeCommandListDestroy(lists[i]));
        ZE(zeMemFree(context, buffers[i]));
    }
    ZE(zeContextDestroy(context));
    return failures ? 5 : (peer[0][1] && peer[1][0] ? 0 : 6);
}
