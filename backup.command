#!/bin/bash

vers=2019.10.25.A
# backup script, started by a launch daemon, controlled by a job file, scheduled and updated from an update server



           ##
           ####
           ##  ##
           ##    ##
#############      ##
##                   ##
##                     ##     ONLY EDIT THIS FILE ON BACKUP SERVER, the clients will update themselves automatically
##                   ##
#############      ##
           ##    ##
           ##  ##
           ####
           ##



##  source a config file if update_address/port are different for this installation (this must occur before CONFIGURATION below)

if [ -e /var/root/backup/.config ] ; then
  source /var/root/backup/.config
  # this file should look like this:
  #   update_address={server domain name or IP address}
  #   update_port={specify port, 22 is the default}
fi



## some vars have to be preset because remote server access won't preset some of the expected variables and we don't want it to dump at the end

remote_schedule=0
local_schedule=0





########################################################################################################################################################################################################
##
##  INSTRUCTIONS FOR SETTING UP A NEW SERVER TO BACK UP TO
##
########################################################################################################################################################################################################

# install developer (or just command line) tools.  verify they are authorized by trying a command from terminal like "setfile", to make sure the installation has been agreed to and activated

# create a folder /var/root/backups and copy this script there

# create a .config file and define update_address and update_port if you are fetching script updates from your own server (otherwise it defaults to mine)

# run "./backup.command -I" to initialize the server databases, create an example job file, and set dsa keyapir

# run "./backup.command -u" to test key and check for files - install any support files that are missing







########################################################################################################################################################################################################
##
##  INSTRUCTIONS FOR SETTING UP A NEW CLIENT TO BACK UP FROM
##
########################################################################################################################################################################################################

### THESE INSTRUCTIONS NEED TO BE TESTED ###

# install developer (or just command line) tools.  verify they are authorized by trying a command from terminal like "setfile", to make sure the installation has been agreed to and activated

# create a folder /var/root/backup

# copy this script and the .config file also if you made one to the backup folder

# if backing up to another computer: if the client already has a dsa keypair for root, copy the pub to the backup server's root authorized_keys
# otherwise, use the command "ssh-keygen -t rsa" to make one and copy it to the server

# test run the script without any parameters with the command "./backup.command"

# think of a job name that's unique from other jobs.  The best names are all lower case and underscores.  NO SPACES or other symbols.  20 chars max.

# rename the example job file, and edit, change the job name, and edit the other backup parameters.  change the default time also so you don't have several jobs starting at the same time

# create backup destination folder(s) as defined in the job file

# normalize the job file with a command similar to: "./backup.command -jobfile myjobname.job -normalize"

# review the normalized job file and make any necessary corrections, repeating the normalize if you made changes

# test the emailer with a command similar to: "./backup.command -mailtest" (you may need to enable emailing from "insecure apps" in google mail)

# test the backup by kicking it off manually with a command similar to: "./backup.command -update -jobfile myjobname.job -daemon"

# if the backup has problems, fix the job file and try again until it runs correctly

# install the job file with a command similar to: ".backup.command -jobfile myjobname.job -schedule -install"  (omit -schedule to load job to be run manually)







########################################################################################################################################################################################################
##
##  BUGS / KNOWN ISSUES / TO-DO
##
########################################################################################################################################################################################################

# remote changing of schedule could probably use more testing

# changing schedule remotely requires touching mod date in table also, but this may not have an easy work-around







########################################################################################################################################################################################################
########################################################################################################################################################################################################
###
###  CONFIGURATION
###
########################################################################################################################################################################################################
########################################################################################################################################################################################################

##  control use of WALL - set flags to "1" or ""

wall_debug_broadcasts=1
wall_daemon_broadcasts=
log_central_history=1



##  define update server to download and update backup program files from
##  this does not have to be the server the backups are being synced to
##  although that's probably going to be the typical installation
##  :- makes these vars only get set if they have not been previously set by a .config import at the top of this script

update_address=${update_address:-backup.vftp.net}
update_port=${update_port:-2222}
 


##  define static paths

install_folder="/var/root/backup"
       appname="backup.command"
    log_folder="${install_folder}/LOGS"  # most log files will be fully defined after we know our job name
    history_db="${install_folder}/history.db"
   schedule_db="${install_folder}/schedule.db"


job_log="${log_folder}/job.log"
cmd_log="${log_folder}/cmd.log"
sql_log="${log_folder}/sql.log"
sql_log_debug="${log_folder}/sql_debug.log"


## fixlinks and gmail email support file paths are hardcoded in the script



##  enable or disable emailing - set flags to "1" or ""

email_successes=
email_failures=1



##  SQL log and jobs database configuration

max_db_attempts=5







########################################################################################################################################################################################################
########################################################################################################################################################################################################
###
###  EARLY SETUP
###
########################################################################################################################################################################################################
########################################################################################################################################################################################################


##  insure PATH is set

# insure environment variables are set
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/sw/bin"
export TERM=xterm-color



##  configure BASH to crash when accessing an unassigned variable - sometimes painful but very helpful for debugging - accessing an unset variable is always a bug

set -u



# launchctl will log this to the stderr file for this job
# don't echo anything to stdout until we know we're not an instance on the backup server that needs to respond to -getschedule or -version

echo "$(date "+%Y/%m/%d %H:%M:%S") - BACKUP version $vers" 1>&2



##  caculate proper hostname (undo common modifications)

host=$HOSTNAME
host=${host%.local}
host=${host%.localhost}
host=${host%.home}



##  define a tempfile

tempfile="/tmp/backup_${RANDOM}.tmp"



# embed this in strings that require embedded linefeeds, to avoid $LINENO from getting out of sync
LF=$'\n'
TAB=$'\t'







########################################################################################################################################################################################################
########################################################################################################################################################################################################
###
###  TRAPS
###
########################################################################################################################################################################################################
########################################################################################################################################################################################################


########################################
##  SIGNAL INTERRUPT
########################################

##  received sigint, probably from launchd due to job being stopped (or possibly from user hitting ctrl-c)
##  used as a flag to exit out of loops or abort further process executions

got_sigint=
trapsigint () {

got_sigint=1

}



########################################
##  PING SUCCEEDED
########################################

##  pinger thread signaling main thread that ping succeeded
##  only used by OS's whose PING does not support the -t flag (mac os 10.4 and earlier?)

trapio () {

pingresult=0

}



########################################
##  PING FAILED
########################################

##  pinger thread signaling main thread that ping failed
##  only used by OS's whose PING does not support the -t flag

trapabrt () {

pingresult=1

}







########################################################################################################################################################################################################
########################################################################################################################################################################################################
###
###  THREADS
###
########################################################################################################################################################################################################
########################################################################################################################################################################################################


########################################
##  PINGER
########################################

## "pinger" thread, for Mac OS 10.4 and earlier where PING does not support the TIMEOUT flag

if [[ (${#@} != 0) && ("$1" == "-pinger") ]] ; then
  # we are the pinger thread.  try to ping, and then signal to our parent process whether successful or unsuccessful
  # this is done in a separate thread because ping will hang this thread if timeout is not (or cannot) be specified and the ip does not respond
  /sbin/ping -c 1 "$2" > /dev/null
  rc=$?
  if [ $rc != 0 ] ; then  # signal ping failed (NRTH etc)
    kill -sigabrt $PPID
  else  # signal ping successful
    kill -sigio $PPID
  fi
  exit
fi






 
########################################################################################################################################################################################################
########################################################################################################################################################################################################
###
###  FUNCTIONS
###
########################################################################################################################################################################################################
########################################################################################################################################################################################################


########################################
##  CALLING
########################################

##  indent call trace

depth=0
dent="                                                                                                                                     "
switch_trace=

calling () {

if [ "$switch_trace" ] ; then
  echo "${dent:0:depth*5}-> -> ->     CALL TO: $1" 1>&2
  calls[depth]="$1"
fi
((depth++))

}



########################################
##  RETURNING
########################################

##  backdent call trace

returning () {

((depth--))
if [ "$switch_trace" ] ; then
  echo "${dent:0:depth*5}<- <- <- RETURN FROM: ${calls[depth]}" 1>&2
fi

}



########################################
##  SLEEP MILLIS
########################################

## sleep milliseconds.  will abort if $stop_sleeping is nonblank (via code in a TRAP when a signal is sent to the process)
## this is necessary to sleep less than one second, OR to sleep inside a launch daemon where SLEEP does nothing

sleep_millis () {
local i


((s=$1/1000))
((m=$1%1000))
local i
stopsleeping=
for ((i=0;i<s;i++)) ; do
  /usr/bin/perl -e "select(undef,undef,undef,1.0)"
  if [ -n "$stopsleeping" ] ; then
    return
  fi
done
if [ $m != 0 ] ; then
  /usr/bin/perl -e "select(undef,undef,undef,0.${m})"
fi

}



########################################
##  DEBUG
########################################

##  display a line to STDERR if debugging

switch_debug=

debug () {

if [ "$switch_debug" ] ; then
  echo "DEBUG: $1" 1>&2
fi

}



########################################
##  MSG
########################################

##  display a message to stdut (only if not -daemon)

msg () {

if [ ! "$switch_daemon" ] ; then
  echo "$1"
fi

}



########################################
##  DEBUG2
########################################

##  display a line to STDERR if debugging

switch_debug2=

debug2 () {

if [ "$switch_debug2" ] ; then
  echo "DEBUG2: $1" 1>&2
fi

}



########################################
##  LOG JOB
########################################

##  record all job-related actions

log_job () {

debug "logging job action: $1"
mkdir -p "${job_log%/*}"
assert $LINENO "create log folder" "mkdir -p \"${job_log%/*}\""
touch "$job_log"
assert $LINENO "touch job log file" "touch \"$job_log\""
echo "$(date "+%Y/%m/%d %H:%M:%S") - $1" >> "$job_log"
assert $LINENO "add job log" "echo \"$(date "+%Y/%m/%d %H:%M:%S") - $1\" >> \"$job_log\""

}



########################################
##  LOG CMD
########################################

##  record the cmd command if any

log_cmd () {

debug "logging cmd $1"
mkdir -p "${cmd_log%/*}"
assert $LINENO "create log folder" "mkdir -p \"${cmd_log%/*}\""
touch "$cmd_log"
assert $LINENO "touch cmd log file" "touch \"$cmd_log\""
echo "$(date "+%Y/%m/%d %H:%M:%S") - $1" >> "$cmd_log"
assert $LINENO "add cmd log" "echo \"$(date "+%Y/%m/%d %H:%M:%S") - $1\" >> \"$cmd_log\""

}



########################################
##  LOG SQL
########################################

##  enter a line in the sql log file (usually for database changes - INSERT and UPDATE)

log_sql () {

mkdir -p "${sql_log%/*}"
assert $LINENO "create log folder" "mkdir -p \"${sql_log%/*}\""
touch "$sql_log"
assert $LINENO "touch sql log file" "touch \"$sql_log\""
echo "$(date "+%Y/%m/%d %H:%M:%S") - $1 with CMD: $2" >> "$sql_log"
assert $LINENO "add sql log" "echo \"$(date "+%Y/%m/%d %H:%M:%S") - $1\" >> \"$sql_log\""
debug "$1"

}
# history is ongoing, but the logfile is for this run only



########################################
##  LOG SQL DEBUG
########################################

## sql debug log, all commands

log_sql_debug () {

mkdir -p "${sql_log_debug%/*}"
touch "$sql_log_debug"
echo "$(date "+%Y/%m/%d %H:%M:%S") - $1" >> "$sql_log_debug"

}
 


########################################
##  LOG SQL RESULT
########################################

## sql debug log, all command results

log_sql_result () {

mkdir -p "${sql_log_debug%/*}"
touch "$sql_log_debug"
if [ "$result" == "${result#*$'\n'}" ] ; then
  # result is a single line
  echo "$(date "+%Y/%m/%d %H:%M:%S") - RESULT: $result" >> "$sql_log_debug"
else
  # result is multiline
  local result_lines result_firstline
  result_lines=$(($(echo "$result" | wc -l)))
  result_firstline=$(echo "$result" | head -n1)
  echo "$(date "+%Y/%m/%d %H:%M:%S") - $result_lines lines, first line: $result_firstline" >> "$sql_log_debug"
fi

}



########################################
##  LOG
########################################

##  enter a line in the log file and then forward to DEBUG

log () {

if [ -d "${log_file%/*}" ] ; then
  debug2 "log folder found at \"${log_file%/*}\""
else
  mkdir -p "${log_file%/*}"
  assert $LINENO "create log folder" "mkdir -p \"${log_file%/*}\""
fi
if [ -f "$log_file" ] ; then
  debug2 "log file found at \"$log_file\""
else
  touch "$log_file"
  assert $LINENO "touch log file" "touch \"$log_file\""
fi
echo "$(date "+%Y/%m/%d %H:%M:%S") - $1" >> "$log_file"
assert $LINENO "add log" "echo \"$(date "+%Y/%m/%d %H:%M:%S") - $1\" >> \"$log_file\""
debug "$1"

}
# history is ongoing, but the logfile is for this run only



########################################
##  DEBUG HISTORY
########################################

debug_central_history () {

## if debugging central history, log activity as called

if [ $log_central_history ] ; then
  log "$1"
fi

}



########################################
##  HISTORY
########################################

##  enter a line in the history file and then forward to LOG

history () {

if [ -d "${log_file%/*}" ] ; then
  debug2 "log folder found at \"${log_file%/*}\""
else
  mkdir -p "${log_file%/*}"
  assert $LINENO "create log folder" "mkdir -p \"${log_file%/*}\""
fi
if [ -f "$history_file" ] ; then
  debug2 "history file found at \"$history_file\""
else
  touch "$history_file"
  assert $LINENO "touch history file" "touch \"$history_file\""
fi
echo "$(date "+%Y/%m/%d %H:%M:%S") - $1" >> "$history_file"
assert $LINENO "add history" "echo \"$(date "+%Y/%m/%d %H:%M:%S") - $1\" >> \"$history_file\""
log "$1"
if [ ! "$switch_debug" ] ; then
  # the LOG call above will have already echoed to console if debugging is on
  echo "$1"
fi

}



########################################
##  CENTRAL HISTORY
########################################

##  send a line to the update server's central history database
##  errors contacting the central server will NOT abort the backup script
##  then forwards to DEBUG

# preset a few variables

h_started=$(date "+%Y/%m/%d %H:%M:%S")
h_finished=

central_opened=  # haven't sent an opening entry to central history yet


central_history () {
calling CENTRAL_HISTORY

debug_central_history "calling CENTRAL HISTORY with ${#@} parameters: $(format_array "${@}")"

# load parameters

h_rc="$1"
h_note="$2"


# assemble history record

c[0]="-history"
c[1]="$host"
c[2]="$job_name"
c[3]="$h_started"
c[4]="$h_finished"
c[5]="$h_rc"
c[6]="$h_note"


# prepend to note for dryruns

if [ ! "$switch_live" ] ; then
  c[6]="DRYRUN: ${c[6]}"
fi


# send history record to update server

debug_central_history "CMD: ssh -p \"$update_port\" -o StrictHostKeyChecking=no \"root@$update_address\" \"$install_folder/$appname $(format_array "${c[@]}")\""
debug "CMD: ssh -p \"$update_port\" -o StrictHostKeyChecking=no \"root@$update_address\" \"$install_folder/$appname $(format_array "${c[@]}")\""
ssh -p "$update_port" -o StrictHostKeyChecking=no "root@$update_address" "$install_folder/$appname $(format_array "${c[@]}")"
rc=$?
if [ $rc == 0 ] ; then
  debug "central history successfully sent"
  debug_central_history "central history successfully sent"
else
  debug "RC=$rc trying to send central history"
  debug_central_history "RC=$rc trying to send central history"
fi


# central history line has been opened, further calls from aborts and backup success/finish will try to
# close this entry instead of creating a new one

if [ -n "$h_finished" ] ; then
  # backup has finished, for better or worse
  if [ $central_opened ] ; then
    debug "finishing central history entry"
  else
    debug "starting and finishing central history entry"
  fi
else
  # backup has not finished yet (or is just starting)
  if [ $central_opened ] ; then
    debug "updating unfinished central history entry"
  else
    debug "starting central history entry"
  fi
fi

# further calls to central_history will always update an existing entry
central_opened=1

returning
}



########################################
##  BROADCAST
########################################

##  broadcast a message to WALL, displaying on all open terminals we can send to
##  will also send to the backup server's WALL if it's a remote backup and is scheduled
##  only scheduled backups broadcast to wall
##  then forwards to DEBUG

broadcast () {

# log and broadcast a message to wall
if [[ $switch_debug && (! $wall_debug_broadcasts) ]] ; then
  debug "WALL: $1"
elif [[ $switch_daemon && $wall_daemon_broadcasts ]] ; then
  echo "job $job_name: $1" | wall
  assert $LINENO "send broadcast to local wall" "echo \"$1\" | wall"
  if [ -n "$backup_address" ] ; then
    debug "this is a remote backup, wall on the backup server also"
    ssh -p "$backup_port" -o StrictHostKeyChecking=no "root@$backup_address" "echo \"$job_name: $1\" | wall"
    assert $LINENO "send broadcast to backup server's wall" "ssh -p \"$backup_port\" -o StrictHostKeyChecking=no \"root@$backup_address\" \"echo \\\"$job_name: $1\\\" | wall\""
  fi
fi
history "$1"

}



########################################
##  FINISH
########################################

##  script has finsihed after getting an error or doing something (possibly successfully backing up)
##  does not email, broadcast, or add to central history - just makes a final entry in the local history file and exits with the specified exit code

finish () {

# exit script
history "$1"
history "================================================================================"
exit "$2"

} 



########################################
##  ABORT
########################################

##  script has stopped on an error

aborting=

abort () {

# prevent infinite recursion (assert can be called inside backup_failed and finish, which can call abort)
if [ $aborting ] ; then
  exit 1
fi
aborting=1

# abort script with error
if [ -z "${job_name:-}" ] ; then
  # jobfile not yet loaded, cannot log anything
  echo "ABORT on line $1: $2" 1>&2
  exit 1
fi
if [ $central_opened ] ; then
  backup_failed "line $1: $2"
fi
finish "ABORT on line $1: $2" 1

}



########################################
##  ASSERT
########################################

##  test exit code of last command, abort with helpful information if it's nonzero
##  syntax:  ASSERT $LINENO "verbal description of what we were trying to do" "the command we were trying to execute"
##  first parameter will be line number of attempted process PLUS ONE

assert () {

rc=$?

if [ ${#@} != 3 ] ; then
  echo "assert failed to get correct parameter count, parameters passed: $(format_array 
"$@")"
  exit 1
fi

# test the return code of a previous function.   provide $?, TRY, and CMD
if [ $rc == 0 ] ; then
  debug2 "SUCCESS on line $(($1-1)) trying to $2 with CMD: $3"
  return
fi
abort $(($1-1)) "RC=$rc trying to $2 with CMD: $3"

}



########################################
##  ELAPSED
########################################

##  print elapsed time, specified in seconds, minutes, hours, and (optionally) days

elapsed () {

local d s
if [ "$1" -lt 86400 ] ; then
  date -j -u -f "%s" "$1" "+%H:%M:%S"
else
  ((d=$1/86400))
  ((s=$1%86400))
  echo "${d}d + $(date -j -u -f "%s" "$1" "+%H:%M:%S")"
fi

}



########################################
##  PING TEST
########################################

##  attempt to ping a server.  returns nothing on success, or a line of text on failure
##  works regardless of whether or not the PING command supports the TIMEOUT switch
##  sets good_ping=1 on success

pingtest () {

local result i
good_ping=
if [ -z "$1" ] ; then
  return
fi
pingtimeout=5
/sbin/ping -c 1 -t 1 127.0.0.1 &> /dev/null  # test to see if ping supports timeout flag
if [ $? == 0 ] ; then
  # installed version of ping supports the timeout flag
  result="$(/sbin/ping -c 1 -t "$pingtimeout" "$1" 2>&1 | grep 'bytes from')"
  log "pingtest result: \"$result\""
  if [ -z "$result" ] ; then
    return
  fi
else
  # this version of ping DOES NOT support the timeout flag (pre-10.4)
  # this is a new ping tester for pre-10.4 systems, using a trap
  # it starts a one packet ping via a thread.  the thread signals us if it succeeds or fails to ping,
  # or not at all if it stalls/hangs.  If it doesn't signal us within the limit, the thread is killed
  # we will get a "terminated" message if we kill it, which is unavoidable
  # I recall a way to redirect stdout to somewhere else for a time but don't remember how and it's not that important
  trap trapio sigio
  trap trapabrt sigabrt
  pingresult=-1
  "$0" -pinger "$1" &
  pingpid=$!
  for ((i=1;i<$((pingtimeout+3));i+=1)) ; do
    sleep_millis 1000
    if [ "$pingresult" -ne "-1" ] ; then  # the ping thread signalled us
      break
    fi
  done
  # pingresult =0 if ping succeeded and trapio was called by a SIGIO from pinger thread
  # pingresult =1 if ping failed and trapabrt was called by a SIGABRT from pinger thread
  # pingresult=-1 if ping timed out and pinger thread is hung
  if [ $pingresult == "-1" ] ; then  # ping timed out before we got a signal
    # pinger thread is probably hung.  kill it.
    kill $pingpid
  fi
  # unset traps
  trap - sigabrt
  trap - sigio
  if [ "$pingresult" != 0 ] ; then  # ping failed  (ping returned fail code or pinger thread hung)
    return
  fi
fi
log "backup server \"$1\" responds to ping without timeout"
good_ping=1

}



########################################
##  COMMAS
########################################

##  output a number formatted with commas every 3 decimal places

commas () {

#local n p out
n=$1
if [ "$n" -lt 1000 ] ; then
  echo "$n"
  return
fi
out=
while true ; do
  ((p=n%1000))
  ((n/=1000))
  if [ $n == 0 ] ; then
    echo "$p$out"
    return
  fi
  if [ $p -lt 10 ] ; then
    out="00$p$out"
  elif [ $p -lt 100 ] ; then
    out="0$p$out"
  else
    out="$p$out"
  fi
  out=",$out"
done

}



########################################
##  ADD PARAMETER
########################################

##  add a parameter to rsync's parameters array

add_parameter () {

if [ -z "${parameters[0]:-}"  ] ; then
  parameters[0]=$1
else
  parameters[${#parameters[@]}]=$1
fi
debug "added parameter \"$1\""

}



########################################
##  ADD EXCLUSION
########################################

##  add an exclusion to rsync's parameter array (job files can also use this function to add job-specific exclusions)

addex () {

debug "adding exclusion \"$1\""
add_parameter "--exclude=$1"

}



########################################
##  FORMAT ARRAY
########################################

##  display an array as quoted, escaped parameter values
##  this is useful to display commands properly that were called with passed parameter arrays
##  it's also necessary in some cases to send command arguments via ssh
##  rc must be piped through because some assert calls embed format_array in their CMD parameter, which would otherwise clear the previous exit code and mask errors (yes, that one was fun to debug)

format_array () {

rc=$?
local f n
#debug "passed ${#@} elements" 1>&2
while [ ${#@} != 0 ] ; do
  if [ -z "${f:-}" ] ; then
    # first parameter
    f=1
  else
    # not first parameter
    echo -n " "
    ((f++))
  fi
  n=$(echo "${1}" | sed 's/\$/\\\$/g' | sed 's/\"/\\\"/g')  # escape dollar signs
  echo -n "\"$n\""
  #echo -n "$f"
  shift
done
return $rc

}



########################################
###  ATTEMPT TO UPDATE
########################################

##  compare local and update versions for specified file
##  updates file if not found locally or if versions do not match (regardless of which claims to be newer)
##  sets $updated=1 if updated, aborts on error

attempt_to_update () {

file=$1
debug "check version on file \"$file\""
if [ -r "$file" ] ; then
  stamp_local=$(stat -f %m "$file")  # "1527141212"
  assert $LINENO "get local file timestamp" "stat -f %m \"$file\""
  debug " stamp_local = \"$stamp_local\""

  # this is how we used to do it when checking versions one at a time via ssh
  #stamp_update=$(ssh -p $update_port -o StrictHostKeyChecking=no root@$update_address "stat -f %m \"$file\"")  # "1527141212" (201805240053.32)
  #assert $LINENO "fetch update stamp" "ssh -p $update_port -o StrictHostKeyChecking=no root@$update_address \"stat -f %m \\\"$file\\\"\""

  # extract version of specified file from output of -versions request made earlier
  stamp_update="${versions#*$'\n'${file##*/}=}"
  if [ "$stamp_update" == "$versions" ] ; then
    abort $LINENO "file \"$file\" not found in version list"
  fi
  stamp_update=${stamp_update%%$'\n'*}  # "1527139586"

  debug "stamp_update = \"$stamp_update\""
  if [ "$stamp_local" == "$stamp_update" ] ; then
    debug "versions match, file is up-to-date"
    return
  fi
  log "stamp mismatch ($stamp_local -> $stamp_update), update required"
else
  log "local file not found, download required"
fi

# file is either missing or version does not match (could be older OR newer - we don't care, it's getting replaced)

# insure the parent folder exists
mkdir -p "${file%/*}"
assert $LINENO "create parent folder for file if necessary" "mkdir -p \"${file%/*}\"" 

# download the update
scp -o StrictHostKeyChecking=no -P "$update_port" "root@$update_address:$file" "$file" > /dev/null 2>/dev/null
assert $LINENO "download update" "scp -o StrictHostKeyChecking=no -P \"$update_port\" \"root@$update_address:$file\" \"$file\""

# correct the timestamp on the new download to match the update server's file, so it matches next time we check it
stamp2=$(date -j -f %s "$stamp_update" "+%Y%m%d%H%M.%S")
assert $LINENO "convert totalsec to touch format" "date -j -f %s \"$stamp_update\" \"+%Y%m%d%H%M.%S\""
touch -t "$stamp2" "$file"
assert $LINENO "update file timestamp following update" "touch -t \"$stamp2\" \"$file\""

# warning, this may have actually updated US (bash doesn't handle this as well now as it used to)
# indicate this file was updated
u=$(grep "^vers=" "$file" | head -n1)  # "vers=2018.05.21.A"
s=$(date -j -f %s "$stamp_update" "+%Y/%m/%d %H:%M:%S")
history "successfully updated $file to version ${u#*=}  (last modified $s)"

# with this set, script should attempt to call itself again so it's running the latest version. THIS script may crash, but that doesn't matter.
debug "setting flag to indicate updates were downloaded"
updated=1

}



########################################
##  DEFINE PATHS
########################################

##  define paths before trying to log anything
##  this gets called (as "UNDEFINED") before the jobfile is loaded so that logging can occur prior to jobfile load
##  and will get called a second time after the jobfile is laoded, at which time new log entries will change their destination

define_paths () {

debug "defining paths for job \"$job_name\""

    log_file="${log_folder}/${job_name}_log.txt"          # log of all backup events
history_file="${log_folder}/${job_name}_history_log.txt"  # historic log of all errors/results
  rs_out_log="${log_folder}/${job_name}_rs_runlog.txt"    # this rsync's non-error output
  rs_err_log="${log_folder}/${job_name}_rs_errlog.txt"    # this rsync's error output
  rs_run_log="${log_folder}/${job_name}_rs_runlog.txt"    # this rsync's non-error and error output
     fixfile="${log_folder}/${job_name}_fixfile.txt"      # fixlinks errror file

s_plist=/Library/LaunchDaemons/backup_${job_name}.plist
m_plist=/Library/LaunchDaemons/backup_${job_name}_manual.plist

debug "s_plist=\"$s_plist\""
debug "m_plist=\"$m_plist\""

s_daemon="backup_${job_name}"
m_daemon="backup_${job_name}_manual"

debug "s_daemon=\"$s_daemon\""
debug "m_daemon=\"$m_daemon\""


}



########################################
##  DOWNLOAD IF MISSING
########################################

##  download a file from the update server if it is not present on the local computer
##  does NOT compare file versions, ALWAYS blindly downloads if missing

download_if_missing () {

file=$1

# if it's already here, don't attempt to download it (if it needs to be updated, you will need to delete it)
if [ -r "$file" ] ; then
  debug "file is already present: \"$file\""
  return
fi

# insure the parent folder exists
mkdir -p "${file%/*}"
assert $LINENO "create parent folder for file if necessary" "mkdir -p \"${file%/*}\""

# download the update
scp -o StrictHostKeyChecking=no -P "$update_port" "root@$update_address:$file" "$file" > /dev/null 2>/dev/null                          
assert $LINENO "download missing file" "scp -o StrictHostKeyChecking=no -P \"$update_port\" \"root@$update_address:$file\" \"$file\""

history "downloaded missing file \"$file\""

}



########################################
##  SEND EMAIL
########################################

##  send an email via gmail's sendmail Expect script

send_email () {

local subject body
subject=$1
body=$2


# download any email support files if they are not present (won't udpdate them automatically though)

download_if_missing "/usr/local/bin/gmail_sendmail"
download_if_missing "/usr/local/bin/gmail_sendmail.exp"
download_if_missing "/var/root/.gmailpassword"
download_if_missing "/var/root/.gmailrecipient"
download_if_missing "/var/root/.gmailuser"


# set and export email parameters

MAIL_USER=$(cat /var/root/.gmailuser)
MAIL_PASS=$(cat /var/root//.gmailpassword)
  MAIL_TO=$(cat /var/root/.gmailrecipient)
export  MAIL_USER
export  MAIL_PASS
export  MAIL_TO
export  MAIL_SUB="$subject"
export  MAIL_NOISY=0


# send the email

echo "$body" | /usr/local/bin/gmail_sendmail
assert $LINENO "call gmail_sendmail to send mail" "echo \"\$body\" | /usr/local/bin/gmail_sendmail"
log "sent email"

}



########################################
##  BACKUP SUCCESSFUL
########################################

##  backup completed with no critical errors
##  if launched by launchctl, send an email indicating backup success (if success emails are enabled)

backup_successful () {

if [[ "$switch_daemon" && "$email_successes" ]] ; then
  debug "backup was successful, sending email"
  send_email "backup job $job_name was successful" "there were no fatal prpblems"
fi

h_finished=$(date "+%Y/%m/%d %H:%M:%S")
if [ "$skb" -lt 10000 ] ; then
  # less than 10 MB synced, report in KB
  central_history "0" "backup successful: $(commas "$files") files ($(commas "$smb") KB) synchronized in $(elapsed "$t3")"
elif [ "$smb" -lt 10000 ] ; then
  # less than 10 GB synced, report in MB
  central_history "0" "backup successful: $(commas "$files") files ($(commas "$smb") MB) synchronized in $(elapsed "$t3")"
else
  # more than 10 GB synced, report in GB
  central_history "0" "backup successful: $(commas "$files") files ($(commas "$sgb") GB) synchronized in $(elapsed "$t3")"
fi

}



########################################
##  BACKUP FAILED
########################################

##  critcal error during backup
##  if launched by launchctl, send an email indicating backup failure (if failure emails are enabled)

backup_failed () {

note=$1

if [[ "$switch_daemon" && "$email_failures" ]] ; then
  debug "backup was NOT successful, sending email with note \$note\""
  send_email "backup job $job_name HAS FAILED" "$note"
fi

h_finished=$(date "+%Y/%m/%d %H:%M:%S")  #  set finished time even for failures - we may be interested in knowing how long it ran before failing
central_history "1" "$note"

}



########################################
## VALIDATE JOB
########################################

##  verify job switches/parameters were defined by the job file we sourced (all parameters/switches must be defined, even if blank)
##  use the NORMALIZE flag to fix a job file that is missing options or is otherwise not in the standard format

validate () {

if [ -z "$1" ] ; then
  abort $LINENO "Undefined job parameter \"$2\""
fi
if [ "${1//[\$\"|]/_}" != "$1" ] ; then
  abort $LINENO "job parameter \"$2\" contains illegal character (pipe/dollar/quote)"
fi

}

validate_job () {

# ${variable+default} will return default if variable is SET, otherwise blank
if [ -z "$jobfile" ] ; then
  abort $LINENO "job file was not specified"
fi

validate "${job_name+x}"         "job_name"
validate "${source_folder+x}"    "source_folder"
validate "${backup_folder+x}"    "backup_folder"
validate "${switch_delete+x}"    "switch_delete"
validate "${switch_schedule+x}"  "switch_schedule"
validate "${switch_zip+x}"       "switch_zip"
validate "${max_del+x}"          "max_del"
validate "${run_hour+x}"         "run_hour"
validate "${run_min+x}"          "run_min"
validate "${run_day+x}"          "run_day"
validate "${run_dow+x}"          "run_dow"

debug "job is valid"

}



########################################
##  GET FILE VERSION
########################################

##  get version (modification time in totalsec) of a specified file

get_file_version () {

local f v
f=${1##*/}
if [ -r "$1" ] ; then
  v=$(stat -f %m "$1")
  assert $LINENO "get modification time" "stat -f %m \"$1\""
else
  v=0
fi
echo "$f=$v"

}



########################################
##  UNLOCK
########################################

## unlock one object

unlock () {
coammnd setfile > /dev/null 2> /dev/null rc=$?
if [ $? != 0 ] ; then
  debug "SETFILE not found (is developer tools installed?)   files cannot be unlocked"
  return
fi
if [ -e "$1" ] ; then
  setfile -a l "$1"
  assert $LINENO "unlock file" "setfile -a l \"$1\""
fi

}



########################################
##  ADD SW
########################################

# add an element to the fixlinks_switches array

add_sw () {

if [ -z "${fixlinks_switches[0]:-}"  ] ; then
  fixlinks_switches[0]=$1
else
  fixlinks_switches[${#fixlinks_switches[@]}]=$1
fi

}



########################################
##  ADD NORM
########################################

##  add one parameter to a job file

add_norm () {

local key default defined note value
    key="$1"
default="$2"
defined="$3"
   note="$4"

if [ -z "$defined" ] ; then
  debug "key \"$key\" is undefined, setting to default (\"$default\")"
  value="$default"
else
  eval value="\$$key"
  if [[ (-z "$value") && (-n "$default") ]] ; then
    debug "key \"$key\" is defined blank, setting to default (\"$default\")"
    value="$default"
  else
    debug "key \"$key\" is defined (\"$value\")"
  fi
fi

key="                         $key"
key=${key:${#key}-20}
value="${value}        "
value=${value:0:8}
echo "$key=$value  # $note" >> "$jobfile"

}



########################################
##  INSTALL CHECK
########################################

##  verify one executable object is present and in PATH

install_check () {

command -v "$1" > /dev/null
assert $LINENO "verify \"$1\" is installed" "command -v \"$1\""

}



########################################
##  SQL
########################################

# perform an SQL command with logging and some limited error checking and retries
# any results are returned in $result

sql () {
local line command tryto permitted sql_db

line=0
permitted=
# sql $LINENO "DATABASE" "TRY" "COMMAND"
# sql $LINENO "DATABASE" "TRY" "COMMAND" 19  # allowable error code is optional, -1 to return any error
     line=$(($1))
   sql_db=$2
    tryto=$3
  command=$4
if [ ${#@} == 5 ] ; then
  permitted=$(($5))
fi

result=
if [[ (-z "$line") || ($line == 0) || (${#@} -lt 4) || (${#@} -gt 5) || ((${#@} == 5) && ($permitted == -2)) ]] ; then
  abort $LINENO "SQL: parameter error: \"$1\" / \"$2\" / \"$3\" / \"$4\" / \"$5\""
fi

if [ "$permitted" == "-1" ] ; then
  returnerrors=1
elif [ -n "$permitted" ] ; then
  tryto="$tryto (allow RC=$permitted)"
fi

debug "SQL: trying to $tryto"

log_sql_debug "LINE $line: sqlite3 \"$sql_db\" \"$command\""
log_sql "$tryto" "sqlite3 \"$sql_db\" \"$command\""

debug "sqlite3 \"$sql_db\" \"$command\""
result=$(sqlite3 "$sql_db" "$command") ; rc=$?
log_sql_debug "RC=$rc"
t=0
# RC=5  database is locked by another database process
# RC=8  insufficient rights (check database owner and permissions)
# RC=19 attempt to insert a row or update a cell using a duplicate value in a unique column
# RC=1  database is not found OR ANY OTHER ERROR OCCURS (like table not found)
# since rc=1 could be DB not found or "anything else", test for db.  if found, we will treat code 1 as "try again"
if ! [ -r "$sql_db" ] ; then
  abort $LINENO "SQL: DATABASE NOT ACCESSIBLE: \"$sql_db\""
fi
if [[ ("$rc" == 0) || ("$rc" == "$permitted") ]] ; then
  # succeeded on first try
  log_sql_result
  return 0
elif [ $returnerrors ] ; then
  # RC != 0 but caller wants to deal with any errors, so return error to caller instead of retrying command
  log_sql_result
  return $rc
fi
log_sql "SQL lock warning (RC=$rc), will retry"
for ((t=1;t<=max_db_attempts;t++)) ; do
  # database is probably locked by another check-in
  sleep_millis 1000
  log_sql "retrying: sqlite3 \"$sql_db\" \"$command\""
  result=$(sqlite3 "$sql_db" "$command") ; rc=$?
  if [[ ("$rc" == 0) || ("$rc" == "$permitted") ]] ; then
    log_sql "query succeeded with RC=$rc after $t retries"
    log_sql_result
    return 0
  fi
  # no need to test for return errors
  log_sql "failed again, RC=$rc"
done
log_sql "SQL: FAILURE AFTER $max_db_attempts ATTEMPTS"
abort $LINENO "SQL: (from line $line) TIMEOUT: sqlite3 \"$sql_db\" \"$command\" ($tryto)"

}



########################################
##  CREATE HISTORY DB
########################################

##  create history database if not found

create_history_db () {

if [ -e "$history_db" ] ; then
  debug "histroy database found at \"$history_db\""
else
  sql $LINENO "$history_db" "create history database" "CREATE TABLE History (host CHAR(30), job CHAR(20), started CHAR(19), finished CHAR(19), rc CHAR(3), note CHAR(119));"
  history "history database created"
fi

}



########################################
##  CREATE SCHEDULE DB
########################################

##  create schedule database if not found

create_schedule_db () {

if [ -e "$schedule_db" ] ; then
  debug "schedule database found"
else
  sql "$schedule_db" "create schedule database" "CREATE TABLE Schedules (job CHAR(20), host CHAR(30), modified_ts CHAR(10), modified_stamp CHAR(19), run_min CHAR(2), run_hour CHAR(2), run_day CHAR(1), run_dow CHAR(1), scheduled CHAR(1));"
  history "schedule database created"
fi

}



########################################
##  CREATE EXAMPLE JOBS
########################################

##  create example job files (always)

create_example_jobs () {

# extract example job from the end of our script file
# it's at the end to prevent embedded linefeeds from screwing up line number reporting

local e="EXAMPLE"

cat "$0" | grep -B1 -A100 "^##  $e JOB" > /var/root/backup/example_boot.job  # broke up to prevent it triggering itself

debug "created example job file at /var/root/backup/example_boot.job"

}



########################################
##  BUILD LOCAL SCHEDULE
########################################

# build local schedule record

build_local_schedule () {

local_schedule="$job_name|$host|$modified_ts|$modified_stamp|$run_min|$run_hour|$run_day|$run_dow|$scheduled"
debug "local_schedule=\"$local_schedule\""

}



########################################
##  APPLY DOWNLOADED SCHEDULE
########################################

# apply downloaded schedule.  we will assume there WERE changes and we need to import the schedule vars, remove the daemon, rebuild the job file, rebuld the plist, and reload the daemon

apply_downloaded_schedule () {
calling APPLY_DOWNLOADED_SCHEDULE


# apply downloaded schedule

  run_min=$r_run_min
 run_hour=$r_run_hour
  run_day=$r_run_day
  run_dow=$r_run_dow
scheduled=$r_schedule

debug "  run_min=\"$run_min\""
debug " run_hour=\"$run_hour\""
debug "  run_day=\"$run_day\""
debug "  run_dow=\"$run_dow\""
debug "scheduled=\"$scheduled\""


# create/update job file

do_save_jobfile
# correct the timestamp on the new job file to match the server timestamp, to prevent us from uploading next run
stamp2=$(date -j -f %s "$r_modified_ts" "+%Y%m%d%H%M.%S")
assert $LINENO "convert totalsec to touch format" "date -j -f %s \"$r_modified_ts\" \"+%Y%m%d%H%M.%S\""
touch -t "$stamp2" "$jobfile"
assert $LINENO "update file timestamp following update" "touch -t \"$stamp2\" \"$jobfile\""
modified_ts="$r_modified_ts"  # so test as script is exiting doesn't spaz out


# if the daemon ran us, make sure we don't try to back up if it was JUST uncheduled

if [[ $switch_daemon && $switch_live ]] ; then
  switch_live=
  debug "disabling backup switch since newly downloaded schedule is not scheduled"
else
  debug "not touching backup switch"
fi


# construct local schedule string
build_local_schedule



# remove daemons / delete plists

remove_daemons


# rebuld the plist and start the daemon

install_daemon "s"  # always install the scheduled daemon (to either run the backup or just watch for updates)
if [ ! "$scheduled" ] ; then
  install_daemon "m"  # only install the manual daemon if the job isn't scheduled
fi


returning

}



########################################
##  UPLOAD SCHEDULE
########################################

##  upload local schedule to server

upload_schedule () {
calling UPLOAD_SCHEDULE

# job file needs to be loaded
validate_job

# upload it
ssh -p "$update_port" -o StrictHostKeyChecking=no "root@$update_address" "$install_folder/$appname -setschedule \"$local_schedule\""
assert $LINENO "send schedule to update server" "ssh -p \"$update_port\" -o StrictHostKeyChecking=no \"root@$update_address\" \"$install_folder/$appname -setschedule \\\"$local_schedule\\\""
history "uploaded job schedule to update server: \"$local_schedule\""

# make the remote schedule match the local schedule (don't need to bother with the other r_ vars)
r_modified_ts=$modified_ts

returning
}



########################################
##  DOWNLOAD SCHEDULE
########################################

##  download schedule from server to remote schedule

download_schedule () {
calling DOWNLOAD_SCHEDULE

debug "CMD: ssh -p $update_port -o StrictHostKeyChecking=no root@$update_address \"$install_folder/$appname -getschedule \\\"$job_name\\\"\""
rec=$(ssh -p "$update_port" -o StrictHostKeyChecking=no "root@$update_address" "$install_folder/$appname -getschedule \"$job_name\"") ; rc=$?
if [ $rc != 0 ] ; then
  # if the server can't find the record, it will NOT return an error code.  if you get here, there was an error contacting the server or the server got an error attempting the lookup
  debug "error getting schedule from update server, skipping schedule sync"
  return
fi
debug "rec=\"$rec\""

if [ "$rec" == "NOT FOUND" ] ; then
  debug "job schedule not found on update server"
  r_modified_ts=0
  remote_schedule=""
else
  remote_schedule="$rec"
  # update server found this job in the Schedules table, parse fields from record found in Schedules table
             r_job=${rec%%|*} ; rec=${rec#*|}
            r_host=${rec%%|*} ; rec=${rec#*|}
     r_modified_ts=${rec%%|*} ; rec=${rec#*|}
  r_modified_stamp=${rec%%|*} ; rec=${rec#*|}
         r_run_min=${rec%%|*} ; rec=${rec#*|}
        r_run_hour=${rec%%|*} ; rec=${rec#*|}
         r_run_day=${rec%%|*} ; rec=${rec#*|}
         r_run_dow=${rec%%|*} ; rec=${rec#*|}
        r_schedule=${rec%%|*} ; rec=${rec#*|}
  debug2 "           r_job=\"$r_job\""
  debug2 "          r_host=\"$r_host\""
  debug2 "   r_modified_ts=\"$r_modified_ts\""
  debug2 "r_modified_stamp=\"$r_modified_stamp\""
  debug2 "       r_run_min=\"$r_run_min\""
  debug2 "      r_run_hour=\"$r_run_hour\""
  debug2 "       r_run_day=\"$r_run_day\""
  debug2 "       r_run_dow=\"$r_run_dow\""
  debug2 "      r_schedule=\"$r_schedule\""
fi

debug "remote_schedule=\"$remote_schedule"

returning
}



########################################
##  GET LOCAL TS
########################################

# get local jobfile timestamps

get_local_ts () {

modified_ts=$(stat -f "%m" "$jobfile")
assert $LINENO "get jobfile mod ts" "stat -f \"%m\" \"$jobfile\""
debug "modified_ts=\"$modified_ts\""  # set by do_load_schedule

modified_stamp=$(date -j -f %s "$modified_ts" "+%Y/%m/%d %H:%M:%S")
assert $LINENO "convert ts to stamp" "date -j -f %s \"$modified_ts\" \"+%Y/%m/%d %H:%M:%S\""
debug "modified_stamp=\"$modified_stamp\""

}



########################################
##  REMOVE DAEMON
########################################

# remove the job daemon and delete its plist

# specify "s" or "m" for first parameter to specify the schedule or manual daemon

remove_daemon () {

calling REMOVE_DAEMON

dmode=${1:-}
debug "dmode=\"$dmode\""
if [ "$dmode" == "s" ] ; then
  j2="$s_daemon"
  p2="$s_plist"
elif [ "$dmode" == "m" ] ; then
  j2="$m_daemon"
  p2="$m_plist"
else
  abort $LINENO "install_daemon called with invalid mode \"$dmode\""
fi
debug "j2=\"$j2\""
debug "p2=\"$p2\""


# remove daemon from launchctl

launchctl list "$j2" > /dev/null 2> /dev/null ; rc=$?
if [ $rc != 0 ] ; then
  debug "daemon \"$j2\" was not loaded"
else
  launchctl remove "$j2" ; rc=$?
  if [ $rc == 0 ] ; then
    log_job "unloaded daemon \"$j2\""
  elif [ $rc == 3 ] ; then
    # earlier os x doesn't do this
    debug "daemon \"$j2\" was not loaded"
  else
    (exit $rc)  # presets rc for assert which WILL abort us now
    assert $LINENO "unload existing daemon" "launchctl remove $j2"
  fi
fi


# remove daemon startup plist

if [ -f "$p2" ] ; then
  rm "$p2"
  assert $LINENO "remove daemon" "rm \"$p2\""
  log_job "removed launch daemon from \"$p2\""
else
  debug "no launch daemon found at \"$p2\" to remove"
fi


debug "backup daemon(s) for ${job_name} are removed"

returning

}



########################################
##  REMOVE DAEMONS
########################################

# remove schedule and manual daemons if present

remove_daemons () {

calling REMOVE_DAEMONS

remove_daemon "s"
remove_daemon "m"

returning

}



########################################
##  INSTALL DAEMON
########################################

# install startup plist and load into launchctl

# specify "s" or "m" for first parameter to specify the schedule or manual daemon

install_daemon () {

calling INSTALL_DAEMON

dmode=${1:-}
debug "dmode=\"$dmode\""
if [ "$dmode" == "s" ] ; then
  j2="$s_daemon"
  p2="$s_plist"
elif [ "$dmode" == "m" ] ; then
  j2="$m_daemon"
  p2="$m_plist"
else
  abort $LINENO "install_daemon called with invalid mode \"$dmode\""
fi
debug "j2=\"$j2\""
debug "p2=\"$p2\""


#  define an automatic starting schedule if scheduled is set

# hour and minute will always be defined if scheduled
s="hour $run_hour | minute $run_min"

# set day of week if defined (defaults to every day)
if [ -n "$run_dow" ] ; then
  s="$s | day of week $run_dow"
  rundow="${TAB}${TAB}<key>WeekDay</key>${LF}${TAB}${TAB}<integer>${run_dow}</integer>${LF}"
else
  rundow=""
fi
# set day of month if defined (defaults to every day)
if [ -n "$run_day" ] ; then
  s="$s | day of month $run_day"
  runday="${TAB}${TAB}<key>Day</key>${LF}${TAB}${TAB}<integer>${run_day}</integer>${LF}"
else
  runday=""
fi
calendar=
if [ "$dmode" == "m" ] ; then
  cal_mode=
  cal_mode="${cal_mode}${TAB}${TAB}<string>-live</string>${LF}"
  cal_mode="${cal_mode}${TAB}${TAB}<string>-backup</string>${LF}"
elif [ "$scheduled" ] ; then
  calendar="${calendar}${TAB}<key>StartCalendarInterval</key>${LF}"
   calendar="${calendar}${TAB}<dict>${LF}"
  calendar="${calendar}${TAB}${TAB}<key>Hour</key>${LF}"
  calendar="${calendar}${TAB}${TAB}<integer>${run_hour}</integer>${LF}"
  calendar="${calendar}${TAB}${TAB}<key>Minute</key>${LF}"
  calendar="${calendar}${TAB}${TAB}<integer>${run_min}</integer>${LF}"
  calendar="${calendar}${runday}"
  calendar="${calendar}${rundow}"
  calendar="${calendar}${TAB}</dict>${LF}"
  cal_mode=
  cal_mode="${cal_mode}${TAB}${TAB}<string>-live</string>${LF}"
  cal_mode="${cal_mode}${TAB}${TAB}<string>-backup</string>${LF}"
else
  # updates to script and schedule will be checked periodically (once an hour) at a second chosen based on a hash of the backup job's name
  #sn=$(/usr/sbin/system_profiler SPHardwareDataType | grep "Serial Number (system)")
  #sn=${sn##* }
  #if [ -n "${sn:-}" ] ; then
  #  seed="$sn"
  #  debug "sn available for seed: $seed"
  #else
  #  seed="${RANDOM}${RANDOM}"
  #  debug "sn unavailable, using random seed: $seed"
  #fi
  #sec=$(($(echo "ibase=16 ; $(echo "$seed" | openssl md5 | tr a-f A-F | cut -c 1-5)" | bc)*3600/1048576))
  # change of plan.  seconds seed is now being based on backup job name.  this is necessary because one machine may have several backup jobs loaded, and we can't have them all trying to update at the same time
  sec=$(($(echo "ibase=16;$(echo "$job_name" | openssl md5 | tr a-f A-F | cut -c 1-5)" | bc)%86400))
  debug "sec = \"$sec\""
  ((u_run_min=sec%3600/60))
  ((u_run_sec=sec%60))
  calendar="${calendar}${TAB}<key>StartCalendarInterval</key>${LF}"
  calendar="${calendar}${TAB}<dict>${LF}"
  calendar="${calendar}${TAB}${TAB}<key>Minute</key>${LF}"
  calendar="${calendar}${TAB}${TAB}<integer>${u_run_min}</integer>${LF}"
  calendar="${calendar}${TAB}${TAB}<key>Second</key>${LF}"
  calendar="${calendar}${TAB}${TAB}<integer>${u_run_sec}</integer>${LF}"
  calendar="${calendar}${TAB}</dict>${LF}"
  cal_mode=  # not backing up, just updating schedule (which is caused by loading the job file)
fi

# construct the daemon plist, with parameters built-in

daemon=
daemon="${daemon}<?xml version=\"1.0\" encoding=\"UTF-8\"?>${LF}"
daemon="${daemon}<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">${LF}"
daemon="${daemon}<plist version=\"1.0\">${LF}"
daemon="${daemon}<dict>${LF}"
daemon="${daemon}${TAB}<key>Label</key>${LF}"
daemon="${daemon}${TAB}<string>$j2</string>${LF}"
daemon="${daemon}${TAB}<key>StandardOutPath</key>${LF}"
daemon="${daemon}${TAB}<string>${log_folder}/${job_name}_launchctl_stdout</string>${LF}"
daemon="${daemon}${TAB}<key>StandardErrorPath</key>${LF}"
daemon="${daemon}${TAB}<string>${log_folder}/${job_name}_launchctl_stderr</string>${LF}"
daemon="${daemon}${TAB}<key>Program</key>${LF}"
daemon="${daemon}${TAB}<string>${install_folder}/$appname</string>${LF}"
daemon="${daemon}${TAB}<key>ProgramArguments</key>${LF}"
daemon="${daemon}${TAB}<array>${LF}"
daemon="${daemon}${TAB}${TAB}<string>${install_folder}/$appname</string>${LF}"
daemon="${daemon}${TAB}${TAB}<string>-daemon</string>${LF}"  # DAEMON goes before -and- after UPDATE so errors during -and- after update both get emailed
daemon="${daemon}${TAB}${TAB}<string>-update</string>${LF}"  # UPDATE must occur before all other parameters
daemon="${daemon}${TAB}${TAB}<string>-daemon</string>${LF}"
daemon="${daemon}${TAB}${TAB}<string>-jobfile</string>${LF}"  # JOBFILE must occur before BACKUP or SYNCSCHEDULE
daemon="${daemon}${TAB}${TAB}<string>$jobfile</string>${LF}"
daemon="${daemon}${cal_mode}"  # must occur after JOBFILE
daemon="${daemon}${TAB}</array>${LF}"
daemon="${daemon}${TAB}<key>RunAtLoad</key>${LF}"
daemon="${daemon}${TAB}<false/>${LF}"
daemon="${daemon}${calendar}"
daemon="${daemon}</dict>${LF}"
daemon="${daemon}</plist>"


# install daemon to load at startup

echo "$daemon" > "$p2"
assert $LINENO "install new launch daemon" "echo \"$daemon\" > \"$p2\""
log_job "installed new launch daemon at \"$p2\""

# load (but not start) daemon now also (installing it does not load or start it)


debug "loading daemon plist"

# thanks to launchctl's mental retardation, it returns with exit code 0 EVEN IF THERE ARE ERRORS
#launchctl load "$p2"
#assert $LINENO "load daemon" "launchctl load \"$p2\""

rc=$(launchctl load "$p2" 2>&1)  # this is a hack.  launchctl won't return anything if the load works, but will return something if there's an error.  so, "no news is good news"
if [ -z "$rc" ] ; then
  rc=0
else
  rc=1
fi
assert $LINENO "load daemon" "launchctl load \"$p2\""
log_job "loaded \"$p2\" into launchctl (not started)"


returning

}




########################################################################################################################################################################################################
########################################################################################################################################################################################################
###
###  SERVER SUBROUTINES
###
########################################################################################################################################################################################################
########################################################################################################################################################################################################

##  these are functions that are switched by a remote client calling the backup server


########################################
##  DO INIT
########################################

##  initialize a new server


server_init () {
calling SERVER_INIT

local k k2 a

# create databases if not found
create_history_db
create_schedule_db

# create dsa key if not found
if [ -e "/var/root/.ssh/id_rsa" ] ; then
  debug "found ssh private key"
else
  echo "You will need to generate an RSA key now.  Press RETURN after each prompt:"
  echo
  ssh-keygen -t rsa
  assert $LINENO "creaate server key pair" "ssh-keygen -t rsa"
  if ! [ -e "/var/root/.ssh/id_rsa" ] ; then
    abort $LINENO "key gen unsuccessfun, re-run script to try again"
  fi
  log "dsa key generated"
  echo "dsa key generated"
fi

# make sure key is allowed
k=$(cat /var/root/.ssh/id_rsa.pub)
assert $LINENO "load public key" "cat /var/root/.ssh/id_rsa.pub"
k2=${k#* }
k2=${k2%% *}

a="/var/root/.ssh/authorized_keys"

if ! [ -e "$a" ] ; then
  echo "$k" > "$a"
  chmod 600 "$a"
  log "created authorized keys file"
elif ! (cat "$a" | grep -q "$k2 ") ; then
  echo "$k" >> "$a"
  chown root "$a"
  chmod 600 "$a"
  log "added server's own key to athorized keys file"
else
  debug "server is in its own authorized keys file"
fi

# all set
log "server initialized"
echo "server initialized"

returning 
}



########################################
##  SERVER VERSION
########################################

##  display versions for script files
##  this is primarily used by the script to check versions on the backup server

server_version () {
calling SERVER_VERSION

log "display versions"

get_file_version "$install_folder/$appname"
get_file_version "/usr/local/bin/fixlinks"

if [[ $email_successes || $email_failures ]] ; then
  get_file_version "/usr/local/bin/gmail_sendmail"
  get_file_version "/usr/local/bin/gmail_sendmail.exp"
  get_file_version "/var/root/.gmailpassword"
  get_file_version "/var/root/.gmailrecipient"
  get_file_version "/var/root/.gmailuser"
fi

returning 
}


########################################
##  SERVER DUMP HISTORY
########################################

##  display the history database on the backup server, in table format

server_dump_history () {
calling SERVER_DUMP_HISTORY

echo
if [ ${#@} == 0 ] ; then
  # no optional pattern specified
  debug "sqlite3 -header -column -cmd \".width 30 20 19 19 3 119\" \"$history_db\" \"SELECT * FROM History\""
  sqlite3 -header -column -cmd ".width 30 20 19 19 3 119" "$history_db" "SELECT * FROM History"
else
  # filter by specified pattern
  k=$1
# lets confuse some readers with regular expressions and shell substitutions
#  k=$(echo "$k" | sed 's/\\/\\\\/g')
#  k=$(echo "$k" | sed 's/\^/\\\^/g')
#  k=$(echo "$k" | sed 's/\$/\\\$/g')
  k="${k//\\/\\\\}"
  k="${k/\^/\\^/}"
  k="${k/\$/\\\$/}"
  debug "sqlite3 -header -column -cmd \".width 30 20 19 19 3 119\" \"$history_db\" \"SELECT * FROM History\" | grep -- \"^host  \\|^-----\\|$k\""
  sqlite3 -header -column -cmd ".width 30 20 19 19 3 119" "$history_db" "SELECT * FROM History" | grep -- "^host  \|^-----\|$k"
fi
echo

returning 
}



########################################
##  SERVER DUMP JOB HISTORY
########################################

##  display the history database on the backup server, in table format, sorted by job

server_dump_jobhistory () {
calling SERVER_DUMP_JOBHISTORY

if [ -z "${1:-}" ] ; then
  # get a list of jobs,alphabetized
  jobs=$(sqlite3 history.db "SELECT DISTINCT job FROM History ORDER BY job")
  for j in $jobs ; do
    sqlite3 -header -column -cmd ".width 30 20 19 19 3 119" "$history_db" "SELECT * FROM History WHERE job IS '$j' ORDER BY started"
    echo
  done
else
  sqlite3 -header -column -cmd ".width 30 20 19 19 3 119" "$history_db" "SELECT * FROM History WHERE job IS '$1' ORDER BY started"
fi

returning 
}



########################################
##  SERVER JOB STATUS
########################################

##  display the last successful backup for each job in the history database on the backup server, in table format

server_jobstatus () {
calling SERVER_JOBSTATUS

local i

# make sure temp file is ok

echo > "$tempfile"
assert $LINENO "verify tempfile" "echo > \"$tempfile\""


# generate sorted list of jobs in history

sqlite3 "$history_db" "SELECT distinct job FROM History order by job" > "$tempfile"
assert $LINENO "generate sorted list of jobs" "sqlite3 \"$history_db\" \"SELECT distinct job FROM History order by job\" > \"$tempfile\""


# load list

jobs=0
while read -r j[jobs] ; do
  ((jobs++))
done < "$tempfile"

rm "$tempfile"
assert $LINENO "remove tempfile" "rm \"$tempfile\""

if [ ${#@} == 0 ] ; then

  # dump sorted table of one entry for each job in history table
  echo "Displaying most recently attempted backup for all defined jobs, sorted by date:"
  echo

  # display header
  sqlite3 -header -column -cmd ".width 21 21 30 20 3 115" "$history_db" "SELECT started,finished,host,job,rc,note FROM History" | head -n2
  assert $LINENO "display header" "sqlite3 -header -column -cmd \".width 21 21 30 20 3 115\" \"$history_db\" \"SELECT started,finished,host,job,rc,note FROM History\" | head -n2\""

  (for ((i=0;i<jobs;i++)) ; do
#    sqlite3 -column -cmd ".width 21 21 30 20 3 115" "$history_db" "SELECT started,finished,host,job,rc,note FROM History WHERE job IS '${j[i]}' AND rc IS 0 ORDER BY started DESC LIMIT 1"
    sqlite3 -column -cmd ".width 21 21 30 20 3 115" "$history_db" "SELECT started,finished,host,job,rc,note FROM History WHERE job IS '${j[i]}' ORDER BY started DESC LIMIT 1"
    assert $LINENO "display one job entry" "sqlite3 -column -cmd \".width 21 21 30 20 3 115\" \"$history_db\" \"SELECT started,finished,host,job,rc,note FROM History WHERE job IS '${j[i]}' ORDER BY started DESC LIMIT 1\""
  done) | sort

else

  # search pattern specified, dump history table filtered by provided pattern
  echo
  echo "Displaying entries in history that match search pattern \"$1\":"
  echo

  k=$1
  # lets confuse some readers with regular expressions and shell substitutions to armor agaist special characters in the pattern
  k="${k//\\/\\\\}"
  k="${k/\^/\\^/}"
  k="${k/\$/\\\$/}"
  debug "sqlite3 -header -column -cmd \".width 30 20 19 19 3 119\" \"$history_db\" \"SELECT * FROM History\" | grep -- \"^host  \|^-----\|$k\""
  sqlite3 -header -column -cmd ".width 30 20 19 19 3 119" "$history_db" "SELECT * FROM History" | grep -- "^host  \|^-----\|$k"
  assert $LINENO "display filtered list" "sqlite3 -header -column -cmd \".width 30 20 19 19 3 119\" \"$history_db\" \"SELECT * FROM History\" | grep -- \"^host  \|^-----\|$k\""
fi

echo

returning
}



########################################
##  SERVER HISTORY
########################################
    
##  record job history in the history database
##  this is called by backup jobs when they start or finish (successfully or unsuccessfully) a job
##  since there are very low chances of concurrent database access this will not use complex robust database calls

server_history () {
calling SERVER_HISTORY

# parse parameters

debug_central_history "server_history called with ${#@} parameters: $(format_array "${@}")"

debug "parameter count = ${#@}"

    h_host=$1
     h_job=$2
 h_started=$3
h_finished=$4
      h_rc=$5
    h_note=$6

# create database if it doesn't exist

sql $LINENO "$history_db" "count records in history table" "SELECT COUNT (*) FROM History;" -1
if [ $rc == 0 ] ; then
  debug "found $result records in History table"
  debug_central_history "found $result records in History table"
else
  debug "History database not found"
  debug_central_history "History database not found"
  create_history_db
fi

# try to locate matching job + start time

sql $LINENO "$history_db" "search for existing entry in history" "SELECT ROWID,* FROM History WHERE job='$h_job' AND started='$h_started';"
rec=$result
if [ -z  "$rec" ] ; then
  debug "history search for job \"$h_job\" + started \"$h_started\" was not found"
  debug_central_history "history search for job \"$h_job\" + started \"$h_started\" was not found"
else
  debug_central_history "found $rec records in central history for job \"$h_job\" + started \"$h_started\""
  # parse fields from record found in history
  r_rowid=${rec%%|*}    ; rec=${rec#*|}
  r_host=${rec%%|*}     ; rec=${rec#*|}
  r_job=${rec%%|*}      ; rec=${rec#*|}
  r_started=${rec%%|*}  ; rec=${rec#*|}
  r_finished=${rec%%|*} ; rec=${rec#*|}
  r_rc=${rec%%|*}       ; rec=${rec#*|}
  r_note=${rec%%|*}     ; rec=${rec#*|}
  # keep any fields fields unchanged that have blank new values
  if [ -z "$h_host" ] ; then
    h_host=$r_host
  fi
  if [ -z "$h_job" ] ; then
    h_job=$r_job
  fi
  if [ -z "$h_started" ] ; then
    h_started=$r_started
  fi
  if [ -z "$h_finished" ] ; then
    h_finished=$r_finished
  fi
  if [ -z "$h_rc" ] ; then
    h_rc=$r_rc
  fi
  if [ -z "$h_note" ] ; then
    h_note=$r_note
    # it may be annoying if NOTE is unchanged, (it should never be specified as blank) but lets be consistent
  fi
  debug "history search for job \"$h_job\" + started \"$h_started\" found at row $r_rowid"
  debug_central_history "history search for job \"$h_job\" + started \"$h_started\" found at row $r_rowid"
fi


# record information in database

if [ -z "$rec" ] ; then
  # create new entry
  debug_central_history "CMD: sql $LINENO \"$history_db\" \"create new entry in history\" \"INSERT INTO History (host,job,started,finished,rc,note) VALUES ('$h_host','$h_job','$h_started','$h_finished','$h_rc','$h_note');\""
  sql $LINENO "$history_db" "create new entry in history" "INSERT INTO History (host,job,started,finished,rc,note) VALUES ('$h_host','$h_job','$h_started','$h_finished','$h_rc','$h_note');"
  log "new history created for job \"$h_job\" + started \"$h_started\""
else
  # update existing entry
  debug_central_history "CMD: sql $LINENO \"$history_db\" \"update entry in history\" \"UPDATE History SET finished='$h_finished',rc='$h_rc',note='$h_note' WHERE ROWID=$r_rowid;\""
  sql $LINENO "$history_db" "update entry in history" "UPDATE History SET finished='$h_finished',rc='$h_rc',note='$h_note' WHERE ROWID=$r_rowid;"
  log "history updated for job \"$h_job\" + started \"$h_started\""
fi

debug_central_history "call to sql returned"

returning 
}



########################################
##  SERVER GET SCHEDULE
########################################

##  get the schedule for specified job

server_getschedule () {
calling SERVER_GETSCHEDULE

# parse parameters

debug "parameter count = ${#@}"

if [ ${#@} == 0 ] ; then
  s_job=""
else
  s_job=$1
fi


# create database if it doesn't exist

sql $LINENO "$schedule_db" "count records in schedules table" "SELECT COUNT (*) FROM Schedules;" -1
if [ $rc == 0 ] ; then
  debug "found $result records in Schedules table"
else
  debug "Schedule database not found"
  create_schedule_db
fi


# if no job specified, dump entire job table

if [ -z "$s_job" ] ; then
  debug "no job specified, dumping schedules table"
  debug "sqlite3 -header -column -cmd \".width 20 30 11 19 7 8 7 7\" \"$schedule_db\" \"SELECT * FROM Schedules\""

  echo "Displaying Schedules table, sorted, sorted by job:"
  echo
  sqlite3 -header -column -cmd ".width 20 30 11 19 7 8 7 7" "$schedule_db" "SELECT * FROM Schedules" | head -n2
  sqlite3 -header -column -cmd ".width 20 30 11 19 7 8 7 7" "$schedule_db" "SELECT * FROM Schedules" | grep "/" | sort
  echo
  echo

  echo "Displaying Schedules table, sorted, sorted by hour/minute:"
  echo
  sqlite3 -header -column -cmd ".width 9 7 7 8 7 20 30 11 19" "$schedule_db" "SELECT scheduled,run_dow,run_day,run_hour,run_min,job,host,modified_ts,modified_stamp FROM Schedules" | head -n2
  sqlite3 -header -column -cmd ".width 9 7 7 8 7 20 30 11 19" "$schedule_db" "SELECT scheduled,run_dow,run_day,run_hour,run_min,job,host,modified_ts,modified_stamp FROM Schedules WHERE scheduled IS ''" | grep "/" | sort
  sqlite3 -header -column -cmd ".width 9 7 7 8 7 20 30 11 19" "$schedule_db" "SELECT scheduled,run_dow,run_day,run_hour,run_min,job,host,modified_ts,modified_stamp FROM Schedules" | head -n2 | tail -n1
  sqlite3 -header -column -cmd ".width 9 7 7 8 7 20 30 11 19" "$schedule_db" "SELECT scheduled,run_dow,run_day,run_hour,run_min,job,host,modified_ts,modified_stamp FROM Schedules WHERE scheduled IS NOT ''" | grep "/" | sort
  echo

  returning 
  return
fi


# try to locate matching job

debug "looking for specified job \"$s_job\""
sql $LINENO "$schedule_db" "search for existing entry in Schedules" "SELECT * FROM Schedules WHERE job='$s_job';"  # "workhorse_bdb|Workhorse|1528895679|2018/06/13 08:14:39|45|0||6|1"
if [ -z "$result" ] ; then
  debug "schedule search for job \"$s_job\" was not found"
  echo "NOT FOUND"
  exit 0
fi


# return found record in sql format

echo "$result"

returning 
}



########################################
##  SERVER SET SCHEDULE
########################################

##  set the schedule for specified job
##  assumes caller intends to make changes, does not compare to see if changes are necessary

server_setschedule () {
calling SERVER_SETSCHEDULE

# parse parameters

p=$1
           s_job=${p%%|*} ; p=${p#*|}
          s_host=${p%%|*} ; p=${p#*|}
   s_modified_ts=${p%%|*} ; p=${p#*|}
s_modified_stamp=${p%%|*} ; p=${p#*|}
       s_run_min=${p%%|*} ; p=${p#*|}
      s_run_hour=${p%%|*} ; p=${p#*|}
       s_run_day=${p%%|*} ; p=${p#*|}
       s_run_dow=${p%%|*} ; p=${p#*|}
      s_schedule=${p%%|*} ; p=${p#*|}


# create database if it doesn't exist

create_schedule_db


# try to locate matching job
# modify record if found, otherwise make a new record

debug "looking for specified job \"$s_job\""
sql $LINENO "$schedule_db" "search for existing entry in Schedules" "SELECT ROWID FROM Schedules WHERE job='$s_job';"
if [ -z  "$result" ] ; then
  debug "schedule search for job \"$s_job\" was not found, create new record"
  sql $LINENO "$schedule_db" "create new schedue record" "INSERT INTO Schedules (job,host,modified_ts,modified_stamp,run_min,run_hour,run_day,run_dow,scheduled) VALUES ('$s_job','$s_host','$s_modified_ts','$s_modified_stamp','$s_run_min','$s_run_hour','$s_run_day','$s_run_dow','$s_schedule');"
  history "create new schedule record for job \"$s_job\""
else
  debug "schedule found job \"$s_job\" at record $result, updating fields"
  sql $LINENO "$schedule_db" "update job schedule" "UPDATE Schedules SET host='$s_host',modified_ts='$s_modified_ts',modified_stamp='$s_modified_stamp',run_min='$s_run_min',run_hour='$s_run_hour',run_day='$s_run_day',run_dow='$s_run_dow',scheduled='$s_schedule' WHERE job='$s_job';"
  history "update existing schedule record for job \"$s_job\""
fi

returning
}





########################################################################################################################################################################################################
########################################################################################################################################################################################################
###
###  "DO" SUBROUTINES
###
########################################################################################################################################################################################################
########################################################################################################################################################################################################

##  these are functions that are called directly by the command line switch parser (though some are also called by other DO_ subroutines)

########################################
## DO LOAD JOBFILE
########################################

##  load specified job file to local schedule

do_load_jobfile () {
calling DO_LOAD_JOBFILE

jobfile=$1


# unset parameters before loading (ALL parameters should be defined in job file, will error out later if anything was omitted)

unset source_folder
unset backup_folder
unset switch_delete
unset switch_zip
unset max_del
unset run_hour
unset run_min
unset run_day
unset run_dow


#  source the jobfile

if ! [ -r "$jobfile" ] ; then
  abort $LINENO "unable to read jobfile at \"$jobfile\""
fi
debug "sourcing jobfile at \"$jobfile\""
source "$jobfile"
assert $LINENO "source jobfile" "source \"$jobfile\""


# redefine paths

define_paths
debug "jobfile successfully loaded"


# get local jobfile timestamps

get_local_ts


# figure out of we're actually scheduled or not

if [ -r "$s_plist" ] ; then
  debug "scheduled job plist found at \"$s_plist\""
  grep -q "<string>-backup</string>" "$s_plist"
  if [ $? == 0 ] ; then
    debug "job is scheduled for backup"
    scheduled=1
  else
    debug "job is scheduled for updates only"
    scheduled=
  fi
else
  debug "daemon plist \"$s_plist\" not found, job is not loaded"
  scheduled=
fi
# m_plist is not checked


# build local schedule record

build_local_schedule


# download schedule from server, apply if newer, upload schedule if older

download_schedule
debug " local_schedule=\"$local_schedule\""
debug "r_modified_ts=\"$r_modified_ts\""
debug "  modified_ts=\"$modified_ts\""



# adjust local load / schedule status if necessary
# note that this may cause us to abort a backup that is trying to start



if [ "$switch_install" ] ; then
  # user installs ALWAYS upload schedule if there are differences
  if [ -z "${r_schedule:-}" ] ; then
    # r_schedule is not defined, this schedule doesn't exist on the server
    msg "this schedule doesn't exist on the server"
  elif [[ ("$modified_ts" == "$r_modified_ts") && ("$switch_schedule" == "$r_schedule") ]] ; then
    msg "installing, but there are no schedule changes to upload to remote"
  else
    msg "installing, and there are scheduling changes that will be uploaded as the script exits"
  fi
else
  # not installing
  if [ -z "${r_schedule:-}" ] ; then
    msg "will create new schedule on server"
    upload_schedule
  elif [ "$scheduled" != "$r_schedule" ] ; then
    msg "schedule flag was changed on remote, apply downloaded schedule"
    apply_downloaded_schedule  # this will update modified_ts and local_history
  elif [ "$modified_ts" -gt "$r_modified_ts" ] ; then
    msg "local job file was recently modified, upload schedule changes to remote"
    upload_schedule
  elif [ "$r_modified_ts" -gt "$modified_ts" ] ; then
    msg "remote job file was recently modified, apply downloaded schedule"
    apply_downloaded_schedule
  else
    msg "local and remote schedules are the same"
  fi
fi


returning

}





########################################
##  DO UPDATE
########################################

##  download updates to this script and fixlinks from server

do_update () {
calling DO_UPDATE

#  ping test update server

pingtest "$update_address"
if ! [ $good_ping ] ; then
  abort $LINENO "failed to ping update server at \"$update_address\""
  
fi
# ping was good
log "good ping from update server at \"$update_address\""


#  download versions

versions=$(ssh -p "$update_port" -o StrictHostKeyChecking=no "root@$update_address" "$install_folder/$appname -v")  # "backup.command=1527776038"  (multiline)
#assert $LINENO "get versions from update server" "ssh -p \"$update_port\" -o StrictHostKeyChecking=no \"root@$update_address\" \"$install_folder/$appname -v\""
# this will RC=255 if it fails to ssh to the backup server to get the version number
# we want to get an email if this happens, before we abort
rc=$?
if [ $rc != 0 ] ; then
  send_email "BACKUP JOB '$job_name' CANNOT RUN" "rc=$rc trying to download versions, is update server at '$update_address' down?"
fi
versions=$'\n'"$versions"$'\n'
debug "versions=\"$versions\""


#  update files

updated=
attempt_to_update "$install_folder/$appname"
attempt_to_update "/usr/local/bin/fixlinks"
if [[ $email_successes || $email_failures ]] ; then
  # we also need these support files if we're going to be sending emails
  attempt_to_update "/usr/local/bin/gmail_sendmail"
  attempt_to_update "/usr/local/bin/gmail_sendmail.exp"
  attempt_to_update "/var/root/.gmailuser"
  attempt_to_update "/var/root/.gmailpassword"  # make sure this file is only readable by root (duh)
  attempt_to_update "/var/root/.gmailrecipient"
fi
history "files are up to date"


#  handle updates made

if [ ! "$updated" ] ; then
  # as long as we didn't update ourselves, we can just return to the switch parser, maybe there's more switches to process
  debug "no updates needed, returning to switch processor"
  returning 
  return
fi

# we self-updated - call our new version and exit immediately
if [ ${#@} == 0 ] ; then
  # it seems there are no more parameters, there's no reason to re-call ourselves
  debug "no parameters following udate, will return to switch processor who will exit"
  returning 
  return
fi

# we updated some part of ourselves, possibly even this script.  re-call ourselves with the remaining parameters
if [ "$switch_debug" ] ; then
  log "launching updated program with remaining paramerters using CMD: \"$install_folder/$appname\" -debug $(format_array "$@")"
  debug "----------------------------------------------------------------------------------------------------------------------------------------------------------------"
  "$install_folder/$appname" -debug "$@"
else
  log "launching updated program with remaining paramerters using CMD: \"$install_folder/$appname\" $(format_array "$@")"
  "$install_folder/$appname" "$@"
fi

exit 0  # must exit now to prevent switch-processing caller from continuing


}



########################################
##  DO REMOVE
########################################

##  unload and remove our backup daemon
##  DOES NOT unschedule

do_remove () {
calling DO_REMOVE

# make sure job file was loaded

validate_job


# remove and delete backup daemon

remove_daemons


# trigger scheduling update

scheduled=
build_local_schedule


returning 
}



########################################
##  DO INSTALL
########################################

##  install and load our launch daemon
##  switch_schedule and switch_do_not_unlock will affect the parameters in the job plist
##  if switch_schedule is not set, it will be set if job is already installed and StartCalendarInterval is defined in the existing plist (ie it's already scheduled)


do_install () {
calling DO_INSTALL


#  jobfile is required for installation

validate_job

# set switch_schedule if it's set in an existing job file (may already have been set by user)

if [ -r "$jobfile" ] ; then
  debug "job was already installed"

  if [ "$switch_schedule" ] ; then
    debug "job schedule switched, will schedule installation"
  else
    debug "job was not switched by user, will not schedule installation"
  fi
elif [ "$switch_schedule" ] ; then
  debug "schedule was switched by user, will schedule installation"
else
  debug "schedule not switched by user, will not schedule installation"
fi


# remove daemons / delete plists

remove_daemons


# set schedule flag (do before building local schedul)

if [ "$switch_schedule" ] ; then
  debug "setting scheduled flag"
  scheduled=1
else
  debug "clearing scheduled flag"
  scheduled=
fi


# get local jobfile timestamps and rebuild local schedule record in case the job file was changed
get_local_ts
build_local_schedule


# create the job daemon plist and start the daemon (do after building local schedule)

if [ "$switch_schedule" ] ; then
  install_daemon "s"
else
  install_daemon "s"
  install_daemon "m"
fi


returning 
}



########################################
##  DO SAVE JOBFILE
########################################
                                                                  
##  normalize the backup job file to a standard format
##  expects jobfile to already be loaded (uses parameters in memory)
##  state of scheduling is NOT saved in the job file

do_save_jobfile () {
calling DO_SAVE_JOBFILE

# make sure job file was loaded
# do not validate it, it may not BE valid, we just need it to be LOADED

local i

if [ -z "$jobfile" ] ; then
  abort $LINENO "must specify job file to normalize"
fi


# create new plist

echo > "$jobfile"
assert $LINENO "create normalized job file" "echo > \"$jobfile\""
echo "# name of job (used for naming log files and also in messages sent to WALL)" >> "$jobfile"
echo "job_name=\"$job_name\"" >> "$jobfile"
echo >> "$jobfile"

echo "# specify folder to back up from, \"/\" to back up entire boot drive">> "$jobfile"
echo "source_folder=\"$source_folder\"" >> "$jobfile"
echo >> "$jobfile"

echo "# first available backup folder will be used. format for network folder backup is \"root:port@address:/path/\"" >> "$jobfile"
for ((i=0;i<${#backup_folder[@]};i++)) ; do
  echo "backup_folder[$i]=\"${backup_folder[i]}\"" >> "$jobfile"
done
echo >> "$jobfile"


# add normalized values, using defaults if not defined by loaded job file

add_norm "switch_do_not_unlock" ""  "${switch_do_not_unlock+X}" "1 to disable unlocking of special files when backing up bootable drives"
add_norm "switch_delete"        "1" "${switch_delete+X}"        "1 to enable deleting of files on backup that don't exist on source"
add_norm "switch_zip"           ""  "${switch_zip+X}"           "1 to compress (for backups over the internet)"
add_norm "max_del"              ""  "${max_del+X}"              "maximum number of files to delete (blank for unlimited)"
add_norm "run_min"              "0" "${run_min+X}"              "minute to run job"
add_norm "run_hour"             "0" "${run_hour+X}"             "hour to run job (0 for midnight)"
add_norm "run_day"              ""  "${run_day+X}"              "day of month to run job (blank for every day)"
add_norm "run_dow"              ""  "${run_dow+X}"              "day of week to run job (blank for every day, 0 is Sunday)"
echo >> "$jobfile"

echo "# do not back up these folders.  begin paths with slash for absolute, or not for anywhere" >> "$jobfile"

# add any other defined parameters

if [ -z "${parameters[0]:-}"  ] ; then
  echo "#addex \"DATA_XFER\"" >> "$jobfile"
  echo "#addex \"/Users/Shared\"" >> "$jobfile"
else
  for ((i=0;i<${#parameters[@]};i++)) ; do
    echo "addex \"${parameters[i]:10}\"" >> "$jobfile"
  done
fi
debug "jobfile \"$jobfile\" was normalized"


returning 

}



########################################
##  DO MAIL TEST
########################################

##  send a test email to verify emailing system is working

do_mailtest () {
calling DO_MAILTEST

log "attempting to send test email"

send_email "test email from backup" "test mail sent $(date) from ${HOSTNAME%.*}"

echo "test email sent to $MAIL_TO"

returning 
}





################################################################################
###
###  DO BACKUP
###
################################################################################

do_backup () {

local i
calling DO_BACKUP


# make sure job file was loaded

validate_job



##  ====================================
##  VERIFY REQUIRED COMMANDS
##  ====================================

##  verify essential support scripts and commands are available

install_check "setfile"
install_check "rsync"
install_check "fixlinks"



##  ====================================
##  VERIFY ROOT
##  ====================================

##  verify script has root privileges if backing up boot drive

if [ "$source_folder" == "/"  ] ; then
  if [ $UID != 0 ] ; then
    clear
    echo
    echo "Backup must be run as root"
    exit 1
  fi
fi



##  ====================================
##  DEFINE EXCLUSIONS
##  ====================================

##  build a list of file and folder exclusions to pass to rsync

if [[ ("${source_folder}" == "/") || ("${source_folder:0:9}" == "/Volumes/") ]] ; then  # for device backups
  # all of these root-level folders should be skipped
  if [ "$source_folder" == "/" ] ; then
    r=""
  else
    # rsync roots exclusions at the end object in the source path
    r="$source_folder"  # "usbdrive/checkerboards/data1"
    r=${r##*/}  # "data1"
    r="/$r"  # "/data1"
  fi
  debug "exclusion root r=\"$r\""
  addex "$r/Network"
  addex "$r/automount"
  addex "$r/private/tmp"
  addex "$r/private/var/vm"
  addex "$r/private/var/tmp"
  addex "$r/private/var/folders"
  addex "$r/.Spotlight-V100"
  addex "$r/DocumentRevisions-V100"
  addex "$r/.fseventsd"
  addex "$r/.dbfseventsd"
  addex "$r/home"  # new for leopard
  addex "$r/net"  # new 4/3/09 ?
  addex "$r/.ServerBackups"  # new for 10.6 server with time machine turned on and running a backup

  # am SO sick of rsync choking on sockets
  #addex "$r/private/var/launchd/0/sock"
  #addex "$r/private/var/run/*"  # sockets AND PID files (both expendable)
  #addex "$r/private/var/spool/postfix/public/*"
  #addex "$r/private/var/spool/postfix/private/*"
  #addex "$r/private/etc/racoon/racoon.sock"
  #addex "$r/private/etc/racoon/vpncontrol.sock"
  #addex "$r/private/var/samba/winbindd_privileged/pipe"
  #addex "$r/private/var/samba/winbindd_public/pipe"
  addex "$log_folder"
  # ok I give up there are dozens of them some in home folders and some with random filenames (10.13 seems to have fixed this?)

#else  # for home or data folder backups
  # these folders don't need to be backed up for home folder backups
  #addex "Library/Safari/Icons"


fi

# excludes for any backup
# addex "DATA_XFER"  # this folder can occur anywhere   - we are now requiring that to be in the job file
addex "Library/Caches/"

# Even in vers 3.0.6 there appears to be no way to truly keep rsync's fingers away from
# sockets.  You can tell it to skip them by not using -a, --special, or --devices, but if
# you try to use -XA it doesn't matter it will still try to stat them and generate an IO
# error so the only solution appears to be to specifically exclude sockets by filename.
# How retarded!

# as of 10.13 anyway, rsync is still reporting versioh 2.6.9 but it seems to be MUCH better
# behaved, I can only assume Apple has patched it extensively without touchin the version
# number



##  ====================================
##  DEFINE RSYNC SWITCHES
##  ====================================

##  start setting up rsync switches by adding universal switches

# non-local backups to root go by numeric IDs not lexical usernames
if [ "$(echo "$backup_folder" | cut -c 1-5)" == "root@" ] ; then
  add_parameter "--numeric-ids"
fi

# dry-run if LIVE switch was not specified
if [ ! "$switch_live" ] ; then
  log "this will be a dry run"
  add_parameter "--dry-run"
fi

# delete files on backup not present on source if SWITCH_DELETE flag was specified
if [ "$switch_delete" ] ; then
  add_parameter "--delete"
  if [ -n "$max_del" ] ; then
    add_parameter "--max-delete=$max_del"
    log "no more than $(commas "$max_del") files will be deleted"
  fi
else
  debug "no files will be deleted"
fi

# compress (zip) backups if SWITCH_ZIP flag was specified (always use this on internet backups)
if [ "$switch_zip" ] ; then
  add_parameter "--compress"
fi

# switches for any backup type
add_parameter "--archive"          # apply common backup flags
add_parameter "--hard-links"       # preserve hard links
add_parameter "--one-file-system"  # do not back up mount points such as in /Volumes/
add_parameter "--progress"         # display (log) each file as it is being transferred
add_parameter "--timeout=1200"     # io timeout in seconds (not total backup time) - this is also the max time to wait for receiver to count files, so setting to 20 min
add_parameter "--partial"          # keep partially synced files if backup is interrupted
add_parameter "--verbose"          # display a little verbosity

# debugging why DMG are fully transferring even though only small areas chage, or no changes but only date on file is new
add_parameter "--itemize-changes"
add_parameter "--stats"
# no they are working, it's just taking awhile to run the checksums

# switches not currently in use
#add_parameter "--ignore-errors"         # sockets always generate io errors unfortunately so we have to skip them otherwise --delete is disabled (fixed for 10.13?)
#flags="${flags} -aHAXx"                 # new flags for rsync 3.0.6
#flags="${flags} -HAXxrlptgo --devices"  # 3.0.6 flags MINUS --special  DOES NOT AVOID SOCKETS AS EXPECTED (fixed for 10.13?)



##  ====================================
##  PICK BACKUP AND VERIFY PING
##  ====================================

##  verify we can ping the destination if it is a network backup (therefore backup server must respond to pings!)
##  this process also selects the first available backup if more than one was specified

for ((i=0;i<${#backup_folder[@]};i++)) ; do
  debug "backup_folder[$i] = \"${backup_folder[i]}\""
  a=${backup_folder[i]%%@*}  # "root:2222"
  b=${backup_folder[i]#*@}  # "192.168.1.20:/Volumes/BACKUP_WORKHORSE/WORKHORSE_BACKUPS/MBP"
  if [ "$a" == "$b" ] ; then
    # local backup
    if ! [ -d "$b" ] ; then
      log "backup folder \"$b\" is not available"
      continue
    fi
    # local backup folder is avallable, use it
    log "will use local backup folder \"$b\""
    backup_folder=$b
    backup_address=
    # verify backup folder exists
    if [ ! -d "$backup_folder" ] ; then
      abort $LINENO "backup folder \"$backup_folder\" not found"
    fi
    # fixlinks needs to know if this is remote
    remote_backup=
    break
  fi
  # remote backup
  backup_login=${a%:*}  # "root"
  backup_port=${a#*:}  # "2222"
  debug "backup_port=\"$backup_port\""
  if [ "$backup_port" == "$backup_login" ] ; then
    backup_port=22
    debug "backup_port changed to \"$backup_port\""
  fi
  debug "backup_folder[$i]=\"${backup_folder[i]}\""  # "root:2222@192.168.1.20:/Volumes/BACKUP_WORKHORSE/WORKHORSE_BACKUPS/MBP"
  backup_address=${backup_folder[i]%:*}  # "root:2222@192.168.1.20"
  backup_address=${backup_address#*@} # "root:2222@192.168.1.20"
  debug "backup_address=\"$backup_address\""
  backup_root=${backup_folder[i]##*:}  # "/Volumes/BACKUP_WORKHORSE/WORKHORSE_BACKUPS/MBP"
  debug "backup_root=\"$backup_root\""
  debug "ping-testing backup server at \"$backup_address\""
  pingtest "$backup_address"
  if ! [ $good_ping ] ; then
    log "failed to ping backup server at \"$backup_address\""
    continue
  fi
  # ping was good, use this one
  log "good ping from backup server at \"$backup_address\""
  # overwrite backup_folder[0] with the one that works
  # create rsync destination syntax (excludes port number)
  backup_folder="$backup_login@$backup_address:$backup_root"
  debug "will sync to remote backup at \"$backup_folder\""

  # verify ssh to backup server
  /usr/bin/ssh -p $backup_port -o StrictHostKeyChecking=no "$backup_login@$backup_address" true
  assert $LINENO "verify ssh to backup server (possibly bad key)" "/usr/bin/ssh -p $backup_port \"$backup_login@$backup_address\" true"

  # verify backup folder exists
  /usr/bin/ssh -p $backup_port -o StrictHostKeyChecking=no "$backup_login@$backup_address" "if [ -d \"$backup_folder\" ] ; then true ; fi"
  assert $LINENO "verify remote backup folder exists" "/usr/bin/ssh -p $backup_port \"$backup_login@$backup_address\" \"if [ -d \\\"$backup_folder\\\" ] ; then true ; fi\""

  # fixlinks needs to know if this is remote
  remote_backup=1

  # all checks passed, use this backup folder
  break
done
if [ $i == ${#backup_folder[@]} ] ; then
  abort $LINENO "no backup folders are usable"
fi



##  ====================================
##  VERIFY TRAILING SLASHES
##  ====================================

# rsync -a source target  backs up sourcem folder INTO target folder (unlike say, ditto) so force the user to specifiy it as "rsync -a source target/" to make the behavior clear

if [[ ("$source_folder" != "/") && ("${source_folder%/}" != "$source_folder") ]] ; then
  abort $LINENO "source folder path \"$source_folder\" ends in a slash"
fi
if [ "${backup_folder%/}" == "$backup_folder" ] ; then
  abort $LINENO "backup folder path \"$backup_folder\" does not end in a slash"
fi



##  ====================================
##  VERIFY SSH KEY IS PRESENT
##  ====================================

if [ -n "$backup_address" ] ; then
  if [ -r /var/root/.ssh/id_rsa ] ; then
    debug "found ssh private key at \"/var/root/.ssh/id_rsa\""
  else
    echo "You will need to generate an RSA key and upload the public copy to the backup server"
    echo
    echo "Enter this command while logged in as root on the client:  ssh-keygen -t rsa"
    echo
    echo "After generating the key, append the contents of /var/root/.ssh/id_rsa.pub on the client to /var/root/.ssh/authorized_keys on the backup server"
    echo
    echo "The authorized_keys file on the backup server  must be owned by root and permissions set to 600 (rw-------)"
    echo "(the .ssh folder must also be owned by root, rwx------)"
    echo
    abort $LINENO "ssh key not present for network backup"
  fi
fi



##  ====================================
##  UNLOCK LOCKED STRUCTURES
##  ====================================

##  if this is a backup of the boot volume, unlock certain system files that tend to be locked so they don't generate rsync errors
##  this will fail if SIP is enabled

if [ "$switch_do_not_unlock" ] ; then
  debug "skipping unlocks"
else
  debug "checking for unlocks"
  if [ "$source_folder" == "/"  ] ; then
    # make sure system is not set to rootless (SIP enabled)
    command csrutil 2> /dev/null > /dev/null ; rc=$?
    if [ $rc != 0 ] ; then
      debug "csrutil command not available"
    else
      csrutil status | grep disabled
      assert $LINENO "verify SIP is disabled" "csrutil status | grep disabled"
    fi
    # unlock files on the boot drive
    unlock "/System/Library/CoreServices/boot.efi"
    unlock "/System/Library/CoreServices/bootx"
    unlock $'/.HFS+ Private Directory Data\r'
  elif [ "${source_folder:0:9}" == "/Volumes/"  ] ; then
    # unlock files on another volume
    v=${source_folder:9}
    v="/Volumes/${v%%/*}"
    unlock "$v/System/Library/CoreServices/boot.efi"
    unlock "$v/System/Library/CoreServices/bootx"
    unlock "$v"$'/.HFS+ Private Directory Data\r'
  fi
fi



##  ====================================
##  VERIFY OWNERS ARE ENABLED
##  ====================================

##  verify owers are enabled on backup source (if not the boot volume) and backup target (if local)

if [ "${source_folder:0:9}" == "/Volumes/" ] ; then
  x=${source_folder:9}
  x="/Volumes/${x%%/*}"
  if (vsdbutil -c "$x" | grep -q " are enabled\\.$") ; then
    if ! (diskutil info "$x" | grep Owners | grep Enabled ) ; then
     abort $LINENO "permissions are not enabled for \"$x\""
    fi
  fi
fi
if [ "${backup_folder:0:9}" == "/Volumes/" ] ; then
  x=${backup_folder:9}
  x="/Volumes/${x%%/*}"
  if ! (vsdbutil -c "$x" | grep -q " are enabled\\.$") ; then
    if ! (diskutil info "$x" | grep Owners | grep -q Enabled) ; then
      abort $LINENO "permissions are not enabled for \"$x\""
    fi
  fi
fi



##  ====================================
##  FINAL PARAMETER ASSEMBLY
##  ====================================

##  backup source and target are the last rsync parameters to be added

if [ -n "$backup_address" ] ; then
  add_parameter "--rsh=/usr/bin/ssh -p $backup_port -o StrictHostKeyChecking=no"
fi
add_parameter "$source_folder"
add_parameter "$backup_folder"  # rsync isn't like ditto, it backs up the source INTO the destination, not AT the destination



##  ====================================
##  RUN BACKUP
##  ====================================

##  parameters are all programmed and all preflight tests and operations have been run, are are ready to begin the backup process

broadcast "backup has started"
central_history "" "backup started"
startsec=$SECONDS
# rsync ignores rsh parameter 
# source and backup are both local
history "rsync $(format_array "${parameters[@]}") 2> \"${rs_err_log}1\" > \"${rs_run_log}1\""
echo    "rsync $(format_array "${parameters[@]}") 2> \"${rs_err_log}1\" > \"${rs_run_log}1\"" > "$rs_run_log"
echo -n > "$rs_out_log"  # log of all non-error output from rsync
echo -n > "$rs_err_log"  # log of all error output from rsync
echo -n > "$rs_err_log"  # log of all output from rsync
if [ ! "$switch_live" ] ; then
  broadcast "DRYRUN: skipping rsync, SLEEP 5"
  rsync_rc=0
  t1=$SECONDS
  sleep_millis 5000
  t2=$SECONDS
  ((t3=t2-t1))
else
  debug "rsync starting now"
  echo -n > "${rs_run_log}1"
  debug "output is being piped to file, to view, CMD: tail -f \"${rs_run_log}1\""
  trap trapsigint SIGINT
  debug "SIGINT is now being trapped"


  #############
  ##  RSYNC
  #############
  t1=$SECONDS
  rsync "${parameters[@]}" 2> "${rs_err_log}1" > "${rs_run_log}1"
  # is necessary to use ${}1 as an intermediary before changing CR's to LF's because piping (to 'tr') will mask rsync's return code
  # it is also necessary to send > and 2> to different files or output from the second will overwrite output from the first
  rsync_rc=$?
  t2=$SECONDS
  ((t3=t2-t1))
  #############

  debug "rsync done with RC=$rsync_rc"

  trap - SIGINT
  debug "SIGINT is no longer being trapped"
  if [ $got_sigint ] ; then
    abort $LINENO "received SIGINT while RSYNC was running (job stopped via launchctl or user hit crtl-c), aborting"
  fi

  # post-process log files
  cat "${rs_run_log}1" | tr '\r' '\n' >> "$rs_run_log"
  cat "${rs_err_log}1" | tr '\r' '\n' >> "$rs_err_log"
  #rm "${rs_run_log}1"
  #rm "${rs_err_log}1"
  cat "$rs_err_log" >> "$rs_run_log"  # combine non error and error runfiles to make one large runfile (with errors at the end)
  debug "output logs combined into \"$rs_run_log\""
fi

endsec=$SECONDS
log "Rsync done with return code \"$rsync_rc\""  # return code 23 means it was not error free, but it could just be mknod errors?

# rsync: get_xattr_names: llistxattr("Users/nfisher/Library/Acrobat User Data/8.0_x86/Synchronizer/Commands",1024) failed: Operation not permitted (1)
# IO error encountered -- skipping file deletion



##  ====================================
##  CHECK BACKUP RESULTS
##  ====================================

##  perform specific responses based on rsync exit codes and errors found in log files

# should try to deal with rsync_rc instead of catting the rs_run_log, but will need to see what codes do what,
# fill them in as they are discovered

#  24 means rsync received SIGINT (user-hit-ctrl-c or some process like launchctl sent it due to being stopped)
# 139 is rsync segfault (usually means backup server needs to be rebooted)
# 255 can mean host key not known, or host key incorrect (or maybe any ssh authentication failure?) - possibly just means any -rsh error
# although ssh errors should be caught above in the ssh check
# 12 also can mean host key verify failed.  error codes seem to vary by OS version.

if [ $rsync_rc == 139 ] ; then
  # rsync segfaulted
  abort $LINENO "BACKUP FAILED: Rsync segfaulted. (machine needs rebooting?)"
elif [ $rsync_rc == 20 ] ; then
  # rsync received SIGINT, probably means launhcctl stopped job or user hit CTRL-C
  abort $LINENO "BACKUP FAILED: Rsync cancelled by user"
elif (grep -q "connection unexpectedly closed" "$rs_run_log") ; then
  # connection was lost (or never established)
  abort $LINENO "BACKUP FAILED: lost connetion during backup."
elif (grep "Read from remote host " "$rs_run_log" | grep -q ": Operation timed out") ; then
  # timeout or abort
  abort $LINENO "BACKUP FAILED: IO timeout."
#elif [ -n "$(cat "$rs_run_log" | grep "Offending key in ")" ] ; then
#  # ssh key fingerprint has changed
#  abort $LINENO "BACKUP FAILED: ssh key fingerprint has changed."
elif (grep -q "Permission denied (publickey," "$rs_run_log") ; then
  # public key not accepted
  abort $LINENO "BACKUP FAILED: ssh key not accepted."
elif (grep -q "IO error encountered - skipping file deletion" "$rs_run_log") ; then
  # read/write error
  abort $LINENO "BACKUP FAILED: IO error detected"
elif [ $rsync_rc == 24 ] ; then
  # rsync warning: some files vanished before they could be transferred (code 24) at /BuildRoot/Library/Caches/com.apple.xbs/Sources/rsync/rsync-52/rsync/main.c(996) [sender=2.6.9]
  log "rsync said some files vanished, this is normal when backing up the boot drive"
elif [ $rsync_rc == 0 ] ; then
  # ony test for code 0 after having checked logs for other problems
  log "backup appears to have been successful, rsync RC=$rc"
else
  # logs look ok, and rsync returned a non-zero exit code but it's not one we recognize as being fatal
  log "rsync returned with code $rsync_rc, but it doesn't appear to have been a fatal error"
fi



##  ====================================
##  NO IMMEDIATE FAILURES
##  ====================================

##  nothing catastrophic was found in the return code or log files, the backup was at least somewhat successful (it didn't crash or abort withouot doing anything)
##  but even though it succeeded, we may have some non-fatal warnings to issue after this point

warnings=0



##  ====================================
##  CHECK DELETE LIMIT
##  ====================================

##  check for the delete limit on target having been reached

deleted="$(grep "^deleting " "$rs_run_log" | wc | tr -s ' ' | cut -d ' ' -f 2)"
if [ "$deleted" -ge "$max_del" ] ; then
  # Deletions stopped due to --max-delete limit (192634 skipped)
  remaining=$(grep "Deletions stopped due to --max-delete limit" "$rs_run_log" | cut -d "(" -f 2 | cut -d " " -f 1)
  broadcast "file delete limit of ${max_del} was reached, ${remaining} files were not deleted."
  ((warnings++))
fi



##  ====================================
##  REPORT BACKUP STATISTICS
##  ====================================

##  gather totals on files and bytes synced

history "$(commas "$deleted") files were deleted"

files=$(grep -c " 100% " "$rs_run_log")
history "$(commas "$files") files were synchronized"

# parse total bytes sent by rsync to backup server
sbytes=$(tail "$rs_run_log" | grep "^sent [0-9]* bytes")  # "sent 402433046 bytes  received 12098 bytes  966254.85 bytes/sec"
debug "sbytes=\"$sbytes\""
sbytes=${sbytes:5}  # "402433046 bytes  received 12098 bytes  966254.85 bytes/sec"
sbytes=${sbytes%% *}  # "402433046"
if [ -z "$sbytes" ] ; then
  sbytes=0
fi

skb=$((sbytes/1024))
smb=$((sbytes/1024/1024))
sgb=$((sbytes/1024/1024/1024))
if [ ${sbytes} == 0 ] ; then
  broadcast "no data sent by rsync"
  ((warnings++))
fi



##  ====================================
##  FIX LINKS
##  ====================================

##  call fixlinks to clean up rsync errors caused by syncing certain symbolic links
##  (this may no longer be necessary as of 10.13?)

debug "creating fixlinks switches"

add_sw "-source"
add_sw "$source_folder"
add_sw "-backup"
add_sw "$backup_folder"
add_sw "-errorfile"
add_sw "$fixfile"
#add_sw "-live"   # I haven't gotten a chance to test this after rebuilding it because rsync hasn't coughed up any errors yet... is it fixed?

debug "switches created"

debug "creating fix file from error log"

grep " failed:" "${rs_err_log}" | grep -v "mknod " | grep -v "rsync: get_xattr_names:" > "$fixfile"

debug "fix file created"

if [ -s "$fixfile" ] ; then
  debug "fixfile \"$fixfile\" has data"
  #ct=$(($(wc -l "$fixfile")))
  ct=$(($(wc -l < "$fixfile")))
  debug "ct=\"$ct\""
  broadcast "there were ${ct} rsync errors during the backup."
  # if this is a local backup, 
  if [[ ("$remote_backup") && (-n "$backup_port") ]] ; then  # reinject ssh port for fixlinks
    backup_folder="root:$backup_port@${backup_folder#*@}"
  fi
  log "fixlinks $(format_array "${fixlinks_switches[@]}")"
  if [ "$switch_live" ] ; then
    debug "NOPE CMD: /usr/local/bin/fixlinks $(format_array "${fixlinks_switches[@]}")"
    #/usr/local/bin/fixlinks "${fixlinks_switches[@]}"
    rc=$?
  else
    debug "DRYRUN CMD: /usr/local/bin/fixlinks $(format_array "${fixlinks_switches[@]}")"
  fi
  if [ $rc == 0 ] ; then
    log "fixlinks successful"
  else
    broadcast "fixlinks returned code $rc, ${ct} errors were attempted"
    cat "$fixfile" >> "$history_file"
   ((warnings++))
  fi
else
  log "no rsync errors to fix."
fi




##  ====================================
##  FINISH BACKUP
##  ====================================

##  backup is complete, along with all post-processing

if [ "$switch_live" ] ; then
  if [ "$warnings" == "0" ] ; then
    broadcast "BACKUP SUCCESSFUL: There were no fatal problems"
  else
    broadcast "BACKUP FINISED WITH $warnings WARNINGS"
  fi
else
  broadcast "dry-run complete"
fi

backup_successful

finish "backup job ${job_name} done in $(elapsed $((endsec-startsec))), $smb MB synced" 0

returning 
}



########################################
##  DO HELP
########################################

##  display help/use/syntax

do_help () {
calling DO_HELP

echo
echo "${0##*/} version $vers"
echo

echo "client switches:"
echo
echo "-b | -backup               : execute a backup (default is dryrun)"
echo "-L | -daemon               : executed from job launch daemon (affects broadcasts and emails)"
echo "-d | -debug                : include debugging information"
echo "-n | -dryrun               : disable LIVE swtich (regardness of switch order)"
echo "-h | -help                 : display help"
echo "-i | -install              : install daemon to maintain script and schedule changes (or run backup if SCHEDULE was already specified)"
echo "-j | -jobfile {path}       : specify path of backup jobfile to use"
echo "-l | -live                 : live run"
echo "-N | -normalize            : normalize backup job file"
echo "-r | -remove               : stop, unload, and remove backup daemon (will not check for updates, use INSTALL without SCHEDULE to disable backups without unloading)"
echo "-s | -schedule             : configures INSTALL to perform backups at scheduled intervals (omit to only check for updates and schedule changes)"
echo "-t | -trace                : trace calls to significant functions"
echo "-u | -update               : update backup script and support files from server (specify first)"
echo

echo "server switches:"
echo
echo "-D | -dumphist {pattern}   : dump history database, filtering by optional pattern (run on update server only)"
echo "-M | -dumpjobhist          : dump history database sorted by job"
echo "-I | -init                 : initialize new server"
echo "-J | -jobstatus            : display last successful log entry for each job"
echo "-m | -mailtest             : test gmail mailer"
echo

echo "communications switches:"
echo
echo "-G | -getschedule {job}    : get job schedule from server (dump local schedule table if no job specified)"
echo "-H | -history              : record any job's history on central server history file (host/job/started/finished/rc/note)"
echo "-S   -setschedule {params} : write a job's schedule on server's schedule"
echo "-v | -version              : display script and support file version numbers (modification timestamps in totalsec format)"
echo

returning 
}







########################################################################################################################################################################################################
########################################################################################################################################################################################################
###
###  STARTUP
###
########################################################################################################################################################################################################
########################################################################################################################################################################################################

create_example_jobs

if [ -z "${*:-}" ] ; then
  log_cmd "\"$0\""
else
  log_cmd "\"$0\" $(format_array "$@")"
fi

r_modified_ts=0
modified_ts=0





########################################################################################################################################################################################################
########################################################################################################################################################################################################
###
###  PARSE SWITCHES
###
########################################################################################################################################################################################################
########################################################################################################################################################################################################

# calls from switches are handled by DO_ subroutines, not functions (although functions and subroutines can call other subroutines)

if [ ${#@} == 0 ] ; then
  # called with no parameters, display help and exit
  do_help ""
  exit 0
fi


# start with a dummy job so functions that require job information can run even before the job has been defined by switch and loaded

job_name="UNDEFINED"
jobfile=
job_name="UNDEFINED"
define_paths


# these switches assume default values if not specified

switch_live=
switch_schedule=
switch_do_not_unlock=
switch_daemon=
switch_dryrun=
switch_install=
#switch_calling=   # must set earlier

# parse provided switches, call DO subroutines if specfied
# continue processing switches until ABORT, FINISH, or we run out of switches

while [ ${#@} != 0 ] ; do
  if [ -z "$1" ] ; then
    shift

  elif [[ ("$1" == "-b") || ("$1" == "-backup") ]] ; then
    shift
    debug "accepted switch BACKUP, calling do_backup"
    do_backup

  elif [ "$1" == "-d" ] ; then
    shift
    switch_debug=1
    debug "accepted switch DEBUG (basic)"

  elif [ "$1" == "-debug" ] ; then
    shift
    switch_debug=1
    switch_debug2=1
    debug "accepted switch DEBUG (detailed)"

  elif [ "$1" == "-do-not-unlock" ] ; then
    shift
    debug "accepted switch DO NOT UNLOCK"
    switch_do_not_unlock=1

  elif [[ ("$1" == "-D") || ("$1" == "-dumphist") ]] ; then
    shift
    debug "accepted switch DUMP HISTORY, calling server_dump_history"
    if [[ (${#@} != 0) && ("${1:0:1}" != "-") ]] ; then
      # filter output withy spefified pattern
      server_dump_history "$1"
      shift
    else
      # dump all records
      server_dump_history
    fi

  elif [[ ("$1" == "-M") || ("$1" == "-dumpjobhist") ]] ; then
    shift
    if [ ${#@} != 0 ] ; then
      j=$1
      shift
      debug "accepted switch DUMP JOB HISTORY, calling server_dump_jobhistory for job \"$j\""
      server_dump_jobhistory "$j"
    else
      debug "accepted switch DUMP JOB HISTORY, calling server_dump_jobhistory for all jobs"
      server_dump_jobhistory
    fi

  elif [[ ("$1" == "-h") || ("$1" == "-help") ]] ; then
    shift
    debug "accepted switch HELP, calling do_help"
    do_help

  elif [[ ("$1" == "-H") || ("$1" == "-history") ]] ; then
    shift
    if [ ${#@} != 6 ] ; then
      abort $LINENO "HISTORY switch followed by ${#@} parameters ($(format_array "$@"))"
    fi
    debug "accepted switch HISTORY, calling server_history"
    server_history "$1" "$2" "$3" "$4" "$5" "$6"
    shift 6

  elif [[ ("$1" == "-i") || ("$1" == "-install") ]] ; then
    shift
    debug "accepted switch INSTALL, calling do_install"
    switch_install=1  # cause differences in schedule flag to be uploaded (default is download)
    do_install

  elif [[ ("$1" == "-I") || ("$1" == "-init") ]] ; then
    shift
    debug "accepted switch INIT, calling server_init"
    server_init

  elif [[ ("$1" == "-j") || ("$1" == "-jobfile") ]] ; then
    shift
    if [ ${#@} == 0 ] ; then
      abort $LINENO "JOBFILE switch requires a parameter"
    fi
    if [ "${1:0:1}" == "/" ] ; then
      # jobfile path is absolute
      j=$1
    else
      # jobfile path is relative (to backup folder, regardless of CWD)
      j="${install_folder}/$1"
    fi
    debug "accepted switch JOBFILE with parameter \"$1\", calling do_load_jobfile"  # must occur before shift
    shift
    do_load_jobfile "$j"

  elif [[ ("$1" == "-J") || ("$1" == "-jobstatus") ]] ; then
    shift
    if [ ${#@} == 0 ] ; then
      debug "accepted switch JOBSTATUS, calling server_jobstatus for all jobs"
      server_jobstatus
    else
      j=$1
      shift
      debug "accepted switch JOBSTATUS, calling server_jobstatus for specific job \"$j\""
      server_jobstatus "$j"
    fi

  elif [[ ("$1" == "-l") || ("$1" == "-live") ]] ; then
    shift
    if [ $switch_dryrun ] ; then
      debug "rejected switch LIVE due to DRYRUN in effect"
    else
      debug "accepted switch LIVE"
      switch_live=1
    fi

  elif [[ ("$1" == "-n") || ("$1" == "-dryrun") ]] ; then
    shift
    debug "accepted switch DRYRUN (will mask any future LIVE switches"
    switch_dryrun=1
    if [ $switch_live ] ; then
      switch_live=1
      debug "DRYRUN overrides previously accepted LIVE switch"
    fi

  elif [[ ("$1" == "-t") || ("$1" == "-trace") ]] ; then
    shift
    debug "accepted switch TRACE"
    switch_trace=1

  elif [[ ("$1" == "-m") || ("$1" == "-mailtest") ]] ; then
    shift
    debug "accepted switch MAILTEST, calling do_mailtest"
    do_mailtest

  elif [[ ("$1" == "-N") || ("$1" == "-normalize") ]] ; then
    shift
    debug "accepted switch NORMALIZE, calling do_save_jobfile"
    do_save_jobfie

  elif [[ ("$1" == "-r") || ("$1" == "-remove") ]] ; then
    shift
    debug "accepted switch REMOVE, calling do_remove"
    do_remove

  elif [[ ("$1" == "-s") || ("$1" == "-schedule") ]] ; then
    shift
    debug "accepted switch SCHEDULE"
    switch_schedule=1

  elif [[ ("$1" == "-u") || ("$1" == "-update") ]] ; then
    shift
    debug "accepted switch UPDATE, calling do_update"
    do_update "$@"
    # if there is an update, do_update will call us with our remaining switches (after updating us) and then exit
    # otherwise it will just return to us and we can continue processing our remaining switches
    debug "no update was downloaded, will continue to process switches"

  elif [[ ("$1" == "-v") || ("$1" == "-version") ]] ; then
    shift
    debug "accepted switch VERSION, calling server_version"
    server_version

  elif [[ ("$1" == "-L") || ("$1" == "-daemon") ]] ; then
    shift
    debug "accepted switch DAEMON"
    switch_daemon=1

  elif [[ ("$1" == "-G") || ("$1" == "-getschedule") ]] ; then
    shift
    if [ ${#@} == 0 ] ; then
      debug "accepted switch GET SCHEDULE, calling server_getschedule for all schedules"
      server_getschedule
    else
      j=$1
      shift
      debug "accepted switch GET SCHEDULE, calling server_getschedule for job \"$j\""
      server_getschedule "$j"
    fi

  elif [[ ("$1" == "-S") || ("$1" == "-setschedule") ]] ; then
    debug "parameters passed to setschedule: $(format_array "$@")"
    shift
    if [ "${#@}" == 0 ] ; then
      abort $LINENO "switch SET SCHEDULE requires a parameter"
    fi
    p=$1
    shift
    debug "accepted switch SET SCHEDULE, calling server_setschedule with parameter \"$p\""
    server_setschedule "$p"

  else
    debug "encountered unexpected switch \"$1\""
    do_help
    echo "ABORT on line $LINENO: encountered unexpected switch \"$1\""
    exit 1
  fi
done







########################################################################################################################################################################################################
########################################################################################################################################################################################################
###
###  EXIT
###
########################################################################################################################################################################################################
########################################################################################################################################################################################################

# we ran out of switches

debug "no more switches"

debug "  modified_ts /  local_schedule = $modified_ts / $local_schedule"
debug "r_modified_ts / remote_schedule = $r_modified_ts / $remote_schedule"

if [[ ("$r_modified_ts" == "$modified_ts") && ("$remote_schedule" == "$local_schedule") ]] ; then
  debug "no changes made to schedule, no need to upload"
elif [ $r_modified_ts -gt $modified_ts ] ; then
  abort $LINENO "remote ts is somehow still greater than local ts"
else
  debug "remote modified ts ($r_modified_ts) is less than modified ts ($modified_ts), need to upload changed schedule to server"
  upload_schedule
fi

exit 0





# place Example Job at the end of the script because its embedded linefeeds will mess up any $LINENO that follow it
# there is one block above that also needs linefeeds embedded within strings but they are specified inline with ${LF} instead of actual linefeeds (hurts code readability though)

# also note that the scheduled/not scheduled state of a (loaded) job is not indicated within the job file, it exists only in the plist, as a difference in load interval and switches

########################################################################################################################################################################################################
########################################################################################################################################################################################################
###
###  EXAMPLE JOB
###
########################################################################################################################################################################################################
########################################################################################################################################################################################################

# name of job (used for naming log files and also in messages sent to WALL)
job_name="example_boot"

# specify folder to back up from, "/" to back up entire boot drive
source_folder="/"

# first available backup folder will be used. format for network folder backup is "root:port@address:/path/"
backup_folder[0]="root:22@192.168.1.55:/Volumes/BACKUP_DISK/example_boot_disk/"
backup_folder[1]="root:5432@external.address.com:/Volumes/BACKUP_DISK/example_boot_disk/"
backup_folder[2]="/Volumes/LOCAL_BACKUP_DISK/example_boot_disk/"

switch_do_not_unlock=          # 1 to disable unlocking of special files when backing up bootable drives
       switch_delete=1         # 1 to enable deleting of files on backup that does not exist on source
          switch_zip=          # 1 to compress (for backups over the internet)
             max_del=15000     # maximum number of files to delete (blank for unlimited)
             run_min=0         # minute to run job (0-59, required if scheduled)
            run_hour=1         # hour to run job (0-23, required if scheduled)
             run_day=          # day of month to run job (1-31, blank for every day)
             run_dow=          # day of week to run job (0-6, blank for every day, 0 is Sunday)

# do not back up these folders.  begin paths with slash for absolute, or not for anywhere
addex "DATA_XFER"


