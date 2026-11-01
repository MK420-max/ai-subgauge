// Adapted from Stash. Copyright (c) 2026 Brent Ceulemans. MIT; see LICENSE.
#import "include/STMenuBarShim.h"
#import <dlfcn.h>
#import <objc/message.h>
#import <ApplicationServices/ApplicationServices.h>

@implementation STMenuBarShim
+ (BOOL)isAvailable {
    static BOOL loaded;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        loaded = dlopen("/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore", RTLD_NOW) != NULL;
    });
    return loaded && NSClassFromString(@"MBAssessmentModeConfiguration") && NSClassFromString(@"MBAssessmentModeAssertion");
}
+ (nullable id)activateWithAllowedBundleIdentifiers:(NSArray<NSString *> *)bundleIdentifiers
                                allowedSystemItems:(NSArray<NSNumber *> *)systemItems
                                        completion:(void (^)(NSError * _Nullable))completion {
    @try {
        if (![self isAvailable]) { return nil; }
        Class configClass = NSClassFromString(@"MBAssessmentModeConfiguration");
        SEL initSel = NSSelectorFromString(@"initWithAllowedSystemItems:allowedBundleIdentifiers:");
        if (![configClass instancesRespondToSelector:initSel]) { return nil; }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        id config = [[configClass alloc] performSelector:initSel withObject:systemItems withObject:bundleIdentifiers];
#pragma clang diagnostic pop
        if (!config) { return nil; }
        id assertion = [[NSClassFromString(@"MBAssessmentModeAssertion") alloc] init];
        SEL selector = NSSelectorFromString(@"activateWithConfiguration:completionHandler:");
        if (![assertion respondsToSelector:selector]) { return nil; }
        NSMethodSignature *signature = [assertion methodSignatureForSelector:selector];
        if (!signature || signature.numberOfArguments != 4) { return nil; }
        NSInvocation *call = [NSInvocation invocationWithMethodSignature:signature];
        call.target = assertion;
        call.selector = selector;
        [call setArgument:&config atIndex:2];
        id handler = [completion copy];
        [call setArgument:&handler atIndex:3];
        [call retainArguments];
        [call invoke];
        return assertion;
    } @catch (NSException *exception) {
        completion([NSError errorWithDomain:@"MacMenuBarTidy" code:1 userInfo:@{NSLocalizedDescriptionKey: @"系统菜单栏接口拒绝了请求。"}]);
        return nil;
    }
}
+ (NSDictionary<NSString *, id> *)windowDiagnosticsForAccessibilityElement:(id)element {
    @try {
        CFTypeRef value = (__bridge CFTypeRef)element;
        if (!value || CFGetTypeID(value) != AXUIElementGetTypeID()) { return @{@"validAXElement": @NO}; }
        typedef AXError (*WindowLookup)(AXUIElementRef, CGWindowID *);
        static WindowLookup lookup;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            lookup = (WindowLookup)dlsym(RTLD_DEFAULT, "_AXUIElementGetWindow");
            if (!lookup) {
                void *framework = dlopen("/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices", RTLD_LAZY | RTLD_LOCAL);
                if (framework) { lookup = (WindowLookup)dlsym(framework, "_AXUIElementGetWindow"); }
            }
        });
        if (!lookup) { return @{@"symbolAvailable": @NO}; }
        CGWindowID windowID = 0;
        AXError result = lookup((AXUIElementRef)value, &windowID);
        return @{@"symbolAvailable": @YES, @"result": @(result), @"windowID": @(windowID)};
    } @catch (NSException *exception) {
        return @{@"exception": @YES};
    }
}

+ (void)invalidate:(nullable id)token {
    @try {
        SEL selector = NSSelectorFromString(@"invalidate");
        if ([token respondsToSelector:selector]) { ((void (*)(id, SEL))objc_msgSend)(token, selector); }
    } @catch (NSException *exception) { /* A token already discarded by macOS is safe to release. */ }
}
@end
