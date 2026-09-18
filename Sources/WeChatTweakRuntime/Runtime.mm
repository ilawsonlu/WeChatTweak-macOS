#import <Foundation/Foundation.h>

#include <dlfcn.h>
#include <dispatch/dispatch.h>
#include <libkern/OSCacheControl.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <os/log.h>
#include <pthread.h>
#include <sys/mman.h>
#include <unistd.h>

#include <algorithm>
#include <cstdint>
#include <cstring>
#include <atomic>
#include <chrono>
#include <mutex>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

namespace {

using ParseRevokeXML = bool (*)(void *, std::string *, void *);
using ChatBubblePaint = void (*)(void *, void *);
using ChatBubbleEvent = bool (*)(void *, void *);
using MessageViewEvent = bool (*)(void *, void *);
using MessageViewMetaCall = int (*)(void *, int, int, void **);
using MetaObjectGetter = const void *(*)(void *);
using ChatBubbleSetColor = void (*)(void *, const void *);
using MessageUniqueIdInit = void (*)(void *, uint64_t, uint32_t, uint64_t, uint32_t);
using NavigateToMessageAndHighlight = void (*)(void *, const void *, bool);
using IsMessageWidgetVisible = bool (*)(void *, uint64_t);
using NativeMessageHighlight = void (*)(void *, int);
using ChatBubbleSetAnimationColor = void (*)(void *, const void *);
using MessageModelItemView = void *(*)(void *);
using ChatBubbleBindMessageModel = void (*)(void *, const void *);
using ChatBubbleItemConstructor = void *(*)(
    void *,
    void *,
    void *,
    void *,
    uint32_t,
    void *
);
using ChatBubbleItemDestructor = void (*)(void *);
using ChatItemPaint = void (*)(void *, void *);
using ChatItemPainterInit = void (*)(void *, void *);
using ChatItemFillRect = void (*)(void *, const void *, const void *);
using ChatItemPainterDestroy = void (*)(void *);

constexpr const char *supportedBuild = "270098";
constexpr uintptr_t parserEntryOffset = 0x4bc4bac;
constexpr uintptr_t parserContinuationOffset = 0x4bc4bb8;
constexpr uintptr_t chatBubbleFramePaintSlotOffset = 0x99b1700;
constexpr uintptr_t chatBubbleFramePaintOffset = 0x584440;
constexpr uintptr_t dataConstStartOffset = 0x998c470;
constexpr size_t dataConstSize = 0x4a6a50;
constexpr uintptr_t chatBubbleMetaObjectOffset = 0x12bae0;
constexpr uintptr_t chatBubbleMetaCastOffset = 0x12a05c;
constexpr uintptr_t chatBubbleMetaCallOffset = 0x12a2d0;
constexpr uintptr_t chatItemMetaObjectOffset = 0x12c240;
constexpr uintptr_t chatItemMetaCastOffset = 0x12b388;
constexpr uintptr_t chatItemMetaCallOffset = 0x12b4fc;
constexpr uintptr_t chatBubbleEventOffset = 0x58e78c;
constexpr uintptr_t chatBubbleFrameVtableOffset = 0x99b1530;
constexpr uintptr_t chatBubbleSetColorOffset = 0x584230;
constexpr uintptr_t messageViewMetaObjectOffset = 0x130b48;
constexpr uintptr_t messageViewMetaCastOffset = 0x130b64;
constexpr uintptr_t messageViewMetaCallOffset = 0x130d94;
constexpr uintptr_t messageViewEventOffset = 0x862100;
constexpr uintptr_t messageUniqueIdInitOffset = 0x9b6174;
constexpr uintptr_t navigateToMessageAndHighlightOffset = 0x865658;
constexpr uintptr_t isMessageWidgetVisibleOffset = 0x85ab00;
constexpr uintptr_t nativeMessageHighlightCallSiteOffset = 0x870278;
constexpr uintptr_t nativeMessageHighlightOffset = 0x60dbac;
constexpr uintptr_t chatBubbleSetAnimationColorOffset = 0x5b6528;
constexpr uintptr_t messageModelItemViewOffset = 0x60db88;
constexpr uintptr_t chatBubbleBindMessageModelOffset = 0x5b58dc;
constexpr uintptr_t chatBubbleItemConstructorOffset = 0x5b5474;
constexpr uintptr_t chatBubbleItemDestructorOffset = 0x5b5764;
constexpr uintptr_t chatItemPaintOffset = 0x5b56dc;
constexpr uintptr_t chatItemPainterInitOffset = 0x6cc0188;
constexpr uintptr_t chatItemFillRectOffset = 0x6ccd53c;
constexpr uintptr_t chatItemPainterDestroyOffset = 0x6cc0a04;
constexpr uint32_t expectedNativeMessageHighlightCall = 0x97f6764d;
constexpr uint32_t expectedChatBubbleBindMessageModelInstructions[4] = {
    0xd10543ff,
    0xa9116ffc,
    0xa91257f6,
    0xa9134ff4,
};
constexpr uint32_t expectedChatBubbleItemConstructorInstructions[4] = {
    0xd10103ff,
    0xa9024ff4,
    0xa9037bfd,
    0x9100c3fd,
};
constexpr uint32_t expectedChatBubbleItemDestructorInstructions[4] = {
    0xa9be4ff4,
    0xa9017bfd,
    0x910043fd,
    0xaa0003f3,
};
constexpr uint32_t expectedChatItemPaintInstructions[4] = {
    0xd100c3ff,
    0xa9014ff4,
    0xa9027bfd,
    0x910083fd,
};
constexpr size_t qObjectEventVtableIndex = 5;
constexpr size_t chatBubbleBindingCallbackVtableIndex = 0x248 / sizeof(void *);
constexpr size_t chatBubbleItemProbeSize = 0x600;
constexpr int64_t recalledBubbleWindowNanoseconds = 1'000'000'000;
constexpr ptrdiff_t newMsgIdOffset = 0x1c8;
constexpr ptrdiff_t replaceMsgOffset = 0x1d0;
constexpr size_t savedInstructionCount = 3;
constexpr uint32_t savedInstructions[savedInstructionCount] = {
    0xa9bc5ff8,
    0xa90157f6,
    0xa9024ff4,
};

ParseRevokeXML originalParseRevokeXML = nullptr;
ChatBubblePaint originalChatBubblePaint = nullptr;
ChatBubbleEvent originalChatBubbleEvent = nullptr;
MessageViewEvent originalMessageViewEvent = nullptr;
MessageViewMetaCall originalMessageViewMetaCall = nullptr;
std::mutex recalledMessageMutex;
std::unordered_set<uint64_t> recalledMessageIds;
std::unordered_map<void *, uint64_t> matchedBubbleFrames;
std::unordered_map<void *, uint64_t> probedBubbleGenerations;
std::atomic<uint64_t> recalledMessageGeneration{0};
std::atomic<bool> didLogBubbleHierarchy{false};
std::atomic<bool> didLogMessageViewTree{false};
std::atomic<int64_t> recalledBubbleDeadlineNanoseconds{0};
std::atomic<int64_t> loggedFrameMissDeadlineNanoseconds{0};
uintptr_t expectedChatBubbleFrameVtable = 0;
ChatBubbleSetColor setChatBubbleColor = nullptr;
MessageUniqueIdInit initializeMessageUniqueId = nullptr;
NavigateToMessageAndHighlight navigateToMessageAndHighlight = nullptr;
IsMessageWidgetVisible isMessageWidgetVisible = nullptr;
NativeMessageHighlight originalNativeMessageHighlight = nullptr;
ChatBubbleSetAnimationColor setChatBubbleAnimationColor = nullptr;
MessageModelItemView messageModelItemView = nullptr;
ChatBubbleBindMessageModel originalChatBubbleBindMessageModel = nullptr;
ChatBubbleItemConstructor originalChatBubbleItemConstructor = nullptr;
ChatBubbleItemDestructor originalChatBubbleItemDestructor = nullptr;
ChatItemPaint originalChatItemPaint = nullptr;
ChatItemPainterInit initializeChatItemPainter = nullptr;
ChatItemFillRect fillChatItemRect = nullptr;
ChatItemPainterDestroy destroyChatItemPainter = nullptr;
std::atomic<void *> currentMessageView{nullptr};
std::mutex messageViewMutex;
std::unordered_set<void *> knownMessageViews;
std::mutex chatItemBindingMutex;
std::unordered_map<void *, void *> chatItemByMessageModel;
std::unordered_map<void *, void *> messageModelByChatItem;
std::unordered_set<void *> recalledMessageModels;
std::atomic<uint64_t> chatItemBindingHookCalls{0};
std::mutex chatBubbleBindingCallbackMutex;
std::unordered_map<void **, ChatBubbleBindMessageModel>
    originalChatBubbleBindingCallbacks;
std::mutex knownChatBubbleItemsMutex;
std::unordered_set<void *> knownChatBubbleItems;
void *expectedMessageViewMetaObject = nullptr;
void *expectedMessageViewMetaCast = nullptr;
void *expectedMessageViewMetaCall = nullptr;
void *expectedChatBubbleMetaObject = nullptr;
void *expectedChatBubbleMetaCast = nullptr;
void *expectedChatBubbleMetaCall = nullptr;
void *expectedChatItemMetaObject = nullptr;
void *expectedChatItemMetaCast = nullptr;
void *expectedChatItemMetaCall = nullptr;

void hookedNativeMessageHighlight(void *itemView, int durationMilliseconds);
void hookedChatBubbleBindMessageModel(void *itemView, const void *messageModelHolder);
void hookedChatBubbleBindingCallback(void *itemView, const void *messageModelHolder);
void *hookedChatBubbleItemConstructor(
    void *itemView,
    void *argument1,
    void *argument2,
    void *argument3,
    uint32_t argument4,
    void *argument5
);
void hookedChatBubbleItemDestructor(void *itemView);
void hookedChatItemPaint(void *itemView, void *paintEvent);

struct MessageUniqueIdStorage {
    uint64_t serverId;
    uint32_t sequence;
    uint32_t reserved0;
    uint64_t timestamp;
    uint32_t flags;
    uint32_t reserved1;
};

static_assert(sizeof(MessageUniqueIdStorage) == 32, "unexpected MessageUniqueId storage size");

int hookedMessageViewMetaCall(void *messageView, int call, int methodId, void **arguments);

struct QtColorStorage {
    uint32_t spec;
    uint16_t alpha;
    uint16_t red;
    uint16_t green;
    uint16_t blue;
    uint16_t pad;
};

static_assert(sizeof(QtColorStorage) == 16, "unexpected QColor-compatible storage size");

constexpr QtColorStorage recalledBubbleOrange = {
    1,      // QColor::Rgb
    0xffff, // alpha
    0xffff, // red
    0x9595, // green (#95 expanded to 16 bits)
    0x0000, // blue
    0,
};

constexpr QtColorStorage recalledRowOrange = {
    1,      // QColor::Rgb
    0xffff, // opaque during binding-path verification
    0xffff, // red
    0x9595, // green (#95 expanded to 16 bits)
    0x0000, // blue
    0,
};

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

void *buildFourInstructionTrampoline(
    const uint32_t savedInstructions[4],
    uint64_t continuationAddress,
    size_t &allocationSize
) {
    constexpr size_t trampolineByteCount = 8 * sizeof(uint32_t) + sizeof(uint64_t);
    alignas(uint64_t) uint8_t buffer[trampolineByteCount] = {};
    auto *words = reinterpret_cast<uint32_t *>(buffer);
    std::memcpy(
        words,
        savedInstructions,
        4 * sizeof(uint32_t)
    );
    words[4] = 0x58000000u | (4u << 5) | 17u; // ldr x17, #16
    words[5] = 0xd61f0000u | (17u << 5);       // br x17
    words[6] = 0xd503201fu;                     // nop
    words[7] = 0xd503201fu;                     // nop
    std::memcpy(buffer + 32, &continuationAddress, sizeof(continuationAddress));
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

void *allocateNearBranchIsland(
    uintptr_t callSite,
    uintptr_t imageStart,
    uintptr_t imageEnd,
    void *replacement,
    size_t &allocationSize
) {
    if (replacement == nullptr) {
        return nullptr;
    }

    const uintptr_t pageSize = static_cast<uintptr_t>(sysconf(_SC_PAGESIZE));
    if (pageSize == 0 || (pageSize & (pageSize - 1)) != 0) {
        return nullptr;
    }
    constexpr int64_t maximumBranchDistance = (1LL << 27) - 4;
    const size_t maximumCandidatePages =
        static_cast<size_t>(maximumBranchDistance / static_cast<int64_t>(pageSize)) + 1;
    std::atomic<int> lastAllocationResult{KERN_SUCCESS};
    std::atomic<int> lastProtectResult{KERN_SUCCESS};
    std::atomic<size_t> allocationAttempts{0};

    const auto tryCandidate = [&](uintptr_t candidate) -> void * {
        const int64_t distance = static_cast<int64_t>(candidate) -
            static_cast<int64_t>(callSite);
        if (distance < -maximumBranchDistance || distance > maximumBranchDistance) {
            return nullptr;
        }

        mach_vm_address_t address = static_cast<mach_vm_address_t>(candidate);
        const kern_return_t allocationResult = mach_vm_allocate(
            mach_task_self(),
            &address,
            static_cast<mach_vm_size_t>(pageSize),
            VM_FLAGS_FIXED
        );
        allocationAttempts.fetch_add(1, std::memory_order_relaxed);
        lastAllocationResult.store(allocationResult, std::memory_order_relaxed);
        if (allocationResult != KERN_SUCCESS || address != candidate) {
            return nullptr;
        }

        alignas(uint64_t) uint8_t island[16] = {};
        auto *words = reinterpret_cast<uint32_t *>(island);
        words[0] = 0x58000051u; // ldr x17, #8
        words[1] = 0xd61f0220u; // br x17; preserve the BL caller's link register
        const uint64_t destination = reinterpret_cast<uint64_t>(replacement);
        std::memcpy(island + 8, &destination, sizeof(destination));
        std::memcpy(reinterpret_cast<void *>(candidate), island, sizeof(island));
        sys_icache_invalidate(reinterpret_cast<void *>(candidate), sizeof(island));

        const kern_return_t protectResult = mach_vm_protect(
            mach_task_self(),
            address,
            static_cast<mach_vm_size_t>(pageSize),
            false,
            VM_PROT_READ | VM_PROT_EXECUTE
        );
        lastProtectResult.store(protectResult, std::memory_order_relaxed);
        if (protectResult == KERN_SUCCESS) {
            allocationSize = pageSize;
            return reinterpret_cast<void *>(candidate);
        }
        mach_vm_deallocate(
            mach_task_self(),
            address,
            static_cast<mach_vm_size_t>(pageSize)
        );
        return nullptr;
    };

    const uintptr_t alignedImageStart = imageStart & ~(pageSize - 1);
    if (alignedImageStart >= pageSize) {
        const uintptr_t firstLowerCandidate = alignedImageStart - pageSize;
        for (size_t index = 0; index < maximumCandidatePages; index += 1) {
            const uintptr_t offset = index * pageSize;
            if (offset > firstLowerCandidate) {
                break;
            }
            const uintptr_t candidate = firstLowerCandidate - offset;
            if (void *result = tryCandidate(candidate)) {
                return result;
            }
        }
    }

    const uintptr_t firstUpperCandidate = (imageEnd + pageSize - 1) & ~(pageSize - 1);
    for (size_t index = 0; index < maximumCandidatePages; index += 1) {
        const uintptr_t candidate = firstUpperCandidate + index * pageSize;
        if (candidate < firstUpperCandidate) {
            break;
        }
        if (void *result = tryCandidate(candidate)) {
            return result;
        }
    }
    os_log_error(
        OS_LOG_DEFAULT,
        "WeChatTweak near-island allocation failed attempts=%{public}zu allocation=%{public}d protect=%{public}d range=0x%{public}llx-0x%{public}llx",
        allocationAttempts.load(std::memory_order_relaxed),
        lastAllocationResult.load(std::memory_order_relaxed),
        lastProtectResult.load(std::memory_order_relaxed),
        static_cast<unsigned long long>(imageStart),
        static_cast<unsigned long long>(imageEnd)
    );
    return nullptr;
}

bool replaceInstructionsWithAbsoluteBranch(
    uint32_t *entry,
    const uint32_t expected[4],
    uintptr_t destination
) {
    constexpr size_t patchSize = 4 * sizeof(uint32_t);
    if (entry == nullptr || destination == 0 ||
        !isAddressRangeReadable(entry, patchSize) ||
        std::memcmp(entry, expected, patchSize) != 0) {
        return false;
    }

    mach_vm_address_t regionAddress = reinterpret_cast<mach_vm_address_t>(entry);
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
    const uintptr_t entryAddress = reinterpret_cast<uintptr_t>(entry);
    const uintptr_t pageStart = entryAddress & ~(pageSize - 1);
    if (entryAddress + patchSize > pageStart + pageSize) {
        return false;
    }
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

    alignas(uint64_t) uint8_t replacement[patchSize] = {};
    auto *words = reinterpret_cast<uint32_t *>(replacement);
    words[0] = 0x58000051u; // ldr x17, #8
    words[1] = 0xd61f0220u; // br x17
    const uint64_t target = static_cast<uint64_t>(destination);
    std::memcpy(replacement + 8, &target, sizeof(target));
    std::memcpy(entry, replacement, sizeof(replacement));
    sys_icache_invalidate(entry, sizeof(replacement));
    const bool didWrite = std::memcmp(entry, replacement, sizeof(replacement)) == 0;
    if (!didWrite) {
        std::memcpy(entry, expected, patchSize);
        sys_icache_invalidate(entry, patchSize);
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

bool replaceBranchInstruction(
    uint32_t *callSite,
    uint32_t expected,
    uintptr_t destination,
    bool link
) {
    if (callSite == nullptr || !isAddressRangeReadable(callSite, sizeof(*callSite))) {
        return false;
    }
    const uintptr_t callSiteAddress = reinterpret_cast<uintptr_t>(callSite);
    const int64_t distance = static_cast<int64_t>(destination) -
        static_cast<int64_t>(callSiteAddress);
    if ((distance & 0x3) != 0 || distance < -(1LL << 27) ||
        distance > ((1LL << 27) - 4)) {
        os_log_error(OS_LOG_DEFAULT, "WeChatTweak branch island is out of range");
        return false;
    }
    if (*callSite != expected) {
        os_log_error(
            OS_LOG_DEFAULT,
            "WeChatTweak native highlight call mismatch actual=0x%{public}08x expected=0x%{public}08x",
            *callSite,
            expected
        );
        return false;
    }

    mach_vm_address_t regionAddress = static_cast<mach_vm_address_t>(callSiteAddress);
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
        os_log_error(
            OS_LOG_DEFAULT,
            "WeChatTweak could not inspect native highlight code region result=%{public}d",
            regionResult
        );
        return false;
    }

    const uintptr_t pageSize = static_cast<uintptr_t>(sysconf(_SC_PAGESIZE));
    const uintptr_t pageStart = callSiteAddress & ~(pageSize - 1);
    const kern_return_t protectResult = vm_protect(
        mach_task_self(),
        static_cast<vm_address_t>(pageStart),
        static_cast<vm_size_t>(pageSize),
        false,
        VM_PROT_READ | VM_PROT_WRITE
    );
    if (protectResult != KERN_SUCCESS) {
        os_log_error(
            OS_LOG_DEFAULT,
            "WeChatTweak could not make native highlight call writable result=%{public}d",
            protectResult
        );
        return false;
    }

    const uint32_t immediate = static_cast<uint32_t>(distance >> 2) & 0x03ffffffu;
    const uint32_t replacement = (link ? 0x94000000u : 0x14000000u) | immediate;
    __atomic_store_n(callSite, replacement, __ATOMIC_RELEASE);
    sys_icache_invalidate(callSite, sizeof(*callSite));
    const bool didWrite = *callSite == replacement;
    if (!didWrite) {
        __atomic_store_n(callSite, expected, __ATOMIC_RELEASE);
        sys_icache_invalidate(callSite, sizeof(*callSite));
    }
    vm_protect(
        mach_task_self(),
        static_cast<vm_address_t>(pageStart),
        static_cast<vm_size_t>(pageSize),
        false,
        info.protection
    );
    if (!didWrite) {
        os_log_error(OS_LOG_DEFAULT, "WeChatTweak native highlight call write did not persist");
    }
    return didWrite;
}

bool installNativeMessageHighlightHook(
    intptr_t slide,
    uintptr_t imageStart,
    size_t imageSize
) {
    const uintptr_t callSiteAddress = static_cast<uintptr_t>(slide) +
        nativeMessageHighlightCallSiteOffset;
    if (!rangeContains(imageStart, imageSize, callSiteAddress, sizeof(uint32_t))) {
        return false;
    }

    originalNativeMessageHighlight = reinterpret_cast<NativeMessageHighlight>(
        static_cast<uintptr_t>(slide) + nativeMessageHighlightOffset
    );
    size_t islandSize = 0;
    void *island = allocateNearBranchIsland(
        callSiteAddress,
        imageStart,
        imageStart + imageSize,
        reinterpret_cast<void *>(&hookedNativeMessageHighlight),
        islandSize
    );
    if (island == nullptr || !replaceBranchInstruction(
            reinterpret_cast<uint32_t *>(callSiteAddress),
            expectedNativeMessageHighlightCall,
            reinterpret_cast<uintptr_t>(island),
            true
        )) {
        if (island != nullptr) {
            mach_vm_deallocate(
                mach_task_self(),
                reinterpret_cast<mach_vm_address_t>(island),
                static_cast<mach_vm_size_t>(islandSize)
            );
        }
        originalNativeMessageHighlight = nullptr;
        return false;
    }
    os_log_info(
        OS_LOG_DEFAULT,
        "WeChatTweak hooked native message highlight target via island=%{public}p",
        island
    );
    return true;
}

bool installChatBubbleBindMessageModelHook(
    intptr_t slide,
    uintptr_t imageStart,
    size_t imageSize
) {
    const uintptr_t entryAddress = static_cast<uintptr_t>(slide) +
        chatBubbleBindMessageModelOffset;
    if (!rangeContains(imageStart, imageSize, entryAddress, sizeof(uint32_t))) {
        return false;
    }

    size_t trampolineSize = 0;
    void *trampoline = buildFourInstructionTrampoline(
        expectedChatBubbleBindMessageModelInstructions,
        entryAddress + sizeof(expectedChatBubbleBindMessageModelInstructions),
        trampolineSize
    );
    if (trampoline == nullptr) {
        return false;
    }
    originalChatBubbleBindMessageModel = reinterpret_cast<ChatBubbleBindMessageModel>(
        trampoline
    );

    if (!replaceInstructionsWithAbsoluteBranch(
            reinterpret_cast<uint32_t *>(entryAddress),
            expectedChatBubbleBindMessageModelInstructions,
            reinterpret_cast<uintptr_t>(&hookedChatBubbleBindMessageModel)
        )) {
        originalChatBubbleBindMessageModel = nullptr;
        munmap(trampoline, trampolineSize);
        return false;
    }
    os_log_info(
        OS_LOG_DEFAULT,
        "WeChatTweak hooked ChatItemView message-model binding directly"
    );
    return true;
}

bool installChatBubbleItemConstructorHook(
    intptr_t slide,
    uintptr_t imageStart,
    size_t imageSize
) {
    const uintptr_t entryAddress = static_cast<uintptr_t>(slide) +
        chatBubbleItemConstructorOffset;
    if (!rangeContains(
            imageStart,
            imageSize,
            entryAddress,
            sizeof(expectedChatBubbleItemConstructorInstructions)
        )) {
        return false;
    }

    size_t trampolineSize = 0;
    void *trampoline = buildFourInstructionTrampoline(
        expectedChatBubbleItemConstructorInstructions,
        entryAddress + sizeof(expectedChatBubbleItemConstructorInstructions),
        trampolineSize
    );
    if (trampoline == nullptr) {
        return false;
    }
    originalChatBubbleItemConstructor = reinterpret_cast<ChatBubbleItemConstructor>(
        trampoline
    );
    if (!replaceInstructionsWithAbsoluteBranch(
            reinterpret_cast<uint32_t *>(entryAddress),
            expectedChatBubbleItemConstructorInstructions,
            reinterpret_cast<uintptr_t>(&hookedChatBubbleItemConstructor)
        )) {
        originalChatBubbleItemConstructor = nullptr;
        munmap(trampoline, trampolineSize);
        return false;
    }
    os_log_info(OS_LOG_DEFAULT, "WeChatTweak hooked ChatItemView construction");
    return true;
}

bool installChatBubbleItemDestructorHook(
    intptr_t slide,
    uintptr_t imageStart,
    size_t imageSize
) {
    const uintptr_t entryAddress = static_cast<uintptr_t>(slide) +
        chatBubbleItemDestructorOffset;
    if (!rangeContains(
            imageStart,
            imageSize,
            entryAddress,
            sizeof(expectedChatBubbleItemDestructorInstructions)
        )) {
        return false;
    }

    size_t trampolineSize = 0;
    void *trampoline = buildFourInstructionTrampoline(
        expectedChatBubbleItemDestructorInstructions,
        entryAddress + sizeof(expectedChatBubbleItemDestructorInstructions),
        trampolineSize
    );
    if (trampoline == nullptr) {
        return false;
    }
    originalChatBubbleItemDestructor = reinterpret_cast<ChatBubbleItemDestructor>(
        trampoline
    );
    if (!replaceInstructionsWithAbsoluteBranch(
            reinterpret_cast<uint32_t *>(entryAddress),
            expectedChatBubbleItemDestructorInstructions,
            reinterpret_cast<uintptr_t>(&hookedChatBubbleItemDestructor)
        )) {
        originalChatBubbleItemDestructor = nullptr;
        munmap(trampoline, trampolineSize);
        return false;
    }
    os_log_info(OS_LOG_DEFAULT, "WeChatTweak hooked ChatItemView destruction");
    return true;
}

bool installChatItemPaintHook(
    intptr_t slide,
    uintptr_t imageStart,
    size_t imageSize
) {
    const uintptr_t entryAddress = static_cast<uintptr_t>(slide) + chatItemPaintOffset;
    if (!rangeContains(
            imageStart,
            imageSize,
            entryAddress,
            sizeof(expectedChatItemPaintInstructions)
        )) {
        return false;
    }

    size_t trampolineSize = 0;
    void *trampoline = buildFourInstructionTrampoline(
        expectedChatItemPaintInstructions,
        entryAddress + sizeof(expectedChatItemPaintInstructions),
        trampolineSize
    );
    if (trampoline == nullptr) {
        return false;
    }
    originalChatItemPaint = reinterpret_cast<ChatItemPaint>(trampoline);
    if (!replaceInstructionsWithAbsoluteBranch(
            reinterpret_cast<uint32_t *>(entryAddress),
            expectedChatItemPaintInstructions,
            reinterpret_cast<uintptr_t>(&hookedChatItemPaint)
        )) {
        originalChatItemPaint = nullptr;
        munmap(trampoline, trampolineSize);
        return false;
    }
    os_log_info(OS_LOG_DEFAULT, "WeChatTweak hooked ChatItemView paint event");
    return true;
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

bool parseUnsignedTag(const std::string &xml, const char *tagName, uint64_t &result) {
    const std::string startTag = "<" + std::string(tagName) + ">";
    const std::string endTag = "</" + std::string(tagName) + ">";
    const size_t start = xml.find(startTag);
    if (start == std::string::npos) {
        return false;
    }
    const size_t valueStart = start + startTag.size();
    const size_t end = xml.find(endTag, valueStart);
    if (end == std::string::npos || end == valueStart) {
        return false;
    }

    uint64_t value = 0;
    for (size_t index = valueStart; index < end; index += 1) {
        const char character = xml[index];
        if (character < '0' || character > '9') {
            return false;
        }
        const uint64_t digit = static_cast<uint64_t>(character - '0');
        if (value > (UINT64_MAX - digit) / 10) {
            return false;
        }
        value = value * 10 + digit;
    }
    if (value == 0) {
        return false;
    }
    result = value;
    return true;
}

bool revokeNewMsgId(const std::string &xml, uint64_t &result) {
    return parseUnsignedTag(xml, "newmsgid", result) ||
        parseUnsignedTag(xml, "newMsgId", result) ||
        parseUnsignedTag(xml, "NewMsgId", result) ||
        parseUnsignedTag(xml, "newmsgId", result);
}

int64_t steadyClockNanoseconds() {
    return std::chrono::duration_cast<std::chrono::nanoseconds>(
        std::chrono::steady_clock::now().time_since_epoch()
    ).count();
}

void armRecalledBubbleColoring() {
    recalledBubbleDeadlineNanoseconds.store(
        steadyClockNanoseconds() + recalledBubbleWindowNanoseconds,
        std::memory_order_release
    );
    os_log_info(OS_LOG_DEFAULT, "WeChatTweak armed recalled-bubble coloring");
}

std::vector<void *> chatBubbleFramesInItemView(void *itemView) {
    std::vector<void *> frames;
    if (expectedChatBubbleFrameVtable == 0 ||
        !isAddressRangeReadable(itemView, chatBubbleItemProbeSize)) {
        return frames;
    }

    const auto *bytes = reinterpret_cast<const uint8_t *>(itemView);
    for (size_t offset = 0; offset + sizeof(void *) <= chatBubbleItemProbeSize;
         offset += sizeof(void *)) {
        void *candidate = nullptr;
        std::memcpy(&candidate, bytes + offset, sizeof(candidate));
        const uintptr_t candidateAddress = reinterpret_cast<uintptr_t>(candidate);
        if (candidateAddress < 0x100000000ULL || (candidateAddress & 0x7) != 0 ||
            !isAddressRangeReadable(candidate, sizeof(void *))) {
            continue;
        }

        uintptr_t vtable = 0;
        std::memcpy(&vtable, candidate, sizeof(vtable));
        if (vtable != expectedChatBubbleFrameVtable) {
            continue;
        }
        if (std::find(frames.begin(), frames.end(), candidate) == frames.end()) {
            frames.push_back(candidate);
        }
    }
    return frames;
}

void colorPendingRecalledBubble(void *itemView) {
    int64_t deadline = recalledBubbleDeadlineNanoseconds.load(std::memory_order_acquire);
    if (deadline == 0 || setChatBubbleColor == nullptr) {
        return;
    }
    if (steadyClockNanoseconds() > deadline) {
        recalledBubbleDeadlineNanoseconds.compare_exchange_strong(
            deadline,
            0,
            std::memory_order_acq_rel
        );
        return;
    }

    const std::vector<void *> frames = chatBubbleFramesInItemView(itemView);
    if (frames.empty()) {
        int64_t previouslyLogged = loggedFrameMissDeadlineNanoseconds.load(
            std::memory_order_relaxed
        );
        if (previouslyLogged != deadline &&
            loggedFrameMissDeadlineNanoseconds.compare_exchange_strong(
                previouslyLogged,
                deadline,
                std::memory_order_relaxed
            )) {
            os_log_info(
                OS_LOG_DEFAULT,
                "WeChatTweak reached a recalled chat item but found no ChatBubbleFrame"
            );
        }
        return;
    }
    if (!recalledBubbleDeadlineNanoseconds.compare_exchange_strong(
            deadline,
            0,
            std::memory_order_acq_rel
        )) {
        return;
    }

    for (void *frame : frames) {
        setChatBubbleColor(frame, &recalledBubbleOrange);
    }
    os_log_info(
        OS_LOG_DEFAULT,
        "WeChatTweak colored a recalled chat bubble orange frames=%{public}zu",
        frames.size()
    );
}

bool rememberRecalledMessage(uint64_t messageId) {
    if (messageId == 0) {
        return false;
    }
    std::lock_guard<std::mutex> lock(recalledMessageMutex);
    if (recalledMessageIds.insert(messageId).second) {
        recalledMessageGeneration.fetch_add(1, std::memory_order_relaxed);
        return true;
    }
    return false;
}

std::vector<uint64_t> recalledMessageSnapshot() {
    std::lock_guard<std::mutex> lock(recalledMessageMutex);
    return std::vector<uint64_t>(recalledMessageIds.begin(), recalledMessageIds.end());
}

const char *qtObjectClassName(void *object) {
    if (!isAddressRangeReadable(object, 2 * sizeof(void *))) {
        return nullptr;
    }

    auto **vtable = *reinterpret_cast<void ***>(object);
    if (!isAddressRangeReadable(vtable, sizeof(void *)) || vtable[0] == nullptr) {
        return nullptr;
    }
    const auto metaObjectGetter = reinterpret_cast<MetaObjectGetter>(vtable[0]);
    const void *metaObject = metaObjectGetter(object);
    if (!isAddressRangeReadable(metaObject, 2 * sizeof(void *))) {
        return nullptr;
    }

    const auto *stringData = *reinterpret_cast<const uint8_t *const *>(
        reinterpret_cast<const uint8_t *>(metaObject) + sizeof(void *)
    );
    if (!isAddressRangeReadable(stringData, 3 * sizeof(uint64_t))) {
        return nullptr;
    }
    const int64_t stringOffset = *reinterpret_cast<const int64_t *>(stringData + 16);
    if (stringOffset <= 0 || stringOffset > 4096) {
        return nullptr;
    }
    const char *name = reinterpret_cast<const char *>(stringData + stringOffset);
    constexpr size_t maximumClassNameLength = 128;
    if (!isAddressRangeReadable(name, maximumClassNameLength)) {
        return nullptr;
    }
    size_t length = 0;
    while (length < maximumClassNameLength && name[length] != '\0') {
        const unsigned char character = static_cast<unsigned char>(name[length]);
        if (character < 0x20 || character > 0x7e) {
            return nullptr;
        }
        length += 1;
    }
    if (length == 0 || length == maximumClassNameLength) {
        return nullptr;
    }
    return name;
}

void *qtObjectParent(void *object) {
    if (!isAddressRangeReadable(object, 2 * sizeof(void *))) {
        return nullptr;
    }
    void *privateData = *(reinterpret_cast<void **>(object) + 1);
    if (!isAddressRangeReadable(privateData, 2 * sizeof(void *))) {
        return nullptr;
    }
    return *(reinterpret_cast<void **>(privateData) + 1);
}

std::vector<void *> qtObjectChildren(void *object) {
    std::vector<void *> result;
    if (!isAddressRangeReadable(object, 2 * sizeof(void *))) {
        return result;
    }
    void *privateData = *(reinterpret_cast<void **>(object) + 1);
    if (privateData == nullptr) {
        return result;
    }
    constexpr size_t childrenListOffset = 2 * sizeof(void *);
    if (!isAddressRangeReadable(
            reinterpret_cast<const uint8_t *>(privateData) + childrenListOffset,
            sizeof(void *)
        )) {
        return result;
    }

    void *listData = nullptr;
    std::memcpy(
        &listData,
        reinterpret_cast<const uint8_t *>(privateData) + childrenListOffset,
        sizeof(listData)
    );
    constexpr size_t listHeaderSize = 16;
    if (!isAddressRangeReadable(listData, listHeaderSize)) {
        return result;
    }

    int32_t allocation = 0;
    int32_t begin = 0;
    int32_t end = 0;
    const auto *listBytes = reinterpret_cast<const uint8_t *>(listData);
    std::memcpy(&allocation, listBytes + 4, sizeof(allocation));
    std::memcpy(&begin, listBytes + 8, sizeof(begin));
    std::memcpy(&end, listBytes + 12, sizeof(end));
    constexpr int32_t maximumChildCount = 4096;
    if (allocation < 0 || begin < 0 || end < begin || end > allocation ||
        end - begin > maximumChildCount) {
        return result;
    }

    const size_t childCount = static_cast<size_t>(end - begin);
    const auto *items = reinterpret_cast<void *const *>(listBytes + listHeaderSize) + begin;
    if (childCount == 0 || !isAddressRangeReadable(items, childCount * sizeof(void *))) {
        return result;
    }
    result.reserve(childCount);
    for (size_t index = 0; index < childCount; index += 1) {
        void *child = items[index];
        if (child != nullptr && isAddressRangeReadable(child, 2 * sizeof(void *))) {
            result.push_back(child);
        }
    }
    return result;
}

std::vector<void *> qtObjectDescendants(void *root, size_t maximumCount = 4096) {
    std::vector<void *> descendants;
    std::vector<void *> pending = qtObjectChildren(root);
    std::unordered_set<void *> visited;
    visited.insert(root);
    while (!pending.empty() && descendants.size() < maximumCount) {
        void *object = pending.back();
        pending.pop_back();
        if (!visited.insert(object).second) {
            continue;
        }
        descendants.push_back(object);
        std::vector<void *> children = qtObjectChildren(object);
        pending.insert(pending.end(), children.begin(), children.end());
    }
    return descendants;
}

bool findMessageIdInRange(
    const void *address,
    size_t byteCount,
    const std::vector<uint64_t> &messageIds,
    uint64_t &matchedId,
    size_t &matchedOffset
) {
    if (!isAddressRangeReadable(address, byteCount)) {
        return false;
    }
    const auto *bytes = reinterpret_cast<const uint8_t *>(address);
    for (size_t offset = 0; offset + sizeof(uint64_t) <= byteCount; offset += sizeof(uint64_t)) {
        uint64_t candidate = 0;
        std::memcpy(&candidate, bytes + offset, sizeof(candidate));
        for (uint64_t messageId : messageIds) {
            if (candidate == messageId) {
                matchedId = messageId;
                matchedOffset = offset;
                return true;
            }
        }
    }
    return false;
}

bool objectUsesMetaFunctions(
    void *object,
    void *metaObject,
    void *metaCast,
    void *metaCall,
    void *replacementMetaCall = nullptr
) {
    if (!isAddressRangeReadable(object, sizeof(void *))) {
        return false;
    }
    auto **vtable = *reinterpret_cast<void ***>(object);
    if (!isAddressRangeReadable(vtable, 3 * sizeof(void *))) {
        return false;
    }
    return vtable[0] == metaObject && vtable[1] == metaCast &&
        (vtable[2] == metaCall ||
         (replacementMetaCall != nullptr && vtable[2] == replacementMetaCall));
}

bool isKnownMessageView(void *messageView) {
    return objectUsesMetaFunctions(
        messageView,
        expectedMessageViewMetaObject,
        expectedMessageViewMetaCast,
        expectedMessageViewMetaCall,
        reinterpret_cast<void *>(&hookedMessageViewMetaCall)
    );
}

void rememberMessageView(void *messageView) {
    if (messageView == nullptr) {
        return;
    }
    currentMessageView.store(messageView, std::memory_order_release);
    std::lock_guard<std::mutex> lock(messageViewMutex);
    knownMessageViews.insert(messageView);
}

std::vector<void *> messageViewSnapshot() {
    std::vector<void *> result;
    void *current = currentMessageView.load(std::memory_order_acquire);
    if (current != nullptr) {
        result.push_back(current);
    }
    std::lock_guard<std::mutex> lock(messageViewMutex);
    result.reserve(knownMessageViews.size() + 1);
    for (void *messageView : knownMessageViews) {
        if (messageView != current) {
            result.push_back(messageView);
        }
    }
    return result;
}

bool isKnownChatBubbleItemView(void *itemView) {
    return objectUsesMetaFunctions(
        itemView,
        expectedChatBubbleMetaObject,
        expectedChatBubbleMetaCast,
        expectedChatBubbleMetaCall
    );
}

bool isKnownChatItemView(void *itemView) {
    return objectUsesMetaFunctions(
        itemView,
        expectedChatItemMetaObject,
        expectedChatItemMetaCast,
        expectedChatItemMetaCall
    ) || isKnownChatBubbleItemView(itemView);
}

bool itemViewContainsMessageId(void *itemView, uint64_t messageId) {
    const std::vector<uint64_t> messageIds = {messageId};
    uint64_t matchedId = 0;
    size_t matchedOffset = 0;
    if (findMessageIdInRange(
            itemView,
            chatBubbleItemProbeSize,
            messageIds,
            matchedId,
            matchedOffset
        )) {
        return true;
    }

    constexpr ptrdiff_t viewModelOffset = 0x230;
    constexpr size_t viewModelProbeSize = 0x800;
    if (!isAddressRangeReadable(
            reinterpret_cast<const uint8_t *>(itemView) + viewModelOffset,
            sizeof(void *)
        )) {
        return false;
    }
    void *viewModel = nullptr;
    std::memcpy(
        &viewModel,
        reinterpret_cast<const uint8_t *>(itemView) + viewModelOffset,
        sizeof(viewModel)
    );
    return findMessageIdInRange(
        viewModel,
        viewModelProbeSize,
        messageIds,
        matchedId,
        matchedOffset
    );
}

void *messageModelForChatItem(void *itemView) {
    constexpr ptrdiff_t modelOffset = 0x230;
    const auto *address = reinterpret_cast<const uint8_t *>(itemView) + modelOffset;
    if (!isAddressRangeReadable(address, sizeof(void *))) {
        return nullptr;
    }
    void *messageModel = nullptr;
    std::memcpy(&messageModel, address, sizeof(messageModel));
    return messageModel;
}

void rememberKnownChatBubbleItem(void *itemView) {
    if (itemView == nullptr) {
        return;
    }
    std::lock_guard<std::mutex> lock(knownChatBubbleItemsMutex);
    knownChatBubbleItems.insert(itemView);
}

void forgetKnownChatBubbleItem(void *itemView) {
    std::lock_guard<std::mutex> lock(knownChatBubbleItemsMutex);
    knownChatBubbleItems.erase(itemView);
}

size_t colorKnownChatBubbleItems() {
    if (setChatBubbleAnimationColor == nullptr) {
        return 0;
    }
    std::vector<void *> items;
    {
        std::lock_guard<std::mutex> lock(knownChatBubbleItemsMutex);
        items.assign(knownChatBubbleItems.begin(), knownChatBubbleItems.end());
    }

    size_t coloredCount = 0;
    std::vector<void *> staleItems;
    for (void *itemView : items) {
        if (!isKnownChatItemView(itemView)) {
            staleItems.push_back(itemView);
            continue;
        }
        setChatBubbleAnimationColor(itemView, &recalledRowOrange);
        coloredCount += 1;
    }
    if (!staleItems.empty()) {
        std::lock_guard<std::mutex> lock(knownChatBubbleItemsMutex);
        for (void *itemView : staleItems) {
            knownChatBubbleItems.erase(itemView);
        }
    }
    return coloredCount;
}

void rememberChatItemBinding(void *itemView) {
    void *messageModel = messageModelForChatItem(itemView);
    std::lock_guard<std::mutex> lock(chatItemBindingMutex);
    const auto previous = messageModelByChatItem.find(itemView);
    if (previous != messageModelByChatItem.end() && previous->second != messageModel) {
        const auto mappedItem = chatItemByMessageModel.find(previous->second);
        if (mappedItem != chatItemByMessageModel.end() && mappedItem->second == itemView) {
            chatItemByMessageModel.erase(mappedItem);
        }
    }
    if (messageModel == nullptr) {
        messageModelByChatItem.erase(itemView);
        return;
    }
    messageModelByChatItem[itemView] = messageModel;
    chatItemByMessageModel[messageModel] = itemView;
}

bool applyRecalledRowColor(void *messageModel) {
    if (messageModel == nullptr || setChatBubbleAnimationColor == nullptr) {
        return false;
    }
    void *itemView = nullptr;
    {
        std::lock_guard<std::mutex> lock(chatItemBindingMutex);
        const auto match = chatItemByMessageModel.find(messageModel);
        if (match == chatItemByMessageModel.end()) {
            return false;
        }
        itemView = match->second;
    }
    if (!isKnownChatItemView(itemView) ||
        messageModelForChatItem(itemView) != messageModel) {
        std::lock_guard<std::mutex> lock(chatItemBindingMutex);
        chatItemByMessageModel.erase(messageModel);
        messageModelByChatItem.erase(itemView);
        return false;
    }
    setChatBubbleAnimationColor(itemView, &recalledRowOrange);
    return true;
}

void hookedChatItemPaint(void *itemView, void *paintEvent) {
    if (originalChatItemPaint == nullptr) {
        return;
    }
    originalChatItemPaint(itemView, paintEvent);

    void *messageModel = messageModelForChatItem(itemView);
    bool shouldColor = false;
    {
        std::lock_guard<std::mutex> lock(chatItemBindingMutex);
        shouldColor = recalledMessageModels.find(messageModel) != recalledMessageModels.end();
    }
    if (!shouldColor || paintEvent == nullptr || initializeChatItemPainter == nullptr ||
        fillChatItemRect == nullptr || destroyChatItemPainter == nullptr ||
        !isAddressRangeReadable(
            static_cast<const uint8_t *>(paintEvent) + 0x14,
            4 * sizeof(int32_t)
        )) {
        return;
    }

    alignas(16) uint8_t painterStorage[32] = {};
    initializeChatItemPainter(
        painterStorage,
        static_cast<uint8_t *>(itemView) + 0x10
    );
    fillChatItemRect(
        painterStorage,
        static_cast<const uint8_t *>(paintEvent) + 0x14,
        &recalledRowOrange
    );
    destroyChatItemPainter(painterStorage);
}

bool applyRecalledRowColorFromNativeModel(void *messageModel, void **candidateItemView) {
    if (candidateItemView != nullptr) {
        *candidateItemView = nullptr;
    }
    if (messageModel == nullptr || messageModelItemView == nullptr ||
        setChatBubbleAnimationColor == nullptr) {
        return false;
    }

    void *itemView = messageModelItemView(messageModel);
    if (candidateItemView != nullptr) {
        *candidateItemView = itemView;
    }
    if (!isKnownChatItemView(itemView)) {
        return false;
    }

    setChatBubbleAnimationColor(itemView, &recalledRowOrange);
    return true;
}

bool colorRecalledMessageInView(void *messageView, uint64_t messageId) {
    if (!isKnownMessageView(messageView) || setChatBubbleColor == nullptr) {
        return false;
    }

    const std::vector<void *> descendants = qtObjectDescendants(messageView);
    size_t itemViewCount = 0;
    for (void *object : descendants) {
        if (!isKnownChatBubbleItemView(object)) {
            continue;
        }
        itemViewCount += 1;
        if (!itemViewContainsMessageId(object, messageId)) {
            continue;
        }
        const std::vector<void *> frames = chatBubbleFramesInItemView(object);
        if (frames.empty()) {
            os_log_info(
                OS_LOG_DEFAULT,
                "WeChatTweak found recalled item but no ChatBubbleFrame id=%{public}llu",
                static_cast<unsigned long long>(messageId)
            );
            return false;
        }
        for (void *frame : frames) {
            setChatBubbleColor(frame, &recalledBubbleOrange);
        }
        os_log_info(
            OS_LOG_DEFAULT,
            "WeChatTweak colored recalled message orange id=%{public}llu frames=%{public}zu",
            static_cast<unsigned long long>(messageId),
            frames.size()
        );
        return true;
    }
    os_log_info(
        OS_LOG_DEFAULT,
        "WeChatTweak scanned MessageView without recalled item id=%{public}llu descendants=%{public}zu chat_items=%{public}zu",
        static_cast<unsigned long long>(messageId),
        descendants.size(),
        itemViewCount
    );
    return false;
}

void scheduleRecalledMessageColorAttempt(
    void *messageView,
    uint64_t messageId,
    int64_t delayNanoseconds
) {
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, delayNanoseconds),
        dispatch_get_main_queue(),
        ^{
            colorRecalledMessageInView(messageView, messageId);
        }
    );
}

void highlightAndColorRecalledMessage(uint64_t messageId) {
    if (messageId == 0) {
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        if (initializeMessageUniqueId == nullptr || navigateToMessageAndHighlight == nullptr ||
            isMessageWidgetVisible == nullptr) {
            os_log_info(OS_LOG_DEFAULT, "WeChatTweak native message highlighting is unavailable");
            return;
        }

        void *visibleMessageView = nullptr;
        std::vector<void *> validViews;
        std::vector<void *> staleViews;
        const void *current = currentMessageView.load(std::memory_order_acquire);
        const std::vector<void *> candidates = current == nullptr
            ? std::vector<void *>{}
            : std::vector<void *>{const_cast<void *>(current)};
        for (void *candidate : candidates) {
            if (!isKnownMessageView(candidate)) {
                staleViews.push_back(candidate);
                continue;
            }
            validViews.push_back(candidate);
            if (isMessageWidgetVisible(candidate, messageId)) {
                visibleMessageView = candidate;
                break;
            }
        }
        if (!staleViews.empty()) {
            std::lock_guard<std::mutex> lock(messageViewMutex);
            for (void *staleView : staleViews) {
                knownMessageViews.erase(staleView);
            }
        }
        if (visibleMessageView == nullptr) {
            os_log_info(
                OS_LOG_DEFAULT,
                "WeChatTweak found no visible MessageView among %{public}zu valid candidates id=%{public}llu",
                candidates.size(),
                static_cast<unsigned long long>(messageId)
            );
            return;
        }

        MessageUniqueIdStorage uniqueId = {};
        initializeMessageUniqueId(&uniqueId, messageId, 0, 0, 0);
        armRecalledBubbleColoring();
        navigateToMessageAndHighlight(visibleMessageView, &uniqueId, true);
        scheduleRecalledMessageColorAttempt(visibleMessageView, messageId, 50'000'000);
        scheduleRecalledMessageColorAttempt(visibleMessageView, messageId, 250'000'000);
        scheduleRecalledMessageColorAttempt(visibleMessageView, messageId, 700'000'000);
        os_log_info(
            OS_LOG_DEFAULT,
            "WeChatTweak requested native highlight for recalled message id=%{public}llu visible_match=1",
            static_cast<unsigned long long>(messageId)
        );
    });
}

bool findMessageIdFromViewModel(
    void *itemView,
    const std::vector<uint64_t> &messageIds,
    uint64_t &matchedId,
    size_t &ownerOffset,
    size_t &modelOffset
) {
    constexpr size_t objectProbeSize = 0x600;
    constexpr size_t modelProbeSize = 0x800;
    if (!isAddressRangeReadable(itemView, objectProbeSize)) {
        return false;
    }
    if (findMessageIdInRange(itemView, objectProbeSize, messageIds, matchedId, modelOffset)) {
        ownerOffset = 0;
        return true;
    }

    const auto *bytes = reinterpret_cast<const uint8_t *>(itemView);
    for (size_t offset = 0x10; offset + sizeof(void *) <= objectProbeSize;
         offset += sizeof(void *)) {
        void *candidate = nullptr;
        std::memcpy(&candidate, bytes + offset, sizeof(candidate));
        const uintptr_t candidateAddress = reinterpret_cast<uintptr_t>(candidate);
        if (candidateAddress < 0x100000000ULL || (candidateAddress & 0x7) != 0) {
            continue;
        }
        if (!isAddressRangeReadable(candidate, modelProbeSize)) {
            continue;
        }
        size_t candidateOffset = 0;
        if (findMessageIdInRange(
                candidate,
                modelProbeSize,
                messageIds,
                matchedId,
                candidateOffset
            )) {
            ownerOffset = offset;
            modelOffset = candidateOffset;
            return true;
        }
    }
    return false;
}

void logBubbleHierarchyOnce(void *frame) {
    bool expected = false;
    if (!didLogBubbleHierarchy.compare_exchange_strong(expected, true)) {
        return;
    }
    void *object = frame;
    for (unsigned depth = 0; object != nullptr && depth < 8; depth += 1) {
        const char *name = qtObjectClassName(object);
        os_log_info(
            OS_LOG_DEFAULT,
            "WeChatTweak bubble hierarchy depth=%{public}u object=%{public}p class=%{public}s",
            depth,
            object,
            name == nullptr ? "<unknown>" : name
        );
        object = qtObjectParent(object);
    }
}

void probeRecalledBubble(void *frame) {
    const std::vector<uint64_t> messageIds = recalledMessageSnapshot();
    if (messageIds.empty()) {
        return;
    }
    const uint64_t generation = recalledMessageGeneration.load(std::memory_order_relaxed);
    {
        std::lock_guard<std::mutex> lock(recalledMessageMutex);
        const auto previous = probedBubbleGenerations.find(frame);
        if (previous != probedBubbleGenerations.end() && previous->second == generation) {
            return;
        }
        probedBubbleGenerations[frame] = generation;
    }

    void *object = frame;
    for (unsigned depth = 0; object != nullptr && depth < 8; depth += 1) {
        const char *name = qtObjectClassName(object);
        if (name != nullptr && std::strcmp(name, "mmui::ChatBubbleItemView") == 0) {
            uint64_t matchedId = 0;
            size_t ownerOffset = 0;
            size_t modelOffset = 0;
            if (findMessageIdFromViewModel(
                    object,
                    messageIds,
                    matchedId,
                    ownerOffset,
                    modelOffset
                )) {
                bool changed = false;
                {
                    std::lock_guard<std::mutex> lock(recalledMessageMutex);
                    const auto previous = matchedBubbleFrames.find(frame);
                    changed = previous == matchedBubbleFrames.end() || previous->second != matchedId;
                    matchedBubbleFrames[frame] = matchedId;
                }
                if (changed) {
                    os_log_info(
                        OS_LOG_DEFAULT,
                        "WeChatTweak matched recalled bubble id=%{public}llu owner_offset=0x%{public}zx model_offset=0x%{public}zx",
                        static_cast<unsigned long long>(matchedId),
                        ownerOffset,
                        modelOffset
                    );
                }
                return;
            }
            std::lock_guard<std::mutex> lock(recalledMessageMutex);
            matchedBubbleFrames.erase(frame);
            return;
        }
        object = qtObjectParent(object);
    }
}

void hookedChatBubblePaint(void *frame, void *paintEvent) {
    if (originalChatBubblePaint == nullptr) {
        return;
    }
    logBubbleHierarchyOnce(frame);
    probeRecalledBubble(frame);
    originalChatBubblePaint(frame, paintEvent);
}

void *hookedChatBubbleItemConstructor(
    void *itemView,
    void *argument1,
    void *argument2,
    void *argument3,
    uint32_t argument4,
    void *argument5
) {
    if (originalChatBubbleItemConstructor == nullptr) {
        return itemView;
    }
    void *result = originalChatBubbleItemConstructor(
        itemView,
        argument1,
        argument2,
        argument3,
        argument4,
        argument5
    );
    rememberKnownChatBubbleItem(result == nullptr ? itemView : result);
    return result;
}

void hookedChatBubbleItemDestructor(void *itemView) {
    forgetKnownChatBubbleItem(itemView);
    if (originalChatBubbleItemDestructor != nullptr) {
        originalChatBubbleItemDestructor(itemView);
    }
}

void recordChatBubbleBinding(void *itemView) {
    rememberKnownChatBubbleItem(itemView);
    rememberChatItemBinding(itemView);

    const uint64_t callIndex = chatItemBindingHookCalls.fetch_add(
        1,
        std::memory_order_relaxed
    );
    if (callIndex == 0) {
        os_log_info(
            OS_LOG_DEFAULT,
            "WeChatTweak observed the first ChatBubbleItemView message-model binding"
        );
    }

    void *messageModel = messageModelForChatItem(itemView);
    bool recalled = false;
    {
        std::lock_guard<std::mutex> lock(chatItemBindingMutex);
        recalled = recalledMessageModels.find(messageModel) != recalledMessageModels.end();
    }
    if (!recalled && messageModel != nullptr) {
        const std::vector<uint64_t> messageIds = recalledMessageSnapshot();
        for (uint64_t messageId : messageIds) {
            if (!itemViewContainsMessageId(itemView, messageId)) {
                continue;
            }
            std::lock_guard<std::mutex> lock(chatItemBindingMutex);
            recalledMessageModels.insert(messageModel);
            recalled = true;
            break;
        }
    }
    if (recalled && applyRecalledRowColor(messageModel)) {
        os_log_info(
            OS_LOG_DEFAULT,
            "WeChatTweak reapplied recalled row color after item binding model=%{public}p",
            messageModel
        );
    }
}

void hookedChatBubbleBindMessageModel(void *itemView, const void *messageModelHolder) {
    if (originalChatBubbleBindMessageModel == nullptr) {
        return;
    }
    originalChatBubbleBindMessageModel(itemView, messageModelHolder);
    recordChatBubbleBinding(itemView);
}

void hookedChatBubbleBindingCallback(void *itemView, const void *messageModelHolder) {
    if (itemView == nullptr || !isAddressRangeReadable(itemView, sizeof(void *))) {
        return;
    }
    void **vtable = nullptr;
    std::memcpy(&vtable, itemView, sizeof(vtable));
    ChatBubbleBindMessageModel original = nullptr;
    {
        std::lock_guard<std::mutex> lock(chatBubbleBindingCallbackMutex);
        const auto match = originalChatBubbleBindingCallbacks.find(vtable);
        if (match != originalChatBubbleBindingCallbacks.end()) {
            original = match->second;
        }
    }
    if (original == nullptr) {
        return;
    }
    original(itemView, messageModelHolder);
    recordChatBubbleBinding(itemView);
}

bool hookedChatBubbleEvent(void *itemView, void *event) {
    if (originalChatBubbleEvent == nullptr) {
        return false;
    }
    rememberKnownChatBubbleItem(itemView);
    rememberChatItemBinding(itemView);
    const bool result = originalChatBubbleEvent(itemView, event);
    void *messageModel = messageModelForChatItem(itemView);
    bool shouldColor = false;
    {
        std::lock_guard<std::mutex> lock(chatItemBindingMutex);
        shouldColor = recalledMessageModels.find(messageModel) != recalledMessageModels.end();
    }
    if (shouldColor && setChatBubbleAnimationColor != nullptr) {
        setChatBubbleAnimationColor(itemView, &recalledRowOrange);
    }
    return result;
}

void hookedNativeMessageHighlight(void *messageModel, int durationMilliseconds) {
    if (originalNativeMessageHighlight == nullptr) {
        return;
    }
    const int64_t deadline = recalledBubbleDeadlineNanoseconds.exchange(
        0,
        std::memory_order_acq_rel
    );
    if (deadline == 0 || steadyClockNanoseconds() > deadline) {
        originalNativeMessageHighlight(messageModel, durationMilliseconds);
        return;
    }
    {
        std::lock_guard<std::mutex> lock(chatItemBindingMutex);
        recalledMessageModels.insert(messageModel);
    }
    void *nativeItemView = nullptr;
    const bool directlyColored = applyRecalledRowColorFromNativeModel(
        messageModel,
        &nativeItemView
    );
    const bool mappedColored = directlyColored ? false : applyRecalledRowColor(messageModel);
    const size_t fallbackColoredCount = directlyColored || mappedColored
        ? 0
        : colorKnownChatBubbleItems();
    originalNativeMessageHighlight(messageModel, durationMilliseconds);
    if (directlyColored) {
        applyRecalledRowColorFromNativeModel(messageModel, nullptr);
    }
    os_log_info(
        OS_LOG_DEFAULT,
        "WeChatTweak applied recalled row highlight model=%{public}p native_item=%{public}p direct=%{public}d mapped=%{public}d fallback_items=%{public}zu",
        messageModel,
        nativeItemView,
        directlyColored,
        mappedColored,
        fallbackColoredCount
    );
}

void logMessageViewTreeOnce(void *messageView) {
    bool expected = false;
    if (!didLogMessageViewTree.compare_exchange_strong(expected, true)) {
        return;
    }

    const std::vector<void *> descendants = qtObjectDescendants(messageView);
    std::unordered_map<std::string, size_t> classCounts;
    for (void *object : descendants) {
        const char *name = qtObjectClassName(object);
        if (name != nullptr) {
            classCounts[name] += 1;
        }
    }
    os_log_info(
        OS_LOG_DEFAULT,
        "WeChatTweak MessageView tree contains %{public}zu QObject descendants and %{public}zu classes",
        descendants.size(),
        classCounts.size()
    );
    for (const auto &entry : classCounts) {
        if (entry.first.find("Chat") == std::string::npos &&
            entry.first.find("Message") == std::string::npos &&
            entry.first.find("Bubble") == std::string::npos) {
            continue;
        }
        os_log_info(
            OS_LOG_DEFAULT,
            "WeChatTweak MessageView class=%{public}s count=%{public}zu",
            entry.first.c_str(),
            entry.second
        );
    }
}

void probeMessageView(void *messageView) {
    const std::vector<uint64_t> messageIds = recalledMessageSnapshot();
    if (messageIds.empty()) {
        return;
    }

    const std::vector<void *> descendants = qtObjectDescendants(messageView);
    for (void *object : descendants) {
        const char *name = qtObjectClassName(object);
        if (name == nullptr || std::strstr(name, "ChatBubbleItemView") == nullptr) {
            continue;
        }
        uint64_t matchedId = 0;
        size_t ownerOffset = 0;
        size_t modelOffset = 0;
        if (!findMessageIdFromViewModel(
                object,
                messageIds,
                matchedId,
                ownerOffset,
                modelOffset
            )) {
            continue;
        }

        os_log_info(
            OS_LOG_DEFAULT,
            "WeChatTweak MessageView matched recalled bubble id=%{public}llu class=%{public}s owner_offset=0x%{public}zx model_offset=0x%{public}zx",
            static_cast<unsigned long long>(matchedId),
            name,
            ownerOffset,
            modelOffset
        );
        void *hierarchyObject = object;
        for (unsigned depth = 0; hierarchyObject != nullptr && depth < 6; depth += 1) {
            const char *hierarchyName = qtObjectClassName(hierarchyObject);
            os_log_info(
                OS_LOG_DEFAULT,
                "WeChatTweak matched hierarchy depth=%{public}u class=%{public}s",
                depth,
                hierarchyName == nullptr ? "<unknown>" : hierarchyName
            );
            hierarchyObject = qtObjectParent(hierarchyObject);
        }
        return;
    }
}

bool hookedMessageViewEvent(void *messageView, void *event) {
    if (originalMessageViewEvent == nullptr) {
        return false;
    }
    rememberMessageView(messageView);
    return originalMessageViewEvent(messageView, event);
}

int hookedMessageViewMetaCall(void *messageView, int call, int methodId, void **arguments) {
    if (originalMessageViewMetaCall == nullptr) {
        return methodId;
    }
    rememberMessageView(messageView);
    return originalMessageViewMetaCall(messageView, call, methodId, arguments);
}

size_t installMessageViewHooks(
    intptr_t slide,
    uintptr_t imageStart,
    size_t imageSize
) {
    const uintptr_t scanStart = static_cast<uintptr_t>(slide) + dataConstStartOffset;
    if (!rangeContains(imageStart, imageSize, scanStart, dataConstSize) ||
        !isAddressRangeReadable(reinterpret_cast<const void *>(scanStart), dataConstSize)) {
        return 0;
    }

    const void *expectedMetaObject = reinterpret_cast<const void *>(
        static_cast<uintptr_t>(slide) + messageViewMetaObjectOffset
    );
    const void *expectedMetaCast = reinterpret_cast<const void *>(
        static_cast<uintptr_t>(slide) + messageViewMetaCastOffset
    );
    void *expectedMetaCall = reinterpret_cast<void *>(
        static_cast<uintptr_t>(slide) + messageViewMetaCallOffset
    );
    void *expectedEvent = reinterpret_cast<void *>(
        static_cast<uintptr_t>(slide) + messageViewEventOffset
    );
    expectedMessageViewMetaObject = const_cast<void *>(expectedMetaObject);
    expectedMessageViewMetaCast = const_cast<void *>(expectedMetaCast);
    expectedMessageViewMetaCall = expectedMetaCall;

    size_t installedCount = 0;
    for (size_t offset = 0; offset + 8 * sizeof(void *) <= dataConstSize; offset += sizeof(void *)) {
        auto **vtable = reinterpret_cast<void **>(scanStart + offset);
        if (vtable[0] != expectedMetaObject || vtable[1] != expectedMetaCast ||
            vtable[2] != expectedMetaCall) {
            continue;
        }

        if (originalMessageViewMetaCall == nullptr) {
            originalMessageViewMetaCall = reinterpret_cast<MessageViewMetaCall>(vtable[2]);
        }
        if (originalMessageViewEvent == nullptr && vtable[qObjectEventVtableIndex] == expectedEvent) {
            originalMessageViewEvent = reinterpret_cast<MessageViewEvent>(
                vtable[qObjectEventVtableIndex]
            );
        }

        bool installedMetaCall = writeHookSlot(
            vtable + 2,
            reinterpret_cast<void *>(&hookedMessageViewMetaCall)
        );
        bool installedEvent = false;
        if (vtable[qObjectEventVtableIndex] == expectedEvent) {
            installedEvent = writeHookSlot(
                vtable + qObjectEventVtableIndex,
                reinterpret_cast<void *>(&hookedMessageViewEvent)
            );
        }
        if (installedMetaCall || installedEvent) {
            installedCount += 1;
        }
    }
    return installedCount;
}

size_t installChatBubbleEventHooks(
    intptr_t slide,
    uintptr_t imageStart,
    size_t imageSize
) {
    const uintptr_t scanStart = static_cast<uintptr_t>(slide) + dataConstStartOffset;
    if (!rangeContains(imageStart, imageSize, scanStart, dataConstSize) ||
        !isAddressRangeReadable(reinterpret_cast<const void *>(scanStart), dataConstSize)) {
        return 0;
    }

    const void *expectedMetaObject = reinterpret_cast<const void *>(
        static_cast<uintptr_t>(slide) + chatBubbleMetaObjectOffset
    );
    const void *expectedMetaCast = reinterpret_cast<const void *>(
        static_cast<uintptr_t>(slide) + chatBubbleMetaCastOffset
    );
    const void *expectedMetaCall = reinterpret_cast<const void *>(
        static_cast<uintptr_t>(slide) + chatBubbleMetaCallOffset
    );
    void *expectedEvent = reinterpret_cast<void *>(
        static_cast<uintptr_t>(slide) + chatBubbleEventOffset
    );
    expectedChatBubbleMetaObject = const_cast<void *>(expectedMetaObject);
    expectedChatBubbleMetaCast = const_cast<void *>(expectedMetaCast);
    expectedChatBubbleMetaCall = const_cast<void *>(expectedMetaCall);

    size_t installedCount = 0;
    size_t installedBindingCallbackCount = 0;
    for (size_t offset = 0;
         offset + (chatBubbleBindingCallbackVtableIndex + 1) * sizeof(void *) <=
             dataConstSize;
         offset += sizeof(void *)) {
        auto **vtable = reinterpret_cast<void **>(scanStart + offset);
        if (vtable[0] != expectedMetaObject || vtable[1] != expectedMetaCast ||
            vtable[2] != expectedMetaCall) {
            continue;
        }

        bool installedBindingCallback = false;
        void **bindingCallbackSlot = vtable + chatBubbleBindingCallbackVtableIndex;
        if (*bindingCallbackSlot == reinterpret_cast<void *>(
                &hookedChatBubbleBindingCallback
            )) {
            installedBindingCallback = true;
        } else if (*bindingCallbackSlot != nullptr) {
            const auto original = reinterpret_cast<ChatBubbleBindMessageModel>(
                *bindingCallbackSlot
            );
            {
                std::lock_guard<std::mutex> lock(chatBubbleBindingCallbackMutex);
                originalChatBubbleBindingCallbacks[vtable] = original;
            }
            installedBindingCallback = writeHookSlot(
                bindingCallbackSlot,
                reinterpret_cast<void *>(&hookedChatBubbleBindingCallback)
            );
            if (!installedBindingCallback) {
                std::lock_guard<std::mutex> lock(chatBubbleBindingCallbackMutex);
                originalChatBubbleBindingCallbacks.erase(vtable);
            }
        }
        if (installedBindingCallback) {
            installedBindingCallbackCount += 1;
        }

        void **eventSlot = vtable + qObjectEventVtableIndex;
        bool installedEvent = false;
        if (*eventSlot == reinterpret_cast<void *>(&hookedChatBubbleEvent)) {
            installedEvent = true;
        } else if (*eventSlot == expectedEvent) {
            if (originalChatBubbleEvent == nullptr) {
                originalChatBubbleEvent = reinterpret_cast<ChatBubbleEvent>(*eventSlot);
            }
            installedEvent = writeHookSlot(
                eventSlot,
                reinterpret_cast<void *>(&hookedChatBubbleEvent)
            );
        }
        if (installedEvent || installedBindingCallback) {
            installedCount += 1;
        }
    }
    os_log_info(
        OS_LOG_DEFAULT,
        "WeChatTweak hooked %{public}zu chat bubble binding callbacks",
        installedBindingCallbackCount
    );
    return installedCount;
}

bool installChatBubblePaintHook(
    intptr_t slide,
    uintptr_t imageStart,
    size_t imageSize
) {
    const uintptr_t slotAddress = static_cast<uintptr_t>(slide) + chatBubbleFramePaintSlotOffset;
    if (!rangeContains(imageStart, imageSize, slotAddress, sizeof(void *)) ||
        !isAddressRangeReadable(reinterpret_cast<const void *>(slotAddress), sizeof(void *))) {
        return false;
    }

    auto **slot = reinterpret_cast<void **>(slotAddress);
    if (*slot == reinterpret_cast<void *>(&hookedChatBubblePaint)) {
        return true;
    }
    const uintptr_t expectedPaintAddress = static_cast<uintptr_t>(slide) + chatBubbleFramePaintOffset;
    if (*slot != reinterpret_cast<void *>(expectedPaintAddress)) {
        os_log_error(OS_LOG_DEFAULT, "WeChatTweak refused an unexpected ChatBubbleFrame paint slot");
        return false;
    }

    originalChatBubblePaint = reinterpret_cast<ChatBubblePaint>(*slot);
    if (!writeHookSlot(slot, reinterpret_cast<void *>(&hookedChatBubblePaint))) {
        originalChatBubblePaint = nullptr;
        return false;
    }
    return true;
}

bool hookedParseRevokeXML(void *message, std::string *xml, void *flag) {
    if (originalParseRevokeXML == nullptr) {
        return false;
    }

    uint64_t incomingMessageId = 0;
    if (message != nullptr) {
        const auto *incomingNewMsgId = reinterpret_cast<const uint64_t *>(
            reinterpret_cast<const uint8_t *>(message) + newMsgIdOffset
        );
        if (isAddressRangeReadable(incomingNewMsgId, sizeof(*incomingNewMsgId))) {
            std::memcpy(&incomingMessageId, incomingNewMsgId, sizeof(incomingMessageId));
        }
    }

    const bool result = originalParseRevokeXML(message, xml, flag);
    const bool revokeXML = isRevokeXML(xml);
    if (revokeXML) {
        os_log_info(OS_LOG_DEFAULT, "WeChatTweak observed a revoke event; parser result=%{public}d", result);
    }
    if (!result || message == nullptr || !revokeXML) {
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

    const uint64_t objectMessageId = *newMsgId;
    uint64_t xmlMessageId = 0;
    const bool hasXMLMessageId = revokeNewMsgId(*xml, xmlMessageId);
    std::vector<uint64_t> candidateMessageIds;
    const auto addCandidate = [&candidateMessageIds](uint64_t candidate) {
        if (candidate != 0 &&
            std::find(candidateMessageIds.begin(), candidateMessageIds.end(), candidate) ==
                candidateMessageIds.end()) {
            candidateMessageIds.push_back(candidate);
        }
    };
    addCandidate(xmlMessageId);
    addCandidate(incomingMessageId);
    addCandidate(objectMessageId);
    constexpr const char *alternateIdTags[] = {
        "msgid", "msgId", "MsgId", "svrmsgid", "svrMsgId", "msgsvrid",
    };
    for (const char *tag : alternateIdTags) {
        uint64_t alternateId = 0;
        if (parseUnsignedTag(*xml, tag, alternateId)) {
            addCandidate(alternateId);
        }
    }
    for (uint64_t candidateMessageId : candidateMessageIds) {
        rememberRecalledMessage(candidateMessageId);
        highlightAndColorRecalledMessage(candidateMessageId);
    }
    if (candidateMessageIds.empty()) {
        os_log_info(OS_LOG_DEFAULT, "WeChatTweak could not resolve recalled message id");
    } else {
        os_log_info(
            OS_LOG_DEFAULT,
            "WeChatTweak resolved %{public}zu recalled message id candidate(s) xml=%{public}d incoming=%{public}d object=%{public}d",
            candidateMessageIds.size(),
            hasXMLMessageId,
            incomingMessageId != 0,
            objectMessageId != 0
        );
    }

    const uint64_t realNewMsgId = hasXMLMessageId ? xmlMessageId : objectMessageId;

    const std::string originalTip = *replaceMsg;
    if (isSelfRecall(originalTip) || isSelfRecall(*xml)) {
        if (realNewMsgId != 0) {
            *newMsgId = realNewMsgId;
        }
        os_log_info(OS_LOG_DEFAULT, "WeChatTweak left a self-recall tip unchanged");
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
    expectedChatBubbleFrameVtable = static_cast<uintptr_t>(slide) +
        chatBubbleFrameVtableOffset;
    expectedChatBubbleMetaObject = reinterpret_cast<void *>(
        static_cast<uintptr_t>(slide) + chatBubbleMetaObjectOffset
    );
    expectedChatBubbleMetaCast = reinterpret_cast<void *>(
        static_cast<uintptr_t>(slide) + chatBubbleMetaCastOffset
    );
    expectedChatBubbleMetaCall = reinterpret_cast<void *>(
        static_cast<uintptr_t>(slide) + chatBubbleMetaCallOffset
    );
    expectedChatItemMetaObject = reinterpret_cast<void *>(
        static_cast<uintptr_t>(slide) + chatItemMetaObjectOffset
    );
    expectedChatItemMetaCast = reinterpret_cast<void *>(
        static_cast<uintptr_t>(slide) + chatItemMetaCastOffset
    );
    expectedChatItemMetaCall = reinterpret_cast<void *>(
        static_cast<uintptr_t>(slide) + chatItemMetaCallOffset
    );
    setChatBubbleColor = reinterpret_cast<ChatBubbleSetColor>(
        static_cast<uintptr_t>(slide) + chatBubbleSetColorOffset
    );
    setChatBubbleAnimationColor = reinterpret_cast<ChatBubbleSetAnimationColor>(
        static_cast<uintptr_t>(slide) + chatBubbleSetAnimationColorOffset
    );
    initializeChatItemPainter = reinterpret_cast<ChatItemPainterInit>(
        static_cast<uintptr_t>(slide) + chatItemPainterInitOffset
    );
    fillChatItemRect = reinterpret_cast<ChatItemFillRect>(
        static_cast<uintptr_t>(slide) + chatItemFillRectOffset
    );
    destroyChatItemPainter = reinterpret_cast<ChatItemPainterDestroy>(
        static_cast<uintptr_t>(slide) + chatItemPainterDestroyOffset
    );
    messageModelItemView = reinterpret_cast<MessageModelItemView>(
        static_cast<uintptr_t>(slide) + messageModelItemViewOffset
    );
    initializeMessageUniqueId = reinterpret_cast<MessageUniqueIdInit>(
        static_cast<uintptr_t>(slide) + messageUniqueIdInitOffset
    );
    navigateToMessageAndHighlight = reinterpret_cast<NavigateToMessageAndHighlight>(
        static_cast<uintptr_t>(slide) + navigateToMessageAndHighlightOffset
    );
    isMessageWidgetVisible = reinterpret_cast<IsMessageWidgetVisible>(
        static_cast<uintptr_t>(slide) + isMessageWidgetVisibleOffset
    );
    if (!installNativeMessageHighlightHook(slide, imageStart, imageSize)) {
        os_log_error(OS_LOG_DEFAULT, "WeChatTweak could not hook the native highlight target");
    }
    if (!installChatBubbleBindMessageModelHook(slide, imageStart, imageSize)) {
        os_log_error(
            OS_LOG_DEFAULT,
            "WeChatTweak could not hook ChatItemView message-model binding"
        );
    }
    if (!installChatBubbleItemConstructorHook(slide, imageStart, imageSize)) {
        os_log_error(
            OS_LOG_DEFAULT,
            "WeChatTweak could not hook ChatItemView construction"
        );
    }
    if (!installChatBubbleItemDestructorHook(slide, imageStart, imageSize)) {
        os_log_error(
            OS_LOG_DEFAULT,
            "WeChatTweak could not hook ChatItemView destruction"
        );
    }
    if (!installChatItemPaintHook(slide, imageStart, imageSize)) {
        os_log_error(OS_LOG_DEFAULT, "WeChatTweak could not hook ChatItemView paint event");
    }
    const size_t messageViewHookCount = installMessageViewHooks(slide, imageStart, imageSize);
    if (messageViewHookCount == 0) {
        os_log_error(OS_LOG_DEFAULT, "WeChatTweak could not enable native recalled-message highlighting");
    } else {
        os_log_info(
            OS_LOG_DEFAULT,
            "WeChatTweak enabled native recalled-message highlighting on %{public}zu MessageView types",
            messageViewHookCount
        );
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
