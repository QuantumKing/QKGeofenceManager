//
//  QKGeofenceManager.h
//
//  Created by Eric Webster on 8/20/2014.
//  Copyright (c) 2014 Eric Webster. All rights reserved.
//

#import <CoreLocation/CoreLocation.h>

typedef enum _QKGeofenceManagerState : int16_t {
    
    QKGeofenceManagerStateIdle,
    QKGeofenceManagerStateProcessing,
    QKGeofenceManagerStateFailed
    
} QKGeofenceManagerState;

@class QKGeofenceManager;

@protocol QKGeofenceManagerDataSource <NSObject>

@required
- (NSArray *)geofencesForGeofenceManager:(QKGeofenceManager *)geofenceManager;

@end

@protocol QKGeofenceManagerDelegate <NSObject>

@optional
- (void)geofenceManager:(QKGeofenceManager *)geofenceManager isInsideGeofence:(CLRegion *)geofence;
- (void)geofenceManager:(QKGeofenceManager *)geofenceManager didExitGeofence:(CLRegion *)geofence;
- (void)geofenceManager:(QKGeofenceManager *)geofenceManager didChangeState:(QKGeofenceManagerState)state;
- (void)geofenceManager:(QKGeofenceManager *)geofenceManager didFailWithError:(NSError *)error;

@end

@interface QKGeofenceManager : NSObject<CLLocationManagerDelegate>

@property (nonatomic, weak) id<QKGeofenceManagerDelegate> delegate;
@property (nonatomic, weak) id<QKGeofenceManagerDataSource> dataSource;
@property (nonatomic, readonly) QKGeofenceManagerState state;

+ (instancetype)sharedGeofenceManager;

- (void)reloadGeofences;

@end
