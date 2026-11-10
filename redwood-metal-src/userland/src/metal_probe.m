/*
 * metal_probe: the whole Metal ladder, one rung at a time, printed to /dev/console.
 *
 * v3 exists because v2 found the hang and the frame it hangs in, but not whether the frame is
 * the *cause* or a symptom, and not whether the one knob we know of (OS_ACTIVITY_MODE) helps:
 *
 *   #26 RedwoodMetal  -[RedwoodMetalDevice initWithAcceleratorPort:]
 *   #18 CoreFoundation CFCopySearchPathForDirectoriesInDomains
 *   #12 libsystem_trace os_log_create
 *   #8  libdispatch    voucher_activity_flush
 *   #4  libsystem_kernel mach_msg            <-- never returns
 *
 * So each risky rung now runs in its OWN forked child, with its own timeout. A rung that hangs
 * costs that child and nothing else: the parent kills it and moves to the next rung, and the
 * whole picture comes out of one boot instead of one boot per question. The parent's heartbeat
 * every five seconds is what tells "still working" from "the parent died too".
 *
 *   parent   STEP 1  IOAcceleratorES, the two properties, set them, bundle path, dlopen, class
 *   child A  os_log_create("com.redwood.probe", "rung")
 *   child B  NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES)
 *   child C  [[_MTLDevice alloc] init]                                    -- Metal, no driver
 *   child D  [[RedwoodMetalDevice alloc] initWithAcceleratorPort:]        -- as it is
 *   child E  the same, after setenv("OS_ACTIVITY_MODE", "disable")       -- the knob
 *   child F  MTLCreateSystemDefaultDevice()                              -- as it is
 *   child G  the same, after the same setenv                             -- the knob
 *   child H  [fix] os_log_create                                          -- the cure
 *   child I  [fix] [[_MTLDevice alloc] init]                              -- the cure
 *   child J  [fix] MTLCreateSystemDefaultDevice                           -- the cure
 *   child K  [fix]  -initWithAcceleratorPort:                             -- the cure
 *   parent   STEP 8  backboardd / SpringBoard pids; with "kick" a SIGTERM to backboardd
 *
 * H..K repeat A..F after `install_activity_fix()`: voucher_activity_flush() is rewritten to a
 * plain `ret`, which is the whole of what k36 said was missing. H returning where A hung is
 * the proof; K returning a device means the driver was never the problem.
 *
 * Every child keeps v2's handlers, so a child that faults prints the signal and a stack with the
 * image each frame belongs to, instead of disappearing.
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
#include <mach/mach.h>
#include <objc/runtime.h>
#include <os/log.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#define kPluginNameKey  "MetalPluginName"
#define kPluginClassKey "MetalPluginClassName"

/* The three of this driver's own answers that are not in any public Metal header. Declared so
 * the calls below compile; the class answers them (see redwoodmetal.m). */
@protocol RWProbeDevice <NSObject>
- (instancetype)initWithAcceleratorPort:(io_service_t)port;
- (NSUInteger)featureProfile;
- (uint64_t)maxBufferLength;
@end

extern kern_return_t set_cf_properties(io_registry_entry_t entry, CFTypeRef properties)
    __asm("_IORegistryEntrySetCFProperties");

/* one io_service_t, kept here so a forked child inherits it without passing anything around */
static io_service_t gService;

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
	 * itself faults that would be a loop with no output at all. */
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
	say("metal_probe: !!! %s (%d)", name, sig);
	dump_stack();
	if (sig == SIGALRM) {
		return;   /* the rung keeps waiting; the parent's timeout will collect the child */
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

/*
 * The activity fix.
 *
 * k36 rung A settled it: os_log_create() by itself never returns. It dispatch_sync()s into
 * libsystem_trace, which calls voucher_activity_flush(), which mach_msg()s a request and
 * waits for a reply this userspace never sends -- launchd says as much at boot, "System
 * logger socket was not opened during early boot. (Proceeding anyway)". Every Metal init
 * creates a log ([_MTLDevice init] does), so nothing that logs can start, which is why
 * backboardd and SpringBoard came up and then did nothing at all.
 *
 * voucher_activity_flush is `void` and is called across an image boundary, so one `ret` at
 * its entry replaces it completely and the caller simply carries on. Losing activity
 * tracing is exactly the trade we want here.
 *
 * If that symbol turns out not to be exported, the fallback rewrites os_log_create's own
 * entry to `return os_log_default` -- the only object it could usefully return anyway.
 * Three instructions, built at runtime so no literal pool or second mapping is needed:
 *
 *     adrp x0, <page of os_log_default>
 *     ldr  x0, [x0, <offset of os_log_default>]
 *     ret
 */
static int
make_writable(void *p, size_t n)
{
	long ps = sysconf(_SC_PAGESIZE);
	vm_address_t a = (vm_address_t) p & ~((vm_address_t) ps - 1);
	vm_address_t e = ((vm_address_t) p + n + (vm_address_t) ps - 1) & ~((vm_address_t) ps - 1);

	return vm_protect(mach_task_self(), a, (vm_size_t) (e - a), 0,
	    VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY) == KERN_SUCCESS ? 0 : 1;
}

/* 0 = patched, 1 = could not, and the caller should say so and carry on */
static int
install_activity_fix(void)
{
	void *flush = dlsym(RTLD_DEFAULT, "voucher_activity_flush");

	if (flush != NULL) {
		uint32_t ret = 0xd65f03c0u;

		if (make_writable(flush, sizeof(ret)) != 0) {
			step("  fix: page of voucher_activity_flush is not writable");
			return 1;
		}
		memcpy(flush, &ret, sizeof(ret));
		__builtin___clear_cache((char *) flush, (char *) flush + sizeof(ret));
		step("  fix: voucher_activity_flush @ %p -> ret", flush);
		return 0;
	}

	{
		void *create = dlsym(RTLD_DEFAULT, "os_log_create");
		void *dflt = dlsym(RTLD_DEFAULT, "os_log_default");
		uint32_t code[3];
		uint64_t target, pc;
		int64_t delta;
		uint32_t imm, imm12;

		if (create == NULL || dflt == NULL) {
			step("  fix: neither voucher_activity_flush nor os_log_create is reachable");
			return 1;
		}
		target = (uint64_t) (uintptr_t) dflt;
		pc = (uint64_t) (uintptr_t) create;
		delta = (int64_t) ((target & ~(uint64_t) 0xfff) - (pc & ~(uint64_t) 0xfff));
		imm = (uint32_t) (delta >> 12);
		code[0] = 0x90000000u | ((imm & 3u) << 29) | (((imm >> 2) & 0x7ffffu) << 5);
		imm12 = (uint32_t) ((target & 0xfffu) >> 3);
		code[1] = 0xf9400000u | (imm12 << 10);
		code[2] = 0xd65f03c0u;
		if (make_writable(create, sizeof(code)) != 0) {
			step("  fix: page of os_log_create is not writable");
			return 1;
		}
		memcpy(create, code, sizeof(code));
		__builtin___clear_cache((char *) create, (char *) create + sizeof(code));
		step("  fix: os_log_create @ %p -> return os_log_default (%p)", create, dflt);
		return 0;
	}
}

/*
 * One rung, one process. The child prints what it is about to do, does it, prints the answer and
 * exits. The parent prints a heartbeat every five seconds while it waits, so a log that goes
 * quiet still says whether the parent is alive; at `secs` the child is killed and the rung is
 * recorded as hung, which is a result and not a failure of the run.
 */
static int
rung(const char *name, void (*body)(void), unsigned secs)
{
	pid_t pid;
	unsigned waited = 0;
	int status = 0;

	step("--- %s (timeout %us)", name, secs);
	fflush(stdout);
	pid = fork();
	if (pid < 0) {
		step("  fork failed: %s", strerror(errno));
		return -1;
	}
	if (pid == 0) {
		/* the child: its own alarm so the stack is dumped before the parent's SIGKILL */
		install_handlers();
		alarm(secs > 3 ? secs - 2 : secs);
		body();
		alarm(0);
		fflush(stdout);
		_exit(0);
	}
	for (;;) {
		pid_t r = waitpid(pid, &status, WNOHANG);

		if (r == pid) {
			break;
		}
		if (r < 0) {
			step("  waitpid failed: %s", strerror(errno));
			return -1;
		}
		if (waited >= secs * 4) {
			step("  >>> %s: HUNG for %us, child %d killed", name, secs, (int) pid);
			kill(pid, SIGKILL);
			waitpid(pid, &status, 0);
			return 1;
		}
		usleep(250000);
		waited++;
		if (waited % 20 == 0) {
			step("  ... %s still running (%us), parent alive", name, waited / 4);
		}
	}
	if (WIFSIGNALED(status)) {
		step("  <<< %s: child died on signal %d", name, WTERMSIG(status));
		return 2;
	}
	step("  <<< %s: returned, exit %d", name, WEXITSTATUS(status));
	return 0;
}

/* ---- the rungs themselves ---- */

static void
rung_oslog(void)
{
	os_log_t log = os_log_create("com.redwood.probe", "rung");

	step("  os_log_create -> %p", (__bridge void *) log);
}

static void
rung_cfpath(void)
{
	/* The public entry to the same walk Metal makes (NSSearchPathForDirectoriesInDomains
	 * calls CFCopySearchPathForDirectoriesInDomains, which is what frame #18 was). */
	NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory,
	    NSUserDomainMask, YES);

	step("  NSSearchPathForDirectoriesInDomains -> %p (%lu paths)",
	    (__bridge void *) paths, (unsigned long) [paths count]);
}

/* Metal's own base class, with nothing of this driver in the way: if this hangs, the driver is
 * irrelevant and the repair is below it. */
static void
rung_mtldevice_init(void)
{
	Class base = NSClassFromString(@"_MTLDevice");
	id obj;

	if (base == Nil) {
		step("  no _MTLDevice class");
		return;
	}
	obj = [[base alloc] init];
	step("  [[_MTLDevice alloc] init] -> %p", (__bridge void *) obj);
}

static void
rung_direct_init(void)
{
	Class c = NSClassFromString(@"RedwoodMetalDevice");
	id<RWProbeDevice> dev;

	if (c == Nil) {
		step("  no class");
		return;
	}
	dev = [(id<RWProbeDevice>) [c alloc] initWithAcceleratorPort:gService];
	step("  -initWithAcceleratorPort: -> %p", (__bridge void *) dev);
	if (dev != nil) {
		step("  name = %s", [[(id<MTLDevice>) dev name] UTF8String] ?: "(null)");
		step("  featureProfile = %lu", (unsigned long) [dev featureProfile]);
		step("  maxBufferLength = %llu", (unsigned long long) [dev maxBufferLength]);
	}
}

static void
rung_mtl_device(void)
{
	id<MTLDevice> dev = MTLCreateSystemDefaultDevice();

	step("  MTLCreateSystemDefaultDevice -> %p", (__bridge void *) dev);
	if (dev != nil) {
		step("  name = %s", [[dev name] UTF8String] ?: "(null)");
		step("  registryID = %llu", (unsigned long long) [dev registryID]);
	}
}

static void
rung_direct_init_noactivity(void)
{
	setenv("OS_ACTIVITY_MODE", "disable", 1);
	step("  OS_ACTIVITY_MODE=%s", getenv("OS_ACTIVITY_MODE") ?: "(unset)");
	rung_direct_init();
}

static void
rung_mtl_device_noactivity(void)
{
	setenv("OS_ACTIVITY_MODE", "disable", 1);
	step("  OS_ACTIVITY_MODE=%s", getenv("OS_ACTIVITY_MODE") ?: "(unset)");
	rung_mtl_device();
}

/* ---- H..K: the same four, after the activity fix ---- */

static void
rung_fix_oslog(void)
{
	install_activity_fix();
	rung_oslog();
}

static void
rung_fix_mtldevice_init(void)
{
	install_activity_fix();
	rung_mtldevice_init();
}

static void
rung_fix_mtl_device(void)
{
	install_activity_fix();
	rung_mtl_device();
}

static void
rung_fix_direct_init(void)
{
	install_activity_fix();
	rung_direct_init();
}

/* ---- the property channel, unchanged from v1 ---- */

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
	pid_t bb, sb;

	setvbuf(stdout, NULL, _IOLBF, 0);
	install_handlers();
	/* does launchd actually pass EnvironmentVariables through? k35 set OS_ACTIVITY_MODE in
	 * the plist and the stack did not change, but nothing ever printed the environment, so
	 * "the knob does nothing" and "the knob never arrived" were still indistinguishable. */
	step("start, mode=%s, uid=%d, REDWOOD_PROBE_ENV=%s", mode, getuid(),
	    getenv("REDWOOD_PROBE_ENV") ?: "(unset)");

	step("STEP 1: looking for IOAcceleratorES");
	gService = IOServiceGetMatchingService(0, IOServiceMatching("IOAcceleratorES"));
	if (gService == IO_OBJECT_NULL) {
		step("  no IOAcceleratorES service -- nothing below this can work");
		return 1;
	}
	step("  got it");

	step("STEP 2: properties now");
	show_prop(gService, kPluginNameKey);
	show_prop(gService, kPluginClassKey);

	if (strcmp(mode, "keep") != 0) {
		step("STEP 3: setting them");
		set_both(gService, "RedwoodMetal", "RedwoodMetalDevice");
		show_prop(gService, kPluginNameKey);
		show_prop(gService, kPluginClassKey);
	}

	step("STEP 4: the path Metal composes");
	{
		const char *p = "/System/Library/Extensions/RedwoodMetal.bundle";
		const char *e = "/System/Library/Extensions/RedwoodMetal.bundle/RedwoodMetal";
		step("  %s: %s", p, access(p, F_OK) == 0 ? "there" : "NOT THERE");
		step("  %s: %s", e, access(e, F_OK) == 0 ? "there" : "NOT THERE");
	}

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
		}
	}

	/* The six isolates. Order matters: the cheapest way to tell "os_log is the cause" from
	 * "os_log is just the first thing that logs" is to ask os_log by itself, before Metal. */
	step("STEP 7: the rungs, one process each");
	rung("A: os_log_create", rung_oslog, 12);
	rung("B: NSSearchPathForDirectoriesInDomains", rung_cfpath, 12);
	rung("C: [[_MTLDevice alloc] init] -- Metal's own, no driver", rung_mtldevice_init, 25);
	rung("D: -initWithAcceleratorPort: as it is", rung_direct_init, 25);
	rung("E: -initWithAcceleratorPort: with OS_ACTIVITY_MODE=disable",
	    rung_direct_init_noactivity, 25);
	rung("F: MTLCreateSystemDefaultDevice as it is", rung_mtl_device, 25);
	rung("G: MTLCreateSystemDefaultDevice with OS_ACTIVITY_MODE=disable",
	    rung_mtl_device_noactivity, 25);

	/* The four that matter: same calls, with voucher_activity_flush turned into a `ret`.
	 * H passing where A hung is the proof; K passing means the driver itself was never the
	 * problem and the device object exists. */
	step("STEP 7b: the same, with the activity fix");
	rung("H: [fix] os_log_create", rung_fix_oslog, 15);
	rung("I: [fix] [[_MTLDevice alloc] init]", rung_fix_mtldevice_init, 25);
	rung("J: [fix] MTLCreateSystemDefaultDevice", rung_fix_mtl_device, 25);
	rung("K: [fix] -initWithAcceleratorPort:", rung_fix_direct_init, 30);

	step("STEP 8: the display clients");
	bb = pid_of("backboardd");
	sb = pid_of("SpringBoard");
	step("  backboardd pid = %d, SpringBoard pid = %d", bb, sb);
	if (strcmp(mode, "kick") == 0) {
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

	step("done");
	return 0;
}
