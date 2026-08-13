#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <IOKit/hid/IOHIDManager.h>
#import <time.h>

static IOHIDDeviceRef activeDevice;
static NSMutableArray<NSNumber *> *featureReportIDs;
static NSTimer *pollTimer;
static BOOL readOnce;
static NSTimeInterval pollInterval;
static BOOL listExitScheduled;
static id wakeObserver;

static double monotonicSeconds(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (double)now.tv_sec + (double)now.tv_nsec / 1000000000.0;
}

static int intProperty(IOHIDDeviceRef device, CFStringRef key) {
    CFTypeRef value = IOHIDDeviceGetProperty(device, key);
    if (!value || CFGetTypeID(value) != CFNumberGetTypeID()) return 0;

    int result = 0;
    CFNumberGetValue((CFNumberRef)value, kCFNumberIntType, &result);
    return result;
}

static NSString *stringProperty(IOHIDDeviceRef device, CFStringRef key) {
    CFTypeRef value = IOHIDDeviceGetProperty(device, key);
    return value ? [NSString stringWithFormat:@"%@", value] : @"";
}

static NSString *hexString(const uint8_t *bytes, CFIndex length) {
    NSMutableString *result = [NSMutableString stringWithCapacity:(NSUInteger)length * 3];
    for (CFIndex i = 0; i < length; i++) {
        [result appendFormat:@"%02X%@", bytes[i], i + 1 == length ? @"" : @" "];
    }
    return result;
}

static const char *elementTypeName(IOHIDElementType type) {
    switch (type) {
        case kIOHIDElementTypeInput_Misc: return "input";
        case kIOHIDElementTypeInput_Button: return "button";
        case kIOHIDElementTypeInput_Axis: return "axis";
        case kIOHIDElementTypeInput_ScanCodes: return "scan";
        case kIOHIDElementTypeInput_NULL: return "null";
        case kIOHIDElementTypeOutput: return "output";
        case kIOHIDElementTypeFeature: return "feature";
        case kIOHIDElementTypeCollection: return "collection";
    }
    return "unknown";
}

static void readFeatureReports(void) {
    if (!activeDevice || featureReportIDs.count == 0) return;

    int maxLength = intProperty(activeDevice, CFSTR(kIOHIDMaxFeatureReportSizeKey));
    if (maxLength < 1) maxLength = 256;

    for (NSNumber *number in featureReportIDs) {
        uint32_t reportID = number.unsignedIntValue;
        CFIndex length = maxLength;
        uint8_t *buffer = calloc((size_t)length, sizeof(uint8_t));
        buffer[0] = (uint8_t)reportID;

        IOReturn result = IOHIDDeviceGetReport(activeDevice,
                                                kIOHIDReportTypeFeature,
                                                reportID,
                                                buffer,
                                                &length);
        if (result == kIOReturnSuccess) {
            NSString *hex = hexString(buffer, length);
            printf("READ t=%.3f report=0x%02X len=%ld bytes=%s\n",
                   monotonicSeconds(), reportID, (long)length, hex.UTF8String);
        } else {
            printf("READ t=%.3f report=0x%02X error=0x%08X\n",
                   monotonicSeconds(), reportID, result);
        }
        free(buffer);
    }
    fflush(stdout);

    if (readOnce) CFRunLoopStop(CFRunLoopGetMain());
}

static void readAfterWake(void) {
    printf("WAKE t=%.3f refreshing remote connection\n", monotonicSeconds());
    fflush(stdout);

    readFeatureReports();
    [NSTimer scheduledTimerWithTimeInterval:1.0
                                    repeats:NO
                                      block:^(NSTimer *timer) {
        (void)timer;
        readFeatureReports();
    }];
    [NSTimer scheduledTimerWithTimeInterval:5.0
                                    repeats:NO
                                      block:^(NSTimer *timer) {
        (void)timer;
        readFeatureReports();
    }];
}

static void inputValueCallback(void *context, IOReturn result, void *sender, IOHIDValueRef value) {
    (void)context;
    (void)sender;
    if (result != kIOReturnSuccess) return;

    IOHIDElementRef element = IOHIDValueGetElement(value);
    if (IOHIDElementGetUsagePage(element) != 0x0C || IOHIDElementGetUsage(element) != 0x04) return;

    printf("MIC t=%.3f %s\n",
           monotonicSeconds(), IOHIDValueGetIntegerValue(value) ? "PRESSED" : "RELEASED");
    fflush(stdout);
}

static NSArray<NSNumber *> *enumerateDevice(IOHIDDeviceRef device, BOOL *hasMicButton) {
    NSString *product = stringProperty(device, CFSTR(kIOHIDProductKey));
    NSString *serial = stringProperty(device, CFSTR(kIOHIDSerialNumberKey));
    NSString *transport = stringProperty(device, CFSTR(kIOHIDTransportKey));
    int maxFeature = intProperty(device, CFSTR(kIOHIDMaxFeatureReportSizeKey));

    printf("DEVICE product=%s serial=%s transport=%s maxFeature=%d\n",
           product.UTF8String, serial.UTF8String, transport.UTF8String, maxFeature);

    CFTypeRef descriptorValue = IOHIDDeviceGetProperty(device, CFSTR(kIOHIDReportDescriptorKey));
    if (descriptorValue && CFGetTypeID(descriptorValue) == CFDataGetTypeID()) {
        CFDataRef descriptor = (CFDataRef)descriptorValue;
        NSString *hex = hexString(CFDataGetBytePtr(descriptor), CFDataGetLength(descriptor));
        printf("DESCRIPTOR len=%ld bytes=%s\n", (long)CFDataGetLength(descriptor), hex.UTF8String);
    }

    NSMutableArray<NSNumber *> *reportIDs = [NSMutableArray array];
    *hasMicButton = NO;
    CFArrayRef elements = IOHIDDeviceCopyMatchingElements(device, NULL, kIOHIDOptionsTypeNone);
    if (!elements) return reportIDs;

    CFIndex count = CFArrayGetCount(elements);
    for (CFIndex i = 0; i < count; i++) {
        IOHIDElementRef element = (IOHIDElementRef)CFArrayGetValueAtIndex(elements, i);
        IOHIDElementType type = IOHIDElementGetType(element);
        uint32_t reportID = IOHIDElementGetReportID(element);
        printf("ELEMENT type=%s report=0x%02X page=0x%04X usage=0x%04X bits=%u count=%u\n",
               elementTypeName(type), reportID,
               IOHIDElementGetUsagePage(element), IOHIDElementGetUsage(element),
               IOHIDElementGetReportSize(element), IOHIDElementGetReportCount(element));

        if (IOHIDElementGetUsagePage(element) == 0x0C &&
            IOHIDElementGetUsage(element) == 0x04 &&
            IOHIDElementGetReportID(element) == 0xFA) {
            *hasMicButton = YES;
        }

        if (type == kIOHIDElementTypeFeature && ![reportIDs containsObject:@(reportID)]) {
            [reportIDs addObject:@(reportID)];
        }
    }
    CFRelease(elements);
    fflush(stdout);
    return reportIDs;
}

static void deviceMatchedCallback(void *context, IOReturn result, void *sender, IOHIDDeviceRef device) {
    (void)context;
    (void)sender;
    if (result != kIOReturnSuccess) return;

    BOOL hasMicButton = NO;
    NSArray<NSNumber *> *reportIDs = enumerateDevice(device, &hasMicButton);
    if (!readOnce && pollInterval == 0) {
        if (!listExitScheduled) {
            listExitScheduled = YES;
            [NSTimer scheduledTimerWithTimeInterval:0.5
                                            repeats:NO
                                              block:^(NSTimer *timer) {
                (void)timer;
                CFRunLoopStop(CFRunLoopGetMain());
            }];
        }
        return;
    }

    if (activeDevice) return;

    int maxFeature = intProperty(device, CFSTR(kIOHIDMaxFeatureReportSizeKey));
    if (!hasMicButton || ![reportIDs containsObject:@0xFF] || maxFeature > 256) {
        printf("SKIP not the mic-button feature interface\n");
        fflush(stdout);
        return;
    }

    IOReturn openResult = IOHIDDeviceOpen(device, kIOHIDOptionsTypeNone);
    if (openResult != kIOReturnSuccess) {
        fprintf(stderr, "IOHIDDeviceOpen failed: 0x%08X\n", openResult);
        return;
    }

    activeDevice = device;
    CFRetain(activeDevice);
    featureReportIDs = [reportIDs mutableCopy];

    if (featureReportIDs.count == 0) {
        fputs("No descriptor-declared feature reports found.\n", stderr);
        if (readOnce || pollInterval == 0) CFRunLoopStop(CFRunLoopGetMain());
        return;
    }

    if (readOnce) {
        readFeatureReports();
    } else if (pollInterval > 0) {
        readFeatureReports();
        pollTimer = [NSTimer scheduledTimerWithTimeInterval:pollInterval
                                                    repeats:YES
                                                      block:^(NSTimer *timer) {
            (void)timer;
            readFeatureReports();
        }];
        printf("Polling every %.1f seconds. Ctrl-C to stop.\n", pollInterval);
        fflush(stdout);
    } else {
        CFRunLoopStop(CFRunLoopGetMain());
    }
}

static void deviceRemovedCallback(void *context, IOReturn result, void *sender, IOHIDDeviceRef device) {
    (void)context;
    (void)result;
    (void)sender;
    if (device != activeDevice) return;

    printf("DEVICE_REMOVED t=%.3f\n", monotonicSeconds());
    fflush(stdout);
    [pollTimer invalidate];
    pollTimer = nil;
    IOHIDDeviceClose(activeDevice, kIOHIDOptionsTypeNone);
    CFRelease(activeDevice);
    activeDevice = NULL;
}

static void printUsage(const char *program) {
    printf("Usage:\n");
    printf("  %s --list\n", program);
    printf("  %s --once\n", program);
    printf("  %s --interval SECONDS\n", program);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc == 2 && (strcmp(argv[1], "--help") == 0 || strcmp(argv[1], "-h") == 0)) {
            printUsage(argv[0]);
            return 0;
        } else if (argc == 2 && strcmp(argv[1], "--list") == 0) {
            pollInterval = 0;
        } else if (argc == 2 && strcmp(argv[1], "--once") == 0) {
            readOnce = YES;
        } else if (argc == 3 && strcmp(argv[1], "--interval") == 0) {
            pollInterval = strtod(argv[2], NULL);
            if (pollInterval < 1) {
                fputs("Interval must be at least one second.\n", stderr);
                return 2;
            }
        } else {
            printUsage(argv[0]);
            return argc == 1 ? 0 : 2;
        }

        featureReportIDs = [NSMutableArray array];
        IOHIDManagerRef manager = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
        NSDictionary *match = @{
            @kIOHIDVendorIDKey: @76,
            @kIOHIDProductIDKey: @621
        };
        IOHIDManagerSetDeviceMatching(manager, (__bridge CFDictionaryRef)match);
        IOHIDManagerRegisterDeviceMatchingCallback(manager, deviceMatchedCallback, NULL);
        IOHIDManagerRegisterDeviceRemovalCallback(manager, deviceRemovedCallback, NULL);
        IOHIDManagerRegisterInputValueCallback(manager, inputValueCallback, NULL);
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), kCFRunLoopDefaultMode);

        IOReturn openResult = IOHIDManagerOpen(manager, kIOHIDOptionsTypeNone);
        if (openResult != kIOReturnSuccess) {
            fprintf(stderr, "IOHIDManagerOpen failed: 0x%08X\n", openResult);
            CFRelease(manager);
            return 1;
        }

        wakeObserver = [[[NSWorkspace sharedWorkspace] notificationCenter]
            addObserverForName:NSWorkspaceDidWakeNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *notification) {
            (void)notification;
            readAfterWake();
        }];

        puts("Waiting for A1962 (vendor 0x004C, product 0x026D). Press a remote button if disconnected.");
        CFRunLoopRun();

        [[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver:wakeObserver];
        [pollTimer invalidate];
        if (activeDevice) {
            IOHIDDeviceClose(activeDevice, kIOHIDOptionsTypeNone);
            CFRelease(activeDevice);
        }
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
        IOHIDManagerClose(manager, kIOHIDOptionsTypeNone);
        CFRelease(manager);
    }
    return 0;
}
