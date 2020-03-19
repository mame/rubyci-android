#!/bin/bash

set -e

# apt-get install qemu-kvm openjdk-8-jdk gradle
# adduser $USER kvm
# yes | sdkmanager --licenses
# sdkmanager emulator tools platform-tools

# adb -s SERIAL_FILE shell screencap -p > screen.png

export PATH=$ANDROID_HOME/tools/bin:$PATH
export PATH=$ANDROID_HOME/emulator:$PATH
export PATH=$ANDROID_HOME/platform-tools:$PATH

if [ -x $3 ]; then
  echo "Usage: $0 [ANDROID_API] [x86|x86_64|arm64-v8a|armeabi-v7a] [port]"
  echo "See 'sdkmanager --list' for the available list."
  exit 1
fi

ANDROID_API=$1
ABI=$2
PORT=$3

NICKNAME=android$ANDROID_API-$ABI
AVD_NAME=rubyci-$NICKNAME

mkdir -p $NICKNAME
SETUP_LOG=$NICKNAME/setup.log
EMULATOR_LOG=$NICKNAME/emulator.log
PID=$NICKNAME/emulator.pid
SERIAL_FILE=$NICKNAME/emulator.serial
ID_RSA_FILE=$NICKNAME/id_rsa

function log() {
  echo >> $SETUP_LOG
  echo >> $SETUP_LOG
  echo "### $1 ###" >> $SETUP_LOG
  echo >> $SETUP_LOG
  echo >> $SETUP_LOG
  echo $1
}

echo -n > $SETUP_LOG

if [ -e $PID ]; then
  log "Stop the old emulator"
  kill $(cat $PID) || true
fi

log "Make sure emulator images available"
BUILD_TOOL=$(sdkmanager --list | grep "build-tools;$ANDROID_API" | tail -1 | awk '{ print $1 }')
sdkmanager emulator tools platform-tools "platforms;android-$ANDROID_API" $BUILD_TOOL "system-images;android-$ANDROID_API;default;$ABI" &>> $SETUP_LOG

log "Create an emulator"
echo no | avdmanager create avd -f -n $AVD_NAME -k "system-images;android-$ANDROID_API;default;$ABI" -c 100M &>> $SETUP_LOG

log "Invoke the emulator"
if [ "x$GITHUB_ACTIONS" = "x" ]; then
  ;
else
  NO_WINDOW=-no-window
fi
emulator -avd $AVD_NAME -partition-size 4096 -no-audio $NO_WINDOW -no-snapshot -no-boot-anim -wipe-data -memory 512 -selinux permissive -prop ro.rubyci_nickname=$NICKNAME &> $EMULATOR_LOG &
sleep 1

adb wait-for-device

log "Find a serial number of the emulator"
for serial in $(adb devices | awk '$2 == "device" { print $1 }'); do
  AVD_ID=$(adb -s $serial shell getprop ro.rubyci_nickname | tr -d '\r\n')
  echo id:$AVD_ID
  echo $NICKNAME
  if [ "x$AVD_ID" = "x$NICKNAME" ]; then
    log "Serial number for $NICKNAME: $serial"
    export ANDROID_SERIAL=$serial
    break
  fi
done

if [ "x$ANDROID_SERIAL" = "x" ]; then
  log "Failed to identify the invoked emulator"
  exit 1
fi

sleep 1
echo $ANDROID_SERIAL > $SERIAL_FILE
log "You can see the screen by: adb -s \$(cat $SERIAL_FILE) shell screencap -p > screen.png"

echo $! > $PID
until [ `adb -s $(cat $SERIAL_FILE) shell getprop sys.boot_completed`x = 1x ]; do
  sleep 1
done

if [ -e termux-app/app/build/outputs/apk/debug/app-debug.apk ]; then
  log "Termux is already built"
else
  log "Checkout and build Termux"
  git clone https://github.com/termux/termux-app.git
  cd termux-app
  ./gradlew assembleDebug -Pandroid.useAndroidX=true
  cd ..
fi
log "Install and setup Termux"
adb -s $(cat $SERIAL_FILE) install termux-app/app/build/outputs/apk/debug/app-debug.apk &>> $SETUP_LOG
adb -s $(cat $SERIAL_FILE) shell pm grant com.termux android.permission.READ_EXTERNAL_STORAGE &>> $SETUP_LOG
adb -s $(cat $SERIAL_FILE) shell pm grant com.termux android.permission.WRITE_EXTERNAL_STORAGE &>> $SETUP_LOG

log "Wait for network"
until adb -s $(cat $SERIAL_FILE) shell dumpsys netstats | grep -q "iface=wlan0"; do
  sleep 1
done
sleep 3

log "Invoke Termux"
adb -s $(cat $SERIAL_FILE) shell am start -n com.termux/.app.TermuxActivity &>> $SETUP_LOG

log "Wait for input"
sleep 3
until [ $(adb -s $(cat $SERIAL_FILE) shell dumpsys input | grep -w com.termux/com.termux.app.TermuxActivity $i | grep -w hasFocus | wc -l) -le 1 ]; do
  sleep 1
done
sleep 3

log "Push the startup script"
adb -s $(cat $SERIAL_FILE) push setup-chkbuild.sh /sdcard/setup-chkbuild.sh &>> $SETUP_LOG
adb -s $(cat $SERIAL_FILE) forward tcp:$PORT tcp:8022 &>> $SETUP_LOG
adb -s $(cat $SERIAL_FILE) shell input text "bash%s/sdcard/setup-chkbuild.sh" &>> $SETUP_LOG
adb -s $(cat $SERIAL_FILE) shell input keyevent KEYCODE_ENTER &>> $SETUP_LOG

sleep 1

log "You can watch the log by: adb -s \$(cat $SERIAL_FILE) shell tail -f /sdcard/setup-chkbuild.log"

adb -s $(cat $SERIAL_FILE) shell tail -f /sdcard/setup-chkbuild.log &
TAIL_PID=$!

until adb -s $(cat $SERIAL_FILE) pull /sdcard/id_rsa.termux $ID_RSA_FILE &>> $SETUP_LOG; do
  sleep 1
done
chmod 600 $ID_RSA_FILE

log "You can login the emulator by: ssh -i $ID_RSA_FILE -p $PORT localhost"

until adb -s $(cat $SERIAL_FILE) pull /sdcard/setup-chkbuild-done /dev/null &>> $SETUP_LOG; do
  sleep 1
done

kill -int $TAIL_PID

log "Setup done"

ssh -oStrictHostKeyChecking=no -i $ID_RSA_FILE -p $PORT localhost cat /sdcard/setup-chkbuild.log

log "Run chkbuild"

ssh -i $ID_RSA_FILE -p $PORT -t localhost "AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY ./run-chkbuild"

log "Result"

ssh -i $ID_RSA_FILE -p $PORT -t localhost "zcat cb/tmp/public_html/ruby-master/log/*.log.txt.gz"

log "Stop the emulator"
kill $(cat $PID) || true
