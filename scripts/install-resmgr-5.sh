#!/bin/bash
#
# Copyright 2014 The Serviced Authors.
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
###############################################################################
#
# Requires about 5G of free space in root's $HOME
#
# Requires script to be run as root
# Requires that all specified hostnames are resolvable to IPs via host command
# Requires passwordless ssh to all specified hosts
# Requires that btrfs filesystem is partitioned and mounted at:
#    /var/lib/docker     # all hosts
#    /opt/serviced/var   # only master
#
# Instructions to run on master as root user:
#    download this script to $HOME of the root user
#    chmod +rx ~/install-resmgr-5.sh
#    ~/install-resmgr-5.sh master MASTER_HOSTNAME REMOTE_HOSTNAME REMOTE2_HOSTNAME ...
#
# Log files are stored in $HOME/resmgr/
# 
###############################################################################

export INSTALL_RESMGR_VERSION="0.1"

#==============================================================================
function usage
{
    cat <<EOF
Usage: $0 master MASTER_HOSTNAME REMOTE_HOSTNAME [OTHER_REMOTE_HOSTNAMES...]
    install resmgr 5 on master and remote host(s)

Example(s):
    $0 master zmaster zremote1 zremote2   # called as root user on master host
        # will:
        #    install/configure software on remotes via ssh
        #    install/configure/deploy software on master
EOF
    exit 1
}

#==============================================================================
function die
{
    echo "ERROR: ${*}" >&2
    exit 1
}

#==============================================================================
function logError
{
    echo "ERROR: ${*}" >&2
}

#==============================================================================
function logWarning
{
    echo "WARNING: ${*}" >&2
}

#==============================================================================
function logInfo
{
    echo "INFO: ${*}" >&2
}

#==============================================================================
function logSummary
{
    echo "INFO: ${*}" >&2
    echo "================================================================================" >&2
}

#==============================================================================
function getLinuxDistro 
{               
    local linux_distro=$([ -f "/etc/redhat-release" ] && echo RHEL || echo DEBIAN; [ "0" = $PIPESTATUS ] && true || false)
    local result=$?

    echo $linux_distro
    return $result
}

#==============================================================================
function checkFilesystems
{
    logInfo "Checking filesystems"
    local numErrors=0
    local wantedFSType="$1"; shift
    local paths="$@"

    for path in $paths; do
        logInfo "checking that path $path is of the required type: $wantedFSType"

        if ! df -H $path; then
            logError "df was not able to find dir: $dir"
            numErrors=$(( numErrors + 1 ))
            continue
        fi

        if ! mount | grep "on $path type $wantedFSType"; then
            logError "filesystem at path: $path is not $wantedFSType"
            numErrors=$(( numErrors + 1 ))
            continue
        fi
    done

    logSummary "checked filesystems - found $numErrors errors"

    return $numErrors
}

#==============================================================================
function checkHostsResolvable
{
    local hosts="$@"
    logInfo "Checking that hosts are resolvable: $hosts"
    local numErrors=0

    for host in $hosts; do
        if ! host $host; then
            numErrors=$(( numErrors + 1 ))
            continue
        fi

        logInfo "host $host is a valid host"
    done

    logSummary "checked that hosts are resolvable - found $numErrors errors"

    return $numErrors
}

#==============================================================================
function checkHostsSsh
{
    local hosts="$@"
    logInfo "Checking that hosts have passwordless ssh: $hosts"
    local numErrors=0

    for host in $hosts; do
        if ! ssh $host id >/dev/null; then
            numErrors=$(( numErrors + 1 ))
            continue
        fi
    done

    logSummary "checked that hosts have passwordless ssh - found $numErrors errors"

    return $numErrors
}

#==============================================================================
function installRemotes
{
    local master="$1"; shift
    local remotes="$@"
    logInfo "Installing remotes with master: $master and remotes: $remotes"
    local numErrors=0

    # scp and launch script
    for host in $remotes; do
        if ! scp $SCRIPT $host:; then
            numErrors=$(( numErrors + 1 ))
            continue
        fi

        nohup ssh $host $SCRIPT remote $master $remotes &>/dev/null &
        if [[ $? != 0 ]] ; then
            numErrors=$(( numErrors + 1 ))
            continue
        fi

        logInfo "scped and launched script on $remote"
    done

    logSummary "installed remotes - found $numErrors errors"

    return $numErrors
}

#==============================================================================
function installHostSoftware
{
    logInfo "Installing software"
    local numErrors=0

    ufw disable

    if test -f /etc/selinux/config && grep '^SELINUX=enforcing' /etc/selinux/config; then
        EXT=$(date +'%Y%m%d-%H%M%S-%Z')
        sudo sed -i.${EXT} -e 's/^SELINUX=.*/SELINUX=permissive/g' \
              /etc/selinux/config && \
              grep '^SELINUX=' /etc/selinux/config

        die "SElinux was found and set to permissive - reboot server and rerun this script on master"
    fi

    set -e

    curl -sSL https://get.docker.io/ubuntu/ | sh

    usermod -aG docker $USER

    apt-key adv --keyserver keys.gnupg.net --recv-keys AA5A1AD7

    REPO=http://get.zenoss.io/apt/ubuntu
    sh -c 'echo "deb [ arch=amd64 ] '${REPO}' trusty universe" \
          > /etc/apt/sources.list.d/zenoss.list'

    apt-get update

    apt-get install -y ntp

    apt-get install -y zenoss-resmgr-service

    logSummary "installed software"

    return $numErrors
}

#==============================================================================
function configureMaster
{
    logInfo "Configuring master"
    local numErrors=0

    set -e

    EXT=$(date +'%Y%m%d-%H%M%S-%Z')
    sed -i.${EXT} \
          -e 's|^#[^S]*\(SERVICED_FS_TYPE=\).*$|\1btrfs|' \
            /etc/default/serviced

    sed -i.${EXT} -e 's|^#[^H]*\(HOME=/root\)|\1|' \
          -e 's|^#[^S]*\(SERVICED_REGISTRY=\).|\11|' \
          -e 's|^#[^S]*\(SERVICED_AGENT=\).|\11|' \
          -e 's|^#[^S]*\(SERVICED_MASTER=\).|\11|' \
                /etc/default/serviced

    MYOPT="\nDOCKER_OPTS=\"--insecure-registry $(hostname -s):5000\""
    sed -i.${EXT} -e '/DOCKER_OPTS=/ s|$|'"${MYOPT}"'|' \
      /etc/default/docker
    stop docker; start docker

    start serviced

    logSummary "configured master"

    return $numErrors
}

#==============================================================================
function configureRemote
{
    logInfo "Configuring remote"
    local master="$1"
    local numErrors=0

    set -e

    EXT=$(date +'%Y%m%d-%H%M%S-%Z')

    MHOST=$(set -o pipefail; host $master | awk '{print $NF}')

    test ! -z "${MHOST}" && \
    sed -i.${EXT} -e 's|^#[^H]*\(HOME=/root\)|\1|' \
      -e 's|^#[^S]*\(SERVICED_REGISTRY=\).|\11|' \
      -e 's|^#[^S]*\(SERVICED_AGENT=\).|\11|' \
      -e 's|^#[^S]*\(SERVICED_MASTER=\).|\10|' \
      -e 's|^#[^S]*\(SERVICED_MASTER_IP=\).*|\1'${MHOST}'|' \
      -e '/=$SERVICED_MASTER_IP/ s|^#[^S]*||' \
      /etc/default/serviced

    start serviced

    logSummary "configured remote"

    return $numErrors
}

#==============================================================================
function duplicateOutputToLogFile
{
    local logfile="$1"
    local logdir=$(dirname $logfile)
    [[ ! -d "$logdir" ]] && \mkdir -p $logdir

    exec &> >(tee -a $logfile)
    echo -e "\n################################################################################" >> $logfile
    return $?
}

#==============================================================================
function main
{
    INITPWD=$(pwd)
    SCRIPT="$(\cd $(dirname $0); \pwd)/$(basename -- $0)"

    local errors=0
    [[ $# -lt 3 ]] && usage
    local role="$1"; shift
    local master="$1"; shift
    local remotes="$@"

    # ---- Check environment
    [[ "root" != "$(whoami)" ]] && die "user is not root - run this script as 'root' user"

    local logdir="$HOME/resmgr"
    [[ ! -d "$logdir" ]] && mkdir -p "$logdir"
    \cd $logdir || die "could not cd to logdir: $logdir"

    duplicateOutputToLogFile "$logdir/$(basename -- $0).log"

    # ---- Show date and version of os
    logInfo "$(basename -- $0)  date:$(date +'%Y%m%d-%H%M%S-%Z')  uname-rm:$(uname -rm)"
    logInfo "installing as '$role' role with master $master with remotes: $remotes"

    # ---- check that each host is ip/hostname resolvable and passwordless ssh works
    checkHostsResolvable $master $remotes || die "failed to satisfy resolvable hosts prereq"

    # ---- install on remotes
    case "$role" in
        "master")
            checkFilesystems "btrfs" "/var/lib/docker" "/opt/serviced/var" || die "failed to satisfy filesystem prereq"

            checkHostsSsh $master $remotes || die "failed to satisfy passwordless ssh prereq"

            installRemotes $master $remotes

            installHostSoftware

            # TODO: sudo usermod -aG sudo $USER  - which user?
            # TODO: how to ensure ~/.dockercfg for docker?

            configureMaster

            # TODO:
            #   add appropriate pools
            #   add hosts to pools
            #   wait for remote by continuously adding host and waiting for success
            #   add template
            #   start zenoss
            #   wait for services to start
            #   use dc-admin to add remote collector to collector pool

            logSummary "software is installed, deployed, and started on master"
            logSummary "TODO: add pools, hosts, template; start services; add collector"
            ;;

        "remote")
            checkFilesystems "btrfs" "/var/lib/docker" || die "failed to satisfy filesystem prereq"

            installHostSoftware

            configureRemote $master

            logSummary "software is installed, deployed, and started on remote"
            ;;

        *)
            die "prereqs not configured"
            ;;
    esac

    # ---- return with number of errors
    return $errors
}

#==============================================================================
# MAIN

if [ "install-resmgr-5.sh" = "$(basename -- $0)" ]; then
    main "$@"
    exit $?
fi

###############################################################################


