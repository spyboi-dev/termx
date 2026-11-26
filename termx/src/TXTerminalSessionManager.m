// TXTerminalSessionManager - see the header.
// SPDX-License-Identifier: GPL-2.0-or-later
#import "TXTerminalSessionManager.h"
#import "TXGhosttyView.h"

@implementation TXTerminalSession

- (instancetype)initWithTmuxName:(NSString *)tmuxName displayName:(NSString *)displayName {
    self = [super init];
    if (self) {
        _tmuxName = [tmuxName copy];
        _displayName = [displayName copy];
    }
    return self;
}

@end

// NSUserDefaults key for the next tmux window number. Persisted so
// window names never collide across app relaunches over a persisted
// guest (a "termx" session from a previous launch may still exist).
static NSString * const kTXNextTmuxWindowKey = @"termx.nextTmuxWindow";
// First window number for a new window (termx-1 is the session's
// initial window).
static const NSInteger kTXFirstNewTmuxWindow = 2;

@implementation TXTerminalSessionManager {
    NSMutableArray<TXTerminalSession *> *_sessions;
    NSUInteger _currentIndex;
    BOOL _tmuxStarted;
    BOOL _tmuxStartPending;
    NSUInteger _tmuxStartGeneration; // the pending start's generation, so a late timeout cannot clear a newer one
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _sessions = [NSMutableArray arrayWithObject:
            [[TXTerminalSession alloc] initWithTmuxName:@"termx-1" displayName:@"iphone"]];
        _currentIndex = 0;
        _tmuxStarted = NO;
        _tmuxStartPending = NO;
    }
    return self;
}

- (NSArray<TXTerminalSession *> *)sessions {
    return [_sessions copy];
}

- (NSUInteger)currentIndex {
    return _currentIndex;
}

- (TXTerminalSession *)currentSession {
    if (_currentIndex < _sessions.count) return _sessions[_currentIndex];
    return _sessions.firstObject;
}

- (BOOL)tmuxStarted {
    return _tmuxStarted;
}

- (BOOL)tmuxStartPending {
    return _tmuxStartPending;
}

// Display names are positional: the first session is "iphone", the
// rest "iphone 2", "iphone 3", ... Rebuilt whenever the list
// changes, so closing a window renumbers the survivors.
- (void)rebuildDisplayNames {
    NSMutableArray<TXTerminalSession *> *rebuilt = [NSMutableArray arrayWithCapacity:_sessions.count];
    for (NSUInteger i = 0; i < _sessions.count; i++) {
        NSString *display = (i == 0) ? @"iphone"
            : [NSString stringWithFormat:@"iphone %lu", (unsigned long)(i + 1)];
        [rebuilt addObject:[[TXTerminalSession alloc]
            initWithTmuxName:_sessions[i].tmuxName displayName:display]];
    }
    _sessions = rebuilt;
}

- (void)notifyUpdate {
    if ([self.delegate respondsToSelector:@selector(sessionManagerDidUpdateSessions:)]) {
        [self.delegate sessionManagerDidUpdateSessions:self];
    }
}

- (void)showAlertWithTitle:(NSString *)title message:(NSString *)message {
    if ([self.delegate respondsToSelector:@selector(sessionManager:showAlertWithTitle:message:)]) {
        [self.delegate sessionManager:self showAlertWithTitle:title message:message];
    }
}

// The next unique tmux window name, from the persisted counter.
- (NSString *)nextTmuxWindowName {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSInteger next = [defaults integerForKey:kTXNextTmuxWindowKey];
    if (next < kTXFirstNewTmuxWindow) next = kTXFirstNewTmuxWindow;
    [defaults setInteger:next + 1 forKey:kTXNextTmuxWindowKey];
    return [NSString stringWithFormat:@"termx-%ld", (long)next];
}

// A tmux command through the command prompt: prefix (Ctrl-B), then
// ":" + the command as typed text, then Enter. The prompt is tmux
// UI, so it reaches tmux even inside a full-screen app, and never
// lands in the shell. Typed text (not the paste path): the paste
// path would wrap the command in bracketed paste.
- (void)sendTmuxCommandPrompt:(NSString *)command {
    if (!self.output) return;
    [self.output sendKey:GHOSTTY_KEY_B mods:GHOSTTY_MODS_CTRL];
    [self.output sendTypedText:[@":" stringByAppendingString:command] mods:GHOSTTY_MODS_NONE];
    [self.output sendKey:GHOSTTY_KEY_ENTER mods:GHOSTTY_MODS_NONE];
}

- (BOOL)isShellAtPrompt {
    NSString *screen = [self.output visibleScreenText] ?: @"";
    // The visible screen ends at the prompt when the shell is idle:
    // the last line is "termx@iphone:<dir>$ " (or "# " as root).
    // Trim the trailing whitespace first: the prompt's trailing
    // space is part of it.
    NSString *trimmed = [screen stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSArray<NSString *> *lines = [trimmed componentsSeparatedByString:@"\n"];
    NSString *last = lines.lastObject ?: @"";
    return [last containsString:@"termx@iphone:"] &&
        ([last hasSuffix:@"$"] || [last hasSuffix:@"#"]);
}

- (void)createSession {
    if (!self.output) return;
    if (!_tmuxStarted) {
        // First window: start tmux. This types a command into the
        // shell, so only do it at a prompt, or the text lands in
        // whatever app is running (vim would read it as commands).
        if (![self isShellAtPrompt]) {
            [self showAlertWithTitle:@"Not at the shell prompt"
                             message:@"Go to the shell prompt first, then tap + to open a second window."];
            return;
        }
        NSString *name = [self nextTmuxWindowName];
        // -A attaches to an existing "termx" session (a persisted
        // guest from a previous launch) instead of failing; the
        // new-window then opens on it. The new window is created
        // in the same command, so the attach lands on it.
        NSString *command = [NSString stringWithFormat:
            @"tmux new-session -A -s termx -n termx-1 \\; new-window -n %@", name];
        [self.output sendTypedText:command mods:GHOSTTY_MODS_NONE];
        [self.output sendKey:GHOSTTY_KEY_ENTER mods:GHOSTTY_MODS_NONE];
        _tmuxStarted = YES;
        _tmuxStartPending = YES;
        NSUInteger generation = ++_tmuxStartGeneration;
        // The pending flag is only for the missing-tmux detection:
        // clear it after 6 s so a later unrelated "command not
        // found" cannot trigger a revert.
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            if (strongSelf->_tmuxStartGeneration == generation) {
                strongSelf->_tmuxStartPending = NO;
            }
        });
        // Optimistic: the session is added now; the missing-tmux
        // detection below reverts it if tmux is not installed.
        [_sessions addObject:[[TXTerminalSession alloc] initWithTmuxName:name displayName:@""]];
        [self rebuildDisplayNames];
        _currentIndex = _sessions.count - 1;
        [self notifyUpdate];
        return;
    }
    // tmux is running: a new window through the command prompt.
    NSString *name = [self nextTmuxWindowName];
    [self sendTmuxCommandPrompt:[NSString stringWithFormat:@"new-window -n %@", name]];
    [_sessions addObject:[[TXTerminalSession alloc] initWithTmuxName:name displayName:@""]];
    [self rebuildDisplayNames];
    _currentIndex = _sessions.count - 1;
    [self notifyUpdate];
}

- (void)switchToSessionAtIndex:(NSUInteger)index {
    if (index >= _sessions.count) return;
    if (index == _currentIndex) return;
    _currentIndex = index;
    if (_tmuxStarted) {
        [self sendTmuxCommandPrompt:[NSString stringWithFormat:@"select-window -t %@",
            _sessions[index].tmuxName]];
    }
    [self notifyUpdate];
}

- (void)closeSessionAtIndex:(NSUInteger)index {
    if (_sessions.count <= 1) return; // the last session never closes
    if (index >= _sessions.count) return;
    NSString *name = _sessions[index].tmuxName;
    [_sessions removeObjectAtIndex:index];
    [self rebuildDisplayNames];
    // tmux picks a window itself after a kill; select one
    // explicitly so host and tmux agree on the current window.
    // Prefer the session that was after the closed one, else the
    // last one.
    if (_currentIndex == index) {
        _currentIndex = MIN(index, _sessions.count - 1);
    } else if (_currentIndex > index) {
        _currentIndex -= 1;
    }
    if (_tmuxStarted) {
        [self sendTmuxCommandPrompt:[NSString stringWithFormat:@"kill-window -t %@", name]];
        [self sendTmuxCommandPrompt:[NSString stringWithFormat:@"select-window -t %@",
            _sessions[_currentIndex].tmuxName]];
    }
    [self notifyUpdate];
}

- (void)resetToSingleSession {
    // The guest rebooted (or tmux ended): the console is a plain
    // shell again, so the session list goes back to one.
    _sessions = [NSMutableArray arrayWithObject:
        [[TXTerminalSession alloc] initWithTmuxName:@"termx-1" displayName:@"iphone"]];
    _currentIndex = 0;
    _tmuxStarted = NO;
    _tmuxStartPending = NO;
    [self notifyUpdate];
}

- (void)checkConsoleOutputForTmuxFailure:(NSData *)data {
    if (!_tmuxStartPending) return;
    // tmux is not installed: the shell prints "tmux: command not
    // found" (bash) or "command not found: tmux" (zsh). Revert the
    // optimistic second session and tell the user why.
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!text) return;
    if ([text rangeOfString:@"command not found" options:NSCaseInsensitiveSearch].location == NSNotFound) return;
    _tmuxStartPending = NO;
    _tmuxStarted = NO;
    if (_sessions.count > 1) [_sessions removeLastObject];
    [self rebuildDisplayNames];
    _currentIndex = 0;
    [self notifyUpdate];
    [self showAlertWithTitle:@"Multiple windows need tmux"
                     message:@"tmux is not installed in this system image yet. Rebuild the image with tmux to enable multiple windows."];
}

@end
