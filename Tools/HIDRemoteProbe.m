#import <Foundation/Foundation.h>
#import <IOKit/hid/IOHIDManager.h>

static NSString *stringProperty(IOHIDDeviceRef device, CFStringRef key) {
    CFTypeRef value = IOHIDDeviceGetProperty(device, key);
    if (!value) return @"";
    return [NSString stringWithFormat:@"%@", value];
}

static int intProperty(IOHIDDeviceRef device, CFStringRef key) {
    CFTypeRef value = IOHIDDeviceGetProperty(device, key);
    if (!value || CFGetTypeID(value) != CFNumberGetTypeID()) return 0;
    int result = 0;
    CFNumberGetValue((CFNumberRef)value, kCFNumberIntType, &result);
    return result;
}

static NSString *hexString(const uint8_t *bytes, CFIndex length) {
    NSMutableString *result = [NSMutableString stringWithCapacity:(NSUInteger)length * 3];
    for (CFIndex i = 0; i < length; i++) {
        [result appendFormat:@"%02X%@", bytes[i], i + 1 == length ? @"" : @" "];
    }
    return result;
}

static void inputValueCallback(void *context, IOReturn result, void *sender, IOHIDValueRef value) {
    (void)context;
    (void)sender;
    if (result != kIOReturnSuccess) return;

    IOHIDElementRef element = IOHIDValueGetElement(value);
    uint32_t page = IOHIDElementGetUsagePage(element);
    uint32_t usage = IOHIDElementGetUsage(element);
    CFIndex integerValue = IOHIDValueGetIntegerValue(value);
    uint32_t reportID = IOHIDElementGetReportID(element);

    printf("VALUE report=0x%02X page=0x%04X usage=0x%04X value=%ld\n",
           reportID, page, usage, (long)integerValue);
    fflush(stdout);
}

static void inputReportCallback(void *context,
                                IOReturn result,
                                void *sender,
                                IOHIDReportType type,
                                uint32_t reportID,
                                uint8_t *report,
                                CFIndex reportLength) {
    (void)context;
    (void)sender;
    if (result != kIOReturnSuccess || type != kIOHIDReportTypeInput) return;

    NSString *hex = hexString(report, reportLength);
    printf("REPORT id=0x%02X len=%ld bytes=%s\n",
           reportID, (long)reportLength, [hex UTF8String]);
    fflush(stdout);
}

static void deviceMatchedCallback(void *context, IOReturn result, void *sender, IOHIDDeviceRef device) {
    (void)sender;
    if (result != kIOReturnSuccess) return;

    NSString *product = stringProperty(device, CFSTR(kIOHIDProductKey));
    NSString *serial = stringProperty(device, CFSTR(kIOHIDSerialNumberKey));
    NSString *transport = stringProperty(device, CFSTR(kIOHIDTransportKey));
    int page = intProperty(device, CFSTR(kIOHIDPrimaryUsagePageKey));
    int usage = intProperty(device, CFSTR(kIOHIDPrimaryUsageKey));
    int location = intProperty(device, CFSTR(kIOHIDLocationIDKey));
    int maxInput = intProperty(device, CFSTR(kIOHIDMaxInputReportSizeKey));

    printf("MATCH product=%s serial=%s transport=%s page=0x%04X usage=0x%04X location=0x%X maxInput=%d\n",
           [product UTF8String], [serial UTF8String], [transport UTF8String],
           page, usage, location, maxInput);
    fflush(stdout);

    if (maxInput < 1) maxInput = 256;
    uint8_t *buffer = calloc((size_t)maxInput, sizeof(uint8_t));
    CFMutableArrayRef buffers = (CFMutableArrayRef)context;
    CFDataRef holder = CFDataCreateWithBytesNoCopy(kCFAllocatorDefault,
                                                   buffer,
                                                   maxInput,
                                                   kCFAllocatorMalloc);
    CFArrayAppendValue(buffers, holder);
    CFRelease(holder);

    IOHIDDeviceRegisterInputValueCallback(device, inputValueCallback, NULL);
    IOHIDDeviceRegisterInputReportCallback(device, buffer, maxInput, inputReportCallback, NULL);
}

int main(void) {
    @autoreleasepool {
        IOHIDManagerRef manager = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
        NSDictionary *match = @{
            @kIOHIDVendorIDKey: @76,
            @kIOHIDProductIDKey: @621
        };
    IOHIDManagerSetDeviceMatching(manager, (__bridge CFDictionaryRef)match);

        CFMutableArrayRef buffers = CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);
        IOHIDManagerRegisterDeviceMatchingCallback(manager, deviceMatchedCallback, buffers);
        IOHIDManagerRegisterInputValueCallback(manager, inputValueCallback, NULL);
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);

        IOReturn openResult = IOHIDManagerOpen(manager, kIOHIDOptionsTypeNone);
        printf("open=0x%08X\n", openResult);
        CFSetRef devices = IOHIDManagerCopyDevices(manager);
        if (devices) {
            CFIndex count = CFSetGetCount(devices);
            IOHIDDeviceRef *deviceList = calloc((size_t)count, sizeof(IOHIDDeviceRef));
            CFSetGetValues(devices, (const void **)deviceList);
            for (CFIndex i = 0; i < count; i++) {
                deviceMatchedCallback(buffers, kIOReturnSuccess, NULL, deviceList[i]);
            }
            free(deviceList);
            CFRelease(devices);
        }
        printf("Press remote buttons now. Ctrl-C to stop.\n");
        fflush(stdout);

        CFRunLoopRun();
        CFRelease(buffers);
        CFRelease(manager);
    }
    return 0;
}
