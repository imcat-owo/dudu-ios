//
//  MapsOffload.m
//  MinisApp
//
//  Native offload handler for `apple-maps`.
//  Subcommands: search, route, eta
//

#import <Foundation/Foundation.h>
#import <MapKit/MapKit.h>
#import <CoreLocation/CoreLocation.h>
#import <UIKit/UIKit.h>
#import "NativeOffloadUtils.h"
#import "CoordinateUtils.h"
#include "kernel/native_offload.h"
#include <unistd.h>

static NSString *const TOOL_NAME = @"apple-maps";

static NSString *const HELP_TEXT =
    @"apple-maps - Search places, get directions, and estimate travel times\n"
     "\n"
     "USAGE:\n"
     "  apple-maps <command> [options]\n"
     "\n"
     "COMMANDS:\n"
     "  search      Search for places and points of interest\n"
     "  route       Get directions between two points\n"
     "  eta         Get estimated travel time (lightweight)\n"
     "\n"
     "COMMON OPTIONS:\n"
     "  --help, -h           Show this help message\n"
     "  --compact            Minimize JSON output\n"
     "  -q, --quiet          Output only data field\n"
     "\n"
     "SEARCH OPTIONS:\n"
     "  --query <text>       Search query (required)\n"
     "  --lat <degrees>      Center latitude (optional; default: current location)\n"
     "  --lon <degrees>      Center longitude (optional; default: current location)\n"
     "  --radius <m>         Search radius in meters (default 1000)\n"
     "  --limit <N>          Maximum results (default 10)\n"
     "\n"
     "ROUTE / ETA OPTIONS:\n"
     "  --from <addr|lat,lon>  Origin (required)\n"
     "  --to <addr|lat,lon>    Destination (required)\n"
     "  --mode <mode>          Transport: driving, walking, transit (default driving)\n"
     "\n"
     "EXAMPLES:\n"
     "  apple-maps search --query \"coffee shops\" --lat 37.7749 --lon -122.4194\n"
     "  apple-maps search --query \"gas station\" --radius 500 --limit 5\n"
     "  apple-maps route --from \"San Francisco\" --to \"Los Angeles\" --mode driving\n"
     "  apple-maps route --from 37.7749,-122.4194 --to 34.0522,-118.2437\n"
     "  apple-maps eta --from \"New York\" --to \"Boston\" --mode transit\n";

// ── Helpers ──

/// Try to parse a "lat,lon" string. Returns YES if successful.
static BOOL parse_lat_lon(NSString *str, CLLocationCoordinate2D *outCoord) {
    NSArray *parts = [str componentsSeparatedByString:@","];
    if (parts.count != 2) return NO;

    NSString *latStr = [parts[0] stringByTrimmingCharactersInSet:
                        [NSCharacterSet whitespaceCharacterSet]];
    NSString *lonStr = [parts[1] stringByTrimmingCharactersInSet:
                        [NSCharacterSet whitespaceCharacterSet]];

    NSScanner *latScanner = [NSScanner scannerWithString:latStr];
    NSScanner *lonScanner = [NSScanner scannerWithString:lonStr];
    double lat, lon;

    if (![latScanner scanDouble:&lat] || !latScanner.isAtEnd) return NO;
    if (![lonScanner scanDouble:&lon] || !lonScanner.isAtEnd) return NO;

    if (lat < -90 || lat > 90 || lon < -180 || lon > 180) return NO;

    outCoord->latitude = lat;
    outCoord->longitude = lon;
    return YES;
}

/// Geocode an address string synchronously. Returns kCLLocationCoordinate2DInvalid on failure.
static CLLocationCoordinate2D geocode_address(NSString *address) {
    __block CLLocationCoordinate2D result = kCLLocationCoordinate2DInvalid;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    CLGeocoder *geocoder = [[CLGeocoder alloc] init];
    [geocoder geocodeAddressString:address completionHandler:^(NSArray<CLPlacemark *> *placemarks, NSError *error) {
        if (placemarks.count > 0) {
            CLPlacemark *place = placemarks.firstObject;
            result = place.location.coordinate;
        }
        dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC));

    return result;
}

/// Resolve a location string (either "lat,lon" or address) to a coordinate.
static CLLocationCoordinate2D resolve_location(NSString *str) {
    CLLocationCoordinate2D coord;
    if (parse_lat_lon(str, &coord)) {
        return coord;
    }
    return geocode_address(str);
}

/// Map mode string to MKDirectionsTransportType.
static MKDirectionsTransportType transport_type_for_mode(NSString *mode) {
    if ([mode isEqualToString:@"walking"])  return MKDirectionsTransportTypeWalking;
    if ([mode isEqualToString:@"transit"])  return MKDirectionsTransportTypeTransit;
    return MKDirectionsTransportTypeAutomobile; // default: driving
}

// ── Current location (search center fallback) [s2-29] ──
//
// Same one-shot fix pattern as WeatherOffload's get_location_sync /
// LocationOffload: manager retained in a __block variable (CLLocationManager
// holds its delegate weakly), authorization handled inline, 15s semaphore.

@interface NoffMapsLocationDelegate : NSObject <CLLocationManagerDelegate>
@property (nonatomic, strong) CLLocation *location;
@property (nonatomic, strong) NSError *error;
@property (nonatomic, strong) dispatch_semaphore_t semaphore;
@end

@implementation NoffMapsLocationDelegate
- (instancetype)init {
    self = [super init];
    if (self) _semaphore = dispatch_semaphore_create(0);
    return self;
}
- (void)locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray<CLLocation *> *)locations {
    self.location = locations.lastObject;
    dispatch_semaphore_signal(self.semaphore);
}
- (void)locationManager:(CLLocationManager *)manager didFailWithError:(NSError *)error {
    self.error = error;
    dispatch_semaphore_signal(self.semaphore);
}
/// [batch7 用户-P2-7] 授权变化回调：用户在系统弹窗上晚点"允许"，
/// 这里收到 authorized 就立刻发起定位请求——不再靠 2 秒后无条件
/// requestLocation 碰运气；用户点了"不允许"则直接报错收尾，
/// 不用等满 15 秒超时。
- (void)locationManagerDidChangeAuthorization:(CLLocationManager *)manager {
    CLAuthorizationStatus status = manager.authorizationStatus;
    if (status == kCLAuthorizationStatusAuthorizedWhenInUse ||
        status == kCLAuthorizationStatusAuthorizedAlways) {
        [manager requestLocation];
    } else if (status == kCLAuthorizationStatusDenied ||
               status == kCLAuthorizationStatusRestricted) {
        self.error = [NSError errorWithDomain:@"NativeOffload" code:3
                           userInfo:@{NSLocalizedDescriptionKey:
                               @"Location access denied. To grant access, open "
                                "Settings > Privacy & Security > Location Services "
                                "and enable 分身版 — or pass --lat/--lon to search "
                                "around a specific point."}];
        dispatch_semaphore_signal(self.semaphore);
    }
    // NotDetermined：等用户在弹窗上作答，不做任何事。
}
@end

/// One-shot current location. On failure returns nil and sets *outError to
/// a plain-language explanation (never a guessed coordinate).
static CLLocation *current_location_sync(NSError **outError) {
    __block NoffMapsLocationDelegate *delegate = [[NoffMapsLocationDelegate alloc] init];
    __block CLLocationManager *manager = nil;

    dispatch_async(dispatch_get_main_queue(), ^{
        manager = [[CLLocationManager alloc] init];
        manager.delegate = delegate;
        manager.desiredAccuracy = kCLLocationAccuracyKilometer;

        CLAuthorizationStatus status = manager.authorizationStatus;
        if (status == kCLAuthorizationStatusNotDetermined) {
            // [batch7 用户-P2-7] 只弹授权框，不再 2 秒后无条件 requestLocation：
            // 用户作答后走上面的 locationManagerDidChangeAuthorization 回调，
            // 晚点了"允许"也会触发新的定位请求。
            [manager requestWhenInUseAuthorization];
        } else if (status == kCLAuthorizationStatusAuthorizedWhenInUse ||
                   status == kCLAuthorizationStatusAuthorizedAlways) {
            [manager requestLocation];
        } else {
            delegate.error = [NSError errorWithDomain:@"NativeOffload" code:3
                               userInfo:@{NSLocalizedDescriptionKey:
                                   @"Location access denied. To grant access, open "
                                    "Settings > Privacy & Security > Location Services "
                                    "and enable 分身版 — or pass --lat/--lon to search "
                                    "around a specific point."}];
            dispatch_semaphore_signal(delegate.semaphore);
        }
    });

    long waitResult = dispatch_semaphore_wait(delegate.semaphore,
                            dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC));
    if (delegate.location) return delegate.location;
    if (outError) {
        if (delegate.error) {
            *outError = delegate.error;
        } else {
            NSString *why = waitResult != 0
                ? @"timed out waiting for a location fix"
                : @"location services returned no fix";
            *outError = [NSError errorWithDomain:@"NativeOffload" code:4
                               userInfo:@{NSLocalizedDescriptionKey:
                                   [NSString stringWithFormat:
                                       @"Could not determine your current location (%@). "
                                        "Pass --lat/--lon to search around a specific point.", why]}];
        }
    }
    return nil;
}

// ── Subcommands ──

static int cmd_search(int argc, char **argv, int stdout_fd, int stderr_fd, BOOL compact, BOOL quiet) {
    NSString *query = noff_find_arg(argc, argv, "--query");
    if (!query) {
        noff_emit_help(stderr_fd, HELP_TEXT);
        NSDictionary *err = noff_json_error(TOOL_NAME, @"search",
                                             NOFF_ERR_INVALID_ARGS,
                                             @"Required: --query");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }

    NSString *latStr = noff_find_arg(argc, argv, "--lat") ?: noff_find_arg(argc, argv, "--latitude");
    NSString *lonStr = noff_find_arg(argc, argv, "--lon") ?: noff_find_arg(argc, argv, "--longitude");
    NSString *radiusStr = noff_find_arg(argc, argv, "--radius");
    NSString *limitStr = noff_find_arg(argc, argv, "--limit");

    double radiusM = radiusStr ? [radiusStr doubleValue] : 1000.0;
    NSInteger limit = limitStr ? [limitStr integerValue] : 10;
    if (limit <= 0) limit = 10;

    CLLocationCoordinate2D center;
    NSString *centerSource = @"provided";
    if (!latStr && !lonStr) {
        // [s2-29] No center given: use the current location as the search
        // center (the HELP_TEXT examples always promised this worked).
        // If no fix can be obtained, fail with a plain-language error —
        // never invent a center coordinate.
        NSError *locError = nil;
        CLLocation *current = current_location_sync(&locError);
        if (!current) {
            NSDictionary *err = noff_json_error(TOOL_NAME, @"search",
                                                 NOFF_ERR_NOT_AVAILABLE,
                                                 locError.localizedDescription ?:
                                                 @"Could not determine your current location. Pass --lat/--lon to search around a specific point.");
            noff_emit_json(stdout_fd, err, compact, quiet);
            return NOFF_EXIT_NOT_AVAILABLE;
        }
        center = current.coordinate;
        centerSource = @"current_location";
    } else if (!latStr || !lonStr) {
        noff_emit_help(stderr_fd, HELP_TEXT);
        NSDictionary *err = noff_json_error(TOOL_NAME, @"search",
                                             NOFF_ERR_INVALID_ARGS,
                                             @"--lat and --lon must be given together — pass both, or neither to search around your current location.");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    } else {
        center = CLLocationCoordinate2DMake([latStr doubleValue], [lonStr doubleValue]);
    }

    // MapKit objects (MKMapItem, MKLocalSearch, etc.) must be created and
    // released on the main thread to avoid crashes in NSNotificationCenter
    // during dealloc. Dispatch the entire MapKit operation to main.
    __block NSDictionary *resultData = nil;
    __block NSString *errorMsg = nil;
    dispatch_semaphore_t mainSem = dispatch_semaphore_create(0);

    dispatch_async(dispatch_get_main_queue(), ^{
        MKLocalSearchRequest *request = [[MKLocalSearchRequest alloc] init];
        request.naturalLanguageQuery = query;

        MKCoordinateRegion region = MKCoordinateRegionMakeWithDistance(center,
                                                                       radiusM * 2,
                                                                       radiusM * 2);
        request.region = region;

        MKLocalSearch *search = [[MKLocalSearch alloc] initWithRequest:request];
        [search startWithCompletionHandler:^(MKLocalSearchResponse *response, NSError *error) {
            if (error || !response) {
                errorMsg = error.localizedDescription ?: @"Search returned no results";
                dispatch_semaphore_signal(mainSem);
                return;
            }

            NSArray<MKMapItem *> *items = response.mapItems;
            if ((NSInteger)items.count > limit) {
                items = [items subarrayWithRange:NSMakeRange(0, limit)];
            }

            CLLocation *centerLoc = [[CLLocation alloc] initWithLatitude:center.latitude
                                                                       longitude:center.longitude];

            NSMutableArray *results = [NSMutableArray array];
            for (MKMapItem *item in items) {
                NSMutableDictionary *d = [NSMutableDictionary dictionary];
                d[@"name"] = item.name ?: @"";

                // Build address string from placemark
                MKPlacemark *pm = item.placemark;
                NSMutableArray *addrParts = [NSMutableArray array];
                if (pm.subThoroughfare) [addrParts addObject:pm.subThoroughfare];
                if (pm.thoroughfare) [addrParts addObject:pm.thoroughfare];
                if (pm.locality) [addrParts addObject:pm.locality];
                if (pm.administrativeArea) [addrParts addObject:pm.administrativeArea];
                if (pm.postalCode) [addrParts addObject:pm.postalCode];
                if (pm.country) [addrParts addObject:pm.country];
                d[@"address"] = addrParts.count > 0 ? [addrParts componentsJoinedByString:@", "] : @"";

                d[@"lat"] = @(item.placemark.coordinate.latitude);
                d[@"lon"] = @(item.placemark.coordinate.longitude);
                if (!gcj_isOutOfChina(center.latitude, center.longitude)) {
                    d[@"coordinate_system"] = @"GCJ-02";
                }
                d[@"phone"] = item.phoneNumber ?: [NSNull null];
                d[@"url"] = item.url.absoluteString ?: [NSNull null];

                if (@available(iOS 13.0, *)) {
                    d[@"category"] = item.pointOfInterestCategory ?: [NSNull null];
                } else {
                    d[@"category"] = [NSNull null];
                }

                CLLocation *itemLoc = [[CLLocation alloc]
                    initWithLatitude:item.placemark.coordinate.latitude
                           longitude:item.placemark.coordinate.longitude];
                double distM = [centerLoc distanceFromLocation:itemLoc];
                d[@"distance_m"] = @((int)round(distM));

                [results addObject:d];
            }

            resultData = @{
                @"results": results,
                @"count": @(results.count),
                @"query": query,
                @"center_lat": @(center.latitude),
                @"center_lon": @(center.longitude),
                @"center_source": centerSource,
            };
            dispatch_semaphore_signal(mainSem);
        }];
    });
    dispatch_semaphore_wait(mainSem, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC));

    if (errorMsg || !resultData) {
        NSDictionary *err = noff_json_error(TOOL_NAME, @"search",
                                             NOFF_ERR_INTERNAL_ERROR,
                                             errorMsg ?: @"Search timed out");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_ERROR;
    }

    noff_emit_json(stdout_fd, noff_json_envelope(TOOL_NAME, @"search", resultData), compact, quiet);
    return NOFF_EXIT_SUCCESS;
}

static int cmd_route(int argc, char **argv, int stdout_fd, int stderr_fd, BOOL compact, BOOL quiet) {
    NSString *fromStr = noff_find_arg(argc, argv, "--from");
    NSString *toStr = noff_find_arg(argc, argv, "--to");

    if (!fromStr || !toStr) {
        noff_emit_help(stderr_fd, HELP_TEXT);
        NSDictionary *err = noff_json_error(TOOL_NAME, @"route",
                                             NOFF_ERR_INVALID_ARGS,
                                             @"Required: --from, --to");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }

    NSString *mode = noff_find_arg(argc, argv, "--mode") ?: @"driving";

    CLLocationCoordinate2D fromCoord = resolve_location(fromStr);
    if (!CLLocationCoordinate2DIsValid(fromCoord)) {
        noff_emit_help(stderr_fd, HELP_TEXT);
        NSDictionary *err = noff_json_error(TOOL_NAME, @"route",
                                             NOFF_ERR_INVALID_ARGS,
                                             @"Could not resolve --from location");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }

    CLLocationCoordinate2D toCoord = resolve_location(toStr);
    if (!CLLocationCoordinate2DIsValid(toCoord)) {
        noff_emit_help(stderr_fd, HELP_TEXT);
        NSDictionary *err = noff_json_error(TOOL_NAME, @"route",
                                             NOFF_ERR_INVALID_ARGS,
                                             @"Could not resolve --to location");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }

    // MapKit objects must be created/released on the main thread to avoid
    // crashes in -[MKMapItem dealloc] → NSNotificationCenter removeObserver:.
    __block NSDictionary *resultData = nil;
    __block NSString *errorMsg = nil;
    MKDirectionsTransportType transportType = transport_type_for_mode(mode);
    dispatch_semaphore_t mainSem = dispatch_semaphore_create(0);

    dispatch_async(dispatch_get_main_queue(), ^{
        MKDirectionsRequest *request = [[MKDirectionsRequest alloc] init];
        MKPlacemark *srcPlacemark = [[MKPlacemark alloc] initWithCoordinate:fromCoord];
        MKPlacemark *dstPlacemark = [[MKPlacemark alloc] initWithCoordinate:toCoord];
        request.source = [[MKMapItem alloc] initWithPlacemark:srcPlacemark];
        request.destination = [[MKMapItem alloc] initWithPlacemark:dstPlacemark];
        request.transportType = transportType;
        request.requestsAlternateRoutes = NO;

        MKDirections *directions = [[MKDirections alloc] initWithRequest:request];
        [directions calculateDirectionsWithCompletionHandler:^(MKDirectionsResponse *response, NSError *error) {
            if (error || !response || response.routes.count == 0) {
                errorMsg = error.localizedDescription ?: @"No route found";
                dispatch_semaphore_signal(mainSem);
                return;
            }

            MKRoute *route = response.routes.firstObject;

            NSMutableArray *steps = [NSMutableArray array];
            for (MKRouteStep *step in route.steps) {
                if (step.instructions.length == 0) continue;
                [steps addObject:@{
                    @"instruction": step.instructions,
                    @"distance_m": @((int)round(step.distance)),
                }];
            }

            resultData = @{
                @"distance_km": @(round(route.distance / 10.0) / 100.0),
                @"duration_minutes": @(round(route.expectedTravelTime / 6.0) / 10.0),
                @"steps": steps,
                @"polyline_point_count": @(route.polyline.pointCount),
            };
            dispatch_semaphore_signal(mainSem);
        }];
    });
    dispatch_semaphore_wait(mainSem, dispatch_time(DISPATCH_TIME_NOW, 35 * NSEC_PER_SEC));

    if (errorMsg || !resultData) {
        NSDictionary *err = noff_json_error(TOOL_NAME, @"route",
                                             NOFF_ERR_INTERNAL_ERROR,
                                             errorMsg ?: @"Route calculation timed out");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_ERROR;
    }

    noff_emit_json(stdout_fd, noff_json_envelope(TOOL_NAME, @"route", resultData), compact, quiet);
    return NOFF_EXIT_SUCCESS;
}

static int cmd_eta(int argc, char **argv, int stdout_fd, int stderr_fd, BOOL compact, BOOL quiet) {
    NSString *fromStr = noff_find_arg(argc, argv, "--from");
    NSString *toStr = noff_find_arg(argc, argv, "--to");

    if (!fromStr || !toStr) {
        noff_emit_help(stderr_fd, HELP_TEXT);
        NSDictionary *err = noff_json_error(TOOL_NAME, @"eta",
                                             NOFF_ERR_INVALID_ARGS,
                                             @"Required: --from, --to");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }

    NSString *mode = noff_find_arg(argc, argv, "--mode") ?: @"driving";

    CLLocationCoordinate2D fromCoord = resolve_location(fromStr);
    if (!CLLocationCoordinate2DIsValid(fromCoord)) {
        noff_emit_help(stderr_fd, HELP_TEXT);
        NSDictionary *err = noff_json_error(TOOL_NAME, @"eta",
                                             NOFF_ERR_INVALID_ARGS,
                                             @"Could not resolve --from location");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }

    CLLocationCoordinate2D toCoord = resolve_location(toStr);
    if (!CLLocationCoordinate2DIsValid(toCoord)) {
        noff_emit_help(stderr_fd, HELP_TEXT);
        NSDictionary *err = noff_json_error(TOOL_NAME, @"eta",
                                             NOFF_ERR_INVALID_ARGS,
                                             @"Could not resolve --to location");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }

    // MapKit objects must be created/released on the main thread.
    __block NSDictionary *resultData = nil;
    __block NSString *errorMsg = nil;
    MKDirectionsTransportType transportType = transport_type_for_mode(mode);
    dispatch_semaphore_t mainSem = dispatch_semaphore_create(0);

    dispatch_async(dispatch_get_main_queue(), ^{
        MKDirectionsRequest *request = [[MKDirectionsRequest alloc] init];
        MKPlacemark *srcPlacemark = [[MKPlacemark alloc] initWithCoordinate:fromCoord];
        MKPlacemark *dstPlacemark = [[MKPlacemark alloc] initWithCoordinate:toCoord];
        request.source = [[MKMapItem alloc] initWithPlacemark:srcPlacemark];
        request.destination = [[MKMapItem alloc] initWithPlacemark:dstPlacemark];
        request.transportType = transportType;

        MKDirections *directions = [[MKDirections alloc] initWithRequest:request];
        [directions calculateETAWithCompletionHandler:^(MKETAResponse *response, NSError *error) {
            if (error || !response) {
                errorMsg = error.localizedDescription ?: @"Could not calculate ETA";
                dispatch_semaphore_signal(mainSem);
                return;
            }

            resultData = @{
                @"distance_km": @(round(response.distance / 10.0) / 100.0),
                @"duration_minutes": @(round(response.expectedTravelTime / 6.0) / 10.0),
                @"expected_arrival": noff_format_date(response.expectedArrivalDate),
            };
            dispatch_semaphore_signal(mainSem);
        }];
    });
    dispatch_semaphore_wait(mainSem, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC));

    if (errorMsg || !resultData) {
        NSDictionary *err = noff_json_error(TOOL_NAME, @"eta",
                                             NOFF_ERR_INTERNAL_ERROR,
                                             errorMsg ?: @"ETA calculation timed out");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_ERROR;
    }

    noff_emit_json(stdout_fd, noff_json_envelope(TOOL_NAME, @"eta", resultData), compact, quiet);
    return NOFF_EXIT_SUCCESS;
}

// ── Main handler ──

static int maps_handler(int argc, char **argv,
                         int stdin_fd, int stdout_fd, int stderr_fd) {
    if (noff_has_flag(argc, argv, "--help") || noff_has_flag(argc, argv, "-h")) {
        noff_emit_help(stderr_fd, HELP_TEXT);
        return NOFF_EXIT_SUCCESS;
    }

    BOOL compact = noff_has_flag(argc, argv, "--compact");
    BOOL quiet = noff_has_flag(argc, argv, "-q") || noff_has_flag(argc, argv, "--quiet");

    NSString *subcmd = noff_get_subcommand(argc, argv);
    if (!subcmd) {
        noff_emit_help(stderr_fd, HELP_TEXT);
        NSDictionary *err = noff_json_error(TOOL_NAME, @"unknown",
                                             NOFF_ERR_INVALID_ARGS,
                                             @"No command specified. Use --help for usage.");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }

    if ([subcmd isEqualToString:@"search"])  return cmd_search(argc, argv, stdout_fd, stderr_fd, compact, quiet);
    if ([subcmd isEqualToString:@"route"])   return cmd_route(argc, argv, stdout_fd, stderr_fd, compact, quiet);
    if ([subcmd isEqualToString:@"eta"])     return cmd_eta(argc, argv, stdout_fd, stderr_fd, compact, quiet);

    noff_emit_help(stderr_fd, HELP_TEXT);
    NSDictionary *err = noff_json_error(TOOL_NAME, subcmd,
                                         NOFF_ERR_INVALID_ARGS,
                                         [NSString stringWithFormat:@"Unknown command '%@'. Valid commands: search, route, eta. Use --help for details.", subcmd]);
    noff_emit_json(stdout_fd, err, compact, quiet);
    return NOFF_EXIT_INVALID_ARGS;
}

// ── Registration ──

void maps_offload_register(void) {
    int err = native_offload_add_handler("apple-maps", maps_handler);
    if (err == 0) {
        noff_ensure_guest_stub("/usr/local/bin/apple-maps");
        NSLog(@"NativeOffloads: apple-maps handler registered");
    } else {
        NSLog(@"NativeOffloads: failed to register apple-maps handler (err=%d)", err);
    }
}
