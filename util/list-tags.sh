#!/usr/bin/env bash
JOB=`basename "$0"`

# Load target
source /etc/restic/targets/includes/pre.sh

# Return unique tags across all snapshots
restic snapshots --json | jq -r '.[] | .tags[]' | sort -u

#source /etc/restic/targets/includes/post.sh
