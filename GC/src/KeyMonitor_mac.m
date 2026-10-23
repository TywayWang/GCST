#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Carbon/Carbon.h>
#import <pthread.h>
#import <stdio.h>
#import <string.h>
#import <stdlib.h>

// Per-target buffers and cursors
static NSMutableDictionary<NSString*, NSMutableString*> *_buffers = nil;
static NSMutableDictionary<NSString*, NSNumber*> *_cursorPositions = nil;
static NSString *_activeTargetId = @"terminal";
static NSString *_activeTargetName = @"Terminal";
static BOOL _activeIsTextEditor = NO;
static BOOL _isRecording = NO;
static pthread_mutex_t _lock = PTHREAD_MUTEX_INITIALIZER;

// App target caching
static pid_t _cachedPid = 0;
static BOOL _cachedIsTarget = NO;
static NSString *_cachedTargetId = @"terminal";
static NSString *_cachedTargetName = @"Terminal";
static BOOL _cachedIsTextEditor = NO;
static uint64_t _cachedTimeMs = 0;

static uint64_t getNowMs(void) {
    return (uint64_t)([[NSDate date] timeIntervalSince1970] * 1000.0);
}

// JSON Escaper
static NSString* escapeJson(NSString *input) {
    if (!input) return @"";
    NSMutableString *s = [NSMutableString stringWithCapacity:[input length] * 1.2];
    for (NSUInteger i = 0; i < [input length]; i++) {
        unichar c = [input characterAtIndex:i];
        switch (c) {
            case '\\': [s appendString:@"\\\\"]; break;
            case '\"': [s appendString:@"\\\""]; break;
            case '\b': [s appendString:@"\\b"]; break;
            case '\f': [s appendString:@"\\f"]; break;
            case '\n': [s appendString:@"\\n"]; break;
            case '\r': [s appendString:@"\\r"]; break;
            case '\t': [s appendString:@"\\t"]; break;
            default:
                if (c < 0x20) {
                    [s appendFormat:@"\\u%04x", c];
                } else {
                    [s appendFormat:@"%C", c];
                }
                break;
        }
    }
    return s;
}

static NSInteger countWords(NSString *text) {
    if (!text || [text length] == 0) return 0;
    NSArray *parts = [text componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSInteger count = 0;
    for (NSString *p in parts) {
        if ([p length] > 0) count++;
    }
    return count;
}

static NSMutableString* getBufferForTarget(NSString *targetId) {
    if (!_buffers) {
        _buffers = [[NSMutableDictionary alloc] init];
    }
    NSMutableString *buf = _buffers[targetId];
    if (!buf) {
        buf = [[NSMutableString alloc] init];
        _buffers[targetId] = buf;
    }
    return buf;
}

static NSInteger getCursorPosForTarget(NSString *targetId) {
    if (!_cursorPositions) {
        _cursorPositions = [[NSMutableDictionary alloc] init];
    }
    NSNumber *posNum = _cursorPositions[targetId];
    return posNum ? [posNum integerValue] : 0;
}

static void setCursorPosForTarget(NSString *targetId, NSInteger pos) {
    if (!_cursorPositions) {
        _cursorPositions = [[NSMutableDictionary alloc] init];
    }
    _cursorPositions[targetId] = @(pos);
}

static void notifyUpdate(NSString *targetId, NSString *targetName) {
    NSMutableString *buf = getBufferForTarget(targetId);
    NSString *text = [buf copy];
    NSInteger len = [text length];
    NSInteger words = countWords(text);
    NSString *escaped = escapeJson(text);
    printf("{\"event\":\"update\",\"target\":\"%s\",\"targetName\":\"%s\",\"text\":\"%s\",\"length\":%ld,\"words\":%ld}\n",
           [targetId UTF8String], [targetName UTF8String], [escaped UTF8String], (long)len, (long)words);
    fflush(stdout);
}

static void notifyAction(NSString *targetId, NSString *targetName, NSString *action) {
    printf("{\"event\":\"action\",\"target\":\"%s\",\"targetName\":\"%s\",\"action\":\"%s\",\"text\":\"\",\"length\":0,\"words\":0}\n",
           [targetId UTF8String], [targetName UTF8String], [action UTF8String]);
    fflush(stdout);
}

static void notifyFocus(NSString *targetId, NSString *targetName) {
    printf("{\"event\":\"focus\",\"target\":\"%s\",\"targetName\":\"%s\"}\n",
           [targetId UTF8String], [targetName UTF8String]);
    fflush(stdout);
}

static NSString *const kWordDelimiters = @";:,.[]{}()/\\|!?^&*-=+'\"`~@#$%<>";

static BOOL isInWord(unichar c) {
    if ([[NSCharacterSet whitespaceAndNewlineCharacterSet] characterIsMember:c]) return NO;
    return [kWordDelimiters rangeOfString:[NSString stringWithCharacters:&c length:1]].location == NSNotFound;
}

static NSInteger getBackwardWordPos(NSString *buf, NSInteger curPos) {
    if (curPos <= 0 || [buf length] == 0) return 0;
    NSInteger i = curPos - 1;
    if (i >= (NSInteger)[buf length]) i = (NSInteger)[buf length] - 1;
    while (i >= 0 && !isInWord([buf characterAtIndex:i])) i--;
    while (i >= 0 && isInWord([buf characterAtIndex:i])) i--;
    return MAX(0, i + 1);
}

static NSInteger getForwardWordPos(NSString *buf, NSInteger curPos) {
    NSInteger n = (NSInteger)[buf length];
    if (curPos >= n) return n;
    NSInteger i = curPos;
    while (i < n && isInWord([buf characterAtIndex:i])) i++;
    while (i < n && !isInWord([buf characterAtIndex:i])) i++;
    return MIN(n, i);
}

static void deleteWordBackward(NSString *targetId, NSString *targetName) {
    NSMutableString *buf = getBufferForTarget(targetId);
    NSInteger curPos = getCursorPosForTarget(targetId);
    if (curPos > 0 && [buf length] > 0) {
        NSInteger start = getBackwardWordPos(buf, curPos);
        NSInteger count = curPos - start;
        if (count > 0) {
            [buf deleteCharactersInRange:NSMakeRange(start, count)];
            setCursorPosForTarget(targetId, start);
            notifyUpdate(targetId, targetName);
        }
    }
}

static void deleteWordForward(NSString *targetId, NSString *targetName) {
    NSMutableString *buf = getBufferForTarget(targetId);
    NSInteger curPos = getCursorPosForTarget(targetId);
    if (curPos < (NSInteger)[buf length]) {
        NSInteger nextPos = getForwardWordPos(buf, curPos);
        NSInteger count = nextPos - curPos;
        if (count > 0) {
            [buf deleteCharactersInRange:NSMakeRange(curPos, count)];
            notifyUpdate(targetId, targetName);
        }
    }
}

static void moveWordBackward(NSString *targetId) {
    NSMutableString *buf = getBufferForTarget(targetId);
    NSInteger curPos = getCursorPosForTarget(targetId);
    setCursorPosForTarget(targetId, getBackwardWordPos(buf, curPos));
}

static void moveWordForward(NSString *targetId) {
    NSMutableString *buf = getBufferForTarget(targetId);
    NSInteger curPos = getCursorPosForTarget(targetId);
    setCursorPosForTarget(targetId, getForwardWordPos(buf, curPos));
}

static void applyPasteForTarget(NSString *targetId, NSString *targetName, BOOL isTextEditor) {
    @autoreleasepool {
        NSPasteboard *pb = [NSPasteboard generalPasteboard];
        NSString *clip = [pb stringForType:NSPasteboardTypeString];
        if (!clip || [clip length] == 0) return;

        if ([clip length] > 20000) {
            clip = [clip substringFromIndex:[clip length] - 20000];
        }

        clip = [clip stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"];
        clip = [clip stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];

        // If single line with trailing newline, strip it so prompt is not prematurely submitted
        if (![clip containsString:@"\n"] || ([clip hasSuffix:@"\n"] && [[clip componentsSeparatedByString:@"\n"] count] == 2)) {
            clip = [clip stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\n"]];
        }

        pthread_mutex_lock(&_lock);
        NSMutableString *buf = getBufferForTarget(targetId);
        NSInteger curPos = getCursorPosForTarget(targetId);
        if (curPos < 0) curPos = 0;
        if (curPos > (NSInteger)[buf length]) curPos = [buf length];

        if (isTextEditor) {
            [buf insertString:clip atIndex:curPos];
            setCursorPosForTarget(targetId, curPos + [clip length]);
            notifyUpdate(targetId, targetName);
        } else {
            NSRange lastNlRange = [clip rangeOfString:@"\n" options:NSBackwardsSearch];
            if (lastNlRange.location == NSNotFound) {
                [buf insertString:clip atIndex:curPos];
                setCursorPosForTarget(targetId, curPos + [clip length]);
                notifyUpdate(targetId, targetName);
            } else if (lastNlRange.location == [clip length] - 1) {
                // Trailing newline submitted the command
                [buf setString:@""];
                setCursorPosForTarget(targetId, 0);
                notifyAction(targetId, targetName, @"enter");
            } else {
                // Multiline paste into terminal: text after last newline remains in prompt
                NSString *remaining = [clip substringFromIndex:lastNlRange.location + 1];
                [buf setString:remaining];
                setCursorPosForTarget(targetId, [remaining length]);
                notifyUpdate(targetId, targetName);
            }
        }
        pthread_mutex_unlock(&_lock);
    }
}

static BOOL isGCApp(NSRunningApplication *app) {
    if (!app) return NO;
    NSString *bundleId = [app bundleIdentifier] ?: @"";
    NSString *appName = [app localizedName] ?: @"";
    if ([bundleId isEqualToString:@"gc-british-grammar-checker"] ||
        [bundleId rangeOfString:@"gc-british" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        return YES;
    }
    if ([bundleId isEqualToString:@"com.github.Electron"] ||
        [appName caseInsensitiveCompare:@"Electron"] == NSOrderedSame) {
        return YES;
    }
    if ([appName caseInsensitiveCompare:@"GC"] == NSOrderedSame ||
        ([appName rangeOfString:@"GC" options:NSCaseInsensitiveSearch].location != NSNotFound &&
         ([appName rangeOfString:@"British" options:NSCaseInsensitiveSearch].location != NSNotFound ||
          [appName rangeOfString:@"Editor" options:NSCaseInsensitiveSearch].location != NSNotFound ||
          [appName rangeOfString:@"Checker" options:NSCaseInsensitiveSearch].location != NSNotFound))) {
        return YES;
    }
    return NO;
}

static BOOL checkIfForegroundIsGC(void) {
    NSRunningApplication *frontApp = [[NSWorkspace sharedWorkspace] frontmostApplication];
    return isGCApp(frontApp);
}

static BOOL classifyForegroundTarget(NSRunningApplication *app, NSString **outTargetId, NSString **outTargetName, BOOL *outIsTextEditor) {
    if (!app) return NO;
    if (isGCApp(app)) return NO;

    NSString *bundleId = [app bundleIdentifier] ?: @"";
    NSString *appName = [app localizedName] ?: @"";

    // 2. Apple Notes
    if ([bundleId isEqualToString:@"com.apple.Notes"] ||
        [bundleId rangeOfString:@"apple.Notes" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [appName caseInsensitiveCompare:@"Notes"] == NSOrderedSame ||
        [appName isEqualToString:@"备忘录"]) {
        if (outTargetId) *outTargetId = @"notes";
        if (outTargetName) *outTargetName = @"Notes";
        if (outIsTextEditor) *outIsTextEditor = YES;
        return YES;
    }

    // 3. Apple TextEdit
    if ([bundleId isEqualToString:@"com.apple.TextEdit"] ||
        [bundleId rangeOfString:@"apple.TextEdit" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [appName caseInsensitiveCompare:@"TextEdit"] == NSOrderedSame ||
        [appName isEqualToString:@"文本编辑"]) {
        if (outTargetId) *outTargetId = @"textedit";
        if (outTargetName) *outTargetName = @"TextEdit";
        if (outIsTextEditor) *outIsTextEditor = YES;
        return YES;
    }

    // 4. CyberTerminal (Desktop app or Electron)
    if ([bundleId rangeOfString:@"cyberterminal" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [appName rangeOfString:@"CyberTerminal" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        if (outTargetId) *outTargetId = @"terminal";
        if (outTargetName) *outTargetName = @"CyberTerminal";
        if (outIsTextEditor) *outIsTextEditor = NO;
        return YES;
    }

    // 5. Terminal Apps: Apple Terminal, iTerm2, Warp, Alacritty, Kitty, WezTerm, Ghostty, etc.
    BOOL isTerm = NO;
    NSString *canonicalName = @"Terminal";

    if ([bundleId rangeOfString:@"alacritty" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [appName caseInsensitiveCompare:@"alacritty"] == NSOrderedSame) {
        isTerm = YES;
        canonicalName = @"Alacritty";
    } else if ([bundleId rangeOfString:@"iterm" options:NSCaseInsensitiveSearch].location != NSNotFound ||
               [appName rangeOfString:@"iterm" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        isTerm = YES;
        canonicalName = @"iTerm2";
    } else if ([bundleId rangeOfString:@"warp" options:NSCaseInsensitiveSearch].location != NSNotFound ||
               [appName caseInsensitiveCompare:@"warp"] == NSOrderedSame) {
        isTerm = YES;
        canonicalName = @"Warp";
    } else if ([bundleId rangeOfString:@"kitty" options:NSCaseInsensitiveSearch].location != NSNotFound ||
               [appName caseInsensitiveCompare:@"kitty"] == NSOrderedSame) {
        isTerm = YES;
        canonicalName = @"kitty";
    } else if ([bundleId rangeOfString:@"wezterm" options:NSCaseInsensitiveSearch].location != NSNotFound ||
               [appName rangeOfString:@"wezterm" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        isTerm = YES;
        canonicalName = @"wezterm";
    } else if ([bundleId rangeOfString:@"ghostty" options:NSCaseInsensitiveSearch].location != NSNotFound ||
               [appName caseInsensitiveCompare:@"ghostty"] == NSOrderedSame) {
        isTerm = YES;
        canonicalName = @"Ghostty";
    } else if ([bundleId isEqualToString:@"com.apple.Terminal"] ||
               [appName caseInsensitiveCompare:@"Terminal"] == NSOrderedSame) {
        isTerm = YES;
        canonicalName = @"Terminal";
    }

    if (isTerm) {
        if (outTargetId) *outTargetId = @"terminal";
        if (outTargetName) *outTargetName = [appName length] > 0 ? appName : canonicalName;
        if (outIsTextEditor) *outIsTextEditor = NO;
        return YES;
    }

    // 6. Explicitly reject code editors, browsers, IDEs, chats from loose title checks
    if ([bundleId rangeOfString:@"com.microsoft.VSCode" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [bundleId rangeOfString:@"com.apple.dt.Xcode" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [bundleId rangeOfString:@"google.Chrome" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [bundleId rangeOfString:@"apple.Safari" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [appName rangeOfString:@"Code" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [appName rangeOfString:@"Slack" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [appName rangeOfString:@"Discord" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        return NO;
    }

    // 7. Check AX Window Title for terminals or shells
    @try {
        AXUIElementRef appRef = AXUIElementCreateApplication([app processIdentifier]);
        if (appRef) {
            AXUIElementRef focusedWindow = NULL;
            AXError err = AXUIElementCopyAttributeValue(appRef, kAXFocusedWindowAttribute, (CFTypeRef *)&focusedWindow);
            if (err == kAXErrorSuccess && focusedWindow) {
                CFTypeRef titleRef = NULL;
                err = AXUIElementCopyAttributeValue(focusedWindow, kAXTitleAttribute, &titleRef);
                if (err == kAXErrorSuccess && titleRef) {
                    NSString *title = (__bridge NSString*)titleRef;
                    if ([title rangeOfString:@"Terminal" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                        [title rangeOfString:@"CyberTerminal" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                        [title rangeOfString:@"zsh" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                        [title rangeOfString:@"bash" options:NSCaseInsensitiveSearch].location != NSNotFound) {
                        CFRelease(titleRef);
                        CFRelease(focusedWindow);
                        CFRelease(appRef);
                        if (outTargetId) *outTargetId = @"terminal";
                        if (outTargetName) *outTargetName = @"Terminal";
                        if (outIsTextEditor) *outIsTextEditor = NO;
                        return YES;
                    }
                    CFRelease(titleRef);
                }
                CFRelease(focusedWindow);
            }
            CFRelease(appRef);
        }
    } @catch (id e) {}

    return NO;
}

static BOOL checkIfForegroundIsTarget(NSString **outTargetId, NSString **outTargetName, BOOL *outIsTextEditor) {
    uint64_t now = getNowMs();
    NSRunningApplication *frontApp = [[NSWorkspace sharedWorkspace] frontmostApplication];
    if (!frontApp) return NO;

    pid_t pid = [frontApp processIdentifier];
    if (pid == _cachedPid && (now - _cachedTimeMs) < 250) {
        if (outTargetId) *outTargetId = _cachedTargetId;
        if (outTargetName) *outTargetName = _cachedTargetName;
        if (outIsTextEditor) *outIsTextEditor = _cachedIsTextEditor;
        return _cachedIsTarget;
    }

    _cachedPid = pid;
    _cachedTimeMs = now;
    _cachedIsTarget = classifyForegroundTarget(frontApp, &_cachedTargetId, &_cachedTargetName, &_cachedIsTextEditor);
    if (outTargetId) *outTargetId = _cachedTargetId;
    if (outTargetName) *outTargetName = _cachedTargetName;
    if (outIsTextEditor) *outIsTextEditor = _cachedIsTextEditor;
    return _cachedIsTarget;
}

// Low level event tap callback
static CGEventRef eventTapCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *refcon) {
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        CGEventTapEnable((CFMachPortRef)refcon, true);
        return event;
    }

    // Handle mouse paste (middle click or right click)
    if (type == kCGEventRightMouseUp || type == kCGEventOtherMouseUp) {
        NSString *targetId = @"terminal";
        NSString *targetName = @"Terminal";
        BOOL isTextEditor = NO;
        if (_isRecording && checkIfForegroundIsTarget(&targetId, &targetName, &isTextEditor) && !isTextEditor) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(60 * NSEC_PER_MSEC)), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                applyPasteForTarget(targetId, targetName, isTextEditor);
            });
        }
        return event;
    }

    if (type != kCGEventKeyDown) {
        return event;
    }

    CGEventFlags flags = CGEventGetFlags(event);
    int64_t keyCode = CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);

    BOOL isCmd = (flags & kCGEventFlagMaskCommand) != 0;
    BOOL isCtrl = (flags & kCGEventFlagMaskControl) != 0;
    BOOL isAlt = (flags & kCGEventFlagMaskAlternate) != 0;
    BOOL isShift = (flags & kCGEventFlagMaskShift) != 0;

    // Ignore GC's own hotkeys:
    // macOS: Shift + Command + X and Shift + Command + Z
    if (isCmd && isShift && (keyCode == kVK_ANSI_X || keyCode == kVK_ANSI_Z)) {
        NSString *tId = nil;
        NSString *tName = nil;
        BOOL isEd = NO;
        NSRunningApplication *frontApp = [[NSWorkspace sharedWorkspace] frontmostApplication];
        if (classifyForegroundTarget(frontApp, &tId, &tName, &isEd)) {
            pthread_mutex_lock(&_lock);
            _activeTargetId = [tId copy];
            _activeTargetName = [tName copy];
            _activeIsTextEditor = isEd;
            _cachedPid = [frontApp processIdentifier];
            _cachedTimeMs = getNowMs();
            _cachedIsTarget = YES;
            _cachedTargetId = [tId copy];
            _cachedTargetName = [tName copy];
            _cachedIsTextEditor = isEd;
            pthread_mutex_unlock(&_lock);
            notifyFocus(tId, tName);
        }
        return event;
    }
    // Also ignore fallback modifier combinations if pressed
    if ((isCmd || isCtrl) && isAlt && (keyCode == kVK_ANSI_X || keyCode == kVK_ANSI_Z)) {
        return event;
    }

    // Check for Undo hotkey in Review Mode: Cmd + Z
    if (isCmd && !isShift && !isAlt && !isCtrl && keyCode == kVK_ANSI_Z) {
        uint64_t now = getNowMs();
        static uint64_t lastUndoNotifyMs = 0;
        if (now - lastUndoNotifyMs > 300) {
            lastUndoNotifyMs = now;
            NSString *targetId = @"terminal";
            NSString *targetName = @"Terminal";
            BOOL isTextEditor = NO;
            if (checkIfForegroundIsTarget(&targetId, &targetName, &isTextEditor)) {
                notifyAction(targetId, targetName, @"undo");
            } else if (checkIfForegroundIsGC()) {
                notifyAction(_activeTargetId ?: @"terminal", _activeTargetName ?: @"Terminal", @"undo");
            }
        }
    }

    pthread_mutex_lock(&_lock);
    if (!_isRecording) {
        pthread_mutex_unlock(&_lock);
        return event;
    }

    // Filter to target windows
    NSString *targetId = @"terminal";
    NSString *targetName = @"Terminal";
    BOOL isTextEditor = NO;
    if (!checkIfForegroundIsTarget(&targetId, &targetName, &isTextEditor)) {
        pthread_mutex_unlock(&_lock);
        return event;
    }

    // Check if active target switched (by ID or target application name)
    if (![_activeTargetId isEqualToString:targetId] || ![_activeTargetName isEqualToString:targetName]) {
        _activeTargetId = [targetId copy];
        _activeTargetName = [targetName copy];
        _activeIsTextEditor = isTextEditor;
        notifyFocus(_activeTargetId, _activeTargetName);
    }

    NSMutableString *buf = getBufferForTarget(targetId);
    NSInteger curPos = getCursorPosForTarget(targetId);
    if (curPos < 0) curPos = 0;
    if (curPos > (NSInteger)[buf length]) curPos = [buf length];
    setCursorPosForTarget(targetId, curPos);

    // -------------------------------------------------------------
    // COMMAND SHORTCUTS (macOS Cmd key held)
    // -------------------------------------------------------------
    if (isCmd) {
        if (keyCode == kVK_ANSI_V) {
            // Cmd + V: Paste
            pthread_mutex_unlock(&_lock);
            applyPasteForTarget(targetId, targetName, isTextEditor);
            return event;
        } else if (keyCode == kVK_Delete) {
            // Cmd + Backspace: Delete from cursor to start of line
            NSInteger lineStart = curPos - 1;
            while (lineStart >= 0 && [buf characterAtIndex:lineStart] != '\n') lineStart--;
            NSInteger start = lineStart + 1;
            NSInteger count = curPos - start;
            if (count > 0) {
                [buf deleteCharactersInRange:NSMakeRange(start, count)];
                setCursorPosForTarget(targetId, start);
                notifyUpdate(targetId, targetName);
            }
        } else if (keyCode == kVK_LeftArrow) {
            // Cmd + Left: Move to start of line
            NSInteger lineStart = curPos - 1;
            while (lineStart >= 0 && [buf characterAtIndex:lineStart] != '\n') lineStart--;
            setCursorPosForTarget(targetId, lineStart + 1);
        } else if (keyCode == kVK_RightArrow) {
            // Cmd + Right: Move to end of line
            NSInteger lineEnd = curPos;
            while (lineEnd < (NSInteger)[buf length] && [buf characterAtIndex:lineEnd] != '\n') lineEnd++;
            setCursorPosForTarget(targetId, lineEnd);
        } else if (keyCode == kVK_Return) {
            if (isTextEditor) {
                // In text editor (Notes), Cmd+Return or Return inserts newline
                [buf insertString:@"\n" atIndex:curPos];
                setCursorPosForTarget(targetId, curPos + 1);
                notifyUpdate(targetId, targetName);
            } else {
                // In terminal, Cmd + Return: Submit prompt
                [buf setString:@""];
                setCursorPosForTarget(targetId, 0);
                notifyAction(targetId, targetName, @"enter");
            }
        }
        pthread_mutex_unlock(&_lock);
        return event;
    }

    // -------------------------------------------------------------
    // CONTROL SHORTCUTS (Unix / Terminal standard line editing)
    // -------------------------------------------------------------
    if (isCtrl) {
        if (keyCode == kVK_ANSI_U) {
            // Ctrl + U: Line kill backward
            NSInteger lineStart = curPos - 1;
            while (lineStart >= 0 && [buf characterAtIndex:lineStart] != '\n') lineStart--;
            NSInteger start = lineStart + 1;
            NSInteger count = curPos - start;
            if (count > 0) {
                [buf deleteCharactersInRange:NSMakeRange(start, count)];
                setCursorPosForTarget(targetId, start);
                notifyUpdate(targetId, targetName);
            }
        } else if (keyCode == kVK_ANSI_K) {
            // Ctrl + K: Kill forward to end of line
            NSInteger lineEnd = curPos;
            while (lineEnd < (NSInteger)[buf length] && [buf characterAtIndex:lineEnd] != '\n') lineEnd++;
            NSInteger count = lineEnd - curPos;
            if (count > 0) {
                [buf deleteCharactersInRange:NSMakeRange(curPos, count)];
                notifyUpdate(targetId, targetName);
            }
        } else if (keyCode == kVK_ANSI_W || keyCode == kVK_Delete) {
            // Ctrl + W: Delete preceding word
            deleteWordBackward(targetId, targetName);
        } else if (keyCode == kVK_ForwardDelete) {
            // Ctrl + Delete: Delete following word
            deleteWordForward(targetId, targetName);
        } else if (keyCode == kVK_ANSI_A) {
            // Ctrl + A: Beginning of line
            NSInteger lineStart = curPos - 1;
            while (lineStart >= 0 && [buf characterAtIndex:lineStart] != '\n') lineStart--;
            setCursorPosForTarget(targetId, lineStart + 1);
        } else if (keyCode == kVK_ANSI_E) {
            // Ctrl + E: End of line
            NSInteger lineEnd = curPos;
            while (lineEnd < (NSInteger)[buf length] && [buf characterAtIndex:lineEnd] != '\n') lineEnd++;
            setCursorPosForTarget(targetId, lineEnd);
        } else if (keyCode == kVK_ANSI_D) {
            // Ctrl + D: Delete char at cursor
            if (curPos < (NSInteger)[buf length]) {
                [buf deleteCharactersInRange:NSMakeRange(curPos, 1)];
                notifyUpdate(targetId, targetName);
            }
        } else if (keyCode == kVK_LeftArrow) {
            // Ctrl + Left: Move backward one word
            moveWordBackward(targetId);
        } else if (keyCode == kVK_RightArrow) {
            // Ctrl + Right: Move forward one word
            moveWordForward(targetId);
        } else if (keyCode == kVK_Return) {
            if (isTextEditor) {
                [buf insertString:@"\n" atIndex:curPos];
                setCursorPosForTarget(targetId, curPos + 1);
                notifyUpdate(targetId, targetName);
            } else {
                // Ctrl + Return: Submit command
                [buf setString:@""];
                setCursorPosForTarget(targetId, 0);
                notifyAction(targetId, targetName, @"enter");
            }
        } else if (keyCode == kVK_ANSI_C) {
            // Ctrl + C in terminal: Cancels current line prompt
            if (!isTextEditor) {
                [buf setString:@""];
                setCursorPosForTarget(targetId, 0);
                notifyUpdate(targetId, targetName);
            }
        } else if (keyCode == kVK_ANSI_V) {
            pthread_mutex_unlock(&_lock);
            applyPasteForTarget(targetId, targetName, isTextEditor);
            return event;
        }
        pthread_mutex_unlock(&_lock);
        return event;
    }

    // -------------------------------------------------------------
    // OPTION / ALT SHORTCUTS
    // -------------------------------------------------------------
    if (isAlt) {
        if (keyCode == kVK_Delete || keyCode == kVK_ANSI_W) {
            // Option + Backspace: Delete preceding word
            deleteWordBackward(targetId, targetName);
        } else if (keyCode == kVK_ForwardDelete || keyCode == kVK_ANSI_D) {
            // Option + Delete: Delete following word
            deleteWordForward(targetId, targetName);
        } else if (keyCode == kVK_LeftArrow || keyCode == kVK_ANSI_B) {
            // Option + Left: Move word backward
            moveWordBackward(targetId);
        } else if (keyCode == kVK_RightArrow || keyCode == kVK_ANSI_F) {
            // Option + Right: Move word forward
            moveWordForward(targetId);
        }
        pthread_mutex_unlock(&_lock);
        return event;
    }

    // -------------------------------------------------------------
    // REGULAR KEYS (Backspace, Arrows, Return, Printable Chars)
    // -------------------------------------------------------------
    if (keyCode == kVK_Delete) {
        // Backspace
        if (curPos > 0) {
            [buf deleteCharactersInRange:NSMakeRange(curPos - 1, 1)];
            setCursorPosForTarget(targetId, curPos - 1);
            notifyUpdate(targetId, targetName);
        }
    } else if (keyCode == kVK_ForwardDelete) {
        // Forward Delete
        if (curPos < (NSInteger)[buf length]) {
            [buf deleteCharactersInRange:NSMakeRange(curPos, 1)];
            notifyUpdate(targetId, targetName);
        }
    } else if (keyCode == kVK_LeftArrow) {
        if (curPos > 0) setCursorPosForTarget(targetId, curPos - 1);
    } else if (keyCode == kVK_RightArrow) {
        if (curPos < (NSInteger)[buf length]) setCursorPosForTarget(targetId, curPos + 1);
    } else if (keyCode == kVK_Home) {
        NSInteger lineStart = curPos - 1;
        while (lineStart >= 0 && [buf characterAtIndex:lineStart] != '\n') lineStart--;
        setCursorPosForTarget(targetId, lineStart + 1);
    } else if (keyCode == kVK_End) {
        NSInteger lineEnd = curPos;
        while (lineEnd < (NSInteger)[buf length] && [buf characterAtIndex:lineEnd] != '\n') lineEnd++;
        setCursorPosForTarget(targetId, lineEnd);
    } else if (keyCode == kVK_Return) {
        if (isTextEditor) {
            [buf insertString:@"\n" atIndex:curPos];
            setCursorPosForTarget(targetId, curPos + 1);
            notifyUpdate(targetId, targetName);
        } else {
            // In Terminal / CyberTerminal, Enter submits the prompt
            [buf setString:@""];
            setCursorPosForTarget(targetId, 0);
            notifyAction(targetId, targetName, @"enter");
        }
    } else if (keyCode == kVK_Space) {
        [buf insertString:@" " atIndex:curPos];
        setCursorPosForTarget(targetId, curPos + 1);
        notifyUpdate(targetId, targetName);
    } else if (keyCode == kVK_Tab) {
        [buf insertString:@"\t" atIndex:curPos];
        setCursorPosForTarget(targetId, curPos + 1);
        notifyUpdate(targetId, targetName);
    } else if (keyCode == kVK_Escape) {
        // Escape
    } else {
        // Extract Unicode string from event
        UniChar chars[16];
        UniCharCount actualLength = 0;
        CGEventKeyboardGetUnicodeString(event, 16, &actualLength, chars);
        if (actualLength > 0) {
            NSMutableString *typedStr = [NSMutableString stringWithCapacity:actualLength];
            for (UniCharCount i = 0; i < actualLength; i++) {
                unichar c = chars[i];
                if (![[NSCharacterSet controlCharacterSet] characterIsMember:c] || c == '\r' || c == '\n' || c == '\t') {
                    [typedStr appendFormat:@"%C", c];
                }
            }
            if ([typedStr length] > 0) {
                [buf insertString:typedStr atIndex:curPos];
                setCursorPosForTarget(targetId, curPos + [typedStr length]);
                notifyUpdate(targetId, targetName);
            }
        }
    }

    pthread_mutex_unlock(&_lock);
    return event;
}

// Thread reading commands from stdin
static void* stdinThreadFunc(void *arg) {
    char lineBuf[512];
    while (fgets(lineBuf, sizeof(lineBuf), stdin) != NULL) {
        size_t len = strlen(lineBuf);
        while (len > 0 && (lineBuf[len - 1] == '\r' || lineBuf[len - 1] == '\n')) {
            lineBuf[--len] = '\0';
        }

        if (strcmp(lineBuf, "START") == 0) {
            pthread_mutex_lock(&_lock);
            _isRecording = YES;
            pthread_mutex_unlock(&_lock);
            printf("{\"event\":\"started\"}\n");
            fflush(stdout);
        } else if (strncmp(lineBuf, "CLEAR", 5) == 0) {
            pthread_mutex_lock(&_lock);
            NSString *specifiedTarget = nil;
            if (strlen(lineBuf) > 5) {
                specifiedTarget = [NSString stringWithUTF8String:lineBuf + 5];
                specifiedTarget = [specifiedTarget stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            }
            if (specifiedTarget && [specifiedTarget length] > 0) {
                NSMutableString *b = getBufferForTarget(specifiedTarget);
                [b setString:@""];
                setCursorPosForTarget(specifiedTarget, 0);
            } else {
                for (NSString *key in _buffers) {
                    [_buffers[key] setString:@""];
                    _cursorPositions[key] = @0;
                }
            }
            pthread_mutex_unlock(&_lock);
        } else if (strcmp(lineBuf, "STOP") == 0) {
            pthread_mutex_lock(&_lock);
            _isRecording = NO;
            NSMutableString *b = getBufferForTarget(_activeTargetId);
            NSString *captured = [b copy];
            [b setString:@""];
            setCursorPosForTarget(_activeTargetId, 0);
            pthread_mutex_unlock(&_lock);
            NSString *escaped = escapeJson(captured);
            printf("{\"event\":\"stopped\",\"target\":\"%s\",\"text\":\"%s\"}\n",
                   [_activeTargetId UTF8String], [escaped UTF8String]);
            fflush(stdout);
        } else if (strcmp(lineBuf, "STATUS") == 0) {
            pthread_mutex_lock(&_lock);
            NSMutableString *b = getBufferForTarget(_activeTargetId);
            NSString *text = [b copy];
            BOOL rec = _isRecording;
            pthread_mutex_unlock(&_lock);
            NSInteger wordCount = countWords(text);
            NSString *escaped = escapeJson(text);
            printf("{\"event\":\"status\",\"target\":\"%s\",\"recording\":%s,\"length\":%ld,\"words\":%ld,\"text\":\"%s\"}\n",
                   [_activeTargetId UTF8String], rec ? "true" : "false", (long)[text length], (long)wordCount, [escaped UTF8String]);
            fflush(stdout);
        } else if (strcmp(lineBuf, "EXIT") == 0) {
            exit(0);
        }
    }
    exit(0);
    return NULL;
}

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        _buffers = [[NSMutableDictionary alloc] init];
        _cursorPositions = [[NSMutableDictionary alloc] init];

        // Prompt for Accessibility if not yet trusted
        NSDictionary *options = @{(__bridge id)kAXTrustedCheckOptionPrompt: @YES};
        BOOL trusted = AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
        if (!trusted) {
            fprintf(stderr, "[GC KeyMonitor] WARNING: Accessibility permissions not granted. Prompting user...\n");
        }

        // Start background thread for stdin commands
        pthread_t stdinThread;
        pthread_create(&stdinThread, NULL, stdinThreadFunc, NULL);

        // Create CGEventTap for keyboard and mouse
        CGEventMask eventMask = (1 << kCGEventKeyDown) |
                                (1 << kCGEventRightMouseUp) |
                                (1 << kCGEventOtherMouseUp);

        CFMachPortRef eventTap = CGEventTapCreate(
            kCGSessionEventTap,
            kCGHeadInsertEventTap,
            kCGEventTapOptionListenOnly,
            eventMask,
            eventTapCallback,
            NULL
        );

        if (!eventTap) {
            fprintf(stderr, "[GC KeyMonitor] ERROR: Failed to create event tap. Ensure Accessibility is enabled for this process.\n");
        } else {
            CFRunLoopSourceRef runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0);
            CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, kCFRunLoopCommonModes);
            CGEventTapEnable(eventTap, true);
        }

        // Detect initially frontmost application on startup
        NSRunningApplication *initApp = [[NSWorkspace sharedWorkspace] frontmostApplication];
        NSString *initTId = nil;
        NSString *initTName = nil;
        BOOL initIsEd = NO;
        if (classifyForegroundTarget(initApp, &initTId, &initTName, &initIsEd)) {
            pthread_mutex_lock(&_lock);
            _activeTargetId = [initTId copy];
            _activeTargetName = [initTName copy];
            _activeIsTextEditor = initIsEd;
            _cachedPid = [initApp processIdentifier];
            _cachedTimeMs = getNowMs();
            _cachedIsTarget = YES;
            _cachedTargetId = [initTId copy];
            _cachedTargetName = [initTName copy];
            _cachedIsTextEditor = initIsEd;
            pthread_mutex_unlock(&_lock);
            notifyFocus(initTId, initTName);
        }

        // Observe foreground app activations to immediately notify focus switches
        [[[NSWorkspace sharedWorkspace] notificationCenter] addObserverForName:NSWorkspaceDidActivateApplicationNotification
                                                                        object:nil
                                                                         queue:[NSOperationQueue mainQueue]
                                                                    usingBlock:^(NSNotification *note) {
            NSRunningApplication *app = note.userInfo[NSWorkspaceApplicationKey];
            NSString *tId = nil;
            NSString *tName = nil;
            BOOL isEd = NO;
            if (classifyForegroundTarget(app, &tId, &tName, &isEd)) {
                pthread_mutex_lock(&_lock);
                _activeTargetId = [tId copy];
                _activeTargetName = [tName copy];
                _activeIsTextEditor = isEd;
                _cachedPid = [app processIdentifier];
                _cachedTimeMs = getNowMs();
                _cachedIsTarget = YES;
                _cachedTargetId = [tId copy];
                _cachedTargetName = [tName copy];
                _cachedIsTextEditor = isEd;
                pthread_mutex_unlock(&_lock);
                notifyFocus(tId, tName);
            } else {
                NSString *appName = [app localizedName] ?: @"";
                if ([appName rangeOfString:@"GC" options:NSCaseInsensitiveSearch].location == NSNotFound) {
                    printf("{\"event\":\"blur\"}\n");
                    fflush(stdout);
                }
            }
        }];

        CFRunLoopRun();
    }
    return 0;
}
