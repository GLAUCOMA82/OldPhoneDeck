// PhoneCam — iOS 9 / armv7 companion app for phonedeck.
//
// Shows the PhoneDeck page (second screen, launcher, Claude) in a web view and, at the same
// time, streams the camera (JPEG frames) and microphone (16 kHz mono s16le PCM) to the Mac
// over one TCP connection on phonedeck's port + 1.
//
// Wire format, every message: 1 byte type | 4 bytes big-endian length | payload
//   'H' hello: access token (UTF-8)      'V' video: one JPEG frame      'A' audio: PCM chunk
//
// With no Wi-Fi, both travel over the USB cable instead: see "Cable relay" below.

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <ImageIO/ImageIO.h>
#import <MobileCoreServices/MobileCoreServices.h>
#include <libkern/OSAtomic.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <poll.h>
#include <pthread.h>
#include <sys/socket.h>
#include <unistd.h>

#pragma mark - Link

@interface Link : NSObject
@property (nonatomic, readonly) BOOL connected;
- (void)connectToHost:(NSString *)host port:(int)port token:(NSString *)token;
- (void)sendVideo:(NSData *)jpeg;
- (void)sendAudio:(NSData *)pcm;
@end

@implementation Link {
    dispatch_queue_t _queue;
    int _fd;
    NSString *_host, *_token;
    int _port;
    volatile int32_t _videoInFlight;
    BOOL _connecting;
}

- (instancetype)init {
    if ((self = [super init])) {
        _queue = dispatch_queue_create("phonecam.link", DISPATCH_QUEUE_SERIAL);
        _fd = -1;
    }
    return self;
}

- (BOOL)connected { return _fd >= 0; }

- (void)connectToHost:(NSString *)host port:(int)port token:(NSString *)token {
    dispatch_async(_queue, ^{
        self->_host = host; self->_port = port; self->_token = token ?: @"";
        [self closeSocket];
        [self open];
    });
}

// Runs on _queue.
- (void)open {
    if (_fd >= 0 || _connecting || !_host.length) return;
    _connecting = YES;
    struct addrinfo hints = {0}, *res = NULL;
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    char port[8]; snprintf(port, sizeof port, "%d", _port);
    int fd = -1;
    if (getaddrinfo(_host.UTF8String, port, &hints, &res) == 0 && res) {
        fd = socket(res->ai_family, res->ai_socktype, res->ai_protocol);
        int one = 1;
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
        struct timeval tv = { .tv_sec = 3 };
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
        if (connect(fd, res->ai_addr, res->ai_addrlen) != 0) { close(fd); fd = -1; }
        freeaddrinfo(res);
    }
    _connecting = NO;
    if (fd < 0) { [self retryLater]; return; }
    _fd = fd;
    if (![self writeType:'H' data:[_token dataUsingEncoding:NSUTF8StringEncoding]]) [self retryLater];
}

- (void)retryLater {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), _queue, ^{ [self open]; });
}

- (void)closeSocket {
    if (_fd >= 0) { close(_fd); _fd = -1; }
}

// Runs on _queue. Returns NO (and schedules a reconnect) if the socket died.
- (BOOL)writeType:(uint8_t)type data:(NSData *)data {
    if (_fd < 0) return NO;
    uint8_t head[5] = { type };
    uint32_t len = htonl((uint32_t)data.length);
    memcpy(head + 1, &len, 4);
    const uint8_t *chunks[2] = { head, data.bytes };
    size_t sizes[2] = { 5, data.length };
    for (int i = 0; i < 2; i++) {
        size_t off = 0;
        while (off < sizes[i]) {
            ssize_t n = write(_fd, chunks[i] + off, sizes[i] - off);
            if (n <= 0) { [self closeSocket]; [self retryLater]; return NO; }
            off += (size_t)n;
        }
    }
    return YES;
}

- (void)sendVideo:(NSData *)jpeg {
    // Drop frames rather than queueing them: latency matters more than smoothness for a webcam.
    if (!OSAtomicCompareAndSwap32(0, 1, &_videoInFlight)) return;
    dispatch_async(_queue, ^{
        [self writeType:'V' data:jpeg];
        OSAtomicCompareAndSwap32(1, 0, &self->_videoInFlight);
    });
}

- (void)sendAudio:(NSData *)pcm {
    dispatch_async(_queue, ^{ [self writeType:'A' data:pcm]; });
}
@end

#pragma mark - Camera

@interface Camera : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@property (nonatomic, weak) Link *link;
@property (nonatomic, readonly) BOOL running;
@property (nonatomic) AVCaptureVideoOrientation orientation;
- (void)start;
- (void)stop;
- (void)flip;
@end

@implementation Camera {
    AVCaptureSession *_session;
    AVCaptureDeviceInput *_input;
    AVCaptureVideoDataOutput *_output;
    dispatch_queue_t _queue;
    AVCaptureDevicePosition _position;
    NSDictionary *_jpegOptions;
}

- (instancetype)init {
    if ((self = [super init])) {
        _queue = dispatch_queue_create("phonecam.video", DISPATCH_QUEUE_SERIAL);
        _position = AVCaptureDevicePositionFront;
        _orientation = AVCaptureVideoOrientationLandscapeRight;
        _jpegOptions = @{ (__bridge NSString *)kCGImageDestinationLossyCompressionQuality: @0.5 };
    }
    return self;
}

- (BOOL)running { return _session.running; }

- (AVCaptureDevice *)deviceAt:(AVCaptureDevicePosition)position {
    for (AVCaptureDevice *d in [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo])
        if (d.position == position) return d;
    return [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
}

- (void)configure {
    _session = [AVCaptureSession new];
    _session.sessionPreset = AVCaptureSessionPreset640x480;
    _output = [AVCaptureVideoDataOutput new];
    _output.videoSettings = @{ (__bridge NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA) };
    _output.alwaysDiscardsLateVideoFrames = YES;
    [_output setSampleBufferDelegate:self queue:_queue];
    if ([_session canAddOutput:_output]) [_session addOutput:_output];
    [self attachDevice];
}

- (void)attachDevice {
    [_session beginConfiguration];
    if (_input) [_session removeInput:_input];
    AVCaptureDevice *dev = [self deviceAt:_position];
    _input = [AVCaptureDeviceInput deviceInputWithDevice:dev error:nil];
    if (_input && [_session canAddInput:_input]) [_session addInput:_input];
    // 15 fps is what the A5 can JPEG-encode comfortably while also showing the PhoneDeck screen.
    if ([dev lockForConfiguration:nil]) {
        dev.activeVideoMinFrameDuration = CMTimeMake(1, 15);
        dev.activeVideoMaxFrameDuration = CMTimeMake(1, 15);
        [dev unlockForConfiguration];
    }
    AVCaptureConnection *c = [_output connectionWithMediaType:AVMediaTypeVideo];
    if (c.isVideoOrientationSupported) c.videoOrientation = _orientation;
    [_session commitConfiguration];
}

- (void)setOrientation:(AVCaptureVideoOrientation)orientation {
    _orientation = orientation;
    AVCaptureConnection *c = [_output connectionWithMediaType:AVMediaTypeVideo];
    if (c.isVideoOrientationSupported) c.videoOrientation = orientation;
}

- (void)start {
    [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted) {
        if (!granted) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!self->_session) [self configure];
            [self->_session startRunning];
        });
    }];
}

- (void)stop { [_session stopRunning]; }

- (void)flip {
    _position = _position == AVCaptureDevicePositionFront ? AVCaptureDevicePositionBack : AVCaptureDevicePositionFront;
    if (_session) [self attachDevice];
}

- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sb
       fromConnection:(AVCaptureConnection *)connection {
    Link *link = self.link;
    if (!link.connected) return;
    CVImageBufferRef pb = CMSampleBufferGetImageBuffer(sb);
    if (!pb) return;
    CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(pb),
                                             CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb), 8,
                                             CVPixelBufferGetBytesPerRow(pb), cs,
                                             kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    CGImageRef img = ctx ? CGBitmapContextCreateImage(ctx) : NULL;
    CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    if (ctx) CGContextRelease(ctx);
    CGColorSpaceRelease(cs);
    if (!img) return;
    NSMutableData *jpeg = [NSMutableData data];
    CGImageDestinationRef dest = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)jpeg, kUTTypeJPEG, 1, NULL);
    CGImageDestinationAddImage(dest, img, (__bridge CFDictionaryRef)_jpegOptions);
    BOOL ok = CGImageDestinationFinalize(dest);
    CFRelease(dest);
    CGImageRelease(img);
    if (ok) [link sendVideo:jpeg];
}
@end

#pragma mark - Microphone

static const double kSampleRate = 16000;

@interface Mic : NSObject
@property (nonatomic, weak) Link *link;
@property (nonatomic, readonly) BOOL running;
- (void)start;
- (void)stop;
- (NSString *)useNextSource;
@end

@implementation Mic {
    AudioQueueRef _queue;
}

static void MicCallback(void *ctx, AudioQueueRef q, AudioQueueBufferRef buf,
                        const AudioTimeStamp *t, UInt32 n, const AudioStreamPacketDescription *d) {
    Mic *mic = (__bridge Mic *)ctx;
    Link *link = mic.link;
    if (buf->mAudioDataByteSize && link.connected)
        [link sendAudio:[NSData dataWithBytes:buf->mAudioData length:buf->mAudioDataByteSize]];
    if (mic.running) AudioQueueEnqueueBuffer(q, buf, 0, NULL);
}

- (BOOL)running { return _queue != NULL; }

- (void)start {
    if (_queue) return;
    AVAudioSession *s = [AVAudioSession sharedInstance];
    [s requestRecordPermission:^(BOOL granted) {
        if (!granted) return;
        dispatch_async(dispatch_get_main_queue(), ^{ [self startQueue]; });
    }];
}

// The iPhone 4S has two microphones: one on the bottom edge by the dock connector (what iOS records from by
// default) and one on top by the headphone jack. The bottom one is easily covered by a dock or case, and on
// an old phone it may simply be worn out, so the top one is the default here. Hold the MIC button to switch.

- (AVAudioSessionPortDescription *)builtInMic {
    for (AVAudioSessionPortDescription *p in [AVAudioSession sharedInstance].availableInputs)
        if ([p.portType isEqualToString:AVAudioSessionPortBuiltInMic]) return p;
    return nil;
}

// Selects the saved microphone (or the first one that isn't on the bottom). Returns its name, nil if there is no choice.
- (NSString *)applySource {
    AVAudioSession *s = [AVAudioSession sharedInstance];
    AVAudioSessionPortDescription *port = [self builtInMic];
    NSArray *sources = port.dataSources;
    if (!sources.count) return nil;
    NSString *saved = [[NSUserDefaults standardUserDefaults] stringForKey:@"micSource"];
    AVAudioSessionDataSourceDescription *pick = nil;
    for (AVAudioSessionDataSourceDescription *d in sources)
        if ([d.dataSourceName isEqualToString:saved]) pick = d;
    if (!pick) for (AVAudioSessionDataSourceDescription *d in sources)
        if (![d.orientation isEqualToString:AVAudioSessionOrientationBottom]) { pick = d; break; }
    if (!pick) pick = sources[0];
    [port setPreferredDataSource:pick error:nil];
    [s setPreferredInput:port error:nil];
    if (s.isInputGainSettable) [s setInputGain:1.0 error:nil];
    return pick.dataSourceName;
}

// Switches to the phone's next microphone and remembers it. Returns the new one's name, nil if there is only one.
- (NSString *)useNextSource {
    NSArray *sources = [self builtInMic].dataSources;
    if (sources.count < 2) return nil;
    NSString *current = [self applySource];
    NSUInteger i = 0;
    for (NSUInteger k = 0; k < sources.count; k++)
        if ([[sources[k] dataSourceName] isEqualToString:current]) i = k;
    NSString *next = [sources[(i + 1) % sources.count] dataSourceName];
    [[NSUserDefaults standardUserDefaults] setObject:next forKey:@"micSource"];
    BOOL wasRunning = self.running;
    [self stop];
    if (wasRunning) [self startQueue]; else [self applySource];
    return next;
}

- (void)startQueue {
    if (_queue) return;
    AVAudioSession *s = [AVAudioSession sharedInstance];
    [s setCategory:AVAudioSessionCategoryPlayAndRecord
       withOptions:AVAudioSessionCategoryOptionMixWithOthers | AVAudioSessionCategoryOptionDefaultToSpeaker error:nil];
    [s setActive:YES error:nil];
    [self applySource];

    AudioStreamBasicDescription f = {0};
    f.mSampleRate = kSampleRate;
    f.mFormatID = kAudioFormatLinearPCM;
    f.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked;
    f.mChannelsPerFrame = 1;
    f.mBitsPerChannel = 16;
    f.mBytesPerFrame = f.mBytesPerPacket = 2;
    f.mFramesPerPacket = 1;
    if (AudioQueueNewInput(&f, MicCallback, (__bridge void *)self, NULL, kCFRunLoopCommonModes, 0, &_queue) != noErr) {
        _queue = NULL; return;
    }
    UInt32 bytes = (UInt32)(kSampleRate * 0.04) * 2;   // 40 ms chunks
    for (int i = 0; i < 4; i++) {
        AudioQueueBufferRef b;
        AudioQueueAllocateBuffer(_queue, bytes, &b);
        AudioQueueEnqueueBuffer(_queue, b, 0, NULL);
    }
    AudioQueueStart(_queue, NULL);
}

- (void)stop {
    if (!_queue) return;
    AudioQueueRef q = _queue;
    _queue = NULL;
    AudioQueueStop(q, true);
    AudioQueueDispose(q, true);
}
@end

#pragma mark - Cable relay

// A USB cable only lets the Mac open connections to the phone (through usbmuxd), never the reverse.
// So phonedeck on the Mac keeps a few idle connections open to kTunnelPort here. The relay also
// listens on 127.0.0.1 at phonedeck's own ports; the web view and the camera link connect to those.
// Each local connection claims one idle Mac connection, sends the Mac port it wants (2 bytes,
// big-endian), and the two are then piped together.

enum { kTunnelPort = 27045 };

static NSLock *gRelayLock;
static NSMutableArray *gIdleTunnels;      // NSNumber file descriptors, connections from the Mac not yet in use
static volatile int32_t gActivePipes;

static void RelaySockOpts(int fd) {
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
}

static int RelayListen(int port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    struct sockaddr_in a = {0};
    a.sin_len = sizeof a; a.sin_family = AF_INET; a.sin_port = htons(port);
    a.sin_addr.s_addr = inet_addr("127.0.0.1");
    if (bind(fd, (struct sockaddr *)&a, sizeof a) != 0 || listen(fd, 16) != 0) { close(fd); return -1; }
    return fd;
}

// The Mac sends nothing on an idle connection, so anything readable there means it has closed.
static BOOL RelayAlive(int fd) {
    struct pollfd p = { .fd = fd, .events = POLLIN };
    return poll(&p, 1, 0) == 0;
}

// Drops dead idle connections and returns how many are left.
static NSUInteger RelayPrune(void) {
    [gRelayLock lock];
    for (NSInteger i = (NSInteger)gIdleTunnels.count - 1; i >= 0; i--) {
        int fd = [gIdleTunnels[i] intValue];
        if (!RelayAlive(fd)) { close(fd); [gIdleTunnels removeObjectAtIndex:i]; }
    }
    NSUInteger n = gIdleTunnels.count;
    [gRelayLock unlock];
    return n;
}

// Waits up to 3 s for a live idle connection from the Mac. Returns -1 if the cable link is down.
static int RelayClaim(void) {
    for (int attempt = 0; attempt < 30; attempt++) {
        int fd = -1;
        [gRelayLock lock];
        if (gIdleTunnels.count) { fd = [gIdleTunnels[0] intValue]; [gIdleTunnels removeObjectAtIndex:0]; }
        [gRelayLock unlock];
        if (fd < 0) { usleep(100 * 1000); continue; }
        if (RelayAlive(fd)) return fd;
        close(fd);
    }
    return -1;
}

typedef struct { int from, to; } RelayPump;

static void *RelayPumpRun(void *arg) {
    RelayPump p = *(RelayPump *)arg;
    uint8_t buf[16 * 1024];
    for (;;) {
        ssize_t n = read(p.from, buf, sizeof buf);
        if (n <= 0) break;
        ssize_t off = 0;
        while (off < n) { ssize_t w = write(p.to, buf + off, (size_t)(n - off)); if (w <= 0) break; off += w; }
        if (off < n) break;
    }
    // Either side ending ends the pair; data already written is still delivered.
    shutdown(p.from, SHUT_RDWR); shutdown(p.to, SHUT_RDWR);
    return NULL;
}

typedef struct { int client, macPort; } RelayJob;

static void *RelayServe(void *arg) {
    RelayJob job = *(RelayJob *)arg; free(arg);
    int tunnel = RelayClaim();
    uint8_t head[2] = { (uint8_t)(job.macPort >> 8), (uint8_t)(job.macPort & 0xFF) };
    if (tunnel < 0 || write(tunnel, head, 2) != 2) { if (tunnel >= 0) close(tunnel); close(job.client); return NULL; }
    OSAtomicIncrement32(&gActivePipes);
    RelayPump up = { job.client, tunnel }, down = { tunnel, job.client };
    pthread_t t;
    BOOL threaded = pthread_create(&t, NULL, RelayPumpRun, &up) == 0;
    RelayPumpRun(&down);
    if (threaded) pthread_join(t, NULL);
    close(tunnel); close(job.client);
    OSAtomicDecrement32(&gActivePipes);
    return NULL;
}

static void RelayDetach(void *(*fn)(void *), void *arg) {
    pthread_t t; pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    pthread_attr_setstacksize(&attr, 128 * 1024);
    if (pthread_create(&t, &attr, fn, arg) != 0 && arg) { close(((RelayJob *)arg)->client); free(arg); }
    pthread_attr_destroy(&attr);
}

// Accept loop for one port. macPort 0 = the tunnel port (connections from the Mac); otherwise a
// local port that stands in for the same port on the Mac. iOS can invalidate a listening socket
// while the app is suspended, so a failed accept rebuilds it.
static void *RelayAccept(void *arg) {
    int macPort = (int)(intptr_t)arg, port = macPort ? macPort : kTunnelPort;
    for (;;) {
        int lfd = RelayListen(port);
        if (lfd < 0) { sleep(2); continue; }
        for (;;) {
            int c = accept(lfd, NULL, NULL);
            if (c < 0) break;
            RelaySockOpts(c);
            if (!macPort) {
                [gRelayLock lock]; [gIdleTunnels addObject:@(c)]; [gRelayLock unlock];
            } else {
                RelayJob *job = malloc(sizeof *job);
                job->client = c; job->macPort = macPort;
                RelayDetach(RelayServe, job);
            }
        }
        close(lfd);
        sleep(1);
    }
    return NULL;
}

// Starts the relay once. basePort is phonedeck's HTTP port; the camera/mic link uses basePort + 1.
static void RelayStart(int basePort) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gRelayLock = [NSLock new];
        gIdleTunnels = [NSMutableArray new];
        signal(SIGPIPE, SIG_IGN);
        intptr_t ports[3] = { 0, basePort, basePort + 1 };
        for (int i = 0; i < 3; i++) {
            pthread_t t;
            if (pthread_create(&t, NULL, RelayAccept, (void *)ports[i]) == 0) pthread_detach(t);
        }
    });
}

// YES while the Mac is reachable over the cable.
static BOOL RelayReady(void) {
    if (!gRelayLock) return NO;
    return RelayPrune() > 0 || gActivePipes > 0;
}

#pragma mark - UI

@interface DeckController : UIViewController <UIWebViewDelegate>
@end

@implementation DeckController {
    UIWebView *_web;
    UIButton *_camBtn, *_micBtn, *_flipBtn, *_setBtn;
    Link *_link;
    Camera *_camera;
    Mic *_mic;
    NSTimer *_statusTimer;
    BOOL _onCable;        // the page and the camera link are going through the USB cable
    int _cableChanged;    // seconds the cable state has differed from _onCable
}

- (NSString *)deckURL {
    NSString *saved = [[NSUserDefaults standardUserDefaults] stringForKey:@"deckURL"];
    return saved.length ? saved : [[NSBundle mainBundle] objectForInfoDictionaryKey:@"PhoneDeckURL"];
}

- (UIButton *)button:(NSString *)title action:(SEL)sel {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont boldSystemFontOfSize:11];
    b.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.75];
    b.layer.cornerRadius = 6;
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:b];
    return b;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];
    _web = [[UIWebView alloc] initWithFrame:self.view.bounds];
    _web.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _web.scrollView.scrollEnabled = NO;
    _web.scrollView.bounces = NO;
    _web.backgroundColor = [UIColor blackColor];
    _web.opaque = NO;
    _web.delegate = self;
    [self.view addSubview:_web];

    _camBtn = [self button:@"CAM" action:@selector(toggleCam)];
    _micBtn = [self button:@"MIC" action:@selector(toggleMic)];
    [_micBtn addGestureRecognizer:[[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(switchMic:)]];
    _flipBtn = [self button:@"FLIP" action:@selector(flip)];
    _setBtn = [self button:@"SET" action:@selector(settings)];

    _link = [Link new];
    _camera = [Camera new]; _camera.link = _link;
    _mic = [Mic new]; _mic.link = _link;

    [self loadDeck];
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (![d objectForKey:@"cam"] || [d boolForKey:@"cam"]) [_camera start];
    if (![d objectForKey:@"mic"] || [d boolForKey:@"mic"]) [_mic start];
    _statusTimer = [NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(refreshButtons)
                                                  userInfo:nil repeats:YES];
    [UIDevice currentDevice].batteryMonitoringEnabled = YES;
    [NSTimer scheduledTimerWithTimeInterval:30 target:self selector:@selector(reportPhone) userInfo:nil repeats:YES];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    // Small pill buttons along the top-right edge, clear of PhoneDeck's bottom tab bar.
    CGFloat w = 40, h = 22, x = self.view.bounds.size.width - w - 4;
    NSArray *buttons = @[_camBtn, _micBtn, _flipBtn, _setBtn];
    for (NSUInteger i = 0; i < buttons.count; i++)
        [buttons[i] setFrame:CGRectMake(x, 4 + i * (h + 4), w, h)];
    UIInterfaceOrientation o = [UIApplication sharedApplication].statusBarOrientation;
    _camera.orientation = o == UIInterfaceOrientationLandscapeLeft ? AVCaptureVideoOrientationLandscapeLeft
                                                                   : AVCaptureVideoOrientationLandscapeRight;
}

- (void)loadDeck {
    NSURL *url = [NSURL URLWithString:[self deckURL]];
    if (!url.host) return;
    RelayStart(url.port ? url.port.intValue : 8045);
    // Over the cable the Mac is reached through the relay on this phone: same URL, host 127.0.0.1.
    _onCable = RelayReady();
    _cableChanged = 0;
    if (_onCable) {
        NSURLComponents *c = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
        c.scheme = @"http"; c.host = @"127.0.0.1";
        if (!c.port) c.port = @8045;
        url = c.URL;
    }
    [_setBtn setTitle:_onCable ? @"USB" : @"SET" forState:UIControlStateNormal];
    [_web loadRequest:[NSURLRequest requestWithURL:url]];
    // Media goes to phonedeck's port + 1; the token is the k= in the URL fragment.
    int port = (url.port ? url.port.intValue : 8045) + 1;
    NSString *token = @"";
    for (NSString *part in [url.fragment ?: @"" componentsSeparatedByString:@"&"])
        if ([part hasPrefix:@"k="]) token = [part substringFromIndex:2];
    [_link connectToHost:url.host port:port token:token];
}

// Hands the phone's own battery to the dashboard (Safari pages can't read it on iOS 8/9).
- (void)reportPhone {
    UIDevice *d = [UIDevice currentDevice];
    if (d.batteryLevel < 0) return;
    BOOL charging = d.batteryState == UIDeviceBatteryStateCharging || d.batteryState == UIDeviceBatteryStateFull;
    [_web stringByEvaluatingJavaScriptFromString:[NSString stringWithFormat:
        @"window.deckPhone && deckPhone({level:%.2f,charging:%@})", d.batteryLevel, charging ? @"true" : @"false"]];
}

- (void)refreshButtons {
    UIColor *on = [UIColor colorWithRed:0.04 green:0.52 blue:1 alpha:0.9];
    UIColor *off = [UIColor colorWithWhite:0.1 alpha:0.75];
    UIColor *warn = [UIColor colorWithRed:0.8 green:0.3 blue:0.1 alpha:0.9];
    BOOL linked = _link.connected;
    _camBtn.backgroundColor = _camera.running ? (linked ? on : warn) : off;
    _micBtn.backgroundColor = _mic.running ? (linked ? on : warn) : off;
    // Cable plugged in or pulled: after two seconds in the new state, reload through the other route.
    if (RelayReady() != _onCable) { if (++_cableChanged >= 2) [self loadDeck]; }
    else _cableChanged = 0;
}

- (void)toggleCam {
    BOOL want = !_camera.running;
    if (want) [_camera start]; else [_camera stop];
    [[NSUserDefaults standardUserDefaults] setBool:want forKey:@"cam"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), dispatch_get_main_queue(), ^{ [self refreshButtons]; });
}

- (void)toggleMic {
    BOOL want = !_mic.running;
    if (want) [_mic start]; else [_mic stop];
    [[NSUserDefaults standardUserDefaults] setBool:want forKey:@"mic"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), dispatch_get_main_queue(), ^{ [self refreshButtons]; });
}

// Hold MIC: switch between the phone's microphones. The button shows the new one's name for two seconds.
- (void)switchMic:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    NSString *name = [_mic useNextSource];
    if (!name) return;
    NSString *shortName = [(name.length > 5 ? [name substringToIndex:5] : name) uppercaseString];
    [_micBtn setTitle:shortName forState:UIControlStateNormal];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [self->_micBtn setTitle:@"MIC" forState:UIControlStateNormal];
    });
}

- (void)flip { [_camera flip]; }

- (void)settings {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"PhoneDeck address"
        message:@"Paste the URL phonedeck prints on the Mac" preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *f) {
        f.text = [self deckURL];
        f.keyboardType = UIKeyboardTypeURL;
        f.autocorrectionType = UITextAutocorrectionTypeNo;
        f.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"Connect" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        [[NSUserDefaults standardUserDefaults] setObject:a.textFields.firstObject.text forKey:@"deckURL"];
        [self loadDeck];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)webViewDidFinishLoad:(UIWebView *)webView { [self reportPhone]; }

- (void)webView:(UIWebView *)webView didFailLoadWithError:(NSError *)error {
    // Mac asleep or phonedeck not running yet: keep retrying quietly.
    if (error.code == NSURLErrorCancelled) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [self loadDeck]; });
}

- (BOOL)prefersStatusBarHidden { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }
@end

#pragma mark - App

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation AppDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)opts {
    app.idleTimerDisabled = YES;   // it's a monitor/webcam: never auto-lock
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.rootViewController = [DeckController new];
    [self.window makeKeyAndVisible];
    return YES;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
