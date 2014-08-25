//
//  DetailViewController.h
//  QKGeofenceManagerDemo
//
//  Created by Eric Webster on 2014-08-25.
//  Copyright (c) 2014 Eric Webster. All rights reserved.
//

#import <UIKit/UIKit.h>
#import <MapKit/MapKit.h>

@interface DetailViewController : UIViewController<MKMapViewDelegate,UITextFieldDelegate>

@property (nonatomic) id geofence;
@property (nonatomic, weak) IBOutlet MKMapView *mapView;
@property (nonatomic, weak) IBOutlet UITextField *identifierTextField;
@property (nonatomic, weak) IBOutlet UITextField *radiusTextField;

@end
