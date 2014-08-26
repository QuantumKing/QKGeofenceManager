//
//  DetailViewController.m
//  QKGeofenceManagerDemo
//
//  Created by Eric Webster on 2014-08-25.
//  Copyright (c) 2014 Eric Webster. All rights reserved.
//

#import "DetailViewController.h"

@interface DetailViewController ()

@property (nonatomic) MKPointAnnotation *marker;
@property (nonatomic) MKCircle *overlay;

@end

@implementation DetailViewController

#pragma mark - Managing the detail item

- (void)viewDidLoad
{
    [super viewDidLoad];
	// Do any additional setup after loading the view, typically from a nib.
    
    UITapGestureRecognizer *recog = [[UITapGestureRecognizer alloc] initWithTarget:self.view action:@selector(endEditing:)];
    recog.cancelsTouchesInView = NO;
    [self.view addGestureRecognizer:recog];
    
    self.identifierTextField.text = [self.geofence valueForKey:@"identifier"];
    self.identifierTextField.delegate = self;
    [self.identifierTextField addTarget:self.view action:@selector(endEditing:) forControlEvents:UIControlEventEditingDidEndOnExit];

    self.radiusTextField.text = [[self.geofence valueForKey:@"radius"] stringValue];
    self.radiusTextField.delegate = self;
    [self.radiusTextField addTarget:self.view action:@selector(endEditing:) forControlEvents:UIControlEventEditingDidEndOnExit];

    CLLocationDegrees lat = [[self.geofence valueForKey:@"lat"] doubleValue];
    CLLocationDegrees lon = [[self.geofence valueForKey:@"lon"] doubleValue];
    CLLocationDistance radius = [[self.geofence valueForKey:@"radius"] doubleValue];
    CLLocationCoordinate2D center = CLLocationCoordinate2DMake(lat, lon);
    MKCoordinateRegion region = MKCoordinateRegionMakeWithDistance(center, radius, radius);
    [self.mapView setRegion:region];
    
    self.overlay = [MKCircle circleWithCenterCoordinate:center radius:radius];
    [self.mapView addOverlay:self.overlay];
    
    self.marker = [[MKPointAnnotation alloc] init];
    self.marker.coordinate = center;
    self.marker.title = @"Hold and drag me";
    [self.mapView addAnnotation:self.marker];
    [self.mapView selectAnnotation:self.marker animated:YES];
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    
    [self.geofence setValue:self.identifierTextField.text forKey:@"identifier"];
    
    CLLocationCoordinate2D center = self.marker.coordinate;
    [self.geofence setValue:@(center.latitude) forKey:@"lat"];
    [self.geofence setValue:@(center.longitude) forKey:@"lon"];
    [self.geofence setValue:@(center.latitude) forKey:@"lat"];
    
    NSNumberFormatter *f = [[NSNumberFormatter alloc] init];
    [f setNumberStyle:NSNumberFormatterDecimalStyle];
    NSNumber *radius = [f numberFromString:self.radiusTextField.text];
    if (radius) {
        [self.geofence setValue:radius forKey:@"radius"];
    }
    
    // Save the context.
    NSError *error = nil;
    NSManagedObjectContext *context = [self.geofence managedObjectContext];
    if (![context save:&error]) {
        // Replace this implementation with code to handle the error appropriately.
        // abort() causes the application to generate a crash log and terminate. You should not use this function in a shipping application, although it may be useful during development.
        NSLog(@"Unresolved error %@, %@", error, [error userInfo]);
        abort();
    }
}

- (void)didReceiveMemoryWarning
{
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}

#pragma mark - MKMapViewDelegate

- (MKOverlayView *)mapView:(MKMapView *)map viewForOverlay:(id <MKOverlay>)overlay
{
    MKCircleView *circleView = [[MKCircleView alloc] initWithOverlay:overlay];
    circleView.strokeColor = [UIColor darkGrayColor];
    circleView.fillColor = [[UIColor blueColor] colorWithAlphaComponent:0.4];
    return circleView;
}

- (MKAnnotationView *)mapView:(MKMapView *)mapView viewForAnnotation:(id <MKAnnotation>)annotation
{
    // Handle any custom annotations.
    if ([annotation isKindOfClass:[MKPointAnnotation class]]) {
        // Try to dequeue an existing pin view first.
        MKAnnotationView *pinView = (MKPinAnnotationView *)[mapView dequeueReusableAnnotationViewWithIdentifier:@"CustomPinAnnotationView"];
        if (!pinView) {
            // If an existing pin view was not available, create one.
            pinView = [[MKPinAnnotationView alloc] initWithAnnotation:annotation reuseIdentifier:@"CustomPinAnnotationView"];
            pinView.draggable = YES;
            pinView.canShowCallout = YES;
        } else {
            pinView.annotation = annotation;
        }
        return pinView;
    }
    return nil;
}

- (void)mapView:(MKMapView *)mapView annotationView:(MKAnnotationView *)view didChangeDragState:(MKAnnotationViewDragState)newState fromOldState:(MKAnnotationViewDragState)oldState
{
    if (newState == MKAnnotationViewDragStateEnding && oldState == MKAnnotationViewDragStateDragging) {
        CLLocationDistance radius = [[self.geofence valueForKey:@"radius"] doubleValue];
        MKPointAnnotation *point = (MKPointAnnotation *)view.annotation;
        [self.mapView removeOverlay:self.overlay];
        self.overlay = [MKCircle circleWithCenterCoordinate:point.coordinate radius:radius];
        [self.mapView addOverlay:self.overlay];
    }
}

#pragma mark - UITextFieldDelegate

- (void)textFieldDidEndEditing:(UITextField *)textField
{
    NSNumberFormatter *f = [[NSNumberFormatter alloc] init];
    [f setNumberStyle:NSNumberFormatterDecimalStyle];
    NSNumber *radius = [f numberFromString:self.radiusTextField.text];
    if (radius) {
        [self.mapView removeOverlay:self.overlay];
        self.overlay = [MKCircle circleWithCenterCoordinate:self.overlay.coordinate radius:[radius doubleValue]];
        [self.mapView addOverlay:self.overlay];
    }
}

@end
