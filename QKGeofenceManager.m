//
//  QKGeofenceManager.m
//
//  Created by Eric Webster on 8/20/2014.
//  Copyright (c) 2014 Eric Webster. All rights reserved.
//

#import "QKGeofenceManager.h"

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
    if ((self = [super init])) {
        self.locationManager = [[CLLocationManager alloc] init];
        self.locationManager.delegate = self;
        self.locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation;
    }
    return self;
}

- (void)_setState:(QKGeofenceManagerState)state
{
    if (state != _state) {
        _state = state;
        if ([self.delegate respondsToSelector:@selector(geofenceManager:didChangeState:)]) {
            [self.delegate geofenceManager:self didChangeState:_state];
        }
    }
}

#pragma mark - Refreshing Geofence Manager

- (void)reloadGeofences
{
    [self.processingTimer invalidate];
    [self.locationManager stopUpdatingLocation];
    [self.locationManager stopMonitoringSignificantLocationChanges];
    
    self.regionsNeedingProcessing = nil;

    for (CLRegion *region in [self.locationManager monitoredRegions]) {
        [self.locationManager stopMonitoringForRegion:region];
    }
    
    NSArray *allGeofences = [self.dataSource geofencesForGeofenceManager:self];

    if ([allGeofences count] > 0) {
        [self _setState:QKGeofenceManagerStateProcessing];
        
        // Timer to get a lock on the GPS location
        NSTimeInterval timeToLock = 9.9 - MaxTimeToProcessGeofences;
        self.processingTimer = [NSTimer scheduledTimerWithTimeInterval:timeToLock target:self selector:@selector(startProcessingGeofences) userInfo:nil repeats:NO];
        
        // Turn on location updates for accuracy and so processing can happen in the background.
        [self.locationManager stopUpdatingLocation];
        [self.locationManager startUpdatingLocation];
        
        // Turn on significant location changes to help monitor the current region.
        [self.locationManager startMonitoringSignificantLocationChanges];
    }
    else {
        [self _setState:QKGeofenceManagerStateIdle];
    }
}

- (void)startProcessingGeofences
{
    MWLog(@"You are near %@", self.locationManager.location);
    self.processingTimer = [NSTimer scheduledTimerWithTimeInterval:MaxTimeToProcessGeofences target:self selector:@selector(failedProcessingGeofencesWithError:) userInfo:nil repeats:NO];
    [self processFencesNearLocation:self.locationManager.location];
}

- (void)processFencesNearLocation:(CLLocation *)location
{
    if (self.state != QKGeofenceManagerStateProcessing) {
        return;
    }
    
    NSArray *allGeofences = [self.dataSource geofencesForGeofenceManager:self];
    NSMutableArray *fencesWithDistanceToBoundary = [NSMutableArray array];
    NSMutableSet *fencesInside = [NSMutableSet set];
    
    for (CLCircularRegion *fence in allGeofences) {
        if (fence.radius < self.locationManager.maximumRegionMonitoringDistance) {
            CLLocation *fenceCenter = [[CLLocation alloc] initWithLatitude:fence.center.latitude longitude:fence.center.longitude];
            CLLocationDistance d_r = [location distanceFromLocation:fenceCenter] - fence.radius;
            CLLocationAccuracy accuracy = location.horizontalAccuracy;
            if (d_r - accuracy < 0) {
                // isInside
                [fencesInside addObject:fence];
            }
            [fencesWithDistanceToBoundary addObject:@[fence, @(fabs(d_r))]];
        }
    }

    [fencesWithDistanceToBoundary sortUsingComparator:^NSComparisonResult(NSArray *tuple1, NSArray *tuple2){
        return [[tuple1 lastObject] compare:[tuple2 lastObject]];
    }];
        
    self.regionsNeedingProcessing = [NSMutableSet set];

    for (NSArray *tuple in fencesWithDistanceToBoundary) {
        CLRegion *fence = [tuple firstObject];
        if ([self.regionsNeedingProcessing count] >= MaxNumberOfGeofences) {
            break;
        }
        else {
            [fencesInside removeObject:fence];
            [self.regionsNeedingProcessing addObject:fence.identifier];
            [self.locationManager startMonitoringForRegion:fence];
        }
    }
    
    CLLocationDistance radius;
    if ([fencesWithDistanceToBoundary count] < MaxNumberOfGeofences) {
        radius = CurrentRegionPaddingRatio * CurrentRegionMaxRadius;
    }
    else {
        NSArray *tuple = [fencesWithDistanceToBoundary firstObject];
        CLLocationDistance d_r = MIN(CurrentRegionMaxRadius, [[tuple lastObject] doubleValue]);
        radius = CurrentRegionPaddingRatio * d_r;
    }
    
    CLCircularRegion *currentRegion = [[CLCircularRegion alloc] initWithCenter:location.coordinate radius:radius identifier:CurrentRegionName];
    [self.regionsNeedingProcessing addObject:currentRegion.identifier];
    [self.locationManager startMonitoringForRegion:currentRegion];
    
    if ([self.delegate respondsToSelector:@selector(geofenceManager:isInsideGeofence:)]) {
        for (CLRegion *fence in fencesInside) {
            [self.delegate geofenceManager:self isInsideGeofence:fence];
        }
    }
}

- (void)failedProcessingGeofencesWithError:(NSError *)error
{
    [self.processingTimer invalidate];
    [self.locationManager stopUpdatingLocation];
    self.regionsNeedingProcessing = nil;
    [self _setState:QKGeofenceManagerStateFailed];
    
    if ([self.delegate respondsToSelector:@selector(geofenceManager:didFailWithError:)]) {
        if ([error isKindOfClass:[NSError class]]) {
            [self.delegate geofenceManager:self didFailWithError:error];
        }
        else {
            NSError *timeoutError = [NSError errorWithDomain:@"Geofence manager timed out" code:kCFURLErrorTimedOut userInfo:nil];
            [self.delegate geofenceManager:self didFailWithError:timeoutError];
        }
    }
}

- (void)finishedProcessingGeofences
{
    [self.processingTimer invalidate];
    [self.locationManager stopUpdatingLocation];
    self.regionsNeedingProcessing = nil;
    [self _setState:QKGeofenceManagerStateIdle];
}

#pragma mark - CLLocationManagerDelegate methods

- (void)locationManager:(CLLocationManager *)manager monitoringDidFailForRegion:(CLRegion *)region withError:(NSError *)error
{    
    if ([CLLocationManager respondsToSelector:@selector(isMonitoringAvailableForClass:)]) {
        if (![CLLocationManager isMonitoringAvailableForClass:[CLCircularRegion class]]) { // Old iOS
            [self failedProcessingGeofencesWithError:error];
            return;
        }
    }
    
    if([CLLocationManager authorizationStatus] == kCLAuthorizationStatusDenied || [CLLocationManager authorizationStatus] == kCLAuthorizationStatusRestricted) { //You need to authorize Location Services for the APP
        [self failedProcessingGeofencesWithError:error];
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
    if (![region.identifier isEqualToString:CurrentRegionName] && self.state != QKGeofenceManagerStateProcessing) { // Don't generate an enter event yet. First refresh to turn on GPS and check the state after.
        [self reloadGeofences];
    }
}

- (void)locationManager:(CLLocationManager *)manager didExitRegion:(CLRegion *)region
{
    if ([region.identifier isEqualToString:CurrentRegionName]) { // We exited the current region, so we need to refresh.
        [self reloadGeofences];
    }
    else if ([self.delegate respondsToSelector:@selector(geofenceManager:didExitGeofence:)]) { // Exited a geofence.
        [self.delegate geofenceManager:self didExitGeofence:region];
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
            CLLocationDistance radius = [(CLCircularRegion *)region radius];
            CLCircularRegion *currentRegion = [[CLCircularRegion alloc] initWithCenter:manager.location.coordinate radius:radius identifier:CurrentRegionName];
            [manager performSelectorOnMainThread:@selector(startMonitoringForRegion:) withObject:currentRegion waitUntilDone:NO];
            return;
        }
    }
    else {        
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
    if (self.state != QKGeofenceManagerStateProcessing || ![self.regionsNeedingProcessing containsObject:region.identifier]) {
        return;
    }
    
    if ([manager respondsToSelector:@selector(requestStateForRegion:)]) {
        [manager requestStateForRegion:region];
    }
}

- (void)locationManager:(CLLocationManager *)manager didFailWithError:(NSError *)error
{
    if ([CLLocationManager authorizationStatus] == kCLAuthorizationStatusDenied || [CLLocationManager authorizationStatus] == kCLAuthorizationStatusRestricted) { //You need to authorize Location Services for the APP
        [self failedProcessingGeofencesWithError:error];
        return;
    }
}

- (void)locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray *)locations
{
    if (self.state != QKGeofenceManagerStateProcessing) { // This is coming from significant location changes, since we are not processing anymore.
        [self reloadGeofences];
    }
    else {
        MWLog(@"location %@", manager.location);
    }
}

@end
