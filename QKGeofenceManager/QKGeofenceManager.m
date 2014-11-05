//
//  QKGeofenceManager.m
//
//  Created by Eric Webster on 8/20/2014.
//  Copyright (c) 2014 Eric Webster. All rights reserved.
//

#import "QKGeofenceManager.h"

@interface QKGeofenceManager ()

@property (nonatomic) CLLocationManager *locationManager;

@property (nonatomic) NSArray *allGeofences;

// Geofences grouped by distance.
@property (nonatomic) NSMutableDictionary *regionsGroupedByDistance;

// Geofences currently being processed, ordered by boundary index.
@property (nonatomic) NSMutableArray *regionsBeingProcessed;

// Boundary indices: 10m -> 1, 20m -> 2, etc...
@property (nonatomic) NSMutableIndexSet *boundaryIndicesBeingProcessed;

// The 19 nearest geofences.
@property (nonatomic) NSMutableSet *nearestRegions;

// All regions which user is inside.
@property (nonatomic) NSMutableSet *insideRegions;

// Regions which user was previously inside
@property (nonatomic) NSMutableArray *previouslyInsideRegionIds;

// Processing happens while processingTimer is valid.
@property (nonatomic) NSTimer *processingTimer;

@end

@implementation QKGeofenceManager {
    BOOL _QK_isTransitioning;
}

@synthesize state = _QK_state;

// iOS gives you 10 seconds in total to process enter/exit events, I use up to 5 seconds to process the geofences
// and the rest to get a lock on the GPS.
static const NSTimeInterval MaxTimeToProcessGeofences = 6.0;

// iOS gives you a maximum of 20 regions to monitor.
static const NSUInteger GeofenceMonitoringLimit = 20;

static NSString *const CurrentRegionName = @"qk_currentRegion";
static const CGFloat CurrentRegionPaddingRatio = 0.5;

// NSUserDefaults key for storing insideRegionIds.
static NSString *const QKInsideRegionsDefaultsKey = @"qk_inside_regions_defaults_key";

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
        
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        NSArray *previouslyInsideRegionIds = [defaults arrayForKey:QKInsideRegionsDefaultsKey];
        self.previouslyInsideRegionIds = [previouslyInsideRegionIds mutableCopy];
    }
    return self;
}

- (void)_QK_setState:(QKGeofenceManagerState)state
{
    if (state != _QK_state) {
        _QK_state = state;
        if ([self.delegate respondsToSelector:@selector(geofenceManager:didChangeState:)]) {
            [self.delegate geofenceManager:self didChangeState:_QK_state];
        }
    }
}

#pragma mark - Refreshing Geofence Manager

- (void)_QK_reloadGeofences
{
    [self.processingTimer invalidate];
    [self.locationManager stopUpdatingLocation];
    [self.locationManager stopMonitoringSignificantLocationChanges];
    
    if ([CLLocationManager authorizationStatus] != kCLAuthorizationStatusAuthorizedAlways) {
        if ([self.locationManager respondsToSelector:@selector(requestAlwaysAuthorization)]) {
            [self.locationManager requestAlwaysAuthorization];
            return;
        }
    }
    
    self.regionsGroupedByDistance = nil;
    self.regionsBeingProcessed = nil;
    
    for (CLRegion *region in [self.locationManager monitoredRegions]) {
        [self.locationManager stopMonitoringForRegion:region];
    }
    
    self.allGeofences = [self.dataSource geofencesForGeofenceManager:self];
    
    if ([self.allGeofences count] > 0) {
        [self _QK_setState:QKGeofenceManagerStateProcessing];
        
        // Timer to get a lock on the GPS location
        NSTimeInterval timeToLock = 10 - MaxTimeToProcessGeofences;
        self.processingTimer = [NSTimer scheduledTimerWithTimeInterval:timeToLock target:self selector:@selector(startProcessingGeofences) userInfo:nil repeats:NO];
        
        // Turn on location updates for accuracy and so processing can happen in the background.
        [self.locationManager stopUpdatingLocation];
        [self.locationManager startUpdatingLocation];
        
        // Turn on significant location changes to help monitor the current region.
        [self.locationManager startMonitoringSignificantLocationChanges];
    }
    else {
        [self _QK_setState:QKGeofenceManagerStateIdle];
    }
}

- (void)_transition_reloadGeofences
{
    _QK_isTransitioning = YES;
    [self _QK_reloadGeofences];
}

- (void)reloadGeofences
{
    _QK_isTransitioning = NO;
    [self _QK_reloadGeofences];
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
    
    self.boundaryIndicesBeingProcessed = [NSMutableIndexSet indexSet];
    self.regionsGroupedByDistance = [NSMutableDictionary dictionary];
    self.regionsBeingProcessed = [NSMutableArray array];
    self.nearestRegions = [NSMutableSet set];
    self.insideRegions = [NSMutableSet set];
    
    NSMutableArray *fencesWithDistanceToBoundary = [NSMutableArray array];
    NSMutableDictionary *minBoundaryDistancesByIndex = [NSMutableDictionary dictionary];
    
    for (CLCircularRegion *fence in self.allGeofences) {
        if (fence.radius < self.locationManager.maximumRegionMonitoringDistance) {
            CLLocation *fenceCenter = [[CLLocation alloc] initWithLatitude:fence.center.latitude longitude:fence.center.longitude];
            
            //CLLocationAccuracy accuracy = location.horizontalAccuracy;
            CLLocationDistance d_r = [location distanceFromLocation:fenceCenter] - fence.radius;
            [fencesWithDistanceToBoundary addObject:@[fence, @(fabs(d_r))]];
            
            if (d_r < 0) {
                [self.insideRegions addObject:fence];
            }
            else {
                int rounded = (int)d_r;
                rounded -= rounded % 10;
                
                if (rounded <= 0) {
                    [self.insideRegions addObject:fence];
                }
                else if (rounded <= 200) { // Group by distances within 10m of eachother, but no more than 200m away from user.
                    NSNumber *key = @(rounded);
                    NSArray *val = self.regionsGroupedByDistance[key];
                    if (val) {
                        if ([minBoundaryDistancesByIndex[key] compare:@(d_r)] == NSOrderedDescending) {
                            val = [@[fence] arrayByAddingObjectsFromArray:val];
                            minBoundaryDistancesByIndex[key] = @(d_r);
                        }
                        else {
                            val = [val arrayByAddingObject:fence];
                        }
                    }
                    else {
                        val = @[fence];
                        minBoundaryDistancesByIndex[key] = @(d_r);
                    }
                    self.regionsGroupedByDistance[key] = val;
                }
            }
        }
    }
    
    [fencesWithDistanceToBoundary sortUsingComparator:^NSComparisonResult(NSArray *tuple1, NSArray *tuple2){
        return [[tuple1 lastObject] compare:[tuple2 lastObject]];
    }];
    
    [fencesWithDistanceToBoundary enumerateObjectsUsingBlock:^(NSArray *tuple, NSUInteger idx, BOOL *stop){
        CLRegion *fence = [tuple firstObject];
        if (idx < GeofenceMonitoringLimit - 1) {
            [self.nearestRegions addObject:fence];
        }
        else {
            *stop = YES;
        }
    }];
    
    if ([self.nearestRegions count] == GeofenceMonitoringLimit - 1) {
    // We need a region around the user to refresh geofences.
        NSArray *tuple = [fencesWithDistanceToBoundary lastObject];
        CLLocationDistance radius = MIN(self.locationManager.maximumRegionMonitoringDistance, [[tuple lastObject] doubleValue]);
        radius = MAX(radius, 2.0) * CurrentRegionPaddingRatio;
        
        CLCircularRegion *currentRegion = [[CLCircularRegion alloc] initWithCenter:location.coordinate radius:radius identifier:CurrentRegionName];
        [self.regionsBeingProcessed addObject:currentRegion];
        [self.boundaryIndicesBeingProcessed addIndex:0];
    }
    else {
        [self.regionsBeingProcessed addObject:[NSNull null]];
    }
    
    for (int i = 1; i <= 20; i++) {
        NSNumber *key = @(10 * i);
        NSArray *val = self.regionsGroupedByDistance[key];
        if (val) {
            CLRegion *fence = [val firstObject];
            [self.regionsBeingProcessed addObject:fence];
            [self.boundaryIndicesBeingProcessed addIndex:i];
        }
        else {
            [self.regionsBeingProcessed addObject:[NSNull null]];
        }
    }
    
    if ([self.boundaryIndicesBeingProcessed count] == 0) {
        for (CLRegion *fence in self.nearestRegions) {
            [self.locationManager startMonitoringForRegion:fence];
        }
    }
    else {
        for (id fence in self.regionsBeingProcessed) {
            if ([fence isKindOfClass:[CLRegion class]]) {
                [self.locationManager startMonitoringForRegion:fence];
            }
        }
    }
}

- (void)failedProcessingGeofencesWithError:(NSError *)error
{
    [self.processingTimer invalidate];
    [self.locationManager stopUpdatingLocation];
    self.regionsGroupedByDistance = nil;
    self.regionsBeingProcessed = nil;
    [self handleGeofenceEvents];
    [self _QK_setState:QKGeofenceManagerStateFailed];
    
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
    self.regionsGroupedByDistance = nil;
    self.regionsBeingProcessed = nil;
    [self handleGeofenceEvents];
    [self _QK_setState:QKGeofenceManagerStateIdle];
}

- (void)handleGeofenceEvents
{
    NSMutableArray *insideRegionIds = [NSMutableArray arrayWithCapacity:[self.insideRegions count]];
    
    for (CLRegion *region in self.insideRegions) {
        [insideRegionIds addObject:region.identifier];
        if ([self.delegate respondsToSelector:@selector(geofenceManager:isInsideGeofence:)]) {
            if (_QK_isTransitioning) {
                if (![self.previouslyInsideRegionIds containsObject:region.identifier]) {
                    [self.delegate geofenceManager:self isInsideGeofence:region];
                }
            }
            else {
                [self.delegate geofenceManager:self isInsideGeofence:region];
            }
        }
    }
    
    if (_QK_isTransitioning && [self.delegate respondsToSelector:@selector(geofenceManager:didExitGeofence:)]) {
        for (CLRegion *region in self.allGeofences) {
            if ([self.insideRegions containsObject:region]) {
                continue;
            }
            
            if ([self.previouslyInsideRegionIds containsObject:region.identifier]) {
                [self.delegate geofenceManager:self didExitGeofence:region];
            }
        }
    }
    
    self.previouslyInsideRegionIds = insideRegionIds;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:insideRegionIds forKey:QKInsideRegionsDefaultsKey];
    [defaults synchronize];
}

#pragma mark - CLLocationManagerDelegate methods

- (void)locationManager:(CLLocationManager *)manager monitoringDidFailForRegion:(CLRegion *)region withError:(NSError *)error
{
    if (self.state != QKGeofenceManagerStateProcessing) {
        return;
    }
    else if (![self.regionsBeingProcessed containsObject:region] && ![self.nearestRegions containsObject:region]) {
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
        [self _transition_reloadGeofences];
    }
}

- (void)locationManager:(CLLocationManager *)manager didExitRegion:(CLRegion *)region
{
    if ([region.identifier isEqualToString:CurrentRegionName] && self.state != QKGeofenceManagerStateProcessing) { // We exited the current region, so we need to refresh.
        [self _transition_reloadGeofences];
    }
    else {
        [self.previouslyInsideRegionIds removeObject:region.identifier];
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        [defaults setObject:self.previouslyInsideRegionIds forKey:QKInsideRegionsDefaultsKey];
        [defaults synchronize];
        
        if ([self.delegate respondsToSelector:@selector(geofenceManager:didExitGeofence:)]) { // Exited a geofence.
            [self.delegate geofenceManager:self didExitGeofence:region];
        }
    }
}

- (void)locationManager:(CLLocationManager *)manager didDetermineState:(CLRegionState)state forRegion:(CLRegion *)region
{
    if (self.state != QKGeofenceManagerStateProcessing) {
        return;
    }
    
    NSInteger idx = [self.regionsBeingProcessed indexOfObject:region];
    
    if (idx == NSNotFound) {
        return;
    }
    
    if ([region.identifier isEqualToString:CurrentRegionName]) {
        if (state == CLRegionStateInside) { // Keep attempting to find the current region.
            NSLog(@"found current region %@", region);
        }
        else {
            CLLocationDistance radius = [(CLCircularRegion *)region radius];
            CLCircularRegion *currentRegion = [[CLCircularRegion alloc] initWithCenter:manager.location.coordinate radius:radius identifier:CurrentRegionName];
            self.regionsBeingProcessed[idx] = currentRegion;
            [manager performSelectorInBackground:@selector(startMonitoringForRegion:) withObject:currentRegion];
            return;
        }
    }
    else {
        NSNumber *key = @(10 * idx);
        if (state == CLRegionStateInside) {
            NSArray *fences = self.regionsGroupedByDistance[key];
            [self.insideRegions addObjectsFromArray:fences];
        }
        
        if ([self.nearestRegions containsObject:region]) {
            [self.nearestRegions removeObject:region];
        }
        else {
            [manager stopMonitoringForRegion:region];
        }
        NSLog(@"processed %@ - %@m", region.identifier, key);
    }
    
    self.regionsBeingProcessed[idx] = [NSNull null];
    [self.boundaryIndicesBeingProcessed removeIndex:idx];
    
    if ([self.boundaryIndicesBeingProcessed count] == 0) {
        for (CLRegion *fence in self.nearestRegions) {
            [manager performSelectorInBackground:@selector(startMonitoringForRegion:) withObject:fence];
        }
    }
}

- (void)locationManager:(CLLocationManager *)manager didStartMonitoringForRegion:(CLCircularRegion *)region
{
    if (self.state != QKGeofenceManagerStateProcessing) {
        return;
    }
    
    if ([self.boundaryIndicesBeingProcessed count] == 0) {
        [self.nearestRegions removeObject:region];
        if ([self.nearestRegions count] == 0) { // All regions have finished processing, finish up.
            [self finishedProcessingGeofences];
        }
    }
    else if ([manager respondsToSelector:@selector(requestStateForRegion:)]) {
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
        [self _transition_reloadGeofences];
    }
}

- (void)locationManager:(CLLocationManager *)manager didChangeAuthorizationStatus:(CLAuthorizationStatus)status
{
    if (status == kCLAuthorizationStatusAuthorizedAlways) {
        // begin
        [self _QK_reloadGeofences];
    }
}

@end
