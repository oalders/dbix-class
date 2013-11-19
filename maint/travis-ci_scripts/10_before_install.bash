#!/bin/bash

source maint/travis-ci_scripts/common.bash
if [[ -n "$SHORT_CIRCUIT_SMOKE" ]] ; then return ; fi

# Different boxes we run on may have different amount of hw threads
# Hence why we need to query
# Originally we used to read /sys/devices/system/cpu/online
# but it is not available these days (odd). Thus we fall to
# the alwas-present /proc/cpuinfo
# The oneliner is a tad convoluted - basicaly what we do is
# slurp the entire file and get the index off the last
# `processor    : XX` line
export NUMTHREADS="$(( $(perl -0777 -n -e 'print (/ (?: .+ ^ processor \s+ : \s+ (\d+) ) (?! ^ processor ) /smx)' < /proc/cpuinfo) + 1 ))"

# install some common tools from APT, more below unless CLEANTEST
apt_install libapp-nopaste-perl tree apt-transport-https

# FIXME - the debian package is oddly broken - uses a bin/env based shebang
# so nothing works under a brew. Fix here until #debian-perl patches it up
sudo /usr/bin/perl -p -i -e 's|#!/usr/bin/env perl|#!/usr/bin/perl|' $(which nopaste)

if [[ "$CLEANTEST" != "true" ]]; then
### apt-get invocation - faster to grab everything at once
  #
  # FIXME these debconf lines should automate the firebird config but do not :(((
  sudo bash -c 'echo -e "firebird2.5-super\tshared/firebird/enabled\tboolean\ttrue" | debconf-set-selections'
  sudo bash -c 'echo -e "firebird2.5-super\tshared/firebird/sysdba_password/new_password\tpassword\t123" | debconf-set-selections'

  # add extra APT repo for Oracle
  # (https is critical - apt-get update can't seem to follow the 302)
  sudo bash -c 'echo -e "\ndeb [arch=i386] https://oss.oracle.com/debian unstable main non-free" >> /etc/apt/sources.list'

  run_or_err "Updating APT available package list" "sudo apt-get update"

  run_or_err "Cloning ora-archive from github" "git clone --bare https://github.com/ribasushi/travis_futzing.git /tmp/aptcachecrap"

  git archive --format=tar --remote=file:///tmp/aptcachecrap poor_cache \
    | sudo bash -c "tar -xO > /var/cache/apt/archives/oracle-xe_10.2.0.1-1.1_i386.deb"

  apt_install memcached firebird2.5-super firebird2.5-dev expect libnss-db oracle-xe

### config memcached
  export DBICTEST_MEMCACHED=127.0.0.1:11211

### config mysql
  run_or_err "Creating MySQL TestDB" "mysql -e 'create database dbic_test;'"
  export DBICTEST_MYSQL_DSN='dbi:mysql:database=dbic_test;host=127.0.0.1'
  export DBICTEST_MYSQL_USER=root

### config pg
  run_or_err "Creating PostgreSQL TestDB" "psql -c 'create database dbic_test;' -U postgres"
  export DBICTEST_PG_DSN='dbi:Pg:database=dbic_test;host=127.0.0.1'
  export DBICTEST_PG_USER=postgres

### conig firebird
  # poor man's deb config
  EXPECT_FB_SCRIPT='
    spawn dpkg-reconfigure --frontend=text firebird2.5-super
    expect "Enable Firebird server?"
    send "\177\177\177\177yes\r"
    expect "Password for SYSDBA"
    send "123\r"
    sleep 1
    wait
    sleep 1
  '
  # creating testdb
  # FIXME - this step still fails from time to time >:(((
  # has to do with the FB reconfiguration I suppose
  # for now if it fails twice - simply skip FB testing
  for i in 1 2 ; do

    run_or_err "Re-configuring Firebird" "
      sync
      DEBIAN_FRONTEND=text sudo expect -c '$EXPECT_FB_SCRIPT'
      sleep 1
      sync
      # restart the server for good measure
      sudo /etc/init.d/firebird2.5-super stop || true
      sleep 1
      sync
      sudo /etc/init.d/firebird2.5-super start
      sleep 1
      sync
    "

    if run_or_err "Creating Firebird TestDB" \
      "echo \"CREATE DATABASE '/var/lib/firebird/2.5/data/dbic_test.fdb';\" | sudo isql-fb -u sysdba -p 123"
    then
      export DBICTEST_FIREBIRD_DSN=dbi:Firebird:dbname=/var/lib/firebird/2.5/data/dbic_test.fdb
      export DBICTEST_FIREBIRD_USER=SYSDBA
      export DBICTEST_FIREBIRD_PASS=123

      export DBICTEST_FIREBIRD_INTERBASE_DSN=dbi:InterBase:dbname=/var/lib/firebird/2.5/data/dbic_test.fdb
      export DBICTEST_FIREBIRD_INTERBASE_USER=SYSDBA
      export DBICTEST_FIREBIRD_INTERBASE_PASS=123

      break
    fi

  done

### config oracle
  EXPECT_ORA_SCRIPT='
    spawn /etc/init.d/oracle-xe configure
    expect "Specify the HTTP port that will be used for Oracle Application Express"
    sleep 0.5
    send "\r"
    expect "Specify a port that will be used for the database listener"
    sleep 0.5
    send "\r"
    expect "Specify a password to be used for database accounts"
    sleep 0.5
    send "123\r"
    expect "Confirm the password"
    sleep 0.5
    send "123\r"
    expect "Do you want Oracle Database 10g Express Edition to be started on boot"
    sleep 0.5
    send "y\r"
    sleep 0.5
    expect eof
    wait
  '

#  run_or_err "Configuring OracleXE" "sudo expect -c '$EXPECT_ORA_SCRIPT'"

bash -c "sudo $(which expect) -c '$EXPECT_ORA_SCRIPT'"

  # if we do not do this it doesn't manage to start before sqlplus
  # is invoked below
  run_or_err "Re-start OracleXE" "sudo /etc/init.d/oracle-xe restart"

  export ORACLE_HOME=/usr/lib/oracle/xe/app/oracle/product/10.2.0/server

  export DBICTEST_ORA_DSN=dbi:Oracle:host=localhost;sid=XE
  export DBICTEST_ORA_USER=dbic_test
  export DBICTEST_ORA_PASS=123
  #DBICTEST_ORA_EXTRAUSER_DSN=dbi:Oracle:host=localhost;sid=XE
  #DBICTEST_ORA_EXTRAUSER_USER=dbic_test_extra
  #DBICTEST_ORA_EXTRAUSER_PASS=123

  sudo ps fuxa | cat
  sudo netstat -an46p | cat

  set +e

  ORACLE_SID=XE $ORACLE_HOME/bin/sqlplus -L -S system/123 @/dev/stdin "$DBICTEST_ORA_PASS" <<< "
    CREATE USER $DBICTEST_ORA_USER IDENTIFIED_BY ?;
    GRANT connect,resource TO $DBICTEST_ORA_USER;
  "

  sudo grep --color=never -r . "$ORACLE_HOME/log/"

  set -e

  false

fi

SHORT_CIRCUIT_SMOKE=1
