#!/system/bin/sh

# Wait for boot to complete
while [ "$(getprop sys.boot_completed)" != 1 ]; do
	/system/bin/sleep 1s
done

# Create a separate temp directory, to hold the current certificates
# Otherwise, when we add the mount we can't read the current certs anymore.

mkdir -p -m 700 /data/local/tmp/tmp-ca-copy

# Copy out the existing certificates and the user ones
cp /apex/com.android.conscrypt/cacerts/* /data/local/tmp/tmp-ca-copy/

cp /data/misc/user/0/cacerts-added/* /data/local/tmp/tmp-ca-copy/

# Create the in-memory mount on top of the system certs folder
mount -t tmpfs tmpfs /system/etc/security/cacerts

# Copy the existing certs back into the tmpfs, so we keep trusting them
mv /data/local/tmp/tmp-ca-copy/* /system/etc/security/cacerts/

# Update the perms & selinux context labels
# set_ perm_recursive /system/etc/security/cacerts/  root root 644 644 u:object_r:system_file:s0
chown root:root /system/etc/security/cacerts/*
chmod 644 /system/etc/security/cacerts/*
chcon u:object_r:system_file:s0 /system/etc/security/cacerts/*

# Deal with the APEX overrides, which need injecting into each namespace:

# First we get the Zygote process(es), which launch each app
ZYGOTE_PID=$(pidof zygote || true)
ZYGOTE64_PID=$(pidof zygote64 || true)
# N.b. some devices appear to have both!

# Apps inherit the Zygote's mounts at startup, so we inject here to ensure
# all newly started apps will see these certs straight away:
for Z_PID in "$ZYGOTE_PID" "$ZYGOTE64_PID"; do
	if [ -n "$Z_PID" ]; then
		/system/bin/nsenter --mount=/proc/$Z_PID/ns/mnt -- /bin/mount --bind /system/etc/security/cacerts /apex/com.android.conscrypt/cacerts
	fi
done

# Then we inject the mount into all already running apps, so they
# too see these CA certs immediately:

# Get the PID of every process whose parent is one of the Zygotes:
APP_PIDS=$(
	echo "$ZYGOTE_PID $ZYGOTE64_PID" |
		xargs -n1 ps -o 'PID' -P |
		grep -v PID
)
# Inject into the mount namespace of each of those apps:
for PID in $APP_PIDS; do
	/system/bin/nsenter --mount=/proc/$PID/ns/mnt -- /bin/mount --bind /system/etc/security/cacerts /apex/com.android.conscrypt/cacerts &
done
wait # Launched in parallel - wait for completion here

# cleanup
rm -rf /data/local/tmp/tmp-ca-copy


