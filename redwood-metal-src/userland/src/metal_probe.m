/*
 * metal_probe: one process, one pass, the whole Metal ladder, printed to /dev/console.
 *
 * Every rung is printed *before* it is tried and flushed, because the next rung can abort the
 * process (Metal's conditions on a device object are asserts -- docs/metal.md 10.2-10.3). A log
 * that stops after "STEP n" is itself the answer: rung n is where it died.
 *
 *   STEP 1  IOAcceleratorES is in the registry
 *   STEP 2  the two properties, as they are now
 *   STEP 3  set them (unless argv[1] is "keep"), and read them back
 *   STEP 4  backboardd / SpringBoard pids; with "kick" a SIGTERM to backboardd -- done before
 *           anything below can abort, so a boot always gets the restart even if Metal kills us
 *   STEP 5  /System/Library/Extensions/RedwoodMetal.bundle resolves
 *   STEP 6  the bundle's executable dlopen()s -- dlerror() printed if not
 *   STEP 7  NSClassFromString("RedwoodMetalDevice") is not nil
 *   STEP 8  MTLCreateSystemDefaultDevice() pointer, and name/registryID if it is not nil
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
#include <objc/runtime.h>
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

extern kern_return_t set_cf_properties(io_registry_entry_t entry, CFTypeRef properties)
    __asm("_IORegistryEntrySetCFProperties");

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
	step("start, mode=%s, uid=%d", mode, getuid());

	step("STEP 1: looking for IOAcceleratorES");
	service = IOServiceGetMatchingService(0, IOServiceMatching("IOAcceleratorES"));
	if (service == IO_OBJECT_NULL) {
		step("  no IOAcceleratorES service -- nothing below this can work");
		return 1;
	}
	step("  got it");

	step("STEP 2: properties now");
	show_prop(service, kPluginNameKey);
	show_prop(service, kPluginClassKey);

	if (strcmp(mode, "keep") != 0) {
		step("STEP 3: setting them");
		set_both(service, "RedwoodMetal", "RedwoodMetalDevice");
		show_prop(service, kPluginNameKey);
		show_prop(service, kPluginClassKey);
	}

	step("STEP 4: the display clients (and the kick, before anything that can abort)");
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

	step("STEP 5: the path Metal composes");
	{
		const char *p = "/System/Library/Extensions/RedwoodMetal.bundle";
		const char *e = "/System/Library/Extensions/RedwoodMetal.bundle/RedwoodMetal";
		step("  %s: %s", p, access(p, F_OK) == 0 ? "there" : "NOT THERE");
		step("  %s: %s", e, access(e, F_OK) == 0 ? "there" : "NOT THERE");
	}

	step("STEP 6: dlopen the bundle executable ourselves");
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

	step("STEP 7: look the class up");
	{
		Class c = NSClassFromString(@"RedwoodMetalDevice");
		step("  NSClassFromString(RedwoodMetalDevice) = %s", c ? "a class" : "nil");
		if (c != Nil) {
			step("  class = %s, super = %s", class_getName(c),
			    class_getSuperclass(c) ? class_getName(class_getSuperclass(c)) : "(none)");
		}
	}

	step("STEP 8: MTLCreateSystemDefaultDevice");
	{
		id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
		step("  device = %p", (__bridge void *) dev);
		if (dev != nil) {
			step("  name = %s", [[dev name] UTF8String] ?: "(null)");
			step("  registryID = %llu", (unsigned long long) [dev registryID]);
		}
	}

	step("done");
	return 0;
}
