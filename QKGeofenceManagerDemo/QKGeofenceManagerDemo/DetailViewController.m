//
//  DetailViewController.m
//  QKGeofenceManagerDemo
//
//  Created by Eric Webster on 2014-08-25.
//  Copyright (c) 2014 Eric Webster. All rights reserved.
//

#import "DetailViewController.h"

@implementation DetailViewController

#pragma mark - Managing the detail item

- (void)viewDidLoad
{
    [super viewDidLoad];
	// Do any additional setup after loading the view, typically from a nib.
}

- (void)didReceiveMemoryWarning
{
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}

#pragma mark - MKMapViewDelegate

- (void)mapViewDidFinishLoadingMap:(MKMapView *)mapView
{
    NSNumber *lat = [self.geofence objectForKey:@"lat"];
    NSNumber *lon = [self.geofence objectForKey:@"lon"];
    NSNumber *radius = [self.geofence objectForKey:@"radius"];
    CLLocationCoordinate2D center = CLLocationCoordinate2DMake([lat doubleValue], [lon doubleValue]);
    MKCoordinateRegion region = MKCoordinateRegionMakeWithDistance(center, [radius doubleValue], [radius doubleValue]);
    [mapView setRegion:region];
}

@end
