#import <Foundation/Foundation.h>
#import <IOKit/hid/IOHIDManager.h>

static int lastPressed = -1;

static void inputValueCallback(void *context, IOReturn result, void *sender, IOHIDValueRef value) {
    (void)context;
    (void)sender;
    if (result != kIOReturnSuccess) return;

    IOHIDElementRef element = IOHIDValueGetElement(value);
    if (IOHIDElementGetUsagePage(element) != 0x0C || IOHIDElementGetUsage(element) != 0x04) return;

    int pressed = IOHIDValueGetIntegerValue(value) != 0;
    if (pressed == lastPressed) return;
    lastPressed = pressed;
    fputs(pressed ? "EVENT button_pressed\n" : "EVENT button_released\n", stdout);
    fflush(stdout);
}

int main(void) {
    @autoreleasepool {
        IOHIDManagerRef manager = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
        NSDictionary *match = @{
            @kIOHIDVendorIDKey: @76,
            @kIOHIDProductIDKey: @621
        };
        IOHIDManagerSetDeviceMatching(manager, (__bridge CFDictionaryRef)match);
        IOHIDManagerRegisterInputValueCallback(manager, inputValueCallback, NULL);
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);

        IOReturn openResult = IOHIDManagerOpen(manager, kIOHIDOptionsTypeNone);
        if (openResult != kIOReturnSuccess) {
            fprintf(stderr, "IOHIDManagerOpen failed: 0x%08X\n", openResult);
            return 1;
        }

        CFRunLoopRun();
        CFRelease(manager);
    }
    return 0;
}
