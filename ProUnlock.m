// ProUnlock.dylib — EverythingWx Pro unlock + telemetry kill (Feather injectable)
// Pure ObjC, zero dependencies (no Substrate/ElleKit needed).
// Hooks NSURLSession at the completion-handler layer:
//  - spoofs RevenueCat's GET /v1/subscribers/<id> with an active "pro"
//    entitlement (verified working via proxy: 200 + 869-byte body).
//  - blackholes pure-telemetry hosts (Firebase Analytics, Crashlytics,
//    install/logging heartbeats) with an empty 204 so nothing leaves.
// Untouched: weather data, alerts backend, Firestore sync, iCloud.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static NSString * const kProCustomerInfoJSON =
@"{"
@"\"request_date\":\"2030-01-01T00:00:00Z\","
@"\"request_date_ms\":1893456000000,"
@"\"subscriber\":{"
@"\"entitlements\":{"
@"\"pro\":{"
@"\"expires_date\":\"2030-01-01T00:00:00Z\","
@"\"grace_period_expires_date\":null,"
@"\"product_identifier\":\"wiseweather_pro_lifetime\","
@"\"purchase_date\":\"2024-01-01T00:00:00Z\"}},"
@"\"first_seen\":\"2024-01-01T00:00:00Z\","
@"\"management_url\":null,"
@"\"non_subscriptions\":{},"
@"\"original_app_user_id\":\"spoofed\","
@"\"original_application_version\":\"681\","
@"\"original_purchase_date\":\"2024-01-01T00:00:00Z\","
@"\"other_purchases\":{},"
@"\"subscriptions\":{"
@"\"wiseweather_pro_lifetime\":{"
@"\"billing_issues_detected_at\":null,"
@"\"expires_date\":\"2030-01-01T00:00:00Z\","
@"\"grace_period_expires_date\":null,"
@"\"is_sandbox\":false,"
@"\"original_purchase_date\":\"2024-01-01T00:00:00Z\","
@"\"ownership_type\":\"PURCHASED\","
@"\"period_type\":\"normal\","
@"\"purchase_date\":\"2024-01-01T00:00:00Z\","
@"\"refunded_at\":null,"
@"\"store\":\"app_store\","
@"\"unsubscribe_detected_at\":null}}"
@"}}";

static BOOL ProUnlockShouldSpoof(NSURL *url) {
    if (url == nil) return NO;
    NSString *host = url.host ?: @"";
    NSString *path = url.path ?: @"";
    if ([host rangeOfString:@"revenuecat.com"].location == NSNotFound) return NO;
    if ([path rangeOfString:@"/v1/subscribers"].location == NSNotFound) return NO;
    if ([path rangeOfString:@"/offerings"].location != NSNotFound) return NO;
    if ([path rangeOfString:@"/attributes"].location != NSNotFound) return NO;
    return YES;
}

static BOOL ProUnlockIsTelemetry(NSURL *url) {
    if (url == nil) return NO;
    NSString *host = url.host ?: @"";
    static NSString *blocked[] = {
        @"app-measurement.com",
        @"firebaselogging-pa.googleapis.com",
        @"crashlytics.com",
        @"crashlyticsreports-pa.googleapis.com",
        @"settings.crashlytics.com",
        @"firebase-settings.crashlytics.com",
    };
    for (unsigned i = 0; i < sizeof(blocked) / sizeof(blocked[0]); i++) {
        if ([host rangeOfString:blocked[i]].location != NSNotFound) return YES;
    }
    return NO;
}

// Wraps the original completion block, swapping in our CustomerInfo body.
static void (^ProUnlockWrapCompletion(void (^orig)(NSData *, NSURLResponse *, NSError *)))(NSData *, NSURLResponse *, NSError *) {
    if (orig == nil) return nil;
    void (^wrapped)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *response, NSError *error) {
        NSData *proData = [kProCustomerInfoJSON dataUsingEncoding:NSUTF8StringEncoding];
        orig(proData, response, error);
    };
    return [wrapped copy];
}

// Wraps completion with an empty 204 — telemetry dies, app moves on.
static void (^ProUnlockWrapBlackhole(void (^orig)(NSData *, NSURLResponse *, NSError *)))(NSData *, NSURLResponse *, NSError *) {
    if (orig == nil) return nil;
    void (^wrapped)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *empty = [[NSHTTPURLResponse alloc] initWithURL:response.URL
                                                               statusCode:204
                                                              HTTPVersion:@"HTTP/1.1"
                                                             headerFields:@{}];
        orig([NSData data], empty, nil);
    };
    return [wrapped copy];
}

static NSURLSessionDataTask * (*orig_dataTaskWithRequestCompletion)(id, SEL, NSURLRequest *, void (^)(NSData *, NSURLResponse *, NSError *));
static NSURLSessionDataTask * (*orig_dataTaskWithURLCompletion)(id, SEL, NSURL *, void (^)(NSData *, NSURLResponse *, NSError *));

static NSURLSessionDataTask * sw_dataTaskWithRequestCompletion(id self, SEL _cmd, NSURLRequest *request, void (^completion)(NSData *, NSURLResponse *, NSError *)) {
    if (ProUnlockIsTelemetry(request.URL)) {
        completion = ProUnlockWrapBlackhole(completion);
    } else if (ProUnlockShouldSpoof(request.URL)) {
        completion = ProUnlockWrapCompletion(completion);
    }
    return orig_dataTaskWithRequestCompletion(self, _cmd, request, completion);
}

static NSURLSessionDataTask * sw_dataTaskWithURLCompletion(id self, SEL _cmd, NSURL *url, void (^completion)(NSData *, NSURLResponse *, NSError *)) {
    if (ProUnlockIsTelemetry(url)) {
        completion = ProUnlockWrapBlackhole(completion);
    } else if (ProUnlockShouldSpoof(url)) {
        completion = ProUnlockWrapCompletion(completion);
    }
    return orig_dataTaskWithURLCompletion(self, _cmd, url, completion);
}

__attribute__((constructor)) static void ProUnlockInit(void) {
    Class cls = [NSURLSession class];
    {
        SEL sel = @selector(dataTaskWithRequest:completionHandler:);
        Method m = class_getInstanceMethod(cls, sel);
        orig_dataTaskWithRequestCompletion = (void *)method_getImplementation(m);
        method_setImplementation(m, (IMP)sw_dataTaskWithRequestCompletion);
    }
    {
        SEL sel = @selector(dataTaskWithURL:completionHandler:);
        Method m = class_getInstanceMethod(cls, sel);
        orig_dataTaskWithURLCompletion = (void *)method_getImplementation(m);
        method_setImplementation(m, (IMP)sw_dataTaskWithURLCompletion);
    }
    NSLog(@"[ProUnlock] loaded, pro spoof + telemetry kill active");
}
