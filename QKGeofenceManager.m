//
//  QKGeofenceManager.m
//
//  Created by Eric Webster on 8/20/2014.
//  Copyright (c) 2014 Eric Webster. All rights reserved.
//

#import "QKGeofenceManager.h"

NSString *const QKGeofenceManagerDefaultsKey = @"qk_geofence_manager_geofences";

@interface QKGeofenceManager ()

@property (nonatomic) CLLocationManager *locationManager;
@property (nonatomic) NSMutableSet *regionsNeedingProcessing;

// Processing happens while processingTimer is valid.
@property (nonatomic) NSTimer *processingTimer;

@end

@implementation QKGeofenceManager

@synthesize state = _state;

// iOS gives you 10 seconds in total to process enter/exit events, I use 5 seconds to get a lock on the GPS
// and the rest is used to process the geofences.
static const NSTimeInterval MaxTimeToProcessGeofences = 5;

// iOS gives you a maximum of 20 regions to monitor. I use one for the current region.
static const NSUInteger MaxNumberOfGeofences = 20 - 1;

static NSString *const CurrentRegionName = @"currentRegion";
static const CLLocationDistance CurrentRegionMaxRadius = 1000;
static const CGFloat CurrentRegionPaddingRatio = 0.5;

+ (instancetype)sharedGeofenceManager
{
    static QKGeofenceManager *GeofenceManager;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        GeofenceManager = [[self alloc] init];
    });
    return GeofenceManager;
}

- (id)init
{
    if ((self = [self init])) {
        self.locationManager = [[CLLocationManager alloc] init];
        self.locationManager.delegate = self;
        self.locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation;
    }
    return self;
}

- (QKGeofenceManagerState)state
{
    if ([self.processingTimer isValid]) {
        return QKGeofenceManagerStateProcessing;
    }
    return _state;
}

#pragma mark - Adding Geofences

- (void)addGeofences:(NSArray *)geofences
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSMutableArray *allGeofences = [[defaults arrayForKey:QKGeofenceManagerDefaultsKey] mutableCopy];
    [allGeofences addObjectsFromArray:geofences];
    [defaults setObject:allGeofences forKey:QKGeofenceManagerDefaultsKey];
    [defaults synchronize];
    
    [self refreshManager];
}

#pragma mark - Removing Geofences

- (void)removeGeofences:(NSArray *)geofences
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSMutableArray *allGeofences = [[defaults arrayForKey:QKGeofenceManagerDefaultsKey] mutableCopy];
    [allGeofences removeObjectsInArray:geofences];
    [defaults setObject:allGeofences forKey:QKGeofenceManagerDefaultsKey];
    [defaults synchronize];
    
    [self refreshManager];
    
    for (CLRegion *fence in geofences) {
        NSLog(@"stopped monitoring %@", fence.identifier);
    }
}

- (void)removeAllGeofences
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults removeObjectForKey:QKGeofenceManagerDefaultsKey];
    [defaults synchronize];
    
    [self refreshManager];
}

#pragma mark - Refreshing Geofence Manager

- (void)refreshManager
{
    _state = QKGeofenceManagerStateIdle;
    
    [self.processingTimer invalidate];
    [self.locationManager stopUpdatingLocation];
    [self.locationManager stopMonitoringSignificantLocationChanges];
    
    self.regionsNeedingProcessing = nil;
    
    for (CLRegion *region in [self.locationManager monitoredRegions]) {
        [self.locationManager stopMonitoringForRegion:region];
    }
    
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSMutableArray *allGeofences = [defaults arrayForKey:QKGeofenceManagerDefaultsKey];
    
    if ([allGeofences count] > 0) {
        // Timer to get a lock on the GPS location
        NSTimeInterval timeToLock = 9.9 - MaxTimeToProcessGeofences;
        self.processingTimer = [NSTimer scheduledTimerWithTimeInterval:timeToLock target:self selector:@selector(startProcessingGeofences) userInfo:nil repeats:NO];
        
        // Turn on location updates for accuracy and so processing can happen in the background.
        [self.locationManager stopUpdatingLocation];
        [self.locationManager startUpdatingLocation];
        
        // Turn on significant location changes to help monitor the current region.
        [self.locationManager startMonitoringSignificantLocationChanges];
        
        MWLog(@"refreshing");
    }
}

- (void)startProcessingGeofences
{
    MWLog(@"You are near %@", self.locationManager.location);

    self.processingTimer = [NSTimer scheduledTimerWithTimeInterval:MaxTimeToProcessGeofences target:self selector:@selector(failedProcessingGeofences) userInfo:nil repeats:NO];
    
    [self processFencesNearLocation:self.locationManager.location];
}

- (void)processFencesNearLocation:(CLLocation *)location
{
    if (self.state != QKGeofenceManagerStateProcessing) {
        return;
    }
    
    self.regionsNeedingProcessing = [NSMutableSet set];

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSMutableArray *allGeofences = [defaults arrayForKey:QKGeofenceManagerDefaultsKey];
    NSMutableArray *fencesWithDistanceToBoundary = [NSMutableArray array];
    
    for (CLRegion *fence in allGeofences) {
        CLLocation *fenceCenter = [[CLLocation alloc] initWithLatitude:fence.center.latitude longitude:fence.center.longitude];
        CLLocationDistance d_r = [location distanceFromLocation:fenceCenter] - fence.radius;
        [fencesWithDistanceToBoundary addObject:@[fence, @(d_r)]];
    }
    
    [fencesWithDistanceToBoundary sortUsingComparator:^NSComparisonResult(NSArray *tuple1, NSArray *tuple2){
        return [[tuple1 lastObject] compare:[tuple2 lastObject]];
    }];
    
    MWLog(@"%@", fencesWithDistanceToBoundary);
    
    for (NSArray *tuple in fencesWithDistanceToBoundary) {
        CLCircularRegion *fence = [tuple firstObject];
        if ([self.regionsNeedingProcessing count] >= MaxNumberOfGeofences) {
            break;
        }
        else if (fence.radius < self.locationManager.maximumRegionMonitoringDistance) {
            [self.regionsNeedingProcessing addObject:fence.identifier];
            [self.locationManager startMonitoringForRegion:fence];
        }
    }
    
    MWLog(@"processing geofences");
    
    CLLocationDistance radius;
    if ([fences count] < MaxNumberOfGeofences) {
        radius = CurrentRegionPaddingRatio * CurrentRegionMaxRadius;
    }
    else {
        NSArray *tuple = [fences lastObject];
        CLLocationDistance d_r = MIN(CurrentRegionMaxRadius, fabs([[tuple lastObject] doubleValue]));
        radius = CurrentRegionPaddingRatio * d_r;
    }
    
    CLCircularRegion *currentRegion = [[CLCircularRegion alloc] initWithCenter:location.coordinate radius:radius identifier:CurrentRegionName];
    [self.regionsNeedingProcessing addObject:currentRegion.identifier];
    [self.locationManager startMonitoringForRegion:currentRegion];
}

- (void)failedProcessingGeofences
{
    [self.processingTimer invalidate];
    [self.locationManager stopUpdatingLocation];
    self.regionsNeedingProcessing = nil;
    _state = QKGeofenceManagerStateFailed;
    MWLog(@"failed processing geofences");
}

- (void)finishedProcessingGeofences
{
    [self.processingTimer invalidate];
    [self.locationManager stopUpdatingLocation];
    self.regionsNeedingProcessing = nil;
    _state = QKGeofenceManagerStateIdle;
    MWLog(@"done or stopped");
}

#pragma mark - CLLocationManagerDelegate methods

- (void)locationManager:(CLLocationManager *)manager monitoringDidFailForRegion:(CLRegion *)region withError:(NSError *)error
{    
    if ([CLLocationManager respondsToSelector:@selector(isMonitoringAvailableForClass:)]) {
        if (![CLLocationManager isMonitoringAvailableForClass:[CLCircularRegion class]]) {
            NSLog(@"Region monitoring unavailable, %@", error);
            [self failedProcessingGeofences];
            return;
        }
    }
    
    if([CLLocationManager authorizationStatus] == kCLAuthorizationStatusDenied || [CLLocationManager authorizationStatus] == kCLAuthorizationStatusRestricted) {
        //You need to authorize Location Services for the APP
        NSLog(@"Location services disabled, %@", error);
        [self failedProcessingGeofences];
        return;
    }
    
    BOOL a = (self.state == QKGeofenceManagerStateProcessing);
    BOOL b = [self.regionsNeedingProcessing containsObject:region.identifier];

    if (a && b) {
        NSLog(@"try again %@", region.identifier);
        [manager performSelectorOnMainThread:@selector(startMonitoringForRegion:) withObject:region waitUntilDone:NO];
    }
}

- (void)locationManager:(CLLocationManager *)manager didEnterRegion:(CLRegion *)region
{
    if (![region.identifier isEqualToString:CurrentRegionName] && self.state != QKGeofenceManagerStateProcessing) {
    // Don't generate an enter event yet. First refresh to turn on GPS and check the state after.
        [self refreshFences];
    }
}

- (void)locationManager:(CLLocationManager *)manager didExitRegion:(CLRegion *)region
{
    if ([region.identifier isEqualToString:CurrentRegionName]) {
    // We exited the current region, so we need to refresh.
        [self refreshFences];
    }
    else if ([self.delegate respondsToSelector:@selector(geofenceManager:isOutsideGeofence:)]) { // Exited a geofence.
        [self.delegate geofenceManager:self isOutsideGeofence:region];
    }
}

- (void)locationManager:(CLLocationManager *)manager didDetermineState:(CLRegionState)state forRegion:(CLRegion *)region
{
    if (self.state != QKGeofenceManagerStateProcessing || ![self.regionsNeedingProcessing containsObject:region.identifier]) {
        return;
    }
    
    if ([region.identifier isEqualToString:CurrentRegionName]) {
        if (state == CLRegionStateInside) {
            MWLog(@"found current region %@", region);
        }
        else { // Keep attempting to find the current region.
            [manager performSelectorOnMainThread:@selector(startMonitoringForRegion:) withObject:region waitUntilDone:NO];
        }
    }
    else {
        if ([self.delegate respondsToSelector:@selector(geofenceManager:finishedProcessingGeofence:)]) {
            [self.delegate geofenceManager:self finishedProcessingGeofence:region];
        }
        
        if (state == CLRegionStateInside) {
            if ([self.delegate respondsToSelector:@selector(geofenceManager:isInsideGeofence:)]) {
                [self.delegate geofenceManager:self isInsideGeofence:region];
            }
        }
        MWLog(@"processed %@", region.identifier);
    }
    
    [self.regionsNeedingProcessing removeObject:region.identifier];

    if ([self.regionsNeedingProcessing count] == 0) { // If all regions have finished processing, finish up.
        [self performSelectorOnMainThread:@selector(finishedProcessingGeofences) withObject:nil waitUntilDone:YES];
    }
}

- (void)locationManager:(CLLocationManager *)manager didStartMonitoringForRegion:(CLCircularRegion *)region
{
    if ([manager respondsToSelector:@selector(requestStateForRegion:)]) {
        [manager requestStateForRegion:region];
    }
}

- (void)locationManager:(CLLocationManager *)manager didFailWithError:(NSError *)error
{
    if ([CLLocationManager authorizationStatus] == kCLAuthorizationStatusDenied || [CLLocationManager authorizationStatus] == kCLAuthorizationStatusRestricted) {
    //You need to authorize Location Services for the APP
        MWLog(@"Location services disabled");
        [self failedProcessingGeofences];
        return;
    }
}

- (void)locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray *)locations
{
    if (self.state != QKGeofenceManagerStateProcessing) { // This is coming from significant location changes, since we are not processing anymore.
        [self refreshFences];
    }
    else {
        MWLog(@"location %@", manager.location);
    }
}

@end
