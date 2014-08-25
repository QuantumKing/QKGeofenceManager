//
//  MasterViewController.h
//  QKGeofenceManagerDemo
//
//  Created by Eric Webster on 2014-08-25.
//  Copyright (c) 2014 Eric Webster. All rights reserved.
//

#import <UIKit/UIKit.h>
#import <CoreData/CoreData.h>

#import "QKGeofenceManager.h"

@interface MasterViewController : UITableViewController <NSFetchedResultsControllerDelegate,QKGeofenceManagerDataSource,QKGeofenceManagerDelegate>

@property (strong, nonatomic) NSFetchedResultsController *fetchedResultsController;
@property (strong, nonatomic) NSManagedObjectContext *managedObjectContext;

@end
