//
//  QKGeofenceManager.m
//
//  Created by Eric Webster on 8/20/2014.
//  Copyright (c) 2014 Eric Webster. All rights reserved.
//

#import "QKGeofenceManager.h"

@interface QKGeofenceManager ()

@property (nonatomic) CLLocationManager *locationManager;

// Geofences queued up to be processed.
@property (nonatomic) NSMutableSet *regionsNeedingProcessing;

// Geofences currently being processed.
@property (nonatomic) NSMutableSet *regionsBeingProcessed;

// The 19 nearest geofences.
@property (nonatomic) NSMutableSet *nearestRegions;

// Add region identifiers which user is inside.
@property (nonatomic) NSMutableSet *insideRegionIds;

// Regions which user was previously inside
@property (nonatomic) NSMutableSet *previouslyInsideRegionIds;

// Processing happens while processingTimer is valid.
@property (nonatomic) NSTimer *processingTimer;

@end

@implementation QKGeofenceManager {
    BOOL _QK_isTransitioning;
}

@synthesize state = _state;

// iOS gives you 10 seconds in total to process enter/exit events, I use up to 5 seconds to process the geofences
// and the rest to get a lock on the GPS.
static const NSTimeInterval MaxTimeToProcessGeofences = 5.0;

// iOS gives you a maximum of 20 regions to monitor. I use one for the current region.
static const NSUInteger GeofenceMonitoringLimit = 20 - 1;

static NSString *const CurrentRegionName = @"qk_currentRegion";
static const CLLocationDistance CurrentRegionMaxRadius = 1000;
static const CGFloat CurrentRegionPaddingRatio = 0.5;

// NSUserDefaults key for storing insideRegionIds.
static NSString *QKInsideRegionsDefaultsKey = @"qk_inside_regions_defaults_key";

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

- (void)_QK_setState:(QKGeofenceManagerState)state
{
    if (state != _state) {
        _state = state;
        if ([self.delegate respondsToSelector:@selector(geofenceManager:didChangeState:)]) {
            [self.delegate geofenceManager:self didChangeState:_state];
        }
    }
}

#pragma mark - Refreshing Geofence Manager

- (void)_QK_reloadGeofences
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
        [self _QK_setState:QKGeofenceManagerStateProcessing];
        
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
        [self _QK_setState:QKGeofenceManagerStateIdle];
    }
}

- (void)_transition_reloadGeofences
{
    _QK_isTransitioning = YES;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSArray *previouslyInsideRegionIds = [defaults arrayForKey:QKInsideRegionsDefaultsKey];
    self.previouslyInsideRegionIds = [NSMutableSet setWithArray:previouslyInsideRegionIds];
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
    
    self.regionsNeedingProcessing = [NSMutableSet set];
    self.regionsBeingProcessed = [NSMutableSet set];
    self.nearestRegions = [NSMutableSet set];
    self.insideRegionIds = [NSMutableSet set];

    NSArray *allGeofences = [self.dataSource geofencesForGeofenceManager:self];
    NSMutableArray *fencesWithDistanceToBoundary = [NSMutableArray array];

    for (CLCircularRegion *fence in allGeofences) {
        if (fence.radius < self.locationManager.maximumRegionMonitoringDistance) {
            CLLocation *fenceCenter = [[CLLocation alloc] initWithLatitude:fence.center.latitude longitude:fence.center.longitude];
            CLLocationAccuracy accuracy = location.horizontalAccuracy;
            CLLocationDistance d_r = [location distanceFromLocation:fenceCenter] - fence.radius;
            [fencesWithDistanceToBoundary addObject:@[fence, @(fabs(d_r))]];
            if (d_r - accuracy < 0) {
                [self.regionsNeedingProcessing addObject:fence];
            }
        }
    }
    
    [fencesWithDistanceToBoundary sortUsingComparator:^NSComparisonResult(NSArray *tuple1, NSArray *tuple2){
        return [[tuple1 lastObject] compare:[tuple2 lastObject]];
    }];
    
    [fencesWithDistanceToBoundary enumerateObjectsUsingBlock:^(NSArray *tuple, NSUInteger idx, BOOL *stop){
        CLRegion *fence = [tuple firstObject];
        if (idx < GeofenceMonitoringLimit) {
            [self.nearestRegions addObject:fence];
            [self.regionsNeedingProcessing removeObject:fence];
        }
        else {
            CLLocationDistance d_r = [[tuple lastObject] doubleValue];
            if (d_r < CurrentRegionMaxRadius) {
                if ([self.regionsBeingProcessed count] < GeofenceMonitoringLimit) {
                    [self.regionsBeingProcessed addObject:fence];
                    [self.regionsNeedingProcessing removeObject:fence];
                }
                else {
                    [self.regionsNeedingProcessing addObject:fence];
                }
            }
            else {
                *stop = YES;
            }
        }
    }];
        
    CLLocationDistance radius;
    if ([self.nearestRegions count] < GeofenceMonitoringLimit) {
        radius = CurrentRegionMaxRadius;
    }
    else {
        NSUInteger idx = [self.nearestRegions count] - 1;
        NSArray *tuple = [fencesWithDistanceToBoundary objectAtIndex:idx];
        radius = MIN(CurrentRegionMaxRadius, [[tuple lastObject] doubleValue]);
        radius = MAX(radius, 2.0);
    }
    radius *= CurrentRegionPaddingRatio;
    
    CLCircularRegion *currentRegion = [[CLCircularRegion alloc] initWithCenter:location.coordinate radius:radius identifier:CurrentRegionName];
    [self.nearestRegions addObject:currentRegion];
    
    if ([self.regionsBeingProcessed count] == 0) {
        self.regionsBeingProcessed = self.nearestRegions;
    }
    
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
    
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:[self.insideRegionIds allObjects] forKey:QKInsideRegionsDefaultsKey];
    [defaults synchronize];
    
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
    self.regionsNeedingProcessing = nil;
    self.regionsBeingProcessed = nil;
    
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:[self.insideRegionIds allObjects] forKey:QKInsideRegionsDefaultsKey];
    [defaults synchronize];
    
    [self _QK_setState:QKGeofenceManagerStateIdle];
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
        [self _transition_reloadGeofences];
    }
}

- (void)locationManager:(CLLocationManager *)manager didExitRegion:(CLRegion *)region
{
    if ([region.identifier isEqualToString:CurrentRegionName] && self.state != QKGeofenceManagerStateProcessing) { // We exited the current region, so we need to refresh.
        [self _transition_reloadGeofences];
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
        if (state != CLRegionStateInside) { // Keep attempting to find the current region.
            CLLocationDistance radius = [(CLCircularRegion *)region radius];
            CLCircularRegion *currentRegion = [[CLCircularRegion alloc] initWithCenter:manager.location.coordinate radius:radius identifier:CurrentRegionName];
            [manager performSelectorInBackground:@selector(startMonitoringForRegion:) withObject:currentRegion];
            return;
        }
    }
    else if (state == CLRegionStateInside) {
        [self.insideRegionIds addObject:region.identifier];
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
    else if (state == CLRegionStateOutside && _QK_isTransitioning) {
        if ([self.delegate respondsToSelector:@selector(geofenceManager:didExitGeofence:)]) {
            if ([self.previouslyInsideRegionIds containsObject:region.identifier]) {
                [self.delegate geofenceManager:self didExitGeofence:region];
            }
        }
    }
    
    NSLog(@"processed %@ - %im", region.identifier, (int)[(CLCircularRegion *)region radius]);
    [self.regionsBeingProcessed removeObject:region];
    
    if (self.regionsBeingProcessed != self.nearestRegions) {
        [manager stopMonitoringForRegion:region];
        CLRegion *nextFenceNeedingProcessing = [self.regionsNeedingProcessing anyObject];
        if (nextFenceNeedingProcessing) {
            [self.regionsBeingProcessed addObject:nextFenceNeedingProcessing];
            [self.regionsNeedingProcessing removeObject:nextFenceNeedingProcessing];
            [manager performSelectorInBackground:@selector(startMonitoringForRegion:) withObject:nextFenceNeedingProcessing];
        }
        else if ([self.regionsBeingProcessed count] == 0) {
            self.regionsBeingProcessed = self.nearestRegions;
            for (CLRegion *fence in self.regionsBeingProcessed) {
                [manager performSelectorInBackground:@selector(startMonitoringForRegion:) withObject:fence];
            }
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
        [self _transition_reloadGeofences];
    }
}

@end
