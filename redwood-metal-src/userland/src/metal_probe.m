/*
 * metal_probe: one process, one pass, the whole Metal ladder, printed to /dev/console.
 *
 * Every rung is printed *before* it is tried and flushed, because the next rung can abort the
 * process (Metal's conditions on a device object are asserts -- docs/metal.md 10.2-10.3). A log
 * that stops after "STEP n" is itself the answer: rung n is where it died.
 *
 * v2 adds three things the first boot asked for (that boot stopped dead at
 * MTLCreateSystemDefaultDevice with nothing printed inside, which is the one outcome the plain
 * ladder cannot tell apart from "the process was killed"):
 *
 *   - a handler on SIGSEGV/SIGBUS/SIGABRT/SIGILL/SIGALRM that prints the signal *and a
 *     backtrace with the image each frame belongs to* (dladdr), straight to fd 2 with write(2),
 *     so it cannot block on a stdio lock the hanging frame might be holding;
 *   - an alarm around each rung, so a rung that never returns is distinguishable from a rung
 *     that returns a poor answer;
 *   - a heartbeat thread that prints the rung it last entered every five seconds, so "blocked
 *     here" and "taken out from outside without a word" are told apart (the first boot at this
 *     point could not tell them apart);
 *   - a rung that instantiates this driver's device class DIRECTLY, without Metal's
 *     registration in the way. That splits "our driver hangs in -initWithAcceleratorPort:"
 *     from "Metal hangs before it ever calls us", which are two different repairs.
 *
 *   STEP 1  IOAcceleratorES is in the registry
 *   STEP 2  the two properties, as they are now
 *   STEP 3  set them (unless argv[1] is "keep"), and read them back
 *   STEP 4  /System/Library/Extensions/RedwoodMetal.bundle resolves
 *   STEP 5  the bundle's executable dlopen()s -- dlerror() printed if not
 *   STEP 6  NSClassFromString("RedwoodMetalDevice"), MTLDeviceSPI, and conformance
 *   STEP 7  the class instantiated directly, -initWithAcceleratorPort: -- no Metal between us
 *   STEP 8  MTLCreateSystemDefaultDevice() pointer, and name/registryID if it is not nil
 *   STEP 9  backboardd / SpringBoard pids; with "kick" a SIGTERM to backboardd
 *
 * Build (macOS, same flags as the rest of bin/):
 *   xcrun --sdk iphoneos clang -arch arm64e -miphoneos-version-min=26.0 \
 *     -isysroot $(xcrun --sdk iphoneos --show-sdk-path) -O1 -fobjc-arc \
 *     -framework Foundation -framework IOKit -framework Metal \
 *     -o metal_probe metal_probe.m
 */
#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <Metal/Metal.h>
#include <dlfcn.h>
#include <errno.h>
#include <execinfo.h>
#include <objc/runtime.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
#include <sys/types.h>
#include <unistd.h>

#define kPluginNameKey  "MetalPluginName"
#define kPluginClassKey "MetalPluginClassName"

/* The three of this driver's own answers that are not in any public Metal header. Declared so
 * the calls below compile; the class answers them (see redwoodmetal.m), and asking for them
 * through a protocol here is the same trick the driver uses on MTLDeviceSPI. */
@protocol RWProbeDevice <NSObject>
- (instancetype)initWithAcceleratorPort:(io_service_t)port;
- (NSUInteger)featureProfile;
- (uint64_t)maxBufferLength;
@end

extern kern_return_t set_cf_properties(io_registry_entry_t entry, CFTypeRef properties)
    __asm("_IORegistryEntrySetCFProperties");

/* write(2) only: a handler must not take a stdio lock, and the frame that hangs may hold one. */
static void
say(const char *fmt, ...)
{
	char buf[1024];
	va_list ap;
	int n;

	va_start(ap, fmt);
	n = vsnprintf(buf, sizeof(buf) - 2, fmt, ap);
	va_end(ap);
	if (n < 0) {
		return;
	}
	if (n > (int) sizeof(buf) - 2) {
		n = (int) sizeof(buf) - 2;
	}
	buf[n++] = '\n';
	write(2, buf, (size_t) n);
}

static void
dump_stack(void)
{
	void *frames[48];
	int n = backtrace(frames, 48);
	int i;

	say("  --- stack (%d frames) ---", n);
	for (i = 0; i < n; i++) {
		Dl_info info;
		if (dladdr(frames[i], &info) && info.dli_fname != NULL) {
			const char *base = strrchr(info.dli_fname, '/');
			say("  #%-2d %s +%#lx  %s", i,
			    base != NULL ? base + 1 : info.dli_fname,
			    (unsigned long) ((char *) frames[i] - (char *) info.dli_fbase),
			    info.dli_sname != NULL ? info.dli_sname : "");
		} else {
			say("  #%-2d %p  (no image)", i, frames[i]);
		}
	}
}

static void
on_signal(int sig)
{
	static volatile sig_atomic_t in_handler;
	const char *name = "?";

	/* SA_NODEFER lets the same signal come back in while the dump is running; if the dump
	 * itself faults that would be a loop with no output at all, which is the one answer
	 * worse than a wrong one. */
	if (in_handler) {
		_exit(4);
	}
	in_handler = 1;

	switch (sig) {
	case SIGSEGV: name = "SIGSEGV"; break;
	case SIGBUS:  name = "SIGBUS";  break;
	case SIGABRT: name = "SIGABRT"; break;
	case SIGILL:  name = "SIGILL";  break;
	case SIGALRM: name = "SIGALRM"; break;
	case SIGTERM: name = "SIGTERM"; break;
	default: break;
	}
	say("metal_probe: !!! %s (%d) at the rung now running", name, sig);
	dump_stack();
	if (sig == SIGALRM) {
		return;   /* the rung is still running; let it be */
	}
	_exit(3);
}

static void
install_handlers(void)
{
	struct sigaction sa;
	int sigs[] = { SIGSEGV, SIGBUS, SIGABRT, SIGILL, SIGALRM, SIGTERM };
	unsigned i;

	memset(&sa, 0, sizeof(sa));
	sa.sa_handler = on_signal;
	sigemptyset(&sa.sa_mask);
	sa.sa_flags = SA_NODEFER;
	for (i = 0; i < sizeof(sigs) / sizeof(sigs[0]); i++) {
		sigaction(sigs[i], &sa, NULL);
	}
}

/* A rung that has not returned by `seconds` is a rung that hangs: the alarm's backtrace says
 * where, in which image. One-shot; disarmed by passing 0. */
static void
watch(unsigned seconds)
{
	alarm(seconds);
}

/*
 * A killed process and a blocked one look the same on this console: both stop printing. The
 * heartbeat is the difference -- if it keeps coming the process is alive and stuck on `rung`,
 * and if it stops without a signal dump the process was taken out from outside.
 */
static volatile int gRung;
static void *gRungName = (void *) "start";

static void
mark(int rung, const char *name)
{
	gRung = rung;
	gRungName = (void *) name;
}

static void *
heartbeat(void *arg)
{
	unsigned tick = 0;

	(void) arg;
	for (;;) {
		sleep(5);
		if (gRung < 0) {
			return NULL;   /* the ladder finished: stop talking */
		}
		tick++;
		say("metal_probe: heartbeat %u, still at rung %d (%s), uid=%d",
		    tick, gRung, (const char *) gRungName, getuid());
	}
	return NULL;
}

static void
start_heartbeat(void)
{
	pthread_t t;

	if (pthread_create(&t, NULL, heartbeat, NULL) != 0) {
		say("metal_probe: no heartbeat thread");
		return;
	}
	pthread_detach(t);
}

static void
step(const char *fmt, ...)
{
	va_list ap;

	printf("metal_probe: ");
	va_start(ap, fmt);
	vprintf(fmt, ap);
	va_end(ap);
	printf("\n");
	fflush(stdout);
}

static CFTypeRef
copy_prop(io_service_t service, const char *key)
{
	CFStringRef k = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);
	CFTypeRef v;

	if (k == NULL) {
		return NULL;
	}
	v = IORegistryEntryCreateCFProperty(service, k, NULL, 0);
	CFRelease(k);
	return v;
}

static void
show_prop(io_service_t service, const char *key)
{
	CFTypeRef v = copy_prop(service, key);
	char buf[256];

	if (v == NULL) {
		step("  %s = (none)", key);
		return;
	}
	if (CFGetTypeID(v) == CFStringGetTypeID() &&
	    CFStringGetCString(v, buf, sizeof(buf), kCFStringEncodingUTF8)) {
		step("  %s = \"%s\"", key, buf);
	} else {
		step("  %s is there but is not a CFString -- Metal would ignore it", key);
	}
	CFRelease(v);
}

static int
set_both(io_service_t service, const char *name, const char *cls)
{
	CFStringRef keys[2] = { CFSTR(kPluginNameKey), CFSTR(kPluginClassKey) };
	CFStringRef values[2];
	CFDictionaryRef dict;
	kern_return_t kr;

	values[0] = CFStringCreateWithCString(NULL, name, kCFStringEncodingUTF8);
	values[1] = CFStringCreateWithCString(NULL, cls, kCFStringEncodingUTF8);
	if (values[0] == NULL || values[1] == NULL) {
		return 1;
	}
	dict = CFDictionaryCreate(NULL, (const void **) keys, (const void **) values, 2,
	    &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	CFRelease(values[0]);
	CFRelease(values[1]);
	if (dict == NULL) {
		return 1;
	}
	kr = set_cf_properties(service, dict);
	CFRelease(dict);
	if (kr != KERN_SUCCESS) {
		step("  setProperties failed %#x%s", kr,
		    kr == kIOReturnUnsupported ? " (kIOReturnUnsupported: boot without metal=1?)" : "");
		return 1;
	}
	step("  set %s=%s, %s=%s", kPluginNameKey, name, kPluginClassKey, cls);
	return 0;
}

/* pid of a process by its BSD name, or -1 */
static pid_t
pid_of(const char *want)
{
	int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
	size_t len = 0;
	struct kinfo_proc *procs;
	pid_t found = -1;
	int i, n;

	if (sysctl(mib, 4, NULL, &len, NULL, 0) != 0 || len == 0) {
		return -1;
	}
	procs = malloc(len);
	if (procs == NULL) {
		return -1;
	}
	if (sysctl(mib, 4, procs, &len, NULL, 0) != 0) {
		free(procs);
		return -1;
	}
	n = (int) (len / sizeof(struct kinfo_proc));
	for (i = 0; i < n; i++) {
		if (strncmp(procs[i].kp_proc.p_comm, want, sizeof(procs[i].kp_proc.p_comm)) == 0) {
			found = procs[i].kp_proc.p_pid;
			break;
		}
	}
	free(procs);
	return found;
}

int
main(int argc, char **argv)
{
	const char *mode = argc > 1 ? argv[1] : "run";
	io_service_t service;
	pid_t bb, sb;

	setvbuf(stdout, NULL, _IOLBF, 0);
	install_handlers();
	start_heartbeat();
	step("start, mode=%s, uid=%d", mode, getuid());

	mark(1, "IOAcceleratorES lookup");
	step("STEP 1: looking for IOAcceleratorES");
	service = IOServiceGetMatchingService(0, IOServiceMatching("IOAcceleratorES"));
	if (service == IO_OBJECT_NULL) {
		step("  no IOAcceleratorES service -- nothing below this can work");
		return 1;
	}
	step("  got it");

	mark(2, "properties now");
	step("STEP 2: properties now");
	show_prop(service, kPluginNameKey);
	show_prop(service, kPluginClassKey);

	if (strcmp(mode, "keep") != 0) {
		mark(3, "set properties");
		step("STEP 3: setting them");
		set_both(service, "RedwoodMetal", "RedwoodMetalDevice");
		show_prop(service, kPluginNameKey);
		show_prop(service, kPluginClassKey);
	}

	mark(4, "the bundle path");
	step("STEP 4: the path Metal composes");
	{
		const char *p = "/System/Library/Extensions/RedwoodMetal.bundle";
		const char *e = "/System/Library/Extensions/RedwoodMetal.bundle/RedwoodMetal";
		step("  %s: %s", p, access(p, F_OK) == 0 ? "there" : "NOT THERE");
		step("  %s: %s", e, access(e, F_OK) == 0 ? "there" : "NOT THERE");
	}

	mark(5, "dlopen the bundle");
	step("STEP 5: dlopen the bundle executable ourselves");
	{
		void *h = dlopen("/System/Library/Extensions/RedwoodMetal.bundle/RedwoodMetal",
		    RTLD_NOW | RTLD_LOCAL);
		if (h == NULL) {
			const char *err = dlerror();
			step("  dlopen FAILED: %s", err ? err : "(no dlerror)");
		} else {
			step("  dlopen ok, handle=%p", h);
		}
	}

	mark(6, "class and protocol");
	step("STEP 6: look the class up");
	{
		Protocol *spi = objc_getProtocol("MTLDeviceSPI");
		Class c = NSClassFromString(@"RedwoodMetalDevice");

		step("  objc_getProtocol(MTLDeviceSPI) = %s", spi ? "present" : "ABSENT");
		step("  NSClassFromString(RedwoodMetalDevice) = %s", c ? "a class" : "nil");
		if (c != Nil) {
			step("  class = %s, super = %s", class_getName(c),
			    class_getSuperclass(c) ? class_getName(class_getSuperclass(c)) : "(none)");
			if (spi != NULL) {
				step("  conformsToProtocol(MTLDeviceSPI) = %s",
				    class_conformsToProtocol(c, spi) ? "yes" : "NO -- Metal would assert");
			}
			step("  instancesRespondTo initWithAcceleratorPort: = %s",
			    [c instancesRespondToSelector:sel_getUid("initWithAcceleratorPort:")] ?
			    "yes" : "NO");
			step("  instancesRespondTo featureProfile = %s",
			    [c instancesRespondToSelector:sel_getUid("featureProfile")] ? "yes" : "NO");
			step("  instancesRespondTo maxBufferLength = %s",
			    [c instancesRespondToSelector:sel_getUid("maxBufferLength")] ? "yes" : "NO");
			step("  instancesRespondTo supportsVertexAmplificationCount: = %s",
			    [c instancesRespondToSelector:sel_getUid("supportsVertexAmplificationCount:")] ?
			    "yes" : "NO");
		}
	}

	/* The split that matters: this is our driver alone, with no Metal registration around it.
	 * If the log stops here, the repair is in redwoodmetal.m; if STEP 7 answers, the driver is
	 * fine and the hang at STEP 8 is Metal's own doing. */
	mark(7, "direct -initWithAcceleratorPort:");
	step("STEP 7: our class, instantiated directly (no Metal in the way)");
	{
		Class c = NSClassFromString(@"RedwoodMetalDevice");

		if (c == Nil) {
			step("  no class -- skipped");
		} else {
			id<RWProbeDevice> dev;

			watch(20);
			dev = [(id<RWProbeDevice>) [c alloc] initWithAcceleratorPort:service];
			watch(0);
			step("  -initWithAcceleratorPort: returned %p", (__bridge void *) dev);
			if (dev != nil) {
				step("  name = %s", [[(id<MTLDevice>) dev name] UTF8String] ?: "(null)");
				step("  featureProfile = %lu", (unsigned long) [dev featureProfile]);
				step("  maxBufferLength = %llu",
				    (unsigned long long) [dev maxBufferLength]);
			}
		}
	}

	mark(8, "MTLCreateSystemDefaultDevice");
	step("STEP 8: MTLCreateSystemDefaultDevice");
	{
		id<MTLDevice> dev;

		watch(20);
		dev = MTLCreateSystemDefaultDevice();
		watch(0);
		step("  device = %p", (__bridge void *) dev);
		if (dev != nil) {
			step("  name = %s", [[dev name] UTF8String] ?: "(null)");
			step("  registryID = %llu", (unsigned long long) [dev registryID]);
		}
	}

	mark(9, "the display clients");
	step("STEP 9: the display clients");
	bb = pid_of("backboardd");
	sb = pid_of("SpringBoard");
	step("  backboardd pid = %d, SpringBoard pid = %d", bb, sb);
	if (strcmp(mode, "kick") == 0) {
		/* our own exec is what runs late, not launchd's ordering: wait for the client to exist */
		int i;
		for (i = 0; i < 20 && bb <= 0; i++) {
			sleep(2);
			bb = pid_of("backboardd");
		}
		if (bb > 0) {
			int r;
			step("  SIGTERM to backboardd(%d) so it comes back with the properties in place", bb);
			r = kill(bb, SIGTERM);
			step("  kill() = %d%s%s", r, r ? ", errno " : "", r ? strerror(errno) : "");
		} else {
			step("  no backboardd after 40s -- nothing kicked");
		}
	}

	mark(-1, "done");
	step("done");
	return 0;
}
