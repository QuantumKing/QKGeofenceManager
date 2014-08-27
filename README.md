QKGeofenceManager
=================

Sets out to improve `CoreLocation`'s region monitoring by increasing the limit of regions from 20 to (theoretically) unlimited. It also helps by covering some of the boilerplate error handling to make region monitoring a smoother experience.

##Usage

`QKGeofenceManager` has the following interface:

``` obj-c
@interface QKGeofenceManager : NSObject<CLLocationManagerDelegate>

@property (nonatomic, weak) id<QKGeofenceManagerDelegate> delegate;
@property (nonatomic, weak) id<QKGeofenceManagerDataSource> dataSource;
@property (nonatomic, readonly) QKGeofenceManagerState state;

+ (instancetype)sharedGeofenceManager;

- (void)reloadGeofences;

@end
```
It uses the dataSource/delegate pattern to provide an array of `CLCircularRegion`s

``` obj-c
@protocol QKGeofenceManagerDataSource <NSObject>

@required
- (NSArray *)geofencesForGeofenceManager:(QKGeofenceManager *)geofenceManager;

@end
```
and to deliver inside/exit events.
``` obj-c
@protocol QKGeofenceManagerDelegate <NSObject>

@optional
- (void)geofenceManager:(QKGeofenceManager *)geofenceManager isInsideGeofence:(CLRegion *)geofence;
- (void)geofenceManager:(QKGeofenceManager *)geofenceManager didExitGeofence:(CLRegion *)geofence;
- (void)geofenceManager:(QKGeofenceManager *)geofenceManager didChangeState:(QKGeofenceManagerState)state;
- (void)geofenceManager:(QKGeofenceManager *)geofenceManager didFailWithError:(NSError *)error;

@end
```
QKGeofenceManager calls `geofenceManager:isInsideGeofence:` when the user enters or is currently inside the geofence. `geofenceManager:didChangeState:` is called when the manager changes from one of three states: `QKGeofenceManagerStateIdle`, `QKGeofenceManagerStateProcessing` and `QKGeofenceManagerStateFailed`.

##Demo

The demo provided allows a user to add geofences and display them in a table view. When the refresh button is pressed, `QKGeofenceManager` does its magic and determines which geofences the user is inside. Moving in and out of geofences will update the table view accordingly.

![](https://raw.githubusercontent.com/QuantumKing/QKGeofenceManager/master/QKGeofenceManagerDemo/screenshots/IMG_0058.PNG)

It is also possible to edit a geofence (which is by default at the current location) by selecting it in the table view and then dragging the marker around on the map.

![](https://raw.githubusercontent.com/QuantumKing/QKGeofenceManager/master/QKGeofenceManagerDemo/screenshots/IMG_0059.PNG)

##Installation via Cocoapods

Add `pod 'QKGeofenceManager', '~> 1.1'` to your `Podfile` and run `pod` to install.
