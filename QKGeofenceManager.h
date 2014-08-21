//
//  QKGeofenceManager.h
//
//  Created by Eric Webster on 8/20/2014.
//  Copyright (c) 2014 Eric Webster. All rights reserved.
//

#import <CoreLocation/CoreLocation.h>

@class QKGeofenceManager;

@protocol QKGeofenceManagerDelegate <NSObject>

@optional
- (void)geofenceManager:(QKGeofenceManager *)geofenceManager finishedProcessingGeofence:(CLCircularRegion *)geofence;
- (void)geofenceManager:(QKGeofenceManager *)geofenceManager isInsideGeofence:(CLCircularRegion *)geofence;
- (void)geofenceManager:(QKGeofenceManager *)geofenceManager isOutsideGeofence:(CLCircularRegion *)geofence;

@end

typedef enum _QKGeofenceManagerState : int16_t {
    
    QKGeofenceManagerStateIdle,
    QKGeofenceManagerStateProcessing,
    QKGeofenceManagerStateFailed
    
} QKGeofenceManagerState;

@interface QKGeofenceManager : NSObject<CLLocationManagerDelegate>

@property (nonatomic, weak) id<QKGeofenceManagerDelegate> delegate;
@property (nonatomic, readonly) QKGeofenceManagerState state;

+ (instancetype)sharedGeofenceManager;

- (void)refreshManager;
- (void)addGeofences:(NSArray *)geofences;
- (void)removeGeofences:(NSArray *)geofences;
- (void)removeAllGeofences;

@end
