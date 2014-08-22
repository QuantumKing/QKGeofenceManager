//
//  QKGeofenceManager.m
//
//  Created by Eric Webster on 8/20/2014.
//  Copyright (c) 2014 Eric Webster. All rights reserved.
//

#import "QKGeofenceManager.h"

@interface QKGeofenceManager ()

@property (nonatomic) CLLocationManager *locationManager;

@property (nonatomic) NSMutableArray *regionsNeedingProcessing;
@property (nonatomic) NSMutableSet *regionsBeingProcessed;
@property (nonatomic) NSMutableSet *nearestRegions;

// Processing happens while processingTimer is valid.
@property (nonatomic) NSTimer *processingTimer;

@end

@implementation QKGeofenceManager

@synthesize state = _state;

// iOS gives you 10 seconds in total to process enter/exit events, I use 5 seconds to get a lock on the GPS
// and the rest is used to process the geofences.
static const NSTimeInterval MaxTimeToProcessGeofences = 5.0;

// iOS gives you a maximum of 20 regions to monitor. I use one for the current region.
static const NSUInteger GeofenceMonitoringLimit = 20 - 1;

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
    self.regionsBeingProcessed = nil;

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
    NSLog(@"You are near %@", self.locationManager.location);
    self.processingTimer = [NSTimer scheduledTimerWithTimeInterval:MaxTimeToProcessGeofences target:self selector:@selector(failedProcessingGeofencesWithError:) userInfo:nil repeats:NO];
    [self processFencesNearLocation:self.locationManager.location];
}

- (void)processFencesNearLocation:(CLLocation *)location
{
    if (self.state != QKGeofenceManagerStateProcessing) {
        return;
    }
    
    self.regionsNeedingProcessing = [NSMutableArray array];
    self.regionsBeingProcessed = [NSMutableSet set];
    self.nearestRegions = [NSMutableSet set];
    
    NSArray *allGeofences = [self.dataSource geofencesForGeofenceManager:self];
    NSMutableArray *fencesWithDistanceToBoundary = [NSMutableArray array];

    for (CLCircularRegion *fence in allGeofences) {
        if (fence.radius < self.locationManager.maximumRegionMonitoringDistance) {
            CLLocation *fenceCenter = [[CLLocation alloc] initWithLatitude:fence.center.latitude longitude:fence.center.longitude];
            CLLocationAccuracy accuracy = location.horizontalAccuracy;
            CLLocationDistance d_r = [location distanceFromLocation:fenceCenter] - fence.radius - accuracy;
            if ([fencesWithDistanceToBoundary count] < GeofenceMonitoringLimit) {
                [fencesWithDistanceToBoundary addObject:@[fence, @(fabs(d_r))]];
            }
            else if (d_r < CurrentRegionMaxRadius) {
                [fencesWithDistanceToBoundary addObject:@[fence, @(fabs(d_r))]];
            }
        }
    }
    
    [fencesWithDistanceToBoundary sortUsingComparator:^NSComparisonResult(NSArray *tuple1, NSArray *tuple2){
        return [[tuple1 lastObject] compare:[tuple2 lastObject]];
    }];

    CLLocationDistance radius;
    if ([fencesWithDistanceToBoundary count] < GeofenceMonitoringLimit) {
        radius = CurrentRegionMaxRadius;
    }
    else {
        NSArray *tuple = [fencesWithDistanceToBoundary firstObject];
        radius = MIN(CurrentRegionMaxRadius, [[tuple lastObject] doubleValue]);
        radius = MAX(radius, 2.0);
    }
    radius *= CurrentRegionPaddingRatio;
    
    CLCircularRegion *currentRegion = [[CLCircularRegion alloc] initWithCenter:location.coordinate radius:radius identifier:CurrentRegionName];
    [self.regionsNeedingProcessing addObject:currentRegion];
    
    [fencesWithDistanceToBoundary enumerateObjectsWithOptions:NSEnumerationReverse usingBlock:^(NSArray *tuple, NSUInteger idx, BOOL *stop){
        CLRegion *fence = [tuple firstObject];
        if ([self.regionsBeingProcessed count] < GeofenceMonitoringLimit) {
            [self.regionsBeingProcessed addObject:fence];
        }
        else {
            [self.regionsNeedingProcessing addObject:fence];
            if (idx < GeofenceMonitoringLimit) {
                [self.nearestRegions addObject:fence];
            }
        }
    }];
    
    for (CLRegion *fence in self.regionsBeingProcessed) {
        [self.locationManager startMonitoringForRegion:fence];
    }
}

- (void)failedProcessingGeofencesWithError:(NSError *)error
{
    [self.processingTimer invalidate];
    [self.locationManager stopUpdatingLocation];
    self.regionsNeedingProcessing = nil;
    self.regionsBeingProcessed = nil;
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
    self.regionsBeingProcessed = nil;
    [self _setState:QKGeofenceManagerStateIdle];
}

#pragma mark - CLLocationManagerDelegate methods

- (void)locationManager:(CLLocationManager *)manager monitoringDidFailForRegion:(CLRegion *)region withError:(NSError *)error
{
    if (self.state != QKGeofenceManagerStateProcessing || ![self.regionsBeingProcessed containsObject:region]) {
        return;
    }
    
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
    
    NSLog(@"try again %@", region.identifier);
    [manager performSelectorInBackground:@selector(startMonitoringForRegion:) withObject:region];
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
    if (self.state != QKGeofenceManagerStateProcessing || ![self.regionsBeingProcessed containsObject:region]) {
        return;
    }
    
    if ([region.identifier isEqualToString:CurrentRegionName]) {
        if (state == CLRegionStateInside) {
            NSLog(@"found current region %@", region);
        }
        else { // Keep attempting to find the current region.
            CLLocationDistance radius = [(CLCircularRegion *)region radius];
            CLCircularRegion *currentRegion = [[CLCircularRegion alloc] initWithCenter:manager.location.coordinate radius:radius identifier:CurrentRegionName];
            [manager performSelectorInBackground:@selector(startMonitoringForRegion:) withObject:currentRegion];
            return;
        }
    }
    else {        
        if (state == CLRegionStateInside) {
            if ([self.delegate respondsToSelector:@selector(geofenceManager:isInsideGeofence:)]) {
                [self.delegate geofenceManager:self isInsideGeofence:region];
            }
        }
        NSLog(@"processed %@", region.identifier);
    }
    
    [self.regionsBeingProcessed removeObject:region];
    
    if (![self.nearestRegions containsObject:region]) {
        [manager stopMonitoringForRegion:region];
        
        CLRegion *nextFenceNeedingProcessing = [self.regionsNeedingProcessing lastObject];
        
        if (nextFenceNeedingProcessing) {
            [self.regionsBeingProcessed addObject:nextFenceNeedingProcessing];
            [self.regionsNeedingProcessing removeLastObject];
            [manager performSelectorInBackground:@selector(startMonitoringForRegion:) withObject:nextFenceNeedingProcessing];
        }
    }
    
    if ([self.regionsBeingProcessed count] == 0 && [self.regionsNeedingProcessing count] == 0) { // All regions have finished processing, finish up.
        [self finishedProcessingGeofences];
    }
}

- (void)locationManager:(CLLocationManager *)manager didStartMonitoringForRegion:(CLCircularRegion *)region
{
    if (self.state != QKGeofenceManagerStateProcessing || ![self.regionsBeingProcessed containsObject:region]) {
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
        NSLog(@"location %@", manager.location);
    }
}

@end
