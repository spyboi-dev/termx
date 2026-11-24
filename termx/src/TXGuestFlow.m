// TXGuestFlow - see the header.
// SPDX-License-Identifier: GPL-2.0-or-later
#import "TXGuestFlow.h"

@implementation TXGuestFlow

- (void)resetForInstall {
    self.autoBootDone = NO;
    self.bootRetryUsed = NO;
    self.bootRetryScheduled = NO;
}

- (void)resetRetry {
    self.bootRetryUsed = NO;
    self.bootRetryScheduled = NO;
}

- (void)acknowledgeCrash {
    self.crashAcknowledged = YES;
}

@end
