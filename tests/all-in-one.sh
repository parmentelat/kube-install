#!/bin/bash

MASTER=sopnode-w2.inria.fr
WORKER=sopnode-w3.inria.fr
FITNODE=fit01
RUNS=1
PERIOD=3

M=root@$MASTER
W=root@$WORKER
F=root@$FITNODE
S=inria_sopnode

function check-config() {
    echo MASTER=$MASTER
    echo WORKER=$WORKER
    echo FITNODE=$FITNODE
    echo RUNS=$RUNS
    echo PERIOD=$PERIOD
    echo -n "type enter to confirm (or control-c to quit) -> "
    read _
}

function load-image() {
    ssh $S@faraday.inria.fr rhubarbe load -i kubernetes $FITNODE
    ssh $S@faraday.inria.fr rhubarbe wait $FITNODE
}

function -map() {
    local verb="$1"; shift
    for h in $M $W $F; do
        ssh $h kube-install.sh $verb
    done
}

function refresh() {
    for h in $M $W; do
        ssh $h "source /root/diana/bash/comp-sopnode.ish; refresh"
    done
    ssh $F git -C kube-install pull
    versions
}

function versions() { -map version; }

function leave() { -map leave-cluster; }

function create() {
    ssh $M kube-install.sh create-cluster
    ssh $M kube-install.sh networking-calico-postinstall
}

function join() {
    for h in $W $F; do
        ssh $h kube-install.sh join-cluster r2lab@$MASTER
    done
    ssh $M "source /usr/share/kube-install/bash-utils/loader.sh; fit-label-nodes"
}

function testpod() { -map testpod; }

function tests() {
    for h in $M $W; do
        echo "running $RUNS tests every $PERIOD s on $h"
        ssh $h "source /usr/share/kube-install/bash-utils/loader.sh; clear-logs; set-fitnode $FIT; run-all $RUNS $PERIOD"
    done
    echo "running $RUNS tests every $PERIOD s on $F"
    ssh $F "source /root/kube-install/bash-utils/loader.sh; clear-logs; set-fitnode $FIT; run-all $RUNS $PERIOD"
}

function gather() {
    ./gather-logs.sh $FITNODE
}

###

function -steps() {
    for step in $@; do
        echo RUNNING STEP $step
        $step
    done
}

function full-monty()   { -steps load-image refresh leave create join testpod; }
function rerun()        { -steps            refresh leave create join testpod; }

function usage() {
    echo "Usage: $0 subcommand1 .. subcommandn"
    echo "subcommand 'full-monty to redo everything including rhubarbe-load'"
    echo "subcommand 'rerun to redo everything except rhubarbe-load'"
    exit 1
}

while getopts "f:r:p:" opt; do
    case $opt in
        f) FITNODE=$OPTARG;;
        r) RUNS=$OPTARG;;
        p) PERIOD=$OPTARG;;
        \?) usage ;;
    esac
done
shift $(($OPTIND - 1))
[[ -z "$@" ]] && usage


for subcommand in "$@"; do
    $subcommand
done