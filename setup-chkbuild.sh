#!/data/data/com.termux/files/usr/bin/bash

set -e

LOG=/sdcard/setup-chkbuild.log

function log() {
  echo >> $LOG
  echo >> $LOG
  echo "### $1 ###" >> $LOG
  echo >> $LOG
  echo >> $LOG
  echo $1
}

echo "You can check the log in $LOG"
echo -n &> $LOG

log "dpkg --configure -a --force-confnew"
dpkg --configure -a --force-confnew &>> $LOG

log "pkg upgrade"
yes | pkg upgrade --yes --force-yes &>> $LOG

log "pkg install"
pkg install openssh make clang autoconf bison ruby git gdbm gdb libdb proot wget -y &>> $LOG

log "sshd"
sshd &>> $LOG

log "ssh-keygen"
yes | ssh-keygen -f id_rsa.termux -t rsa -N "" &>> $LOG
mv id_rsa.termux.pub ~/.ssh/authorized_keys &>> $LOG
chmod 600 ~/.ssh/authorized_keys &>> $LOG
cp id_rsa.termux /sdcard/id_rsa.termux &>> $LOG

log "gem install aws-sdk"
gem install aws-sdk-s3 -N &>> $LOG

log "git clone ruby/chkbuild"
git clone https://github.com/ruby/chkbuild.git cb &>> $LOG

export PUBLIC_DIR=cb/tmp/public_html/ruby-master
mkdir -p $PUBLIC_DIR

for file in current.txt last.html.gz recent.ltsv summary.html summary.txt last.html last.txt recent.html rss summary.ltsv; do
  log "download $PUBLIC_DIR/$file"
  echo "curl -o $PUBLIC_DIR/$file --fail https://rubyci.s3.amazonaws.com/$(getprop ro.rubyci_nickname)/ruby-master/$file" &>> $LOG
       (curl -o $PUBLIC_DIR/$file --fail https://rubyci.s3.amazonaws.com/$(getprop ro.rubyci_nickname)/ruby-master/$file || true) &>> $LOG
done

echo '#!/usr/bin/env bash' > ~/run-chkbuild
echo "set -e" >> ~/run-chkbuild
echo "cd cb" >> ~/run-chkbuild
echo "git pull" >> ~/run-chkbuild
echo "ulimit -n 1024" >> ~/run-chkbuild
echo "export RUBYCI_NICKNAME=$(getprop ro.rubyci_nickname)" >> ~/run-chkbuild
echo "./start-rubyci" >> ~/run-chkbuild
chmod 755 ~/run-chkbuild

log "done"

touch /sdcard/setup-chkbuild-done &>> $LOG
