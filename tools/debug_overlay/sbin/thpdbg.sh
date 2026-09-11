#!/sbin/sh
# DEBUG: start the Huawei THP touch daemon once and log everything to the
# kernel log, so it survives a crash/reboot in /proc/last_kmsg (ramoops).
k() { echo "THPDBG: $*" > /dev/kmsg; }

# let every printk level (including our kmsg lines) reach the ramoops console
echo 8 > /proc/sys/kernel/printk
setenforce 0 2>/dev/null

k "begin uptime=$(cat /proc/uptime) selinux=$(getenforce) panic_on_oops=$(cat /proc/sys/kernel/panic_on_oops)"
k "hostprocessing=$(cat /sys/touchscreen/hostprocessing 2>&1) thp_status=$(cat /sys/touchscreen/thp_status 2>&1) chip=$(cat /sys/touchscreen/touch_chip_info 2>&1)"
k "vendor/lib: $(ls /vendor/lib | grep -i -E 'thp|afehal|tsa' | tr '\n' ' ')"
k "vendor/etc/init: $(ls /vendor/etc/init 2>&1 | tr '\n' ' ')"
k "procs: $(ps | grep -E 'servicemanager|teecd|oeminfo|logd|recovery' | grep -v grep | tr -s ' ' | tr '\n' ';')"

# daemon's own liblog output -> kmsg
logcat -c
logcat -v brief -f /dev/kmsg &
LOGCAT=$!

# touch state once a second for a minute
( i=0; while [ $i -lt 60 ]; do
    k "t+$i thp_status=$(cat /sys/touchscreen/thp_status 2>&1) daemons=$(ps | grep -c '[a]ptouch_daemon')"
    sleep 1; i=$((i+1)); done ) &
MON=$!

export LD_LIBRARY_PATH=/system/lib:/vendor/lib
k "exec /vendor/bin/aptouch_daemon"
/vendor/bin/aptouch_daemon
k "aptouch_daemon exited rc=$?"
sleep 3
kill $MON $LOGCAT 2>/dev/null
