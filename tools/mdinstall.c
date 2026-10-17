// A tiny tool for talking to old iOS devices (like iOS 9) from a current Mac.
// Xcode's newer CoreDevice layer can't pair with these devices, so this uses macOS's
// classic MobileDevice.framework APIs instead (the same ones ios-deploy uses).
//
// Usage:
//   mdinstall list
//   mdinstall install <UDID|-> <App.app>
//   mdinstall syslog  <UDID|-> <seconds>           (prints the device's live system log)
//   mdinstall crashes <UDID|-> <name> <folder>     (downloads crash reports whose name contains <name>)
//
// Use "-" instead of a UDID to pick the first iPad connected over USB.

#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef struct am_device *AMDeviceRef;
struct am_device_notification_callback_info {
    AMDeviceRef dev;
    unsigned int msg;
    void *subscription;
};
typedef void (*am_device_notification_callback)(struct am_device_notification_callback_info *, void *);
typedef int (*am_progress_callback)(CFDictionaryRef, int);

int AMDeviceNotificationSubscribe(am_device_notification_callback, unsigned int, unsigned int, void *, void **);
int AMDeviceConnect(AMDeviceRef);
int AMDeviceDisconnect(AMDeviceRef);
int AMDeviceIsPaired(AMDeviceRef);
int AMDeviceValidatePairing(AMDeviceRef);
int AMDeviceStartSession(AMDeviceRef);
int AMDeviceStopSession(AMDeviceRef);
int AMDeviceGetInterfaceType(AMDeviceRef);
CFStringRef AMDeviceCopyDeviceIdentifier(AMDeviceRef);
CFTypeRef AMDeviceCopyValue(AMDeviceRef, CFStringRef, CFStringRef);
int AMDeviceSecureTransferPath(int, AMDeviceRef, CFURLRef, CFDictionaryRef, am_progress_callback, int);
int AMDeviceSecureInstallApplication(int, AMDeviceRef, CFURLRef, CFDictionaryRef, am_progress_callback, int);
int AMDeviceSecureStartService(AMDeviceRef, CFStringRef, CFDictionaryRef, void **);
long AMDServiceConnectionReceive(void *, void *, size_t);
int AMDServiceConnectionGetSocket(void *);
typedef void *AFCConnectionRef;
int AFCConnectionOpen(int, unsigned int, AFCConnectionRef *);
int AFCDirectoryOpen(AFCConnectionRef, const char *, void **);
int AFCDirectoryRead(AFCConnectionRef, void *, char **);
int AFCDirectoryClose(AFCConnectionRef, void *);
int AFCFileRefOpen(AFCConnectionRef, const char *, unsigned long long, unsigned long long *);
int AFCFileRefRead(AFCConnectionRef, unsigned long long, void *, size_t *);
int AFCFileRefClose(AFCConnectionRef, unsigned long long);

#define ADNCI_MSG_CONNECTED 1
#define INTERFACE_USB 1

static const char *g_mode;
static const char *g_udid;
static const char *g_app;
static int g_seconds = 5;
static const char *g_out;

static void cfprint(const char *label, CFTypeRef v) {
    char buf[256] = "?";
    if (v && CFGetTypeID(v) == CFStringGetTypeID())
        CFStringGetCString(v, buf, sizeof buf, kCFStringEncodingUTF8);
    printf("%s%s", label, buf);
}

static int progress(CFDictionaryRef info, int arg) {
    (void)arg;
    CFStringRef status = CFDictionaryGetValue(info, CFSTR("Status"));
    CFNumberRef pct = CFDictionaryGetValue(info, CFSTR("PercentComplete"));
    int p = 0;
    if (pct) CFNumberGetValue(pct, kCFNumberIntType, &p);
    cfprint("  ", status);
    printf(" %d%%\n", p);
    fflush(stdout);
    return 0;
}

static int open_session(AMDeviceRef dev) {
    int rc;
    if ((rc = AMDeviceConnect(dev))) { fprintf(stderr, "Couldn't connect: 0x%x\n", rc); return rc; }
    if (!AMDeviceIsPaired(dev)) { fprintf(stderr, "The device isn't paired with this Mac (tap 'Trust' on it).\n"); return -1; }
    if ((rc = AMDeviceValidatePairing(dev))) { fprintf(stderr, "Couldn't validate pairing: 0x%x\n", rc); return rc; }
    if ((rc = AMDeviceStartSession(dev))) { fprintf(stderr, "Couldn't start a session: 0x%x\n", rc); return rc; }
    return 0;
}

// With "-" as the UDID, the first iPad on USB is used (so an iPhone on the same Mac is skipped).
static int is_target(AMDeviceRef dev, const char *udid) {
    if (strcmp(g_udid, "-") != 0) return strcasecmp(udid, g_udid) == 0;
    if (AMDeviceGetInterfaceType(dev) != INTERFACE_USB || open_session(dev)) return 0;
    CFTypeRef cls = AMDeviceCopyValue(dev, NULL, CFSTR("DeviceClass"));
    int ipad = cls && CFGetTypeID(cls) == CFStringGetTypeID() && CFEqual(cls, CFSTR("iPad"));
    if (cls) CFRelease(cls);
    AMDeviceStopSession(dev);
    AMDeviceDisconnect(dev);
    return ipad;
}

static void on_device(struct am_device_notification_callback_info *info, void *arg) {
    (void)arg;
    if (info->msg != ADNCI_MSG_CONNECTED) return;
    AMDeviceRef dev = info->dev;

    char udid[128] = "";
    CFStringRef ident = AMDeviceCopyDeviceIdentifier(dev);
    CFStringGetCString(ident, udid, sizeof udid, kCFStringEncodingUTF8);
    CFRelease(ident);

    if (strcmp(g_mode, "list") == 0) {
        printf("%s  [%s]", udid, AMDeviceGetInterfaceType(dev) == INTERFACE_USB ? "USB" : "Wi-Fi");
        if (open_session(dev) == 0) {
            cfprint("  ", AMDeviceCopyValue(dev, NULL, CFSTR("DeviceName")));
            cfprint("  ", AMDeviceCopyValue(dev, NULL, CFSTR("ProductType")));
            cfprint("  iOS ", AMDeviceCopyValue(dev, NULL, CFSTR("ProductVersion")));
            AMDeviceStopSession(dev);
            AMDeviceDisconnect(dev);
        }
        printf("\n");
        return;
    }

    if (!is_target(dev, udid)) return;

    if (strcmp(g_mode, "crashes") == 0) {
        if (open_session(dev)) exit(1);
        void *svc = NULL;
        int rc = AMDeviceSecureStartService(dev, CFSTR("com.apple.crashreportcopymobile"), NULL, &svc);
        AMDeviceStopSession(dev);
        if (rc || !svc) { fprintf(stderr, "Couldn't start crashreportcopymobile: 0x%x\n", rc); exit(1); }
        AFCConnectionRef afc;
        if ((rc = AFCConnectionOpen(AMDServiceConnectionGetSocket(svc), 0, &afc))) { fprintf(stderr, "AFC: 0x%x\n", rc); exit(1); }
        void *dir;
        if ((rc = AFCDirectoryOpen(afc, "/", &dir))) { fprintf(stderr, "Directory: 0x%x\n", rc); exit(1); }
        char *name;
        while (AFCDirectoryRead(afc, dir, &name) == 0 && name) {
            if (!strstr(name, g_app)) continue;
            char remote[512], local[1024];
            snprintf(remote, sizeof remote, "/%s", name);
            snprintf(local, sizeof local, "%s/%s", g_out, name);
            unsigned long long fh;
            if (AFCFileRefOpen(afc, remote, 1, &fh)) continue;
            FILE *f = fopen(local, "wb");
            if (!f) { AFCFileRefClose(afc, fh); continue; }
            char buf[16384];
            size_t len;
            for (;;) {
                len = sizeof buf;
                if (AFCFileRefRead(afc, fh, buf, &len) || len == 0) break;
                fwrite(buf, 1, len, f);
            }
            fclose(f);
            AFCFileRefClose(afc, fh);
            printf("%s\n", local);
        }
        AFCDirectoryClose(afc, dir);
        exit(0);
    }

    if (strcmp(g_mode, "syslog") == 0) {
        if (open_session(dev)) exit(1);
        void *conn = NULL;
        int rc = AMDeviceSecureStartService(dev, CFSTR("com.apple.syslog_relay"), NULL, &conn);
        AMDeviceStopSession(dev);
        if (rc || !conn) { fprintf(stderr, "Couldn't start syslog_relay: 0x%x\n", rc); exit(1); }
        fprintf(stderr, "Reading the log for %d s...\n", g_seconds);
        alarm(g_seconds);  // the read loop blocks; the alarm ends the process when time is up
        char buf[4096];
        long n;
        while ((n = AMDServiceConnectionReceive(conn, buf, sizeof buf)) > 0) {
            for (long i = 0; i < n; i++) if (buf[i]) putchar(buf[i]);
            fflush(stdout);
        }
        exit(0);
    }

    if (open_session(dev)) exit(1);
    cfprint("Device: ", AMDeviceCopyValue(dev, NULL, CFSTR("DeviceName")));
    cfprint(" · iOS ", AMDeviceCopyValue(dev, NULL, CFSTR("ProductVersion")));
    printf("\n");
    AMDeviceStopSession(dev);
    AMDeviceDisconnect(dev);

    CFStringRef path = CFStringCreateWithCString(NULL, g_app, kCFStringEncodingUTF8);
    CFURLRef url = CFURLCreateWithFileSystemPath(NULL, path, kCFURLPOSIXPathStyle, true);
    const void *keys[] = { CFSTR("PackageType") };
    const void *vals[] = { CFSTR("Developer") };
    CFDictionaryRef opts = CFDictionaryCreate(NULL, keys, vals, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);

    printf("Copying...\n");
    int rc = AMDeviceSecureTransferPath(0, dev, url, opts, progress, 0);
    if (rc) { fprintf(stderr, "Copy failed: 0x%x\n", rc); exit(1); }

    printf("Installing...\n");
    if (open_session(dev)) exit(1);
    rc = AMDeviceSecureInstallApplication(0, dev, url, opts, progress, 0);
    AMDeviceStopSession(dev);
    AMDeviceDisconnect(dev);
    if (rc) { fprintf(stderr, "Install failed: 0x%x\n", rc); exit(1); }

    printf("Done: the app is installed.\n");
    exit(0);
}

static void timeout(CFRunLoopTimerRef t, void *info) {
    (void)t; (void)info;
    if (strcmp(g_mode, "list") == 0) exit(0);
    fprintf(stderr, "Device not found: %s\n", strcmp(g_udid, "-") == 0 ? "no iPad on USB" : g_udid);
    exit(1);
}

int main(int argc, char **argv) {
    if (argc >= 2 && strcmp(argv[1], "list") == 0) {
        g_mode = "list";
    } else if (argc == 4 && strcmp(argv[1], "install") == 0) {
        g_mode = "install";
        g_udid = argv[2];
        g_app = argv[3];
    } else if (argc == 5 && strcmp(argv[1], "crashes") == 0) {
        g_mode = "crashes";
        g_udid = argv[2];
        g_app = argv[3];
        g_out = argv[4];
    } else if (argc == 4 && strcmp(argv[1], "syslog") == 0) {
        g_mode = "syslog";
        g_udid = argv[2];
        g_seconds = atoi(argv[3]);
    } else {
        fprintf(stderr,
            "Usage: %s list\n"
            "       %s install <UDID|-> <App.app>\n"
            "       %s syslog  <UDID|-> <seconds>\n"
            "       %s crashes <UDID|-> <name> <folder>\n"
            "  '-' picks the first iPad on USB.\n", argv[0], argv[0], argv[0], argv[0]);
        return 2;
    }

    void *sub;
    AMDeviceNotificationSubscribe(on_device, 0, 0, NULL, &sub);
    CFRunLoopTimerRef t = CFRunLoopTimerCreate(NULL, CFAbsoluteTimeGetCurrent() + (strcmp(g_mode, "syslog") == 0 ? g_seconds : 5),
                                               0, 0, 0, timeout, NULL);
    CFRunLoopAddTimer(CFRunLoopGetCurrent(), t, kCFRunLoopCommonModes);
    CFRunLoopRun();
    return 0;
}
