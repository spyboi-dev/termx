// TXJITDetailViewController - the JIT detail from Settings.
//
// The method picker (Built-in StikJIT / StikDebug) plus pairing,
// connection, and Prepare/Enable, in the same grouped-table style
// as Settings. All state comes from TXStikJITCoordinator and
// TXOnDevicePairing; this controller only presents it. The About
// page keeps its own JIT card; this is the Settings presentation
// of the same working settings.
// SPDX-License-Identifier: GPL-2.0-or-later
#import <UIKit/UIKit.h>

@interface TXJITDetailViewController : UITableViewController <UIDocumentPickerDelegate>

@end
