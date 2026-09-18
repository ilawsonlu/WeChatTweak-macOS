#import <Foundation/Foundation.h>

#include <dlfcn.h>
#include <libkern/OSCacheControl.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <os/log.h>
#include <pthread.h>
#include <sys/mman.h>
#include <unistd.h>

#include <cstdint>
#include <cstring>
#include <string>

namespace {

using ParseRevokeXML = bool (*)(void *, std::string *, void *);

constexpr const char *supportedBuild = "270098";
constexpr uintptr_t parserEntryOffset = 0x4bc4bac;
constexpr uintptr_t parserContinuationOffset = 0x4bc4bb8;
constexpr ptrdiff_t newMsgIdOffset = 0x1c8;
constexpr ptrdiff_t replaceMsgOffset = 0x1d0;
constexpr size_t savedInstructionCount = 3;
constexpr uint32_t savedInstructions[savedInstructionCount] = {
    0xa9bc5ff8,
    0xa90157f6,
    0xa9024ff4,
};

ParseRevokeXML originalParseRevokeXML = nullptr;

bool hasSuffix(const char *value, const char *suffix) {
    if (value == nullptr || suffix == nullptr) {
        return false;
    }
    const size_t valueLength = std::strlen(value);
    const size_t suffixLength = std::strlen(suffix);
    return valueLength >= suffixLength &&
        std::memcmp(value + valueLength - suffixLength, suffix, suffixLength) == 0;
}

bool isTargetWeChatDylib(const char *imageName) {
    return hasSuffix(imageName, "/Contents/Resources/wechat.dylib");
}

std::string currentBuildVersion() {
    @autoreleasepool {
        id value = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"];
        if (![value isKindOfClass:[NSString class]]) {
            return "";
        }
        const char *text = [(NSString *)value UTF8String];
        return text == nullptr ? "" : std::string(text);
    }
}

bool isAddressRangeReadable(const void *address, size_t length) {
    if (address == nullptr || length == 0) {
        return false;
    }

    mach_vm_address_t current = reinterpret_cast<mach_vm_address_t>(address);
    const mach_vm_address_t end = current + length;
    if (end < current) {
        return false;
    }

    while (current < end) {
        mach_vm_address_t regionAddress = current;
        mach_vm_size_t regionSize = 0;
        vm_region_submap_info_data_64_t info = {};
        natural_t depth = 0;
        kern_return_t result = KERN_SUCCESS;
        for (;;) {
            regionAddress = current;
            regionSize = 0;
            mach_msg_type_number_t infoCount = VM_REGION_SUBMAP_INFO_COUNT_64;
            result = mach_vm_region_recurse(
                mach_task_self(),
                &regionAddress,
                &regionSize,
                &depth,
                reinterpret_cast<vm_region_recurse_info_t>(&info),
                &infoCount
            );
            if (result != KERN_SUCCESS || !info.is_submap) {
                break;
            }
            depth += 1;
        }
        if (result != KERN_SUCCESS || regionAddress > current || regionSize == 0 ||
            (info.protection & VM_PROT_READ) == 0) {
            return false;
        }

        const mach_vm_address_t next = regionAddress + regionSize;
        if (next <= current) {
            return false;
        }
        current = next;
    }
    return true;
}

bool checkedRangeEnd(uintptr_t start, size_t length, uintptr_t &end) {
    if (length == 0 || start > UINTPTR_MAX - length) {
        return false;
    }
    end = start + length;
    return true;
}

bool rangeContains(uintptr_t outerStart, size_t outerLength, uintptr_t innerStart, size_t innerLength) {
    uintptr_t outerEnd = 0;
    uintptr_t innerEnd = 0;
    return checkedRangeEnd(outerStart, outerLength, outerEnd) &&
        checkedRangeEnd(innerStart, innerLength, innerEnd) &&
        innerStart >= outerStart && innerEnd <= outerEnd;
}

bool imageAddressRange(
    const mach_header *header,
    intptr_t slide,
    uintptr_t &imageStart,
    size_t &imageSize
) {
    if (header == nullptr || header->magic != MH_MAGIC_64) {
        return false;
    }

    const auto *header64 = reinterpret_cast<const mach_header_64 *>(header);
    const uint8_t *cursor = reinterpret_cast<const uint8_t *>(header64) + sizeof(mach_header_64);
    uintptr_t lowest = UINTPTR_MAX;
    uintptr_t highest = 0;

    for (uint32_t index = 0; index < header64->ncmds; index += 1) {
        const auto *command = reinterpret_cast<const load_command *>(cursor);
        if (command->cmdsize < sizeof(load_command)) {
            return false;
        }
        if (command->cmd == LC_SEGMENT_64) {
            const auto *segment = reinterpret_cast<const segment_command_64 *>(cursor);
            if (segment->vmsize != 0) {
                const uintptr_t start = static_cast<uintptr_t>(
                    static_cast<intptr_t>(segment->vmaddr) + slide
                );
                const uintptr_t end = start + static_cast<uintptr_t>(segment->vmsize);
                if (end < start) {
                    return false;
                }
                lowest = start < lowest ? start : lowest;
                highest = end > highest ? end : highest;
            }
        }
        cursor += command->cmdsize;
    }

    if (lowest == UINTPTR_MAX || highest <= lowest) {
        return false;
    }
    imageStart = lowest;
    imageSize = highest - lowest;
    return true;
}

int64_t signExtend(uint64_t value, unsigned bitCount) {
    const uint64_t signBit = 1ULL << (bitCount - 1);
    const uint64_t mask = (1ULL << bitCount) - 1;
    value &= mask;
    return static_cast<int64_t>((value ^ signBit) - signBit);
}

uint64_t decodeEntryStubSlot(const uint32_t instructions[3], uint64_t entryAddress) {
    const uint32_t adrp = instructions[0];
    const uint32_t ldr = instructions[1];
    const uint32_t branch = instructions[2];
    if ((adrp & 0x9f00001f) != (0x90000000u | 16u) ||
        (ldr & 0xffc003ff) != (0xf9400000u | (16u << 5) | 16u) ||
        branch != (0xd61f0000u | (16u << 5))) {
        return 0;
    }

    const uint32_t immediateLow = (adrp >> 29) & 0x3;
    const uint32_t immediateHigh = (adrp >> 5) & 0x7ffff;
    const int64_t pages = signExtend((immediateHigh << 2) | immediateLow, 21);
    const auto page = static_cast<int64_t>(entryAddress & ~uint64_t(0xfff));
    const int64_t resolvedPage = page + pages * 0x1000;
    if (resolvedPage < 0) {
        return 0;
    }
    const uint64_t offset = static_cast<uint64_t>((ldr >> 10) & 0xfff) << 3;
    return static_cast<uint64_t>(resolvedPage) + offset;
}

void *allocateExecutable(const void *bytes, size_t byteCount, size_t &allocationSize) {
    const size_t pageSize = static_cast<size_t>(sysconf(_SC_PAGESIZE));
    allocationSize = (byteCount + pageSize - 1) & ~(pageSize - 1);

    void *region = mmap(nullptr, allocationSize, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    if (region != MAP_FAILED) {
        std::memcpy(region, bytes, byteCount);
        if (mprotect(region, allocationSize, PROT_READ | PROT_EXEC) == 0) {
            sys_icache_invalidate(region, byteCount);
            return region;
        }
        munmap(region, allocationSize);
    }

    region = mmap(
        nullptr,
        allocationSize,
        PROT_READ | PROT_WRITE | PROT_EXEC,
        MAP_ANON | MAP_PRIVATE | MAP_JIT,
        -1,
        0
    );
    if (region == MAP_FAILED) {
        allocationSize = 0;
        return nullptr;
    }
    pthread_jit_write_protect_np(0);
    std::memcpy(region, bytes, byteCount);
    pthread_jit_write_protect_np(1);
    sys_icache_invalidate(region, byteCount);
    return region;
}

void *buildTrampoline(uint64_t continuationAddress, size_t &allocationSize) {
    constexpr size_t trampolineByteCount = 6 * sizeof(uint32_t) + sizeof(uint64_t);
    alignas(uint64_t) uint8_t buffer[trampolineByteCount] = {};
    auto *words = reinterpret_cast<uint32_t *>(buffer);
    words[0] = savedInstructions[0];
    words[1] = savedInstructions[1];
    words[2] = savedInstructions[2];
    words[3] = 0x58000000u | (3u << 5) | 17u; // ldr x17, #12
    words[4] = 0xd61f0000u | (17u << 5);       // br x17
    words[5] = 0xd503201fu;                     // nop
    std::memcpy(buffer + 24, &continuationAddress, sizeof(continuationAddress));
    return allocateExecutable(buffer, sizeof(buffer), allocationSize);
}

bool writeHookSlot(void **slot, void *replacement) {
    if (slot == nullptr || replacement == nullptr || !isAddressRangeReadable(slot, sizeof(void *))) {
        return false;
    }

    mach_vm_address_t regionAddress = reinterpret_cast<mach_vm_address_t>(slot);
    mach_vm_size_t regionSize = 0;
    vm_region_basic_info_data_64_t info = {};
    mach_msg_type_number_t infoCount = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t objectName = MACH_PORT_NULL;
    const kern_return_t regionResult = mach_vm_region(
        mach_task_self(),
        &regionAddress,
        &regionSize,
        VM_REGION_BASIC_INFO_64,
        reinterpret_cast<vm_region_info_t>(&info),
        &infoCount,
        &objectName
    );
    if (objectName != MACH_PORT_NULL) {
        mach_port_deallocate(mach_task_self(), objectName);
    }
    if (regionResult != KERN_SUCCESS) {
        return false;
    }

    const uintptr_t pageSize = static_cast<uintptr_t>(sysconf(_SC_PAGESIZE));
    const uintptr_t pageStart = reinterpret_cast<uintptr_t>(slot) & ~(pageSize - 1);
    const kern_return_t protectResult = vm_protect(
        mach_task_self(),
        static_cast<vm_address_t>(pageStart),
        static_cast<vm_size_t>(pageSize),
        false,
        VM_PROT_READ | VM_PROT_WRITE
    );
    if (protectResult != KERN_SUCCESS) {
        return false;
    }

    const void *originalValue = *slot;
    *slot = replacement;
    const bool didWrite = *slot == replacement;
    if (!didWrite) {
        *slot = const_cast<void *>(originalValue);
    }
    vm_protect(
        mach_task_self(),
        static_cast<vm_address_t>(pageStart),
        static_cast<vm_size_t>(pageSize),
        false,
        info.protection
    );
    return didWrite;
}

bool isRevokeXML(const std::string *xml) {
    return xml != nullptr &&
        (xml->find("<revokemsg>") != std::string::npos ||
         xml->find("<revokemsg ") != std::string::npos);
}

bool isSelfRecall(const std::string &tip) {
    return tip.find("You recalled ") != std::string::npos ||
        tip.find("你撤回") != std::string::npos ||
        tip.find("你收回") != std::string::npos ||
        tip.find("你回收") != std::string::npos;
}

bool hookedParseRevokeXML(void *message, std::string *xml, void *flag) {
    if (originalParseRevokeXML == nullptr) {
        return false;
    }

    const bool result = originalParseRevokeXML(message, xml, flag);
    if (!result || message == nullptr || !isRevokeXML(xml)) {
        return result;
    }

    auto *newMsgId = reinterpret_cast<uint64_t *>(
        reinterpret_cast<uint8_t *>(message) + newMsgIdOffset
    );
    auto *replaceMsg = reinterpret_cast<std::string *>(
        reinterpret_cast<uint8_t *>(message) + replaceMsgOffset
    );
    if (!isAddressRangeReadable(newMsgId, sizeof(*newMsgId)) ||
        !isAddressRangeReadable(replaceMsg, sizeof(*replaceMsg))) {
        return result;
    }

    const std::string originalTip = *replaceMsg;
    if (isSelfRecall(originalTip) || isSelfRecall(*xml)) {
        return result;
    }

    static const std::string marker = u8"🟧 ";
    if (originalTip.compare(0, marker.size(), marker) != 0) {
        *newMsgId = 0;
        replaceMsg->assign(marker + (originalTip.empty() ? u8"已拦截一条撤回消息" : originalTip));
        os_log_info(OS_LOG_DEFAULT, "WeChatTweak marked a recalled message");
    }
    return result;
}

void installHook(const mach_header *header, intptr_t slide) {
    if (currentBuildVersion() != supportedBuild) {
        return;
    }

    uintptr_t imageStart = 0;
    size_t imageSize = 0;
    if (!imageAddressRange(header, slide, imageStart, imageSize)) {
        return;
    }

    const uintptr_t entryAddress = static_cast<uintptr_t>(slide) + parserEntryOffset;
    if (!rangeContains(imageStart, imageSize, entryAddress, 3 * sizeof(uint32_t)) ||
        !isAddressRangeReadable(reinterpret_cast<const void *>(entryAddress), 3 * sizeof(uint32_t))) {
        return;
    }

    uint32_t entryWords[3] = {};
    std::memcpy(entryWords, reinterpret_cast<const void *>(entryAddress), sizeof(entryWords));
    const uint64_t slotAddress = decodeEntryStubSlot(entryWords, entryAddress);
    if (slotAddress == 0 ||
        !rangeContains(imageStart, imageSize, slotAddress, sizeof(void *)) ||
        !isAddressRangeReadable(reinterpret_cast<const void *>(slotAddress), sizeof(void *))) {
        return;
    }

    auto **slot = reinterpret_cast<void **>(slotAddress);
    if (*slot == reinterpret_cast<void *>(&hookedParseRevokeXML)) {
        return;
    }

    size_t trampolineSize = 0;
    void *trampoline = buildTrampoline(
        static_cast<uintptr_t>(slide) + parserContinuationOffset,
        trampolineSize
    );
    if (trampoline == nullptr) {
        return;
    }

    originalParseRevokeXML = reinterpret_cast<ParseRevokeXML>(trampoline);
    if (!writeHookSlot(slot, reinterpret_cast<void *>(&hookedParseRevokeXML))) {
        originalParseRevokeXML = nullptr;
        munmap(trampoline, trampolineSize);
        return;
    }
    os_log_info(OS_LOG_DEFAULT, "WeChatTweak orange revoke marker enabled for build 270098");
}

void imageAdded(const mach_header *header, intptr_t slide) {
    Dl_info info = {};
    if (header == nullptr || header->magic != MH_MAGIC_64 ||
        header->cputype != CPU_TYPE_ARM64 || dladdr(header, &info) == 0 ||
        !isTargetWeChatDylib(info.dli_fname)) {
        return;
    }

    @autoreleasepool {
        installHook(header, slide);
    }
}

} // namespace

__attribute__((constructor)) static void initializeWeChatTweakRuntime() {
    _dyld_register_func_for_add_image(&imageAdded);
}
