#!/usr/bin/env bash
# Copyright (c) 2014 The Bitcoin Core developers
# Copyright (c) 2018 The Freicoin developers.
#
# This program is free software: you can redistribute it and/or
# modify it under the conjunctive terms of BOTH version 3 of the GNU
# Affero General Public License as published by the Free Software
# Foundation AND the MIT/X11 software license.
#
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# Affero General Public License and the MIT/X11 software license for
# more details.
#
# You should have received a copy of both licenses along with this
# program.  If not, see <https://www.gnu.org/licenses/> and
# <http://www.opensource.org/licenses/mit-license.php>

# Test marking of spent outputs

# Create a transaction graph with four transactions,
# A/B/C/D
# C spends A
# D spends B and C

# Then simulate C being mutated, to create C'
#  that is mined.
# A is still (correctly) considered spent.
# B should be treated as unspent

if [ $# -lt 1 ]; then
        echo "Usage: $0 path_to_binaries"
        echo "e.g. $0 ../../src"
        exit 1
fi

set -f

FREICOIND=${1}/freicoind
CLI=${1}/freicoin-cli

DIR="${BASH_SOURCE%/*}"
SENDANDWAIT="${DIR}/send.sh"
if [[ ! -d "$DIR" ]]; then DIR="$PWD"; fi
. "$DIR/util.sh"

D=$(mktemp -d test.XXXXX)

# Two nodes; one will play the part of merchant, the
# other an evil transaction-mutating miner.

D1=${D}/node1
CreateDataDir $D1 port=11000 rpcport=11001
B1ARGS="-datadir=$D1 -debug=mempool"
$FREICOIND $B1ARGS &
B1PID=$!

D2=${D}/node2
CreateDataDir $D2 port=11010 rpcport=11011
B2ARGS="-datadir=$D2 -debug=mempool"
$FREICOIND $B2ARGS &
B2PID=$!

# Wait until all four nodes are at the same block number
function WaitBlocks {
    while :
    do
        sleep 1
        declare -i BLOCKS1=$( GetBlocks $B1ARGS )
        declare -i BLOCKS2=$( GetBlocks $B2ARGS )
        if (( BLOCKS1 == BLOCKS2 ))
        then
            break
        fi
    done
}

# Wait until node has $N peers
function WaitPeers {
    while :
    do
        declare -i PEERS=$( $CLI $1 getconnectioncount )
        if (( PEERS == "$2" ))
        then
            break
        fi
        sleep 1
    done
}

echo "Generating test blockchain..."

# Start with B2 connected to B1:
$CLI $B2ARGS addnode 127.0.0.1:11000 onetry
WaitPeers "$B1ARGS" 1

# 2 block, 50 XBT each == 100 XBT
# These will be transactions "A" and "B"
$CLI $B1ARGS setgenerate true 2

WaitBlocks
# 100 blocks, 0 mature == 0 XBT
$CLI $B2ARGS setgenerate true 100
WaitBlocks

CheckBalance "$B1ARGS" 1501.13396269 "*"
CheckBalance "$B1ARGS" 1500.98866296
CheckBalance "$B2ARGS" 0 "*"
CheckBalance "$B2ARGS" 0

# restart B2 with no connection
$CLI $B2ARGS stop > /dev/null 2>&1
wait $B2PID
$FREICOIND $B2ARGS &
B2PID=$!

B1ADDRESS=$( $CLI $B1ARGS getnewaddress )
B2ADDRESS=$( $CLI $B2ARGS getnewaddress )

# Transaction C: send-to-self, spend A
TXID_C=$( $CLI $B1ARGS sendtoaddress $B1ADDRESS 750.49419594)

# Transaction D: spends B and C
TXID_D=$( $CLI $B1ARGS sendtoaddress $B2ADDRESS 1500.98866296)

CheckBalance "$B1ARGS" 0

# Mutate TXID_C and add it to B2's memory pool:
RAWTX_C=$( $CLI $B1ARGS getrawtransaction $TXID_C )

# ... mutate C to create C'
L=${RAWTX_C:82:2}
NEWLEN=$( printf "%x" $(( 16#$L + 1 )) )
MUTATEDTX_C=${RAWTX_C:0:82}${NEWLEN}4c${RAWTX_C:84}
# ... give mutated tx1 to B2:
MUTATEDTXID=$( $CLI $B2ARGS sendrawtransaction $MUTATEDTX_C )

echo "TXID_C: " $TXID_C
echo "Mutated: " $MUTATEDTXID

# Re-connect nodes, and have both nodes mine some blocks:
$CLI $B2ARGS addnode 127.0.0.1:11000 onetry
WaitPeers "$B1ARGS" 1

# Having B2 mine the next block puts the mutated
# transaction C in the chain:
$CLI $B2ARGS setgenerate true 1
WaitBlocks

# B1 should still be able to spend 100, because D is conflicted
# so does not count as a spend of B
CheckBalance "$B1ARGS" 1501.06167074 "*"
CheckBalance "$B1ARGS" 1500.98723151

$CLI $B2ARGS stop > /dev/null 2>&1
wait $B2PID
$CLI $B1ARGS stop > /dev/null 2>&1
wait $B1PID

echo "Tests successful, cleaning up"
rm -rf $D
exit 0
