#!/bin/bash
#
# Parallels Tools for Linux. Shared Folders automounting tool.
#
# Copyright (c) 1999-2015 Parallels International GmbH.
# All rights reserved.
# http://www.parallels.com

MOUNTS=/etc/mtab
PRL_LOG=/var/log/parallels.log
ROSETTA_LINUX_SF_NAME=RosettaLinux
ROSETTAD_PID_FILE="/var/run/prlrosettad.pid"
ROSETTAD_SOCK="/var/run/prlrosettad.sock"
BINFMT_CONFIG_COMMAND=prlbinfmtconfig
SF_FUSE_DAEMON=prl_fsd
PRL_SF_BACKEND="${PRL_SF_BACKEND:-fuse}"
SF_LIST=""
RUN_MODE=""

prl_log() {
	level=$1
	shift
	msg=$*
	timestamp=`date '+%m-%d %H:%M:%S 	'`
	echo "$timestamp $level SHAREDFOLDERS: $msg" >>"$PRL_LOG"
	echo "$msg"
}

while [[ "$#" -gt 0 ]]; do
    case $1 in
        --sf)
            shift
            if [ -n "$1" ]; then
                SF_LIST="$SF_LIST"$'\n'"$1"
            else
                prl_log E "Error: --sf requires an argument"
                exit 1
            fi
            ;;
        -f)
            RUN_MODE=f
            ;;
        -u)
            RUN_MODE=u
            ;;
        *)
            prl_log W "Unknown parameter passed: '$1'"
            exit 1
            ;;
    esac
    shift
done

if [ -z "$RUN_MODE" ]; then
    prl_log E "Error: One of -f or -u must be specified."
    exit 1
fi

#Remove 'new line' from the beginning
SF_LIST=$(echo -e "$SF_LIST" | sed '/^$/d')

prl_log I "Shared folders automount tool. Mode: '$RUN_MODE', SFs: '$SF_LIST', Backend: '$PRL_SF_BACKEND'"

[ -d "/media" ] && MNT_PT=/media/psf || MNT_PT=/mnt/psf

# remove all obsolete mount points in MNT_PT dir
rmdir "$MNT_PT"/* 2>/dev/null

# $1 -- SF name
# $2 -- mount point
do_mount() {
	
 	mnt_ops="nosuid,nodev,noatime"

 	if [ "$PRL_SF_BACKEND" = "kmod" ]; then

		# Actually, kmod has code to force set MS_SYNCHRONOUS during mounting/unmounting.
		# Therefore, setting the 'sync' option during mounting is probably not required, but let's
		# keep it to avoid potential regressions.
 	 	mnt_ops="$mnt_ops,share,sync" 

 	 	if [ "$1" = "Home" ]; then
 	 	 	mnt_ops="$mnt_ops,host_inodes"
 	 	fi

 	 	se_target_context=$([ "$1" = "RosettaLinux" ] && 
 	 	 	 	 	 	 	echo "bin_t" || 
 	 	 	 	 	 	 	echo "removable_t")
 	 	if type semodule >/dev/null 2>&1; then
 	 	 	mnt_ops="$mnt_ops,context=system_u:object_r:$se_target_context:s0"
 	 	fi

 	 	mount -t prl_fs -o "$mnt_ops" "$1" "$2"
 	elif [ "$PRL_SF_BACKEND" = "fuse" ]; then
		# '-o big_writes enable larger than 4kB writes'. 
		# Should enable the option explicitly because it's disabled by default in libfuse 2.X
		# ---
		# The 'sync' option must be omited for FUSE because FUSE kmod uses write-through caching by default
		# (write-back caching should be explicitly enabled by the FUSE daemon) and -osync/O_SYNC only leads to
		# extra calls to fsync: https://github.com/torvalds/linux/blob/master/include/linux/fs.h#L2793
		# which are not required (plus we currently don't implement the fsync procedure in the FUSE daemon)
		# and might lead to redundant latencies due to the extra calls from FUSE kmod to the FUSE daemon.
		mnt_ops="$mnt_ops,big_writes"
	
		if [ "$1" = "Home" ]; then
 	 	 	mnt_ops="$mnt_ops,use_ino"
 	 	fi

 	 	"$SF_FUSE_DAEMON" "$2" -o "$mnt_ops,fsname=$1,subtype=prl_fsd" --share --sf="$1"
 	else
 	 	echo "Shared Folders backend is not supported: $PRL_SF_BACKEND"
 	 	return 1
 	fi

 	return $?
}



run_with_logging()
{
	local command=$1
  	shift
	
	local command_out
	command_out=$($command $* 2>&1)
	rc=$?

	# TODO comment
	local original_ifs="$IFS"
	IFS=" "
	if [ $rc -eq 0 ]; then
		prl_log I "Successfully executed: '$command $*'" \
			"Output: $command_out"
	else
		prl_log E "Failed to execute:'$command $*'. " \
			"Retcode=$rc Output: $command_out"
	fi

	IFS="$original_ifs"
	return $rc
}
	
check_socket_existence() {
	local socket_path="$1"
	local timeout=10
	
	local start_time=$(date +%s)
	local end_time=$((start_time + timeout))
	
	while [ ! -S "$socket_path" ] && [ $(date +%s) -lt "$end_time" ]; do
		sleep 1
	done
	
	if [ ! -S "$socket_path" ]; then
		echo "Timeout: Socket $socket_path does not exist within $timeout seconds"
		return 1
	fi
}

start_rosettad() {
	path="$1"
	cache_dir="/var/cache/prlrosettad"
	socket_path="$cache_dir/uds/prlrosettad.sock"

	# Remove stale rosettad native socket (to be able monitor the creation of a new socket) 
	if [ -S "$socket_path" ]; then
		rm -f "$socket_path"
	fi

	# Run rosettad as daemon
	"$path" daemon "$cache_dir" > /var/log/parallels-rosettad.log 2>&1 < /dev/null &
	pid=$!
	echo $pid > $ROSETTAD_PID_FILE
	echo "Rosettad daemon started with PID: $pid"

	# Detach backgroud task (rosettad)
	disown

	# Wait untill rosetad create communication socket
	if check_socket_existence "$socket_path"; then
		# Allow connections from NON-root processes
		#rwx--x--x
		chmod 711 "$cache_dir"
		chmod 711 "$cache_dir/uds"
		#rwxrw-rw-
		chmod 766 "$socket_path"

		# Create symlink to the sock in /var/run/
		ln -s "$socket_path" "$ROSETTAD_SOCK"
	fi

	return $?
}

stop_rosettad() {
	if [ -f "$ROSETTAD_PID_FILE" ]; then
		pid=$(cat "$ROSETTAD_PID_FILE")

		echo "Teminating Rosettad daemon started with PID: $pid"

		kill "$pid"

		rm "$ROSETTAD_PID_FILE"
	else
		echo "Rosettad daemon is not running or PID file does not exist"
	fi

	if [ -h "$ROSETTAD_SOCK" ]; then
		rm "$ROSETTAD_SOCK"
	fi
}

on_mount_rosetta_sf() {
	mount_point="$1"
	rosetta_path=$mount_point/rosetta
	rosettad_daemon_path=$mount_point/rosettad
		
	if [ -f "$rosetta_path" ]; then
		run_with_logging $BINFMT_CONFIG_COMMAND register $ROSETTA_LINUX_SF_NAME $rosetta_path

		if [ $? -eq 0 ]; then
			if [ -f "$rosettad_daemon_path" ]; then
					run_with_logging start_rosettad "$rosettad_daemon_path"
			else
					prl_log I "Skip starting Rosetta OAT сaching daemon. executable '$rosettad_daemon_path' is not found"
			fi
		fi
	else
		prl_log W "Skip registring binfmt. Emulator '$rosetta_path' is not found"
	fi

	return $?
}

on_unmount_rosetta_sf() {
	run_with_logging $BINFMT_CONFIG_COMMAND unregister $ROSETTA_LINUX_SF_NAME
	run_with_logging stop_rosettad
}

IFS=$'\n'

# Get list of SFs which are already mounted
curr_mounts=$(cat "$MOUNTS" | awk '{
	if ($3 == "prl_fs" || $3 == "fuse.prl_fsd") {
		if ($1 == "none") {
			split($4, ops, ",")
			for (i in ops) {
				if (ops[i] ~ /^sf=/) {
					split(ops[i], sf_op, "=")
					print sf_op[2]
					break
				}
			}
		} else {
			n = split($1, dir, "/")
			print dir[n]
		}
	}}')
# and list of their mount points.
curr_mnt_pts=$(cat "$MOUNTS" | awk '{if ($3 == "prl_fs" || $3 == "fuse.prl_fsd") print $2}' | \
	while read -r f; do printf "${f/\%/\%\%}\n"; done)
if [ $RUN_MODE != 'u' ]; then

	# Go through all enabled SFs
	for sf in $SF_LIST; do
		mnt_pt="$MNT_PT/$sf"
		curr_mnt_pts=`echo "$curr_mnt_pts" | sed "/^${mnt_pt//\//\\\/}$/d"`
		# Check if shared folder ($sf) is not mounted already
		printf "${curr_mounts/\%/\%\%}" | grep -q "^$sf$" && continue
		if [ ! -d "$MNT_PT" ]; then
			mkdir "$MNT_PT"
			chmod 755 "$MNT_PT"
		fi
		mkdir "$mnt_pt"
		run_with_logging do_mount $sf $mnt_pt

		if [ $? -eq 0 ]; then
			if [ "$sf" = "$ROSETTA_LINUX_SF_NAME" ]; then
				on_mount_rosetta_sf $mnt_pt
			fi
		fi
	done
fi

# Here in $curr_mnt_pts is the list of SFs which are disabled
# but still mounted -- umount all them.
for mnt_pt in $curr_mnt_pts; do
	# Skip all those mounts outside of our automount directory.
	# Seems user has mounted them manually.
	if ! echo "$mnt_pt" | grep -q "^${MNT_PT}"; then
		prl_log I "Skipping shared folder '${mnt_pt}'"
		continue
	fi

	# Unregister binfmt before unmounting, because binfmt_misc
	# might hold open interpretator
	sf=$(echo "$mnt_pt" | sed "s|^$MNT_PT/||")
	if [ "$sf" = "$ROSETTA_LINUX_SF_NAME" ]; then
		on_unmount_rosetta_sf $mnt_pt
	fi

	run_with_logging umount $mnt_pt
	if [ $? -eq 0 ]; then
		rmdir "$mnt_pt"
	fi
done
exit $rc
