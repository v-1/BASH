#!/bin/bash

vers=2020.01.17.C
# browse and edit sqlite3 databases, with a GUI similar to DBASE IV's table browser



########################################################################################################################
########################################################################################################################
###
###  EDIT THE COPY ON TASK ONLY, IN /USR/LOCAL/BIN/
###
########################################################################################################################
########################################################################################################################





####################################
###  NOT TO DO
####################################

# modify schema in any way at any time (exception: table import)

# dialog to translate fields for import/export

# make column 2 and 3 selections in sort option default selection to prior selection - cannot, they are disabled and unselectable

# use shift-up and shift-down instead of shift-home and shift-end (there are no corresponding ANSI escape sequences for shift-up or shift-down)

# vacuum database (*might* change ROWIDs, and in an unpredictable way, so would require a table reload)

# debug_parser calls are COMMENTED OUT because of their extreme impact on performance.  you must uncomment them as well as enable it in the debug menu



####################################
###  TO DO
####################################

# automatically log changes to database if (filename).dblog exists

# bounce-resize window if they shrink it too narrow (by calling resize_window)

# colorize database and table names in rowinfo?  probably not.

# buffer the data rows for faster rerawing when closing a window etc
#   examined, proably impractical - would be rather difficult to code and would produce only marginal benefits on an infrequent basis
#   currently we draw empty lines and then fill in the cells one at a time, so there's no single string we ever draw for a row that has populated cells
# another option would be to limit what lines are redrawn - just the headers and top few for most menu redraws





####################################
###  KNOWN BUGS
####################################

# pressing ctrl-R during database monitor will just scroll the screen and not stop monitoring if it's in the middle of an update

# there may be a performance problem with sorting on three fields

# enable bash "strict mode" for debugging
#   halt script immediately if ANY function call (external OR script) returns a nonzero return code
#   halt script immediately on reference to undefined variable
#   propogate nonzero return codes up the call chain
set -euo pipefail
# this can be rather brutal to debug if you make changes or otherwise find the script suddenly dumping back to the shell prompt without warning,
# but in close to 100% of the cases, this is indicating a (possibly very subtle) bug you need to fix, and so the warning is worth the inconvenience
# note that ((x++)) will give return code 1 (trigger a stop) if it's the last line in a function that gets executed, and x ends up == 1 (same for --)
# other functions (such as grep and read -t) can also set a nonzero return code.
# note that blank lines, fi, and done WILL NOT clear the exit code, so the instigator may be several lines before the return or "}"
# if necessary, place "true" at the end of a function before the closing brace or after the command that may set the return code
# you can set -e, do a command, and set +e again if you NEED a command (such as read -t, grep, or a function of yours) to give you a return code





########################################################################################################################
########################################################################################################################
###
###  CONFIGURATION
###
########################################################################################################################
########################################################################################################################


# cumulative file where all SQL commands are logged, all the time
sql_logfile="$HOME/Library/Logs/browse_sql.log"

# max number of attempts to perform a database operation
max_db_attempts=10

# maximum number of tables in table listing
max_tables=25

# terminal.app defines these at the prompt but they're not defined inside scripts, so call tput to fetch them reliably and after window resizing
unset COLUMNS  # must do this before asking tput for cols, or it will simply return the value of $COLUMNS, regardlss of current window size
COLUMNS=$(tput cols)  # not to be confused with "columns", which along with "rows" describes the size of the open table
LINES=$(tput lines)

# temporary files
temp_file="${HOME}/.browse_sql.temp"
temp_file2="${HOME}/.browse_sql.temp2"

# debugging defaults (these can be toggled live from the Debug menu)
switch_debug_rowid=   # display ROWID next to row indicator
switch_debug_ansi=    # clear screen to yellow before rendering, to highlight areas overlooked by rendering (every square on the screen should be redrawn)
switch_debug_parser=  # send input parser debugging information to debug file (MAJOR impact on performance)
switch_debug_log=     # send calls to debug() to log file (minor impact on performance)
switch_log_sql=       # log sql commands and return codes to (presistent) sql log file

# additional debugging information is logged to this file (created new every run where -d switch is specified)
# run this in a separate terminal window to monitor this file in real-time: clear ; tail -n 100 -f "$HOME/Library/Logs/browse_debug.log"
debug_file="$HOME/Library/Logs/browse_debug.log"

# maximum supported terminal width
max_terminal_width=500

# fields with undefined length will be checked for max cell width and add this much to their displayed width
# (mainly type INT, which will then end up with 10+4 = 14 character width)
flex_growth=4

# progress indicator interval on load/append/import/export - will update every this many records
progress_interval=100

# database isn't loaded yet
database_up=
table=
lastnotice=





########################################################################################################################
########################################################################################################################
###
###  GENERAL FUNCTIONS
###
########################################################################################################################
########################################################################################################################


############################################################
###  RESET ENVIRONMENT
############################################################

reset_environment () {
# reset environment (terminal configuration) to defaults prior to exit or halt

# reset ANSI
echo -ne "$ansi_cmd_streamoff"
echo -ne "$ansi_cmd_coloroff"
echo -ne "$ansi_cmd_cursoron"

# restore IFS
IFS=$' \t\n'

# restore tty control character settings
stty intr    \^c   # ctrl-c
stty discard \^o   # ctrl-o
stty lnext   \^v   # ctrl-v
stty dsusp   \^y   # ctrl-y
stty susp    \^z   # ctrl-z

# re-enable terminal key echo
stty echo

# strict bash does not need to be disabled because it will be reset automatically when we exit

}



############################################################
###  HALT
############################################################

halt () {
# for debugging, reset colors and stop immediately after displaying halt message

# restore bash environment to defaults so text i/o works normally again
reset_environment

echo
echo "HALT $1"
echo
exit 1
}



############################################################
###  RETURN TO CALLER
############################################################

return_to_caller () {
# reset environment to defaults and return gracefully to caller

# restore bash environment to defaults
reset_environment


# clear bottom line
goto_xy 0 $((LINES-1))
echo -n "${spaces:0:COLUMNS}"

goto_xy 0 $((LINES-1))

if [ ${#@} == 1 ] ; then
  echo "[ $1 ]"
fi
exit 0
}

# interrupt (usually ctrl-c but we redefined it as ctrl-p) will call return_to_caller to restore shell environment and exit
trap return_to_caller SIGINT



############################################################
###  SYNTAX
############################################################

display_syntax () {
# display program syntax

clear
#screen_needs_repainting=1
echo
echo "BROWSE version $vers"
echo
echo "Syntax: browse [-d] [-readonly] {database} [table]"
echo
echo -ne "$ansi_cmd_coloroff"
echo -ne "$ansi_cmd_cursoron"
}



############################################################
###  DEBUG
############################################################

if ! [ -f "$debug_file" ] ; then
  mkdir -p "${debug_file%/*}"
fi

debug () {
# add a message to the debug log file

if [ $switch_debug_log ] ; then
  echo "$1" >> "$debug_file"
fi
}



############################################################
###  ABORT
############################################################

abort () {
# abort program - cite provided line and reason and return_to_caller

line=$1
error=$2
if [[ -z ${started_up:-} ]] ; then
  debug "abort before started up, line $line, eror \"$error\""
  # error during startup, display syntax and error
  display_syntax
  reset_environment
  exit 1
fi
# error after startup
return_to_caller "FATAL ERROR on line $line : $error"
}



#########################################
###  DEFINE ESCAPE SEQUENCES
#########################################

# this block is not a function, it's executed inline before startup to get the escape sequences defined
# escape sequences are accepted as soon as we have parsed enough characters to match any defined sequence
# (unlike ANSI sequences, that always end in ';')
# as these are inputs and not screen outputs, technically I suppose these are VT100 terminal key sequences

define_esc_seq () {
# supported escape sequences will be replaced with labels
esc_seq_name[esc_seqs]=$1
esc_seq_code[esc_seqs]=$2
((esc_seqs++)) ; true
}
esc_seqs=0
define_esc_seq "UP"    $'\x1B[A'     # UP
define_esc_seq "DOWN"  $'\x1B[B'     # DOWN
define_esc_seq "RIGHT" $'\x1B[C'     # RIGHT
define_esc_seq "LEFT"  $'\x1B[D'     # LEFT
define_esc_seq "DEL"   $'\x1B[3~'    # DEL
define_esc_seq "INS"   $'\x1B[4~'    # INS ??   not supported anywhere
define_esc_seq "PGUP"  $'\x1B[5~'    # SHIFT+PAGEUP
define_esc_seq "PGDN"  $'\x1B[6~'    # SHIFT+PAGEDOWN
define_esc_seq "END"   $'\x1B[F'     # SHIFT+END
define_esc_seq "HOME"  $'\x1B[H'     # SHIFT+HOME
define_esc_seq "UNTAB" $'\x1B[Z'     # SHIFT+TAB
define_esc_seq "EOLN"  $'\x1B[1;2C'  # SHIFT+RIGHTARROW
define_esc_seq "BOLN"  $'\x1B[1;2D'  # SHIFT+LEFTARROW



#########################################
## DEFINE CONTORL CHARACTERS
#########################################

ctrl_a=$'\x01'
ctrl_b=$'\x02'
ctrl_c=$'\x03'
ctrl_d=$'\x04'
ctrl_e=$'\x05'
ctrl_f=$'\x06'
ctrl_g=$'\x07'
ctrl_i=$'\x09'  # {TAB}
ctrl_l=$'\x0C'
ctrl_o=$'\x0F'
ctrl_r=$'\x12'
ctrl_v=$'\x16'
ctrl_w=$'\x17'
ctrl_x=$'\x18'

escape=$'\x1B'
delete=$'\x7F'

tab=$ctrl_i



#########################################
## PARSE ESCAPE
#########################################

# used by:
#   display_popup_menu (1)
#   accept_entry (1)
#   main_menu (1)
#   edit_cell (1)
#   begin_browsing (not)

seq=""

parse_esc () {
# we have already parsed an escape (\x1B), parse rest of code into $k and replace k with the escape code (such as "PGUP") when a complete code is parsed
# open the main menu automatically if just [ESC] was pressed alone (unless $1 = 1)
# this is used by the browser, the editor, and the popup window to parse arrow keys that are presented as VT100 terminal escape sequences
# remember this could also just be the user pressing [ESC]
# this code is used everywhere an escape sequence (usually at least an arrow key) can be pressed

local sup i  # k and seq are returned to caller
if [ ${#@} != 0 ] ; then
  return_esc=1
else
  return_esc=
fi
if [ -z "$seq" ] ; then
  seq=$escape
else
  #echo -n $'\a'
  seq="$escape$seq"
  debug "unbuffering \$$(echo -n "$seq" | xxd -u -p)"
fi
#debug_parser "starting ESC parse"

k=""
set +e  # allow read to return nonzero exit code (for read timeout)

#read -n1 -t1 -s k  # -t1 will cause a 1 second delay when the user merely pressed [ESC] rather than hitting a key that generates an escape sequence
#rc=$?

#stty -icanon -icrnl time 0 min 0   works
#stty -icanon time 0 min 0    works
#stty -icanon time 0  does NOT work
stty -icanon min 0   # going to stick with this one
#stty -icanon   does NOT work

read k
# no, you can't use -n1 with -icanon
# VERY interesting... it reads the ENTIRE rest of the escape sequence as one string, every time, very consistently
# if you hold down an arrow, it can cause 2-4 arrows to pile up in k however
# this is very helpful because if you get an [esc] you don't have to wait to see if an escape sequence is starting... if it is, you already have it all
#debug "#k = ${#k}"
stty icanon min 1

set -e

# append whatever was read to the seq read buffer, since there may already be something in the buffer
seq="$seq$k"
#debug_parser "parsing key sequence: \$$(echo -n "$seq" | xxd -u -p)"
if [ ${#seq} == 1 ] ; then
  # this is not an escape sequence, the user just pressed [ESC] (either while browsing, cancelling a cell edit, or escaping out of a popup menu)
  # caller wants us to return the escape key, this is NOT a key read in while the menu is being displayed (cell edit or popup menu)
  k="ESC"
  seq=
  return
fi

# check to see if it begins with (or is exactly) a valid code
for ((i=0;i<esc_seqs;i++)) ; do
  #debug_parser "checking input against sequence $i"
  if [ "${seq:0:${#esc_seq_code[i]}}" == "${esc_seq_code[i]}" ] ; then
    # a supported escape sequence is in the start of the buffer.  peel it off the buffer, and return the represented code name
    #debug_parser "prefix match"
    k="${esc_seq_name[i]}"
    #debug_parser "successfully parsed \"$k\""
    seq=${seq:${#esc_seq_code[i]}}
    return
  fi
  #debug_parser "no partial or complete match yet"
done
#debug_parser "done checking escape sequences"

# the buffer starts with an unsupported escape sequence
k=
# we will set k to null but LEAVE the unsupported sequence in seq so the caller can display it
# the caller MUST detect k is null and MUST clear seq
return
}



#########################################
###  SELECT FILE
#########################################

select_file () {
# select a file from current directory based on specified pattern.  return value in selected_file
# does not handle subfolders, the file to be opened must be in the CWD
# limits number of files in selection by the height of the window (the popup selection cannot scroll)

local title pattern
title="$1"
pattern=$2

new_popup_menu "$title"

# list files in this folder that match specified pattern (cap returned results to fit on screen in a popup)
ls | grep  "$pattern" | head -n $((LINES-5)) > "$temp_file"
while read x ; do
  new_popup_option "$x"
done < "$temp_file"
rm "$temp_file"

if [ $popup_options == 0 ] ; then
  # no matching files in this folder
  popup_message "$title" "No qualifying files found in default folder"
  return
fi

# display popup and get selection
display_popup_menu
debug "got menu option $popup_index \"$popup_result\""
selected_file="$popup_result"
# return selected file (or blank if cancelled) to caller
}



#########################################
###  POPUP CONFIRM
#########################################

popup_confirm () {
# confirm or cancel an action.  returns value in 'confirmed'  ("1"=confirmed, blank=cancelled)
# "cancel" is the default option

local title pattern
title="$1"

# build popup
new_popup_menu "$title"
new_popup_option "CANCEL"
new_popup_option "CONFIRM"

# display popup and get selection
display_popup_menu

# return result to caller
debug "got menu option $popup_index \"$popup_result\""
if [ "$popup_result" == "CONFIRM" ] ; then
  confirmed=1
else
  confirmed=
fi
}



############################################################
###  MILLIS
############################################################

millis () {
# return the number of milliseconds since boot

perl -MTime::HiRes -e 'print int(1000 * Time::HiRes::gettimeofday),"\n"'
}



############################################################
###  SLEEP MILLIS
############################################################


sleep_millis () {
# sleep a specified number of milliseconds
# doesn't block
# used mainly by sql to sleep 100ms when retrying

local t
((t=$1*1000))
perl -MTime::HiRes -e 'Time::HiRes::usleep('$t')'
}


sleep_millis_blocking () {
# sleep a specified number of milliseconds
# doesn't yield, so it chews up CPU time while sleeping

local t
((t=$(millis)+$1))
while [ $(millis) -lt $t ] ; do
  true
done
}



#########################################
###  INVALID COMMAND
#########################################

invalid_command () {
# an invalid key was input, probably while browsing, editing, or using a popup menu

# debug a warning for invalid command, beep
debug "INVALID COMMAND \"$k\" on line $1"
draw_error "INVALID COMMAND \"$k\" on line $1"
echo -n $'\a'
}



#########################################
###  UNSUPPORTED SEQUENCE
#########################################

unsupported_sequence () {
# debug a warning for an invalid escape sequence. beep
debug "UNSUPPORTED ESCAPE SEQUENCE: \$$(echo -n "$seq" | xxd -u -ps) on line $1"
#echo -n $'\a'
}





########################################################################################################################
########################################################################################################################
###
###  SQL FUNCTIONS
###
########################################################################################################################
########################################################################################################################


############################################################
###  LOG SQL
############################################################

log_sql () {
# log an SQL command executed - does not specify database file

if [ $switch_log_sql ] ; then
  mkdir -p "${sql_logfile%/*}"
  touch "$sql_logfile"
  echo "$(date "+%Y/%m/%d %H:%M:%S") - $1" >> "$sql_logfile"
fi
}
switch_debug_sql=



############################################################
###  CREATE CHANGE FILE 
############################################################

create_change_file () {
# create an sql change file and prepare it for adding change statements

if [ ${#@} == 0 ] ; then
  # create a new output file unless told otherwise
  echo -n > "$temp_file"
fi
echo "sqlite3 '$database' \"" >> "$temp_file"
echo "PRAGMA foreign_keys=OFF;" >> "$temp_file"
echo "BEGIN TRANSACTION;" >> "$temp_file"

# make cell changes
for ((i=0;i<changes;i++)) ; do
  echo "${change[i]};" >> "$temp_file"
done

# make row deletes
if [ $rows_deleted != 0 ] ; then
  for ((r=rows;r>0;r--)) ; do
    if [ ${row_deleted[r-1]} ] ; then
      echo "DELETE FROM $table where ROWID IS ${rowid[r-1]};" >> "$temp_file"
    fi
  done
fi

echo "COMMIT;" >> "$temp_file"
# vacuum does NOT guarantee ROWIDs will become sequential.  it CAN change them however.  sometimes it just leaves holes so don't rely on ROWID being squential after a vacuum
#if [ $rows_deleted != 0 ] ; then
#  echo "VACUUM;" >> "$temp_file"
#fi
echo "\"" >> "$temp_file"
}



############################################################
###  DO SQL
############################################################

do_sql () {
# do an SQL command - handles database retries, locking, and logging

# do_sql $LINENO "TRY" "COMMAND"
# do_sql $LINENO "TRY" "COMMAND" 19  # allowable error code is optional, -1 means immediately return any errors to caller
local line command tryto permitted returnerrors
     line=$1
    tryto=$2
  command=$3
if [ ${#@} -gt 3 ] ; then
  permitted=$4
else
  permitted=""
fi
if [ "$permitted" == "-1" ] ; then
  returnerrors=1
elif [ -n "$permitted" ] ; then
  tryto="$tryto (allow RC=$permitted)"
fi
debug "trying to $tryto"
log_sql "LINE $line: sqlite3 \"$database\" \"$command\""
debug "CMD: sqlite3 \"$database\" \"$command\""
if ! [ -r "$database" ] ; then
  # database does not exist or we don't have permission to read it
  abort $LINENO "database not accessible: \"$database\""
fi
#result=$(sqlite3 "$database" "$command") ; rc=$?
set +e  # catch squlite3 errors instead of crashing
if [ $switch_debug_sql ] ; then
  result=$(sqlite3  "$database" "$command" 2>> "$debug_file") ; sql_rc=$?
else
  result=$(sqlite3  "$database" "$command" 2> /dev/null) ; sql_rc=$?
fi
set -e

log_sql "RC=$sql_rc"
# RC=1  database is not found OR ANY OTHER ERROR OCCURS (like table not found) - the genericness of this return code is infuriating
# RC=5  database is locked by another database process
# RC=8  insufficient rights (check database owner and permissions)
# RC=19 attempt to insert a row or update a cell using a duplicate value in a unique column
# since rc=1 could be DB not found or "anything else", test for db.  if found, we will treat code 1 as "try again"
# sometimes getting RC=5 trying to open a locked database, it's NOT erroring out for some reason, just opens blank database - recoded, may be fixed
if [[ ($sql_rc == 0) || ($sql_rc == $permitted) ]] ; then
  # succeeded on first try
  return
elif [ $returnerrors ] ; then
  # RC != 0 but caller wants to deal with any errors, so return error to caller instead of retrying command
  return
fi
log_sql "retrying command"
for ((t=1;t<=max_db_attempts;t++)) ; do
  # database is probably locked by another instance of sqlite3
  sleep_millis 100
  log_sql "retrying"
  set +e
  result=$(sqlite3 "$database" "$command" 2> /dev/null) ; rc=$?
  set -e
  if [[ ($rc == 0) || ($rc == $permitted) ]] ; then
    log_sql "query succeeded with RC=$rc after $t retries"
    return 0
  fi
  # no need to test for returnerrors
  log_sql "failed again, RC=$rc"
done
abort $line "SQL QUERY FAILED after $max_db_attempts retries with CMD: sqlite3 \"$database\" \"$command\" ($tryto)"
}





########################################################################################################################
########################################################################################################################
###
###  ANSI FUNCTIONS
###
########################################################################################################################
########################################################################################################################

# this is not a function, this entire block is executed before startup to define variables

# https://en.wikipedia.org/wiki/ANSI_escape_code
# https://en.wikipedia.org/wiki/Box-drawing_character

# ansi charcters should be printed via:   echo -ne "stringtoprint", and ansi streaming must be on at the time


############################################################
###  ANSI ART CHARACTER STREAMING
############################################################

# VT100 character streaming
# normal printable ascii echoed while streaming is on will be displayed using ansi characters instead of the default terminal font
# used primarily for drawing popup and table borders, and colored text
ansi_cmd_streamon=$'\033(0'
ansi_cmd_streamoff=$'\033(B'



############################################################
###  BOXES AND TABLES
############################################################

# VT100 characters for drawing box and table borders (there are other characters in that range but no others that are very useful)
   ansi_lr="\x6A"
   ansi_ur="\x6B"
   ansi_ul="\x6C"
   ansi_ll="\x6D"
ansi_cross="\x6E"
 ansi_dash="\x71"
   ansi_tr="\x74"
   ansi_tl="\x75"
   ansi_tu="\x76"
   ansi_td="\x77"
 ansi_pipe="\x78"

ansi_bullet="\xE2\x80\xA2"  # to mark deleted rows

# table border and heading colors
table_color_border="\033[1;97;44m"     # window boxes are bold bright grey on dark blue
table_color_header="\033[0;93;44m"     # headers are medium bright yellow on dark blue
table_color_del="\033[1;93;41m"        # bold bright yellow on dark red

# regular box colors
box_color_border="\033[1;93;46m"       # box borders and title are bold bright yellow on dark cyan
box_color_interior="\033[0;97;104m"    # box interior defaults to normal bright grey on light blue (initially filled with spaces) - message text default

# popup box border colors
popup_color_browsing="\033[0;97;104m"  # unselected popup options are normal bright grey on light blue (same as box_color_interior?)
popup_color_selected="\033[0;97;45m"   # selected popup options are normal brightt grey on dark magenta



############################################################
###  TABLE COLORS
############################################################

# you can press keys 1-6 while a popup menu is being displayed to experiment with box and text colors (+shift to reverse cycle direction)

# text:       faint / normal / bold
#             dark / bright
#             black / red / green / yellow / blue / magenta / cyan / grey

# background: light / dark
#             black / red / green / yellow / blue / magenta / cyan / grey

# no, there is no "white".  There is only "grey".  "bright grey" is very close to white however.

# database table cell colors:    # MODE      BLANK     STATUS                TEXT             BACKGROUND
                                 # --------  --------  ---------     ---------------------    ----------
cell_color_bnu="\033[0;96;44m"   # browsing  nonblank  unchanged     normal bright cyan       dark  blue
cell_color_bnc="\033[0;95;44m"   # browsing  nonblank  changed       normal bright magenta    dark  blue  # tried bolding that, and it stands out better, but isn't as clear to read
cell_color_bnw="\033[1;93;41m"   # browsing  nonblank  warning       bold   bright yellow     dark  red
cell_color_bnr="\033[0;96;101m"  # browsing  nonblank  reloaded      normal bright cyan       dark  red
cell_color_bbu="\033[2;37;44m"   # browsing  blank     unchanged     faint  dark   grey       dark  blue
cell_color_bbc="\033[0;91;44m"   # browsing  blank     changed       normal bright red        dark  blue
cell_color_bbw="\033[1;93;41m"   # browsing  blank     warning       bold   bright yellow     dark  red
cell_color_bbr="\033[2;97;101m"  # browsing  blank     reloaded      faint  dark   grey       dark  red
cell_color_snu="\033[0;97;46m"   # selected  nonblank  unchanged     normal bright grey       dark  cyan
cell_color_snc="\033[1;95;46m"   # selected  nonblank  changed       bold   bright magenta    dark  cyan  # normally it would be normal text, but it gets washed out in the light cyan without being bold
cell_color_snw="\033[1;93;101m"  # selected  nonblank  warning       bold   bright yellow     light red
cell_color_snr="\033[1;93;101m"  # selected  nonblank  reloaded      bold   bright yellow     dark  red
cell_color_sbu="\033[0;96;46m"   # selected  blank     unchanged     normal bright cyan       dark  cyan
cell_color_sbc="\033[1;95;46m"   # selected  blank     changed       bold   bright magenta    dark  cyan
cell_color_sbw="\033[1;93;101m"  # selected  blank     warning       bold   bright yellow     light red
cell_color_sbr="\033[1;97;101m"  # selected  blank     reloaded      bold   dark   grey       dark  red
cell_color_edt="\033[0;97;45m"   # editing   any       any           normal bright grey       dark  magenta
cell_color_inu="\033[1;96;104m"  # inactive  nonblank  unchanged     normal bright cyan       dark  blue    # inactive cell colors, when a popup or menu is being displayed
cell_color_ibu="\033[1;90;104m"  # inactive  blank     unchanged     faint  bright grey       dark  blue

cell_color_bug="\033[1;31;103m"  #                                   bold   dark   red        light yellow   # while debugging ANSI screen painting, clear screen to this color to see what's not getting repainted properly

# popup option colors:           # MODE      ENABLED           TEXT             BACKGROUND
                                 # --------  --------  ---------------------    ----------
pop_color_bren="\033[0;97;44m"   # browsing  enabled   normal bright grey       dark  blue
pop_color_brdi="\033[2;96;44m"   # browsing  disabled  faint  bright cyan       dark  blue
pop_color_seen="\033[0;97;105m"  # selected  enabled   normal bright grey       light magenta
pop_color_sedi="\033[2;97;45m"   # selected  enabled   faint  bright grey       dark  magenta   can't select the disabled though

# cell status is stored in cell_status[] - use this enumeration instead of the liternal numbers
cell_status_unchanged=0
cell_status_changed=1
cell_status_warning=2
cell_status_reloaded=3  # reloaded cells are always unchanged.  when a reloaded cell is changed, it changes to cell_status_changed.  when a window is refreshed, all reloaded cells are changed to cell_status_changed

# cell mode is specified by caller when calling DRAW_CELL - use this enumeration instead of the liternal numbers
cell_mode_browsing=0
cell_mode_selected=1
cell_mode_editing=2
cell_mode_inactive=3  # selected cell is inactive while menus and popups are being displayed

# menu bar colors:              # MODE              TEXT             BACKGROUND
                                # --------  ---------------------    ----------
menu_color_br="\033[1;97;100m"  # browsing  bold   bright grey       light black
menu_color_se="\033[1;97;105m"  # selected  bold   bright grey       light magenta
menu_color_op="\033[1;37;45m"   # opened    bold   faint  grey       dark  magenda

# "press RETURN" prompt color
return_color="\033[1;97;105m"   #           bold   bright grey       light magenta

# color of notice displayed at the bottom of the screen following certain actions
notice_color="\033[0;93;41m"    #           normal bright yellow     dark  red



############################################################
###  LONG STRINGS
############################################################

# make some ansi dashes similar to spaces
# note that ansi_dashes are NOT one character long, you will need to multipliy required length by ${#ansi_dash} when printing a specific number of these characters
ansi_dashes=""
dashes=""
spaces=""
for ((i=0;i<max_terminal_width;i++)) ; do
  ansi_dashes="$ansi_dashes$ansi_dash"
  dashes="${dashes}-"
  spaces="${spaces} "
done



############################################################
###  OTHER ANSI COMMANDS
############################################################

ansi_cmd_coloroff="\033[m"      # reset colors to default (does NOT reset settings changed by stty)
ansi_cmd_cursoroff="\033[?25l"  # hide cursor
ansi_cmd_cursoron="\033[?25h"   # show cursor
ansi_cmd_cls="\033[2J"          # clear screen to default color (does not move cursor)  runs just about as fast as "clear" (calls same code?)
ansi_cmd_home="\033[;H"         # home cursor to top-left (clears screen to current color)



############################################################
### GOTO X,Y
############################################################

goto_xy () {
# go to x/y position on screen.  0-based, with 0,0 being upper-left corner
# note that ANSI coordinates are specified as 1-based so we have to adjust them (they are also specified in y,x order, aka row,col)

# goto_xy 222 4 crashes when COLUMNS=222

local x y
x=$1
y=$2
if [ $x -lt 0 ] ; then
  x=0
fi
if [ $x -ge $COLUMNS ] ; then
  ((x=$COLUMNS-1))
fi
#yy="Z"
#yy=$((y))
#if [ "$yy" != "$y" ] ; then
#  debug "ERROR, y = \"$y\", yy = \"$yy\""
#  exit
#fi


if [ $y -lt 0 ] ; then
  y=0
fi
if [ $y -ge $COLUMNS ] ; then
  ((y=$LINES-1))
fi

echo -ne "\033[$((y+1));$((x+1))H"

}



############################################################
###  HOME
############################################################

home () {
# the screen will be cleared based on the current ANSI text color, so be sure to reset it before clearing

if [ $switch_debug_ansi ] ; then
  # debugging ansi, always clear screen to easily spotted color
  echo -ne "$cell_color_bug$ansi_cmd_cls$ansi_cmd_home"  # unexpectedly, on Mac OS Terminal this seems to behave exactly like clear, generating a new page of text
  lastnotice=""
elif [[ (${#@} != 0) || (! $home_ran) ]] ; then
  # not debugging, but caller has requested a screen clear (or this is the first call to home) so clear to table border backcolor
  echo -ne "$table_color_border$ansi_cmd_cls$ansi_cmd_home"  # unexpectedly, on Mac OS Terminal this seems to behave exactly like clear, generating a new page of text
  lastnotice=""
else
  # nothing special, just home the cursor
  goto_xy 0 0
fi
home_ran=1
return
}
home_ran=





########################################################################################################################
########################################################################################################################
###
###  WINDOW FUNCTIONS
###
########################################################################################################################
########################################################################################################################


############################################################
###  DEFINE WINDOW AT
############################################################

define_window_at () {
# define the table's window at a specified (upper-left) row,column
# pre-renders the window headings and blank table lines to be printed into by draw_cell

local rd rs rh c
if [ ${#@} != 1 ] ; then
  # use specified upper-left cell if provided (otherwise use current and just recalculate window parameters)
  debug "DEFINE_WINDOW_AT from line $1, use specified window_top_row=$2, window_left_column=$3"
  window_top_row=$2
  window_left_column=$3
else
  debug "DEFINE_WINDOW_AT from line $1, use current window_top_row=$window_top_row, window_left_column=$window_left_column"
fi
window_columns=0
((window_rows=$LINES-7))
((r=rows-window_top_row))
debug "window_rows = $window_rows, r=$r"
if [ $window_rows -gt $r ] ; then
  # part of the end of the database is visible at the bottom of the screen
  window_rows=$r
fi
window_width=1  # window width ONLY considers fully visible columns, so the rightmost column that's offscreen will NOT be counted
debug "define window at $window_top_row $window_left_column"
# probe to the right to see how many columns we can completely fit across the screen
while [[ ($window_width -lt $COLUMNS) && ($((window_left_column+window_columns)) -lt $columns) ]] ; do
  if [ $((window_width+${column_width[window_left_column+window_columns]}+2)) -ge $COLUMNS ] ; then
    #debug "next column $window_columns is too wide"
    break
  fi
  #debug "next column $window_columns fits"
  ((window_col_x[window_columns]=window_width+1))
  window_heading[window_columns]=${column_name[window_left_column+window_columns]}
  window_colsize[window_columns]=${column_width[window_left_column+window_columns]}
  ((window_width=window_width+column_width[window_left_column+window_columns]+3))
  #debug "defined column $window_columns with heading \"${window_heading[window_columns]}\", width ${window_colsize[window_columns]}, at ${window_col_x[window_columns]}"
  ((window_columns++))
  #debug "columns = $columns, we're ready to display $((window_left_column+window_columns)) columns"
done

# record one more column since it's probably partly visible and goto_cell will need it
# (if the rightmost column is entirely visible on the screen, this column does not exist)
((window_col_x[window_columns]=window_width+1))
# and this will probably need to be trimmed down
((window_colsize[window_columns]=COLUMNS-window_width-2))  # normally -2 needed because draw_cell will append a space on the end which will wrap and erase the pipe at the start of the next line
debug "window width is $window_width"

if [ $window_columns == $columns ] ; then
  debug "rightmost column in window is end of table"
else
  debug "rightmost column in window is column $((window_left_column+window_columns-1))"
fi
((window_lines=LINES-7))

# create the default row strings for faster rereshing
if [ $window_left_column == 0 ] ; then
  # left side of table is on left side of window
  window_row_divtop=$table_color_border$ansi_cmd_streamon$ansi_ul
  window_row_header=$table_color_border$ansi_cmd_streamon$ansi_pipe
  window_row_divdat=$table_color_border$ansi_cmd_streamon$ansi_pipe
  window_row_divdel=$table_color_del$ansi_cmd_streamon$ansi_bullet$table_color_border
  window_row_divmid=$table_color_border$ansi_cmd_streamon$ansi_tr
  window_row_divbot=$table_color_border$ansi_cmd_streamon$ansi_ll
else
  # left side of table is off screen to the left
  window_row_divtop=$table_color_border$ansi_cmd_streamon$ansi_td
  window_row_header=$table_color_border$ansi_cmd_streamon$ansi_pipe
  window_row_divdat=$table_color_border$ansi_cmd_streamon$ansi_pipe
  window_row_divdel=$table_color_del$ansi_cmd_streamon$ansi_bullet$table_color_border
  window_row_divmid=$table_color_border$ansi_cmd_streamon$ansi_cross
  window_row_divbot=$table_color_border$ansi_cmd_streamon$ansi_tu
fi
table_width=1

# create the empty table rows and dividers - also determines displayed table and column widths
for ((c=0;c<window_columns;c++)) ; do
  n=${ansi_dashes:0:${#ansi_dash}*(${window_colsize[c]}+2)}
  h="${window_heading[c]}$spaces"
  h="$ansi_cmd_streamoff$table_color_header ${h:0:window_colsize[c]} $table_color_border$ansi_cmd_streamon"
  window_row_divtop="$window_row_divtop$n"
  window_row_header="$window_row_header$h"
  window_row_divdat="$window_row_divdat${spaces:0:window_colsize[c]+2}"
  window_row_divdel="$window_row_divdel${spaces:0:window_colsize[c]+2}"
  # add a default color blank cell to the default rowbuf
    rowbufdiv[c]=${spaces:0:window_colsize[c]}
  window_row_divmid="$window_row_divmid$n"
  window_row_divbot="$window_row_divbot$n"
  ((table_width=table_width+window_colsize[c]+2))
  if [ $c == $(($window_columns-1)) ] ; then
    # last column on right of window is different
    if [ $((c+window_left_column)) == $((columns-1)) ] ; then
      # right side of table is on the far right of window
      window_row_divtop="$window_row_divtop$ansi_ur$ansi_cmd_streamoff"
      window_row_header="$window_row_header$ansi_pipe$ansi_cmd_streamoff"
      window_row_divdat="$window_row_divdat$ansi_pipe$ansi_cmd_streamoff"
      window_row_divdel="$window_row_divdel$ansi_pipe$ansi_cmd_streamoff"
      window_row_divmid="$window_row_divmid$ansi_tl$ansi_cmd_streamoff"
      window_row_divbot="$window_row_divbot$ansi_lr$ansi_cmd_streamoff"
      ((table_width++))
    else
      # right side of table is off screen to the right
      ((rw=COLUMNS-window_width))  # this can be as low as zero, indicating the rightmost column onscreen contains a divider
      # making a partial column
      rd=${ansi_dashes:0:${#ansi_dash}*rw}
      rs=${spaces:0:rw}
      if [ $rw -le 2 ] ; then
        debug "nothing of this header is visible"  #  (the header and data cells don't render in the rightmost column on the screen, only the borders do)
        rh0=""
      else
        #debug "some of this header is visible"
        rh0=" ${column_name[window_left_column+window_columns]:0:rw-2}$spaces"
      fi
      rh="$ansi_cmd_streamoff$table_color_header${rh0:0:rw}$table_color_border$ansi_cmd_streamon"
      window_row_divtop="$window_row_divtop$ansi_td$rd$ansi_cmd_streamoff"
      window_row_header="$window_row_header$ansi_pipe$rh$ansi_cmd_streamoff"
      window_row_divdat="$window_row_divdat$ansi_pipe$rs$ansi_cmd_streamoff"
      window_row_divdel="$window_row_divdel$ansi_pipe$rs$ansi_cmd_streamoff"
      window_row_divmid="$window_row_divmid$ansi_cross$rd$ansi_cmd_streamoff"
      window_row_divbot="$window_row_divbot$ansi_tu$rd$ansi_cmd_streamoff"
      ((table_width=table_width+rw+1))
    fi
  else
    # not last column on right of window
    window_row_divtop="$window_row_divtop$ansi_td"
    window_row_header="$window_row_header$ansi_pipe"
    window_row_divdat="$window_row_divdat$ansi_pipe"
    window_row_divdel="$window_row_divdel$ansi_pipe"
    window_row_divmid="$window_row_divmid$ansi_cross"
    window_row_divbot="$window_row_divbot$ansi_tu"
    ((table_width++))
  fi
done
debug "defined table_width = $table_width"

# menubar line
# the problem here is that window_row_menubar and window_row_divft1 can be LONGER than table_width if the table is very small
#  window_row_menubar="$menu_color_br$window_row_menubar${spaces:0:table_width-${#window_row_menubar}}"
window_row_menubar="$menu_color_br$window_row_menubar_plain$table_color_border${spaces:0:COLUMNS-${#window_row_menubar_plain}}"
# $COLUMNS=220, right arrow to groups column in checkins.db,  error: COLUMNS-${#window_row_menubar}: substring expression < 0

# rowinfo line - gets messy because it contains multiple variable-length fields
local d2
d2=${database##*/}
# window_row_divft1="$table_color_header                         Database: $d2    Table: $table${spaces:0:table_width-${#d2}-${#table}-59}$vers "
# the problem here is that window_row_menubar and window_row_divft1 can be LONGER than table_width if the table is very small
# calculate rowinfo spacing between table name and version info
#debug "window_row_divft1 = \"$window_row_divft1\""
((w=table_width-${#d2}-${#table}-65))
#debug "initial            w = $w"
#debug "initial  table_width = $table_width"
#debug "initial window_width = $window_width"
#debug "initial      COLUMNS = $COLUMNS"
if [ $w -lt 4 ] ; then
  # rowinfo is wider than table
  w=4
  debug "raising w to $w"
fi
# insert spacing
window_row_divft1="${spaces:0:25}Database: $d2          Table: $table${spaces:0:w}$vers "  # change the "((w=" line above if you change the length of this
#debug "spacing inserted, window_row_divft1 = \"$window_row_divft1\""
# pad end
window_row_divft1="$window_row_divft1${spaces:0:COLUMNS-${#window_row_divft1}}"
#debug "window_row_divft1 = \"$window_row_divft1\""
# colorize
window_row_divft1="$table_color_header$window_row_divft1"
#debug "window_row_divft1 = \"$window_row_divft1\""

# notice line
window_row_divft2="$table_color_header${spaces:0:table_width}"

# lastly, pad all the rows with spaces to fill the gap between the end of the table and end of the window (if any)
((pad=COLUMNS-table_width))
pad="${spaces:0:pad}"
#debug "    COLUMNS=\"$COLUMNS\""
#debug "table_width=\"$table_width\""
#debug "        pad=\"$pad\""

#window_row_menubar="${window_row_menubar}$tpad"
 window_row_divtop="${window_row_divtop}$pad"
 window_row_header="${window_row_header}$pad"
 window_row_divdat="${window_row_divdat}$pad"
 window_row_divdel="${window_row_divdel}$pad"
 window_row_divmid="${window_row_divmid}$pad"
 window_row_divbot="${window_row_divbot}$pad"
#window_row_divft1="${window_row_divft1}$pad"
 window_row_divft2="${window_row_divft2}$pad"

}
# that was VERY tricky to get completely correct.  use great care if you need to edit any of that, there are MANY edge cases with regard to window width



############################################################
###  DRAW NOTICE
############################################################

draw_notice () {
# draw the specified new notice at the bottom of the screen - disappears when the selection is moved - used mainly for "action completed" and "action failed" messages

if [ "$lastnotice" ==  "$1" ] ; then
  # no change to notice
  return
fi
# notice has changed, blank previous (either because it may now be blank, OR the new notice may be shorter than the previous notice)
goto_xy 0 $((LINES-1))
echo -ne "$table_color_border${spaces:0:$COLUMNS-14}"  # don't erase version number
lastnotice="$1"
if [ -n "$lastnotice" ] ; then
  # new notice is not blank, draw it
  goto_xy 0 $((LINES-1))
  echo -ne "$notice_color $lastnotice "
fi
}



############################################################
###  DRAW ERROR
############################################################

draw_error () {
# draw the specified new notice at the bottom of the screen (as a notice) and beep

if [ ${#@} == 0 ] ; then
  draw_notice
  return
fi
draw_notice "$1"
echo -n $'\a'
}



############################################################
###  CLEAR NOTICE
############################################################

clear_notice () {
# clear the notice - supply any $1 to force the clear even if it thought it was clear to begin with

if [ ${#@} != 0 ] ; then
  # force notice to be redrawn (even if blank)
  lastnotice="clearme"
fi
draw_notice ""
}



############################################################
###  DRAW ROWINFO
############################################################

draw_rowinfo () {
# redraw the row info line, second from the bottom of the screen - also clear last notice

local a b n
if [ $rows == 0 ] ; then
  # selection is sitting on the end marker because there's no rows to sit on
  a="    0"
  b="    $rows"
  c="    1"
else
  a="    $((sel_row+1))"
  b="    $rows"
  c="    ${rowid[sel_row]}"
fi
if [ $switch_debug_rowid ] ; then
  n="[ ${a:${#a}-5}/${b:${#b}-5} ] ${c:${#c}-5}"
else
  n="[ ${a:${#a}-5}/${b:${#b}-5} ]"
fi
if [ $switch_readonly ] ; then
  n="$n ${cell_color_sbw} R"
elif [[ ($changes == 0) && ($rows_deleted == 0) ]] ; then
  n="$n   "  # this needs to be 3 spaces, should need 2, not sure why the * isn't getting overwritten with 2 - tired of hunting for an explanation, this just works
else
  # indicate changes were made
  n="$n ${cell_color_bnc} *"
fi
goto_xy 0 $((LINES-2))
echo -e "${table_color_header}${n}"
# clear the last notice if any
clear_notice
}



############################################################
### DRAW CELL
############################################################

draw_cell () {
# draw one cell, position is relative to database, not window
# we may be drawing the actual cell data (browsing) or the cell while it is being edited
# also this cell may be partly offscreen to the right - does not print in the last character column on the right of the screen
# (the last character column DOES print table borders however, just not cell contents)
# this is arguably the most important display code in the program, and needs to run as fast as possible because it repaints the entire table
# there must be no loops here, it needs to be fast, flat code
# unfortunately it's also fairly complex and difficult to debug despite not being especially long
# relies on define_window presetting variables correctly

local n x y c
  got_data=$1  # cell data (may be blank)
   got_row=$2  # database row
   got_col=$3  # database column
got_status=$4  # cell status (0=unchanged, 1=changed, 2=warning, 3=reloaded)
  got_mode=$5  # mode (0=browse, 1=select, 2=edit)

# figure out exactly what to print and in what color scheme
# blank cells are handled specially
# since this loop is called n^2 times during a drawtable, it's slightly optimized for speed - most common possibilites are handled first
if [ $got_mode == $cell_mode_browsing ] ; then
  # browsing
  if [ $got_status == $cell_status_unchanged ] ; then
    # unchanged
    if [ -z "$got_data" ] ; then
      # blank
      cc=$cell_color_bbu
      got_data="(blank)"
    else
      # nonblank
      cc=$cell_color_bnu
    fi
  elif [ $got_status == $cell_status_changed ] ; then
    # changed
    if [ -z "$got_data" ] ; then
      # blank
      cc=$cell_color_bbc
      got_data="(blank)"
    else
      # nonblank
      cc=$cell_color_bnc
    fi
  elif [ $got_status == $cell_status_warning ] ; then
    # warning (don't care about blank)
    cc=$cell_color_bnw  # (or bbw)
  elif [ $got_status == $cell_status_reloaded ] ; then
    # reloaded (changed when relaoded)
    if [ -z "$got_data" ] ; then
      # blank
      cc=$cell_color_bbr
      got_data="(blank)"
    else
      # nonblank
      cc=$cell_color_bnr
    fi
  else
    # invalid cell status
    halt "draw_cell got invalid cell status \"$got_status\" at $got_row,$got_col drawing \"$got_data\""
  fi
elif [ $got_mode == $cell_mode_editing ] ; then
  # editing (don't care about status/warning/blank)
  cc=$cell_color_edt
elif [ $got_mode == $cell_mode_inactive ] ; then
  # inactive (probably navigating a menu)
  if [ -z "$got_data" ] ; then
    # blank
    cc=$cell_color_ibu
    got_data="(blank)"
  else
    cc=$cell_color_inu
  fi
elif [ $got_mode != $cell_mode_selected ] ; then
  halt "draw_cell got invalid cell mode \"$got_mode\" at $got_row,$got_col drawing \"$got_data\""
else  # cell_mode_selected
  # selected
  if [ $got_status == $cell_status_unchanged ] ; then
    # unchanged
    if [ -z "$got_data" ] ; then
      # blank
      cc=$cell_color_sbu
      got_data="(blank)"
    else
      # nonblank
      cc=$cell_color_snu
    fi
  elif [ $got_status == $cell_status_changed ] ; then
    # changed
    if [ -z "$got_data" ] ; then
      # blank
      cc=$cell_color_sbc
      got_data="(blank)"
    else
      # nonblank
      cc=$cell_color_snc
    fi
  elif [ $got_status == $cell_status_reloaded ] ; then
    # reloaded selected
    if [ -z "$got_data" ] ; then
      # blank
      cc=$cell_color_sbr
      got_data="(blank)"
    else
      # nonblank
      cc=$cell_color_snr
    fi
  else
    # warning (don't care about blank)
    cc=$cell_color_snw  # (or sbw)
  fi
fi
n="$got_data$spaces"

# do not draw if we are JUST on the outside of the right of the window (bash crashes unhelpfully, or segfault...)
if [ ${window_col_x[got_col-window_left_column]} == $COLUMNS ] ; then
  return
fi

# move cursor
# this step can't be skipped when redrawing the entire table because we're jumping over the cell borders
goto_cell $((got_row+1)) $got_col 0
#debug "drawing at $got_row,$got_col, wwl=$wwl"

# make sure we're not off window to the left (should be debugged at this point, may be abe to remove this bit)
((a=got_col-window_left_column))
if [ $a -lt 0 ] ; then
  # attempting to draw outside window is a bug
  debug "a=$a\""
  debug "got_col=$got_col\""
  debug "window_left_column=$window_left_column\""
fi

# draw the cell if it's not on the far right edge
((a=window_colsize[got_col-window_left_column]))  # how wide the column is on screen (may be inflated by width of header)
b=${column_size[got_col]}  # the width of the data field itself
if [ $a -gt $b ] ; then
  # shrink it
  a=$b
fi
#debug "wc = \"${window_colsize[got_col-window_left_column]}\""
if [ $a -gt 0 ] ; then
  # it will be less than 1 if it's on the right and out of view
  echo -ne "$cc${n:0:a}$ansi_cmd_coloroff"
fi

}


############################################################
###  DRAW TABLE
############################################################

draw_table () {
# draw table into window, using default cell colors (modified cells will have a different color index) - does NOT clear the screen
# expects the default pre-rendered table rows with their borders and column dividers to already be present

local r wr c i we
draw_rowinfo
((r=window_top_row))

# special case for empty database
if [ $sel_row != $((window_top_row+window_rows)) ] ; then
  ((we=window_rows))
else
  #debug "sel_row = \"$sel_row\", window_rows = \"$window_rows\""
  # the 'end' row is selected, so populate it all (either deleted the only row or opened an empty table)
  ((we=window_rows+1))
fi

# draw all visible rows
for ((wr=0;wr<we;wr++)) ; do
  c=$window_left_column
  for ((wc=0;wc<$window_columns;wc++)) ; do
    ((i=r*columns+c))
    draw_cell "${cell_data[i]}" $r $c ${cell_status[i]} $cell_mode_browsing
    ((c++))
  done
  # now probably display a partial column
  if [ $wc -lt $((columns-window_left_column)) ] ; then
    ((i=r*columns+c))
    # draw_cell will need to be aware of the possibility of a short (or zero length?) cell due to screen truncation
    draw_cell "${cell_data[i]}" $r $c ${cell_status[i]} $cell_mode_browsing
  fi
  
  ((r++))
done

# also draw the current row selection at the bottom
draw_rowinfo
}



############################################################
###  RESIZE_WINDOW
############################################################

# trigger terminal to resize the window

resize_window () {
# pass in width and height.  will cause a SIGWINCH so only do this while browsing

local got_cols got_rows
got_cols=$1
got_rows=$2
debug "about to resize window to $got_cols x $got_rows"
echo -ne "\033[8;${got_rows};${got_cols}t"
}



############################################################
###  DRAW WINDOW
############################################################

draw_window () {
# clear the screen by drawing a predefined empty window with headers and footers - does not draw rowinfo or notice

# make sure live window resizing is re-enabled - not all popups call box_close
local r
popup_blocking_resize=

home
echo -e "$window_row_menubar"
echo -e "$window_row_divtop"
echo -e "$window_row_header"
echo -e "$window_row_divmid"
for ((r=0;r<window_lines;r++)) ; do
  if [ $r -ge $((rows-window_top_row)) ] ; then
    # past end of table
    echo -e "$window_row_divdat"
  elif [ ${row_deleted[window_top_row+r]} ] ; then
    # row is marked for delete
    echo -e "$window_row_divdel"
  else
    # row is normal data
    echo -e "$window_row_divdat"
  fi
done
echo -e "$window_row_divbot"
echo -e "$window_row_divft1"
echo -ne "$window_row_divft2"
}



############################################################
###  CLEAR RELOADS
############################################################

clear_reloads () {
# clear any reload cell status

local i i2

# clear reload indicators
((i2=rows*columns))
for ((i=0;i<i2;i++)) ; do
  if [ ${cell_status[i]} == $cell_status_reloaded ] ; then
    cell_status[i]=$cell_status_unchanged
  fi
done

}



############################################################
###  REFRESH WINDOW
############################################################

refresh_window () {
# clear the screen and redraw the window and table.  optionally supply a notice to display at the bottom too

draw_window
draw_table
draw_rowinfo
if [ ${#@} != 0 ] ; then
  draw_notice "$1"
fi

}



############################################################
###  GOTO CELL
############################################################

goto_cell () {
# move cursor to start of cell plus specified index (if any)
# index probably only used during cell editing, for placement of cursor

local r c
got_row=$1
got_col=$2
got_index=$3
if [ -z "$got_index" ] ; then
  got_index=0
fi
((r=got_row-window_top_row))
((c=got_col-window_left_column))
((x=window_col_x[c]+got_index))
((y=r+3))
#debug "goto $x,$y"

goto_xy $x $y $LINENO

((wwl=COLUMNS-x))  # window width left, before leaving right side of screen.  pass this back to the caller for debugging purposes in draw_cell
}



############################################################
###  RENDER TEST
############################################################

# redraw the entire window ten times to see how fast it can paint
# only meaningful locally, not over ssh (due to network latency)

render_test () {
# performance testing - see how long it takes to draw ten screens
local i t0 t1 t2
t0=$(millis)
for ((i=0;i<10;i++)) ; do
  refresh_window
done
t1=$(millis)
((t2=t1-t0))

box_popup 60 5 "RENDER TEST"
if [ ! $popup_ok ] ; then
  # window isn't tall enough
  return
fi

box_print "Render test complete, $i screen draws in $t2 milliseconds"
box_press_return
}



#########################################
###  SCROLL CHECK
#########################################

scroll_check () {
# called whenever the cell selection is moved - scrolls the window if necessary to keep the selected cell visible
# needs to run fast because user may be holding an up or down arrow key

local always_define scrolled
if [ ${#@} != 0 ] ; then
  always_define=1
else
  always_define=
fi
scrolled=

### scrolling up

if [ $sel_row -le $((window_top_row-1)) ] ; then
  debug "need to scroll up from $window_top_row"
  while [ $sel_row -le $((window_top_row-1)) ] ; do
    # scroll up a page at a time until selection is visible
    ((window_top_row-=window_lines/2))
  done
  if [ $window_top_row -lt 0 ] ; then
    window_top_row=0
  fi
  # adjust window values
  define_window_at $LINENO
  refresh_window
  debug "new window_top_row = $window_top_row"
  scrolled=1
fi

### scrolling down

if [ $sel_row -ge $((window_top_row+window_lines)) ] ; then
  debug "need to scroll down from $window_top_row"
  while [ $sel_row -ge $((window_top_row+window_lines)) ] ; do
    # scroll down a page at a time until selection is visible
    ((window_top_row+=window_lines/2))
  done
  # adjust window values
  define_window_at $LINENO
  refresh_window
  debug "new window_top_row = $window_top_row"
  scrolled=1
fi

### scrolling left

if [ $sel_col -lt $window_left_column ] ; then
  # move one column at a time until we can see it
  while [ $sel_col -lt $window_left_column ] ; do
    define_window_at $LINENO $window_top_row $((window_left_column-1))
  done
  refresh_window
  debug "new window_left_column = $window_left_column"
  scrolled=1
fi

### scrolling right

if [ $sel_col -ge $((window_left_column+window_columns)) ] ; then
  while [ $sel_col -ge $((window_left_column+window_columns)) ] ; do
    # scroll right one column at a time until the selected column is visible (may not end up on the far right of the visible window)
    # scrolling right is tricky because we may need to move more than one column
    debug "scrolling right from $window_top_row,$window_left_column to $window_top_row,$((window_left_column+1))"
    define_window_at $LINENO $window_top_row $((window_left_column+1))
    # a scroll to the right could cause left_column to increment AND window_columns to *decrement*, where we need to repeat this loop, possibly several times
  done
  refresh_window
  debug "new window_left_column = $window_left_column"
  scrolled=1
fi

# if we were told to ALWAYS define the window, even if we don't scroll
if [[ ($always_define) && (-z "$scrolled") ]] ; then
  define_window_at $LINENO
  refresh_window
fi

}



#########################################
### TERMINAL RESIZED
#########################################

# terminal window resizing is very disruptive to any fullscreen GUI
# resizing the terminal window during a cell edit is probably impractical, and is therefore disabled while editing  ("don't DO that")
# since dragging a window corner will call this several times in rapid succession, we will delay 1 second before acting, to allow the window to settle
# it may also misfire once after we handle it, so ignore SIGWINCH if row/col have not actually changed

trap terminal_resized SIGWINCH  # this was not an easy one to find.  trap calls terminal_resized when terminal window is resized by user.  (SIGnal WINdow CHange)

edit_blocking_resize=
terminal_resized () {
local i pcols plines
if [ $edit_blocking_resize ] ; then
  debug "edit blocks live resizing"
  return
elif [ $popup_blocking_resize ] ; then
  debug "popup blocks live resizing"
  return
fi

sleep 1  # allow window to settle

# cache current setting and fetch current window size
((pcols=COLUMNS))
((plines=LINES))
unset COLUMNS  # must do this before asking tput for cols
COLUMNS=$(tput cols)
LINES=$(tput lines)

# if nothing changed, do nothing
if [[ ($COLUMNS == $pcols) && ($LINES == $plines) ]] ; then
  # we already made this adjustment, don't repaint the screen again
  debug "terminal_resized: no change"
  return
fi

# cap terminal width
if [ $COLUMNS -gt $max_terminal_width ] ; then
  COLUMNS=$max_terminal_width
fi

debug "resizing terminal window to $COLUMNS,$LINES"
define_window_at $LINENO
scroll_check
refresh_window

# redraw the selected cell as selected again
((i=sel_row*columns+sel_col))
draw_cell "${cell_data[i]}" $sel_row $sel_col ${cell_status[i]} $cell_mode_selected

# some routines can be resized but need to be notified to repaint some of their screen
repaint_me=1

}



#########################################
###  FAST QUIT
#########################################

# user hit ctrl-x, attempt to fast quit
# prompt for confirmation if there are unsaved changes

fast_quit () {

local window_refresh_needed
window_refresh_needed=$1

if [ "${changes:-X}" == "X" ] ; then
  # popup select cancelled before we even got a table open
  return_to_caller
fi


if [[ ($changes != 0) || ($rows_deleted != 0) ]] ; then
  # give them a chance to change their mind
  echo -n $'\a'  # donk
  popup_confirm "Throw away changes to ${table}?"
  #  popup_confirm always refreshes window when it exits, so we won't need to do it again
  window_refresh_needed=0
  if [ ! $confirmed ] ; then
    # they are having second-thoughts
    draw_notice "fast-quit cancelled"
    return
  fi
fi

# they really do want to throw away unsaved changes, or there are are no unsaved changes

if [ $window_refresh_needed == 1 ] ; then
  # open popups need to be erased
  refresh_window
fi

# remove the selected menu highlight
home
echo -ne "$window_row_menubar"

# remove highlight from seleted cell
((i=sel_row*columns+sel_col))
draw_cell "${cell_data[i]}" $sel_row $sel_col ${cell_status[i]} $cell_mode_browsing

# exit script
return_to_caller

}





########################################################################################################################
########################################################################################################################
###
###  BOX FUNCTIONS
###
########################################################################################################################
########################################################################################################################


#########################################
###  BOX POPUP
#########################################

box_popup () {
# display popup box and prepare to load with text or a menu
# if text, sub with text called us directly.  if popup, called indirectly from display_popup_menu
# note that borders are just outside this defined area, the specified width/height is for the CONTENTS of the box
# so the supplied dimensions are the area of USABLE space inside the borders that will be drawn

local i n f
box_width=$1
box_height=$2
box_title=$3
if [ ${#@} -ge 4 ] ; then
  box_menu_col=$4
else
  box_menu_col=""
fi

# make sure window is tall enough
LINES=$(tput lines)
if [ $LINES -lt $((box_height+2)) ] ; then
  draw_error "RESIZE WINDOW $((box_height+2-LINES)) LINES TALLER TO DISPLAY THIS POPUP"
  popup_ok=
  return
fi
popup_ok=1

box_y=0

if [ -n "$box_title" ] ; then
  box_title=" $box_title "
fi

# position the box
if [ -z "$box_menu_col" ] ; then
  # center it
  if [ $box_width -gt $COLUMNS ] ; then
    box_width=$columns
  fi
  if [ $box_height -ge $((LINES-2)) ] ; then
    box_height=$((LINES-2))
  fi
  ((box_top=(LINES-box_height)/2))
  ((box_left=(COLUMNS-box_width)/2))  # left based on screen width
  #((box_left=(window_width-box_width)/2))  # left based on window (fully visible table columns) width
else
  # position for menu
  ((box_left=box_menu_col+1))
  ((box_top=2))
fi

debug "popping box ${box_width}x${box_height} at ${box_left}x${box_top}"

# build the default box rows
((f=box_width-${#box_title}))
box_win_top="$box_color_border$ansi_cmd_streamon$ansi_ul${ansi_dashes:0:f/2*${#ansi_dash}}$ansi_cmd_streamoff$box_title$ansi_cmd_streamon${ansi_dashes:0:(f+1)/2*${#ansi_dash}}$ansi_ur$ansi_cmd_streamoff"
box_win_mid="$box_color_border$ansi_cmd_streamon$ansi_pipe$box_color_interior${spaces:0:box_width}$box_color_border$ansi_pipe$ansi_cmd_streamoff"
box_win_bot="$box_color_border$ansi_cmd_streamon$ansi_ll${ansi_dashes:0:${#ansi_dash}*box_width}$ansi_lr$ansi_cmd_streamoff"

# display inactive seleted cell if database is up and we have a title (not displaying a menu)
if [ $database_up ] ; then
  if [ -n "$box_title" ] ; then
    ((i=sel_row*columns+sel_col))
    draw_cell "${cell_data[i]}" $sel_row $sel_col ${cell_status[i]} $cell_mode_inactive
  fi
fi

# display the box
goto_xy $((box_left-1)) $((box_top-1))
echo -ne "$box_win_top"
for ((i=0;i<box_height;i++)) ; do
  goto_xy $((box_left-1)) $((box_top+i))
  echo -ne "$box_win_mid"
done
goto_xy $((box_left-1)) $((box_top+box_height))
echo -ne "$box_win_bot"

# block live resizing
popup_blocking_resize=1
}



#########################################
###  BOX PRINT
#########################################

box_print () {
local msg line
# print one or more lines of text into the box
# handles word wrap, and also accounts for linefeeds embedded in the provided text
# call more than once to continue printing farther down

msg="$1"

# "home" the box text position
box_x=0
#box_y=0  # don't move to top, just do that once in box_popup, so we can call box_print more than once
((box_width-=2))

# if the message is blank, that counts as a line
if [ -z "$msg" ] ; then
  #debug "message line is blank"
  msg=$'\n'
fi

echo -ne "$box_color_interior"
while [ -n "$msg" ] ; do
  # trim off one line
  line=${msg%%$'\n'*}
  msg=${msg#*$'\n'}
  #debug "box print line \"$line\""
  if [ "$msg" == "$line" ] ; then
    msg=""
  fi
  # "line" is a single line of text, no linefeed.  it may require word wrapping to fit in the window
  # we may have been passed a blank line, OR there's a final linefeed at the end of a wide or multiline text block
  if [ -z "$line" ] ; then
    # this line is blank
    #debug "printing blank line"
    ((box_y++))  # weirdly enough, if box_y was 0, this sets RC=1, which can cause this function to exit with an RC=1....
  else
    # this input line has characters to print.  it may need to be split up into multiple lines in the popup though
    while [ -n "$line" ] ; do
      #debug "remaining line to print: \"$line\""
      # trim off what will fit on the next line and print it
      r=${line:0:box_width}
      e=${#r}
      if [[ ( ($e == $box_width) && (${#r} -gt $box_width) && ("${r:$e-1}" != " ") ) ]] ; then
        # we have a full line to print, there is more text after that to print, and the last character we are going to print on this line is NOT a space
        #debug "clipping a bit off the end since \"$r\" is not blank at the end ($e)"
        r=${r% *}
      fi
      #debug "printing \"$r\""
      line=${line:${#r}+1}
      goto_xy $((box_left+box_x+1)) $((box_top+box_y))
      echo "$r"
      ((box_y++))
    done
  fi
  #debug "box_y = $box_y"
done
true  # prevent rc=1 caused by ++ or -- executing just before this
}



#########################################
###  BOX CLOSE
#########################################

box_close () {
# close message or popup box - redraw window and table

refresh_window
# resume live resizing, which was disabled by the box/popup appearing
popup_blocking_resize=
}



#########################################
###  BOX PRESS RETURN
#########################################

box_press_return () {
# print a "PRESS RETURN TO CONTINUE" message and key a return keypress
# then redraw the window and table
# call this AFTER popping open a box and printing what you want in it
# call popup_message with title and message for a simple popup


# prompt for a return keypress at bottom line of window
x=" Press RETURN to continue "
goto_xy $((box_left+(box_width-${#x})/2+1)) $((box_top+box_height-1))  # I tried printing this on top of the lower border instead of above it, but it looks worse that way
echo -ne "$return_color"
echo -n " Press RETURN to continue "  # -n because we might actually be on the bottom line of the screen

# get a return keypress
read -s x
box_close
}





########################################################################################################################
########################################################################################################################
###
###  POPUP FUNCTIONS
###
########################################################################################################################
########################################################################################################################


#########################################
###  NEW POPUP MENU
#########################################

new_popup_menu () {
# start defining a new popup menu
# box width and height will be calculated after we have all the options
# after calling this, call new_popup_option repeatedly to define popup menu options, then call display_popup_menu to display the menu

popup_title="$1"
popup_options=0
((popup_width=${#popup_title}+4))
}



#########################################
###  NEW POPUP OPTION
#########################################

new_popup_option () {
# add a popup menu option.  call it several times to define a list of options to be selected from.  set $2 to 1 to disable the option (but still display it)
# disabled options will be shown greyed out and will be skipped by the selection

popup_original[popup_options]="$1"
popup_option[popup_options]=" $1 "
if [ ${#popup_option[popup_options]} -gt $popup_width ] ; then
  popup_width=${#popup_option[popup_options]}
fi
if [ ${#@} -gt 1 ] ; then
  # disabled option
  popup_disabled[popup_options]=1
  popup_color[popup_options*2]=$pop_color_brdi
  popup_color[popup_options*2+1]=$pop_color_sedi
else
  # disabled option
  popup_disabled[popup_options]=
  popup_color[popup_options*2]=$pop_color_bren
  popup_color[popup_options*2+1]=$pop_color_seen
fi
((popup_options++))
true  # for some reason -e is triggering a silent stop when this is called, possibly due to the ((popup_options++)), which DOES have exit code 0 and popup_options is defined)
}



#########################################
###  DISPLAY POPUP MENU
#########################################

shift_one () {
# used while debugging colors, will shift one component of color

local a b opts
a=$1
opts=$2
if [ "$a" == "${opts##* }" ] ; then
  echo "${opts%% *}"
  return
else
  opts=${opts#*$a }
  echo "${opts%% *}"
fi
}


unshift_one () {
# used while debugging colors, will shift one component of color

local a b opts
a=$1
opts=$2
if [ "$a" == "${opts%% *}" ] ; then
  echo "${opts##* }"
  return
else
  opts=${opts% $a*}
  echo "${opts##* }"
fi
}



popup_display_option () {
# draw one popup menu option - works similar to draw-cell.  provide menu index

got_index=$1
got_mode=$2
n=" ${popup_option[got_index]} "
goto_xy $((box_left)) $((box_top+got_index))
echo -ne "${popup_color[$got_index*2+got_mode]}${popup_option[got_index]}$ansi_cmd_coloroff"
}



display_popup_menu () {
# display previously defined popup menu and accept a selection
# returns POPUP_INDEX = -1 and blank POPUP_RESULT for ESC, otherwise POPUP_INDEX = index and POPUP_RESULT is option selected
# specify column to pop menu box on (at row 1) if menu
# or specify initial selection with $2

local got_column got_initial
if [ ${#@} != 0 ] ; then
  got_column=$1
else
  got_column=
fi
if [ ${#@} -gt 1 ] ; then
  got_initial=$2
else
  got_initial=
fi

debug "popup_width = \"$popup_width\", title=\"$popup_title\""

# standardize popup option widths
for ((i=0;i<popup_options;i++)) ; do
  x="${popup_option[i]}$spaces"
  popup_option[i]=${x:0:popup_width}
done

# create and populate popup window
box_popup $popup_width $popup_options "$popup_title" "$got_column"  # if parameter was populated, pass it in as the column to use
if [ ! $popup_ok ] ; then
  # window isn't tall enough to display this menu
  popup_result=""
  return
fi

# print all the options in browse color scheme (disabled options will automatically be displayed as disabled)
for ((i=0;i<popup_options;i++)) ; do
  popup_display_option $i $cell_mode_browsing
done

# get selections and respond
if [ -z "$got_initial" ] ; then
  popup_index=0
else
  popup_index=$got_initial
fi
k="DOWN"  # preset this so we will automatically skip the first option if it is disabled
while true ; do

  # if the currently selected option is disabled, continue moving past it, otherwise get a selection
  if ! [ ${popup_disabled[popup_index]} ] ; then

    # highlight selected option
    popup_display_option $popup_index $cell_mode_selected
    k=""
    read -n1 -s k
    #debug_parser "parsing key sequence (length ${#k}): \$$(echo -n "$k" | xxd -u -p)"

    ####################
    ###  ESC SEQUENCE
    ####################

    if [ "$k" == $escape ] ; then  # escape sequence starting
      parse_esc 1  # ESC keypress alone will return "ESC" instead of opening the menu
      if [ -z "$k" ] ; then
        # parse unsuccessful
        unsupported_sequence $LINENO
        continue
      fi
      # $k is set to some text command like PGUP or NOOP
      #debug_parser "parsed: $k"
    fi
    # we have a keypress (possibly an ESC sequence label) of some sort now.  it MAY be something we don't support while editing though, like PGUP or END
    #debug_parser "editor got k = \$$(echo -n "$k" | xxd -u -ps)"

    # unhighlight the previous selection since we are very likely going to move
    popup_display_option $popup_index $cell_mode_browsing

  fi

  debug "popup parsing keypress \"$k\""

  ####################
  ###  DOWN
  ####################

  if [ "$k" == "DOWN" ] ; then
    # select next option
    if [ $popup_index == $((popup_options-1)) ] ; then
      ((popup_index=0))
    else
      ((popup_index++))
    fi
    continue

  ####################
  ###  UP
  ####################

  elif [ "$k" == "UP" ] ; then
    # select previous option
    if [ $popup_index == 0 ] ; then
      ((popup_index=popup_options-1))
    else
      ((popup_index--))
    fi
    continue

  ####################
  ###  LEFT
  ####################
    
  elif [[ ("$k" == "LEFT") && (-n "$got_column") ]] ; then
    # menu popup, change to previous category
    popup_result="$k"
    return
    
  ####################
  ###  RIGHT
  ####################
  
  elif [[ ("$k" == "RIGHT") && (-n "$got_column") ]] ; then
    # menu popup, change to next category
    popup_result="$k"
    return

  ####################
  ###  ESC
  ####################

  elif [ "$k" == "ESC" ] ; then
    # escape aborts the popup without making a selection
    if [ -n "$table" ] ; then
      refresh_window
      # remember to redraw the selected cell as inactive
      ((i=sel_row*columns+sel_col))
      draw_cell "${cell_data[i]}" $sel_row $sel_col ${cell_status[i]} $cell_mode_inactive
    fi
    popup_index=-1
    popup_result=""
    return

  ####################
  ###  RETURN
  ####################

  elif [ -z "$k" ] ; then
    if [ ${popup_disabled[popup_index]} ] ; then
      debug "option $popup_index is disabled"
      echo -n $'\a'
      continue
    fi
    # return accepts the currently selected option
    if [ -n "$table" ] ; then
      refresh_window
    fi
    popup_result="${popup_original[popup_index]}"
    return

  ####################
  ###  1-6
  ####################

  elif [[ ( ("$k" == "1") || ("$k" == "2") || ("$k" == "3") || ("$k" == "4") || ("$k" == "5") || ("$k" == "6") || ("$k" == "!") || ("$k" == "@") || ("$k" == "#") || ("$k" == "$") || ("$k" == "%") || ("$k" == "^") ) ]] ; then
    # easily try out different color schemes
    # sorry, I'm not aiming for pretty, I'm aiming for maximum usability, which sometimes means gawdy contrasting colors
    # I also want consistency though

    # keys 1-3 change the color of the box border and title (+shift to reverse)
    a=$box_color_border  # "\033[0;93;104m"
    c1=${a:5:1}  # "0"
    a=${a:7}     # "93;104m"
    c2=${a%%;*}  # "93"
    a=${a#*;}    # "104m"
    c3=${a%m}    # "104"
    if [ "$k" == "1" ] ; then
      # "1" cycles through text light/normal/bold
      c1=$(shift_one "$c1" "0 1 2")
    elif [ "$k" == "2" ] ; then
      # "2" cycles through text colors
      c2=$(shift_one "$c2" "30 31 32 33 34 35 36 37 90 91 92 93 94 95 96 97")
    elif [ "$k" == "3" ] ; then
      # "3" cycles through background colors
      c3=$(shift_one "$c3" "40 41 42 43 44 45 46 47 100 101 102 103 104 105 106 107")
    elif [ "$k" == "!" ] ; then
      # "!" cycles through text light/normal/bold
      c1=$(unshift_one "$c1" "0 1 2")
    elif [ "$k" == "@" ] ; then
      # "@" cycles through text colors
      c2=$(unshift_one "$c2" "30 31 32 33 34 35 36 37 90 91 92 93 94 95 96 97")
    elif [ "$k" == "#" ] ; then
      # "#" cycles through background colors
      c3=$(unshift_one "$c3" "40 41 42 43 44 45 46 47 100 101 102 103 104 105 106 107")
    fi
    box_color_border="\033[${c1};${c2};${c3}m"
    debug "box_color_border = \"$box_color_border\""

    # redraw the current popup box using the new color scheme
    #box_popup $popup_width $popup_options "$popup_title" "$got_column"
    # display new popup with title set to its ansi color code
    box_popup $popup_width $popup_options "${c1};${c2};${c3}" "$got_column"
    if [ ! $popup_ok ] ; then
      # window isn't tall enough
      popup_result=""
      return
    fi

    # keys 4-6 change the color of the selected option (+shift to reverse)
    a=${popup_color[popup_index*2+cell_mode_selected]}  # "\033[0;93;104m"
    c1=${a:5:1}  # "0"
    a=${a:7}     # "93;104m"
    c2=${a%%;*}  # "93"
    a=${a#*;}    # "104m"
    c3=${a%m}    # "104"
    if [ "$k" == "4" ] ; then
      # "4" cycles through text light/normal/bold
      c1=$(shift_one "$c1" "0 1 2")
    elif [ "$k" == "5" ] ; then
      # "5" cycles through text colors
      c2=$(shift_one "$c2" "30 31 32 33 34 35 36 37 90 91 92 93 94 95 96 97")
    elif [ "$k" == "6" ] ; then
      # "6" cycles through background colors
      c3=$(shift_one "$c3" "40 41 42 43 44 45 46 47 100 101 102 103 104 105 106 107")
    elif [ "$k" == "$" ] ; then
      # "$" cycles through text light/normal/bold
      c1=$(unshift_one "$c1" "0 1 2")
    elif [ "$k" == "%" ] ; then
      # "%" cycles through text colors
      c2=$(unshift_one "$c2" "30 31 32 33 34 35 36 37 90 91 92 93 94 95 96 97")
    elif [ "$k" == "^" ] ; then
      # "^" cycles through background colors
      c3=$(unshift_one "$c3" "40 41 42 43 44 45 46 47 100 101 102 103 104 105 106 107")
    fi
    popup_color[popup_index*2+cell_mode_selected]="\033[${c1};${c2};${c3}m"
    debug "popup_color[$popup_index*2+$cell_mode_selected] = \"${popup_color[popup_index*2+cell_mode_selected]}\""

    # change the selected option to its ansi color code
    cc=" ${c1};${c2};${c3}$spaces"
    popup_option[popup_index]="${cc:0:popup_width}"

    # redraw the current popup options using the new color scheme (only the selected option will change)
    for ((i=0;i<popup_options;i++)) ; do
      popup_display_option $i $cell_mode_browsing
    done

  ####################
  ###  CTRL-X
  ####################

  elif [ "$k" == $ctrl_x ] ; then

    # quit if there are no unsaved changes
    fast_quit 1  # '1' indicates window must be refreshed (to erase the popup) prior to quitting

    # user cancelled fast-quit
    continue

  ####################
  ###  INVALID
  ####################
  
  else
      invalid_command $LINENO
      continue

  fi
done
# never gets here
}





#########################################
###  POPUP ENTRY
#########################################

popup_entry () {
# open a popup window and accept some text from user
# specify title, length, and initial value ("" if you want it to start out empty)
# entry_result will contain the user-provided value on return
# rc=0 if user pressed RETURN, rc=1 if user pressed ESC

local i width entry_title entry_width entry_initial

# load parameters
entry_title=$1
entry_width=$2
entry_initial=$3

# draw the popup box to host the entry
if [ $((entry_width+2)) -gt ${#entry_title} ] ; then
  debug "initial is bigger"
  ((width=entry_width+2))
else
  debug "title is bigger"
  ((width=${#entry_title}+3))
fi
debug "width = $width"
height=3
box_popup $width $height "$entry_title"  # should set box_left and box_top to suggest where we can put the entry field
#debug "box popped up, box left,top = $box_left,$box_top"

# get the entry input
accept_entry $((box_left+1)) $((box_top+1)) $entry_width "$entry_initial"  # remember to quote entry_initial as it may contain spaces

# entry_escaped is now set by accept_entry (as is entry_result)
}



#########################################
###  ACCEPT ENTRY
#########################################

accept_entry () {
# user needs to provide a little bit of text (this is NOT a cell edit)
# specify x and y start position, length, and initial value (optional)
# edit position will start at the end of the provided text (ignoring spaces) or at the start of the field if no initial value was specified
# entry_result will contain the user-provided value on return, WITH TRAILING SPACES STRIPPED OFF
# rc=0 if user pressed RETURN, rc=1 if user pressed ESC
# caller is responsible for drawing any borders, frames, and backgrounds, and for repaining over the entry field
# this code is similar to cell_edit, but is sufficiently specialized that I decided not to overload one function to provide shared code, it just wasn't a good idea
# (and edit_cell was sufficiently debugged to not be a problem with maintaining two code blocks that were being actively debugged and edited)
# remember there will be NO edit-colored padding to the left or right of the entry, only the entry itself will be getting rendered here

local i width entry_title entry_x entry_y entry_width entry_buffer entry_index

# load parameters
entry_x=$1
entry_y=$2
entry_width=$3
entry_buffer=$4 # optional

# set this if user pressed [ESC]
entry_escaped=

# pad buffer to width with spaces
entry_buffer="$entry_buffer$spaces"
entry_buffer=${entry_buffer:0:entry_width}
debug "starting accept_entry with buffer = \"$entry_buffer\""

# determine cursor position (start edit at start of whitespace on end of initial value or at end of cell if there is no whitespace on the right)
e="${entry_buffer%"${entry_buffer##*[![:space:]]}"}"  # ugly but fast.  using shell substitution only to trim right whitespace.  e=${e%% } does not work for some reason, behaves like =${e% }
entry_index=${#e}
debug "initialize entry buffer with \"$entry_buffer\", cursor at index $entry_index"

# set edit color and turn on the cursor (remember to turn off cursor when exiting with ESC or RETURN)
echo -ne "$ansi_cmd_cursoron$cell_color_edt"

# move the cursor around and get key inputs
while true ; do

  # redraw entry in editing color
  goto_xy $entry_x $entry_y
  echo -n "$entry_buffer"
  #debug "entry_buffer now = \"$entry_buffer\""
  
  # position the cursor
  goto_xy $((entry_x+entry_index)) $entry_y

  k=""   
  read -n1 -s -r k
  #debug_parser "parsing key sequence (length ${#k}): \$$(echo -n "$k" | xxd -u -p)"

  ####################
  ###  ESC SEQUENCE
  ####################

  if [ "$k" == $escape ] ; then  # escape sequence starting
    parse_esc 1  # ESC keypress alone will return "ESC" instead of opening the menu
    if [ -z "$k" ] ; then
      # parse unsuccessful
      
      unsupported_sequence $LINENO
      continue
    fi
    # $k is set to some text command like PGUP or NOOP
    #debug_parser "parsed: $k"
  fi
  # we have a keypress (possibly an ESC sequence label) of some sort now.  it MAY be something we don't support while editing though, like PGUP or END
  #debug_parser "editor got k = \$$(echo -n "$k" | xxd -u -ps)"

  ####################
  ### LEFT
  ####################

  if [ "$k" == "LEFT" ] ; then
    # move left one character
    if [ $entry_index == 0 ] ; then
      # can't arrow left past leftmost character in cell
      echo -n $'\a'
      continue
    fi
    ((entry_index--))

  ####################
  ### RIGHT
  ####################

  elif [ "$k" == "RIGHT" ] ; then
    # move right one character
    if [ $entry_index == $entry_width ] ; then
      # can't arrow right past righmtost character in entry
      echo -n $'\a'
      continue
    fi
    ((entry_index++))
    # this may be as large as $entry_width, which is one character past the entry's width (not editable)

  ####################
  ###  CTRL-A
  ####################

  elif [ "$k" == $ctrl_a ] ; then
    # move cursor to first character
    if [ $entry_index == 0 ] ; then
      # you're already at the start of the entry, silly
      echo -n $'\a'
      continue
    fi
    entry_index=0

  ####################
  ###  CTRL-E
  ####################

  elif [ "$k" == $ctrl_e ] ; then
    # move cursor to last character
    if [ $entry_index == $entry_width ] ; then
      # you're already at the end of the entry, silly
      echo -n $'\a'
      continue
    fi
    e="${entry_buffer%"${entry_buffer##*[![:space:]]}"}"
    entry_index=${#e}

  ####################
  ### ESC
  ####################

  elif [ "$k" == "ESC" ] ; then
    # cancel entry
    debug "entry canelled"
    echo -ne "$ansi_cmd_cursoroff"
    entry_result="CANCELLED"  # mainly for debugging
    entry_escaped=1
    return  # caller needs to clean up the screen

  ####################
  ### RETURN
  ####################

  elif [ -z "$k" ] ; then
    # accept entry
    entry_result=$(echo "$entry_buffer" | sed 's/[ ]*$//g')  # return the buffer, after stripping off trailing spaces
    debug "returning entry_result = \"$entry_result\""
    echo -ne "$ansi_cmd_cursoroff"
    true  # just making sure we rc=0
    return

  ####################
  ###  DELETE (delete-backward)
  ####################

  elif [ "$k" == $delete ] ; then
    # delete character left of cursor and move cursor left one character
    if [ $entry_index == 0 ] ; then
      # you're already at the start of the entry, silly
      echo -n $'\a'
      continue
    fi
    # delete the character to the left of the index, shift in a space on the far right, and move the index left one position
    entry_buffer="${entry_buffer:0:entry_index-1}${entry_buffer:entry_index} "  # boy those are fun to debug.  OBOB much?
    ((entry_index--))

  ####################
  ###  DEL (delete-forward)
  ####################

  elif [ "$k" == "DEL" ] ; then
    # delete character at cursor
    if [ $entry_index == $entry_width ] ; then
      # you're already at the end of the entry, silly
      echo -n $'\a'
      continue
    fi
    # delete the character at the index, shift in a space on the far right, and leave the index where it was
    entry_buffer="${entry_buffer:0:entry_index}${entry_buffer:entry_index+1} "  # much OBOB here too

  ####################
  ###  (some other unsupported escape sequence)
  ####################

  elif [ ${#k} != 1 ] ; then
    # escape sequences use 2+ character names, so this is probably an escape sequence we don't support (like "HOME" or "F2")
    echo -n $'\a'

  ####################
  ###  (entry overflow)
  ####################

  elif [ $entry_index == $entry_width ] ; then
    # they're trying to type another character at the end of the entry, there's no more room
    echo -n $'\a'

  ####################
  ### unsupported control (nonprintable) character
  ####################

  elif [[ "$k" =~ [[:cntrl:]] ]] ; then   # don't ask where I found this, because I really can't remember.  it's an odd bird
    #k="echo -n "$k" | xxd -u -ps)"  # "04"
    #k="\$$(echo -n "$k" | xxd -u -ps)"  # "$04"
    invalid_command $LINENO
    # invalid_command changes the edit color, change it back
    echo -ne "$ansi_cmd_cursoron$cell_color_edt"
    #k="CTRL-$(echo "0: $(echo "obase=16;$(echo "ibase=16;$(echo -n "$k" | xxd -u -ps)" | bc)+64" | bc)" | xxd -r)"  # "CTRL-D"   # using xxd, ps, *and* bc in tandem JUST to confuse you
    #invalid_command $LINENO

  ####################
  ### (any printable character)
  ####################

  else
    #debug "inserting \"$k\" at $entry_index"
    # insert the character into the buffer, shifting right at the insert, deleting the overflow character at the end
    #debug_parser "inserting character: \$$(echo -n "$k" | xxd -u -ps)"
    entry_buffer="${entry_buffer:0:entry_index}$k${entry_buffer:entry_index}"  # just when you thought OBOB had left for good
    entry_buffer=${entry_buffer:0:entry_width}
    ((entry_index++))

  fi
done

# we never get here
}



#########################################
###  POPUP MESSAGE
#########################################

popup_message () {
# open a popup box in the middle of the screen and print a message, get a return keypress, repaint screen
local msg next width height title

# predict width and height of message box (include title)
title="$1"
msg="$2"

# mininum box width is 26 for "Press RETURN to continue" regardless of size of title
local w
w=${#title}
if [ $w -lt 26 ] ; then
  w=26
fi

((width=${#title}+3))

height=3
next=""
while [ "$next" != "$msg" ] ; do
  next=${msg%%$'\n'*}
  msg=${msg#*$'\n'}
  if [ ${#next} -gt $width ] ; then
    width=${#next}
  fi
  ((height++))
done
((width+=4))

# display message
msg="$2"
box_popup $width $height "$title"
if [ ! $popup_ok ] ; then
  # window isn't tall enough
  return
fi
box_print ""
box_print "$msg"

# get a return
box_press_return

}





########################################################################################################################
########################################################################################################################
###
###  TABLE FUNCTIONS
###
########################################################################################################################
########################################################################################################################


#########################################
###  CATALOG TABLES
#########################################

catalog_tables () {
# load a list of tables in selected database to array at dtable[dtables] - there is a maximum limit for the number of tables we will load
# dtables will be zero if error or no tables found

local x schema

do_sql $LINENO "load schema to get table list" ".schema"
schema=$result  # stash this because we will be calling do_sql more here later
dtables=0

if [ -n "$schema" ] ; then
  # we have at least one table
  while true ; do
    # "CREATE TABLE Checkins (sn CHAR(12) PRIMARY KEY, mac CHAR(17), assembled CHAR(10), model CHAR(50));"
    # "CREATE INDEX IX_connectivity_statistics_type ON connectivity_statistics (type);"
    # "CREATE TABLE asdf(sn CHAR(8),host INTEGER);"
    x="${schema%%$'\n'*}"  # "CREATE TABLE Jobs (job_id CHAR4),..."
    debug "catalogging from schema: $x"
    if [ "${x:0:13}" != "CREATE TABLE " ] ; then
      # probably defining an index, skip it
      debug "skipping index definition"
    else
      x=${x#CREATE TABLE }  # "Jobs (job_id CHAR4),..."
      x=${x%% *}  # "Jobs"
      x=${x%%(*}  # "Jobs"
      dtable[dtables]="$x"
      # also get record count for this table
      do_sql $LINENO "get record count" "SELECT COUNT (*) FROM $x"
      dtable_count[dtables]=$result
      # next
      ((dtables++))
    fi
    x="${schema#*$'\n'}"
    if [ "$x" == "$schema" ] ; then
      debug "end of schema"
      # end of list
      break
    fi
    schema="$x"
    if [ $dtables == $max_tables ] ; then
      debug "reached maximum table capacity"
      # we canna take it any more, cap'n
      break
    fi
  done
fi
debug "catalogged $dtables tables"
}



#########################################
###  CREATE END MARKERS
#########################################

create_end_markers () {
# recreate the END markers
# these are only visible on tables that have no records

local c i
for ((c=0;c<columns;c++)) ; do
  ((i=rows*columns+c))
  cell_data[i]="END"
  cell_status[i]=$cell_status_warning
  row_deleted[rows]=""
done
}



#########################################
###  BROWSING NEW TABLE
#########################################

browsing_new_table () {
# prepare to browse a new table

table="$1"

# verify table exists / get row count
do_sql $LINENO "get record count" "SELECT COUNT (*) FROM $table" -1
if [ $sql_rc != 0 ] ; then
  abort $LINENO "unable to open table \"$table\", is that table name correct?"
fi
rows=$result
debug "table \"$table\" looks okay, rows = $rows"

# get last record's ROWID, vacuum table if it's different than the rowcount
#do_sql $LINENO "get ROWID of last record" "SELECT ROWID FROM $table ORDER BY ROWID DESC LIMIT 1"
#last_id=$result
#debug "last ROWID = \$last_id\""
#if [ $last_id != $rows ] ; then
#  debug "table $table needs vacuuming (has vacant rows)"
#  do_sql $LINENO "vacuum table prior to browsing" "VACUUM $table" -1
#  if [ $? != 0 ] ; then
#    abort $LINENO "error vacuuming table $table prior to browse"
#  fi
#fi
# disabled, user can vacuum the table themselves
# it was hoped that a table's ROWIDs would always be sequential following a vacuum, but that's not always the case,
# so we've had to stop relying on it

# load and parse database schema to get column names and widths
do_sql $LINENO "get table schema" ".schema $table"
# "CREATE TABLE Checkins (sn CHAR(12) PRIMARY KEY, mac CHAR(17), assembled CHAR(10), model CHAR(50));"
# schema can include indexes so strip off all but first line
schema=${result%%$'\n'*}
x=${schema#*(}  # "sn CHAR(12) PRIMARY KEY, mac CHAR(17), assembled CHAR(10), model CHAR(50));"
x=${x%);}  # "sn CHAR(12) PRIMARY KEY, mac CHAR(17), assembled CHAR(10), model CHAR(50)"
columns=0
widest_col=0
field_list=""
while [ true ] ; do
  #debug "parsing x=\"$x\""
  # get one column definition
  x=$(echo "$x" | sed $'s/,[ \t]*\(FOREIGN KEY\) .*/)/g' | sed $'s/,[ \t]*\(PRIMARY KEY\) .*/)/g')
  y=${x%%,*}  # "sn CHAR(12) PRIMARY KEY" | "checkin integer" | " Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZLASTSAVED TIMESTAMP, ZID VARCHAR "
  y="$(echo "$y" | sed $'s/^[\t ]*//g')"  # "sn CHAR(12) PRIMARY KEY" | "checkin integer" | "Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZLASTSAVED TIMESTAMP, ZID VARCHAR "
  debug "start y = \"$y\""
  y=$(echo "$y" | sed $'s/\([\t ]\)\{1,99\}/ /g' | sed 's/^ //g' | sed 's/ $//g')
  debug "proc y = \"$y\""
  column_name[columns]=${y%% *} # "sn" | "checkin" | "Z_PK"
  debug "y=\"$y\""
  field_list="${field_list},${column_name[columns]}"
  # trim to column size, if specified
  z=${y#*(}  # "12) PRIMARY KEY" | "checkin integer"
  #debug "z=\"$z\""
  if [ "$z" == "$y" ] ; then
    #debug "no size specified defaults to 10 (mostly integers)"
    debug "no size specified defaults to flexible 0 (mostly integers)"
    column_size[columns]=0  # no need to use 10, we will adjust dynamically now
    column_flex[columns]=0  # this will cause it to be watched while reading in the database, and track the largest found
    # and it will be displayed right-justified since we're assumnig it's for numbers
    column_right[columns]=1
  else
    column_flex[columns]=  # this column isn't flexible
    column_size[columns]=${z%%)*}  # "12"
    debug "using specified column size \"${column_size[columns]}\""
    column_right[columns]=
  fi
  if [ ${column_size[columns]} -ge ${#column_name[columns]} ] ; then
    column_width[columns]=${column_size[columns]}
  else
    # column size is smaller than the width of the header, so set the display width to the width of the header
    column_width[columns]=${#column_name[columns]}
    debug "increasing width of column ${column_name[columns]} to ${#column_name[columns]} to accomodate column header"
  fi
  if [ $widest_col -lt ${column_width[columns]} ] ; then
    # keep tally of the widest column
    widest_col=${column_width[columns]}
  fi
  if [ ${column_right[columns]} ] ; then
    debug "found column $columns, name \"${column_name[columns]}\", size ${column_size[columns]}, width ${column_width[columns]} (right-justified)"
  else
    debug "found column $columns, name \"${column_name[columns]}\", size ${column_size[columns]}, width ${column_width[columns]}"
  fi
  ((columns++))
  y=${x#*,}  # "mac CHAR(17), assembled CHAR(10), model CHAR(50), ip CHAR(15), name CHAR(17), image CHAR(20), checkin integer, automation CHAR(16), groups CHAR(50), highlight CHAR(10), category CHAR(8), previous CHAR(17)"
  y=$(echo "$y" | sed 's/^[ ]*//g')
  if [ "$y" == "$x" ] ; then
    break
  fi
  x=$y
done                                                                                                                                      
debug "loaded $columns columns"
field_list=${field_list:1}  # trim off preceeding comma
debug "field_list = \"$field_list\""

# load database into array   # remember we need ROWID also since we will be making changes by ROWID when modifying or deleting records
# also when adding a row, we assume sqlite3 will use a ROWID that is +1 from the last record's ROWID
do_sql $LINENO "download all records" "SELECT ROWID,$field_list FROM $table ORDER BY ROWID"
for ((r=0;r<rows;r++)) ; do
  if [ $r == $((r/progress_interval*progress_interval)) ] ; then
    # display a load progress indicator every 100 records
    draw_notice "loading row $r/$rows"
  fi
  # these shell subs are about equally expensive as using a bunch of ROWID selects
  record="${result%%$'\n'*}"
  result=${result#*$'\n'}
  debug "loading record $r: \"$record\""
  rowid[r]=${record%%|*}
  record=${record#*|}
  for ((c=0;c<columns;c++)) ; do
    ((i=r*columns+c))
    cell_data[i]=${record%%|*}
    cell_status[i]=$cell_status_unchanged
    record=${record#*|}
    # grow column_size and column_width if necessary (fields like INTEGER and TEXT may have defaulted to 8 because size was not specified)
    w=${#cell_data[i]}
    if [ ${column_flex[c]} ] ; then
      # this is a flexible column, check to see if it's gotten bigger
      if [ $w -gt ${column_size[c]} ] ; then
        column_flex[c]=$w
        column_size[c]=$w
        if [ $w -gt ${column_width[c]} ] ; then
          column_width[c]=$w
          debug "increasing width of column ${column_name[c]} to $w to accomodate \"${cell_data[i]}\" at row $r"
        fi
      fi
    fi
  done
  row_deleted[r]=""
done
debug "table $table has $rows records"

# give fields that needed to grow a little breathing room
for ((c=0;c<columns;c++)) ; do
  if [ ${column_flex[c]} ] ; then
    # this column is flexible, add the allowable growth
    debug "growing flexible column ${column_name[c]} to width $((column_size[c]+flex_growth))"
    ((column_size[c]+=flex_growth))
    if [ ${column_width[c]} -lt ${column_size[c]} ] ; then
      # increase the column display with also
      column_width[c]=${column_size[c]}
    fi
  fi
done

# recreate the END markers
# I think these have been depreciated? they're not displayed anymore
create_end_markers 

debug "database is loaded"

# start edit at top row/record, left column/field
sel_row=0
sel_col=0

# with no changes made
changes=0
rows_deleted=0

# with window scrolled to top-left
define_window_at $LINENO 0 0
refresh_window

# and finally resize terminal window if it's too small to accomodate at least the widest column
((widest_col+=4))
#debug "compare $window_width and $widest_col"
if [ $window_width -lt $widest_col ] ; then
  debug "need to make the window wider"
  resize_window $widest_col $LINES
fi

}





########################################################################################################################
########################################################################################################################
###
###  CATEGORY POPUP
###
########################################################################################################################
########################################################################################################################

category_popup () {
# display a category popup in the main menu
# get a menu selection and perform selected action

# loop until we get a menu selection (may be switching between categories)
while true ; do
  # define the menu box with no title - some options may be disabled, others may have variable names
  #new_popup_menu "" 1 ${category_x[category_index]}
  new_popup_menu ""

  if [ "${category_name[category_index]}" == "File" ] ; then

    ####################
    ###  FILE
    ####################

    if [[ ($changes == 0) && ($rows_deleted == 0) ]] ; then
      new_popup_option "QUIT"
    else
      new_popup_option "SAVE CHANGES"
      new_popup_option "DISCARD CHANGES AND QUIT"
    fi
    if [[ ($changes == 0) && ($rows_deleted == 0) ]] ; then
      new_popup_option "IMPORT TABLE"
      new_popup_option "EXPORT TABLE"
    else
      new_popup_option "IMPORT TABLE" 1
      new_popup_option "EXPORT TABLE" 1
    fi
    new_popup_option "APPEND FROM SDF FILE"
    new_popup_option "EXPORT TO TEXT FILE"

  elif [ "${category_name[category_index]}" == "Edit" ] ; then

    ####################
    ###  EDIT
    ####################

    new_popup_option "APPEND ROW"
    if [ $rows == 0 ] ; then
      new_popup_option "DELETE ROW" 1
    else
      new_popup_option "DELETE ROW"
    fi
    if [[ ($changes == 0) && ($rows_deleted == 0) ]] ; then
      new_popup_option "DISPLAY CHANGES" 1
    else
      new_popup_option "DISPLAY CHANGES"
    fi

  elif [ "${category_name[category_index]}" == "Table" ] ; then

    ####################
    ###  TABLE
    ####################

    new_popup_option "SORT BY COLUMN"
    new_popup_option "DISPLAY SCHEMA"
    if [[ ($changes != 0) || ($rows_deleted != 0) ]] ; then
      # can't change a table while you have unsaved changes in current table
      new_popup_option "CHANGE TABLE" 1
    elif [ $dtables == 1 ] ; then
      # there are no other tables to change to
      new_popup_option "CHANGE TABLE" 1
    else
      new_popup_option "CHANGE TABLE"
    fi
    if [[ ($changes != 0) || ($rows_deleted != 0) ]] ; then
      # can't monitor a table while you have unsaved changes
      new_popup_option "MONITOR TABLE" 1
    elif [ $rows == 0 ] ; then
      # can't monitor a table with no rows
      new_popup_option "MONITOR TABLE" 1
    else
      new_popup_option "MONITOR TABLE"
    fi

  elif [ "${category_name[category_index]}" == "Help" ] ; then

    ####################
    ###  HELP
    ####################

    new_popup_option "DISPLAY HELP"

  elif [ "${category_name[category_index]}" == "Debug" ] ; then

    ####################
    ###  DEBUG
    ####################

    new_popup_option "RENDER TEST"
    if [ $switch_debug_rowid ] ; then
      new_popup_option "DISABLE DEBUG ROWID"
    else
      new_popup_option "ENABLE DEBUG ROWID"
    fi
    if [ $switch_debug_ansi ] ; then
      new_popup_option "DISABLE DEBUG ANSI"
    else
      new_popup_option "ENABLE DEBUG ANSI"
    fi
    if [ $switch_debug_log ] ; then
      new_popup_option "DISABLE DEBUG LOG"
    else
      new_popup_option "ENABLE DEBUG LOG"
    fi
    if [ $switch_debug_parser ] ; then
      new_popup_option "DISABLE DEBUG PARSER"
    else
      new_popup_option "ENABLE DEBUG PARSER"
    fi
    if [ $switch_debug_log ] ; then
      if [ $switch_debug_sql ] ; then
        new_popup_option "DISABLE DEBUG SQL"
      else
        new_popup_option "ENABLE DEBUG SQL"
      fi
    fi

  else

    ####################
    ###  (no match?)
    ####################

    debug "unsupported category name \"${category_name[category_index]}\""
    return

  fi

  # display the selected popup and get a selection
  draw_rowinfo  # clear any notice
  display_popup_menu ${category_x[category_index]}

  if [ "$popup_result" == "LEFT" ] ; then

    ####################
    ###  LEFT
    ####################

    debug "category left"
    if [ $category_index == 0 ] ; then
      category_index=$categories
    fi
    ((category_index--))
    # change option
    refresh_window
    # slightly dim the selected category so the popup menu options are more obviously selected
    goto_xy ${category_x[category_index]} 0
    echo -ne "$menu_color_op ${category_name[category_index]} "
    # dim out the selected cell
    ((i=sel_row*columns+sel_col))
    draw_cell "${cell_data[i]}" $sel_row $sel_col ${cell_status[i]} $cell_mode_inactive
    continue

  elif [ "$popup_result" == "RIGHT" ] ; then

    ####################
    ###  RIGHT
    ####################

    debug "category right"
    ((category_index++))
    if [ $category_index == $categories ] ; then
      category_index=0
    fi
    # change option
    refresh_window
    # slightly dim the selected category so the popup menu options are more obviously selected
    goto_xy ${category_x[category_index]} 0
    echo -ne "$menu_color_op ${category_name[category_index]} "
    # dim out the selected cell
    ((i=sel_row*columns+sel_col))
    draw_cell "${cell_data[i]}" $sel_row $sel_col ${cell_status[i]} $cell_mode_inactive
    continue

  fi
  # was something other than a left/right (probably ENTER or ESC)
  break

done

debug "got menu option $popup_index \"$popup_result\""

# flag for main_menu to return to browsing
menu_return_to_browsing=1

# perform the selected option

####################
###  ESC
####################

if [ "$popup_result" == "" ] ; then
  menu_return_to_browsing=  # resume menu selection
  true  # do nothing, just return

####################
###  QUIT
####################

elif [ "$popup_result" == "QUIT"  ] ; then
  return_to_caller

####################
###  SAVE CHANGES
####################

elif [ "$popup_result" == "SAVE CHANGES"  ] ; then
  save_table
  # return_to_caller
  #k="NOOP"
  #return

####################
###  DISCARD CHANGES
####################

elif [ "$popup_result" == "DISCARD CHANGES AND QUIT"  ] ; then
  popup_confirm "Throw away changes to ${table}?"
  if [ $confirmed ] ; then
    return_to_caller
  fi
  k="NOOP"
  draw_notice "discard cancelled"
  return

####################
###  APPEND ROW
####################

elif [ "$popup_result" == "APPEND ROW"  ] ; then
  append_row

####################
###  DELETE ROW
####################

elif [ "$popup_result" == "DELETE ROW"  ] ; then
  delete_row

####################
###  CHANGE TABLE
####################

elif [ "$popup_result" == "CHANGE TABLE"  ] ; then
  change_table

####################
###  APPEND FROM SDF
####################

elif [ "$popup_result" == "APPEND FROM SDF FILE"  ] ; then
  append_text_file

####################
###  SORT BY COLUMN
####################

elif [ "$popup_result" == "SORT BY COLUMN"  ] ; then
  sort_by_column

####################
###  DISPLAY SCHEMA
####################

elif [ "$popup_result" == "DISPLAY SCHEMA"  ] ; then
  display_schema

####################
###  IMPORT TABLE
####################

elif [ "$popup_result" == "IMPORT TABLE"  ] ; then
  import_table

####################
###  EXPORT TABLE
####################

elif [ "$popup_result" == "EXPORT TABLE"  ] ; then
  export_table

####################
###  EXPORT TEXT FILE
####################

elif [ "$popup_result" == "EXPORT TO TEXT FILE"  ] ; then
  export_text_file

####################
###  HELP
####################

elif [ "$popup_result" == "DISPLAY HELP"  ] ; then
  display_help

####################
###  DISPLAY CHANGES
####################

elif [ "$popup_result" == "DISPLAY CHANGES"  ] ; then
  display_changes

####################
###  RENDER TEST
####################

elif [ "$popup_result" == "RENDER TEST"  ] ; then
  render_test

####################
###  MONITOR TABLE
####################

elif [ "$popup_result" == "MONITOR TABLE"  ] ; then
  monitor_table

####################
### DEBUG ROWID
####################

elif [ "$popup_result" == "ENABLE DEBUG ROWID"  ] ; then
  switch_debug_rowid=1
  refresh_window
elif [ "$popup_result" == "DISABLE DEBUG ROWID"  ] ; then
  switch_debug_rowid=
  refresh_window

####################
###  DEBUG ANSI
####################

elif [ "$popup_result" == "ENABLE DEBUG ANSI"  ] ; then
  switch_debug_ansi=1
  refresh_window
elif [ "$popup_result" == "DISABLE DEBUG ANSI"  ] ; then
  switch_debug_ansi=
  refresh_window

####################
###  DEBUG PARSER
####################

elif [ "$popup_result" == "ENABLE DEBUG PARSER"  ] ; then
  switch_debug_parser=1
elif [ "$popup_result" == "DISABLE DEBUG PARSER"  ] ; then
  switch_debug_parser=

####################
###  DEBUG LOG
####################

elif [ "$popup_result" == "ENABLE DEBUG LOG"  ] ; then
  echo "---------------------------------------------------------------" >> "$debug_file"
  echo "$(date "+%Y/%m/%d %H:%M:%S") START" >> "$debug_file"
  echo "---------------------------------------------------------------" >> "$debug_file"
  switch_debug_log=1
elif [ "$popup_result" == "DISABLE DEBUG LOG"  ] ; then
  echo "===============================================================" >> "$debug_file"
  switch_debug_log=

####################
###  LOG SQL
####################

elif [ "$popup_result" == "ENABLE LOG SQL"  ] ; then
  switch_log_sql=1
elif [ "$popup_result" == "DISABLE LOG SQL"  ] ; then
  switch_log_sql=

####################
###  (invalid?)
####################

else
  k="$popup_result"
  invalid_command $LINENO
  debug "unimplemented menu at $LINENO, should not happen"
fi
k="NOOP"  # browser does not need to act on this when we return to it
return
}





########################################################################################################################
########################################################################################################################
###
###  MAIN MENU
###
########################################################################################################################
########################################################################################################################

# start accessing the main menu

add_category () {
if [ $categories == 0 ] ; then
  category_x[0]=0
  category_name[0]="$1"
  window_row_menubar_plain=" $1 "
else
  ((category_x[categories]=${#window_row_menubar_plain}+4))
  category_name[categories]="$1"
  window_row_menubar_plain="$window_row_menubar_plain     $1 "
fi
((categories++)) ; true  # rc=1 when adding first category
}

window_row_menubar_plain=""  # create the unhighlighted menubar for faster screen refreshes"
categories=0
add_category "File"
add_category "Edit"
add_category "Table"
add_category "Debug"
add_category "Help"

main_menu () {
# open the main menu at the top

local category_index
category_index=0  # start with "File"

# clear any notice
clear_notice

# dim out the selected cell
((i=sel_row*columns+sel_col))
draw_cell "${cell_data[i]}" $sel_row $sel_col ${cell_status[i]} $cell_mode_inactive

while true ; do

  # unhighlight the previous selection and highlight the selected category
  home
  echo -ne "$window_row_menubar"
  goto_xy ${category_x[category_index]} 0
  echo -ne "$menu_color_se ${category_name[category_index]} "

  # get a keypress  
  k=""
  read -n1 -s k

  ####################
  ###  ESC SEQUENCE
  ####################

  if [ "$k" == $escape ] ; then  # escape sequence starting
    parse_esc 1  # ESC keypress alone will return "ESC" instead of opening the menu
    if [ -z "$k" ] ; then
      # parse unsuccessful
      unsupported_sequence $LINENO
      continue
    fi
    # $k is set to some text command like PGUP or NOOP
    #debug_parser "parsed: $k"
  fi

  # we have a keypress (possibly an ESC sequence label) of some sort now.  it MAY be something we don't support while editing though, like PGUP or END
  debug "MENU CATEGORY parsing keypress \"$k\""

  # right now we support left, right, return, and esc

  ####################
  ###  LEFT
  ####################

  if [ "$k" == "LEFT" ] ; then
    ((category_index--))
    if [ $category_index == -1 ] ; then
      ((category_index=categories-1))
    fi
    continue

  ####################
  ###  RIGHT
  ####################

  elif [ "$k" == "RIGHT" ] ; then
    ((category_index++))
    if [ $category_index == $categories ] ; then
      ((category_index=0))
    fi
    continue

  ####################
  ###  ESC
  ####################

  elif [ "$k" == "ESC" ] ; then
    # unhighlight the previous selection and return to browsing
    home
    echo -ne "$window_row_menubar"
    k="NOOP"
    return

  ####################
  ###  RETURN / DOWN
  ####################

  elif [[ ("$k" == "") || ("$k" == "DOWN") ]] ; then
    # user pressed RETURN (or DOWN), pop open a category
    # slightly dim the selected category so the popup menu options are more obviously selected
    goto_xy ${category_x[category_index]} 0
    echo -ne "$menu_color_op ${category_name[category_index]} "
    # pop open the currently selected (category_index) popup category, get a selection, and perform an action
    category_popup

    # popup did some kind of action, exit menu and return to browsing
    if [ $menu_return_to_browsing ] ; then
      return
    fi
    
    # hit ESC or otherwise cancelled the category popup, continue to display menu

  ####################
  ###  CTRL-X
  ####################

  elif [ "$k" == $ctrl_x ] ; then
    # quit if there are no unsaved changes
    fast_quit 0

    # user cancelled fast-quit
    continue

  ####################
  ###  INVALID
  ####################

  else

    invalid_command $LINENO
    debug "unimplemented menu at $LINENO, should not happen"

 fi

done
}





########################################################################################################################
########################################################################################################################
###
###  MENU OPTIONS
###
########################################################################################################################
########################################################################################################################


#########################################
###  DISPLAY HELP
#########################################

display_help () {
# display available key commands

box_popup 61 41 "BROWSE SQL version $vers"
if [ ! $popup_ok ] ; then
  # window isn't tall enough
  return
fi

box_print "
while browsing a table:

            arrows - move selection
            RETURN - edit selected cell
            DELETE - clear selected cell
            ESC    - access menu
            TAB    - select cell to right

    SHIFT + PGUP   - scroll to previous page
            PGDN   - scroll to next page
            LEFT   - scroll to first column
            RIGHT  - scroll to last column
            HOME   - scroll to first record
            END    - scroll to last record
            TAB    - select cell to left

     CTRL + C      - copy selected cell to clipboard
            V      - paste clipboard to selected cell
            B      - append row
            D      - delete or undelete selected row
            F/W    - find / new find
            G      - find again
            L      - reload database and highlight changes
            O      - quick save
            R      - refresh screen
            X      - quick quit

while editing a cell:

            ESC    - discard changes and return to browse
            RETURN - save cell and return to browse
            UP     - save cell and edit cell above
            DOWN   - save cell and edit cell below
            TAB    - save cell and edit cell to right

    SHIFT + TAB    - save cell and edit cell to left

     CTRL + A      - move cursor to beginning of cell
            E      - move cursor to end of cell text
"

box_press_return

}



#########################################
###  DISPLAY CHANGES
#########################################

display_changes () {
# display changes that will need to be made to the database when saving
# will do this in fullscreen beause it's sooo much easier
# this is basically the sql commands executed when saving

# dump change array into temp_file
echo "Displaying SQLITE3 change file...

Use W and F to scroll up and down, press Q when done:
" > "$temp_file"
create_change_file 1

# display it and then return to the menu, which will return to the browser
echo -ne "$ansi_cmd_coloroff"
cat "$temp_file" | less

# return to browser
rm "$temp_file"
refresh_window

}



#########################################
###  DISPLAY SCHEMA
#########################################

display_schema () {
# display database schema

# create output header
echo "Displaying database schema for $database...

Use W and F to scroll up and down, press Q when done:
" > "$temp_file"

# add schema to output file
do_sql $LINENO "load schema" ".schema"
echo "$result" >> "$temp_file"

# display it and then return to the menu, which will return to the browser
echo -ne "$ansi_cmd_coloroff"
cat "$temp_file" | less

# return to browser
rm "$temp_file"
refresh_window

}



#########################################
###  DELETE ROW
#########################################

# need to initialize:
#   row_deleted[] to blank for all selectable rows (also when adding a row)
#   rows_deleted=0 when loading


delete_row () {
# mark the currently selected row as deleted
# may still make edits to it but they won't matter
# does not shift rows or change end markers
# rows will be deleted by rowid (from bottom to top) after all edits

if [ ${row_deleted[sel_row]} ] ; then
  # row is already deleted, UNdelete it
  row_deleted[sel_row]=
  ((rows_deleted--))
  draw_notice "row ${rowid[sel_row]} unmarked for delete"
else
  # delete row
  row_deleted[sel_row]=1
  ((rows_deleted++))
  draw_notice "row ${rowid[sel_row]} marked for delete"
  #change[changes]="DELETE FROM $table where ROWID IS ${rowid[sel_row]}"
fi
# do not increment $changes since we are not adding to the change array right now

# move cursor to start of cell plus specified index (if any)
# index probably only used during cell editing, for placement of cursor

# print a bullet or a pipe on the left
goto_xy 0 $((sel_row-window_top_row+4))
if [ ${row_deleted[sel_row]} ] ; then
  # bullet
  echo -ne "$table_color_del$ansi_cmd_streamon$ansi_bullet$ansi_cmd_streamoff"
else
  # pipe
  echo -ne "$table_color_border$ansi_cmd_streamon$ansi_pipe$ansi_cmd_streamoff"
fi
draw_rowinfo

}



#########################################
###  APPEND ROW
#########################################

append_row () {
# append a new empty row at the bottom of the database
# new cells are initialized as blank ("") and have their change color set
# append entry is also added to change list

# we have a hardcoded limit of 99,999 rows, due only to row printing at the bottom of the table, though
# it's probably impractical to work with at that size anyway
if [ $rows -ge 99999 ] ; then
  debug "too many rows to add another"
  invalid_command $LINENO
  return
fi

# add the row and fill it with blanks ("", not NULL) and mark all of them as changed
c1=
c2=
for ((c=0;c<columns;c++)) ; do
  c1="$c1,${column_name[c]}"
  c2="$c2,''"
  ((i=rows*columns+c))
  cell_data[i]=""
  cell_status[i]=$cell_status_changed
done
((rows++))

# recreate the END markers
create_end_markers 

debug "predict the new ROWID"
# 1 if first record
# (ROWID of formerly last record)+1 otherwise
if [ $rows == 1 ] ; then
  debug "there was no previous row"
  rowid[rows-1]=1
else
  ((rowid[rows-1]=rowid[rows-2]+1))
  debug "previous last rowid[rows-1] = rowid[$((rows-1))] = ${rowid[rows-1]}"
fi
debug "new rowid = ${rowid[rows-1]}"

# record the append
change[changes]="INSERT INTO $table (${c1:1}) VALUES (${c2:1})"
((changes++))

# move selection to appended row, first column
((sel_row=rows-1))
sel_col=0
scroll_check

# redraw the window and table (there will be no scrolling)
define_window_at $LINENO
refresh_window "appended row $rows"
debug "row appended"
}



#########################################
###  APPEND TEXT FILE
#########################################

append_text_file () {
# import records from CSV or TXT file, append to current table
# records must be in the same order as in the table's schema
# (there will be no dialog to match up import colums to the columns of the database)

local i r c clist line lines n n2 jump_to t

# select a CSV/TXT file from current directory
select_file "APPEND FROM TEXT FILE" "\.\(\(csv\)\|\(CSV\)\|\(txt\)\|\(TXT\)\)$"  # sooo many delimiters....
if [ -z "$selected_file" ] ; then
  # they didn't pick a file
  draw_notice "Append from text file cancelled"
  return
fi

# load the text file
lines=0
while read line[lines] ; do
  ((lines++))
done < "$selected_file"
debug "loaded $lines lines from \"$selected_file\""

# abort if it's empty
if [ $lines == 0 ] ; then
  popup_message "APPEND TEXT FILE" "text file contains no data"
  return
fi

# build comma-delimited field list
clist=
for ((c=0;c<columns;c++)) ; do
  clist="${clist},${column_name[c]}"
done
clist=${clist:1}
debug "clist = \"$clist\""

# append lines to cells and changes arrays
jump_to=$rows
t=0
for ((r=0;r<lines;r++)) ; do
  n=${line[r]}
  n=$(echo "$n" | tr '"' ':' | tr "'" ':' | tr '|' ':')
  debug "processing line $r: \"$n\""
  c=0
  ch="INSERT INTO $table ($clist) VALUES ("
  n2=""
  while [ "$n" != "$n2" ] ; do
    # isolate data
    nt=${n%%$'\t'*}
    nc=${n%%,*}
    n2=$n
    if [ ${#nt} -le ${#nc} ] ; then
      # tab delimiter found
      x=$nt
      n=${n#*$'\t'}
    else
      # if no tab found, use comma
      x=$nc
      n=${n#*,}
    fi
    # build change
    ch="${ch}'$x',"
    # store to cell
    ((i=rows*columns+c))  # not rows+r since both r and rows are being incremented
    cell_data[i]=$x
    cell_status[i]=$cell_status_changed
    ((c++))
  done
  # add change
  ch="${ch:0:${#ch}-1})"
  debug "adding change: \"$ch\""
  change[changes++]="$ch"
  # add row
  ((rows++))
  # progress indicator for large tables
  ((t++))
  if [ $((t/progress_interval*progress_interval)) == $t ] ; then
    draw_notice "importing row $t/$lines"
  fi
done
clear_notice

# recreate the END markers
create_end_markers

# finished with append.  move selection and window so first row added is visible
sel_row=$jump_to
sel_col=0
scroll_check 1  # scroll if necessary, and redefine window even if it's not scrolling
refresh_window
popup_message "APPEND TEXT FILE" "Appended $lines records"
k="NOOP"

}



#########################################
###  EXPORT TABLE
#########################################

export_table () {
# export current table to a table (dump) file
local t

t="$table"  # "{QUOTE}Disposed{QUOTE}"
t=${t:1}  # "Disposed{QUOTE}"
t=${t%\"}  # "Disposed"

# will export to CWD, file name will be {table name}.TABLE (name is not user-defined)
f="${t}.TABLE"

# export table schema
#do_sql $LINENO "export schema to table file" ".schema $table"
#echo "$result" > "$f"

# export table data
do_sql $LINENO "export data to table file" ".dump $table"
echo "$result" > "$f"

popup_message "EXPORT TABLE" "table \"$t\" exported to $f"

}



#########################################
###  EXPORT TEXT FILE
#########################################

export_text_file () {
# export current table to an easily readable columned text file

local f r c p i t

# get usable text file name
f="${table}.txt"
while true ; do
  # accept input of filename to export to
  popup_entry "ENTER NAME OF TEXT FILE" 40 "$f"
  if [[ $entry_escaped || (-z "$entry_result") ]] ; then
    # user hit ESC, or hit RETURN with a blank entry
    refresh_window "export cancelled"
    return
  fi
  f=$entry_result
  if [ "$f" == "$database" ] ; then
    echo -n $'\a'
    popup_message "SAFETY" "cannot replace database with text file"
    f="${table}.txt"
    continue
  fi
  if [ -f "$f" ] ; then
    # specified filename already exists, confirm replacement
    popup_confirm "Replace existing \"$f\"?"
    if [ $confirmed ] ; then
      rm "$f" ; rc=$?
      if [ $rc != 0 ] ; then
        # got an error removing existing file
        echo -n $'\a'
        popup_message "FILE ERROR" "error code $rc trying to remove existing \"$f\""
        continue
      fi
      # existing file was removed, proceed with export
      break
    fi
    continue
  fi
  # verify specified path is writable
  touch "$f" ; rc=$?
  if [ $rc == 0 ] ; then
    # specified file path looks usable, proceed with export
    rm "$f"
    break
  fi
  # got an error trying to access the specified path
  echo -n $'\a'
  popup_message "FILE ERROR" "unable to create new file at \"$f\""
done

# determine necessary column widths
for ((c=0;c<columns;c++)) ; do
  p=${#column_name[c]}
  for ((r=0;r<rows;r++)) ; do
    ((i=r*columns+c))
    n=${#cell_data[i]}
    if [ $p -lt $n ] ; then
      p=$n
    fi
  done
  print_width[c]=$p
done

for ((c=0;c<columns;c++)) ; do
  debug "print_width[$c] = ${print_width[c]}"
done

# export settings
column_spacing="  "

# export header
echo -n > "$f"
echo -n "${column_name[0]}${spaces:0:${print_width[0]}-${#column_name[0]}}" >> "$f"
for ((c=1;c<columns;c++)) ; do
  echo -n "$column_spacing${column_name[c]}${spaces:0:${print_width[c]}-${#column_name[c]}}" >> "$f"
done
echo >> "$f"

# export divider
echo -n "${dashes:0:${print_width[0]}}" >> "$f"
for ((c=1;c<columns;c++)) ; do
  echo -n "$column_spacing${dashes:0:${print_width[c]}}" >> "$f"
done
echo >> "$f"

# export records as they are (value and order) in the loaded array (which may have been edited and/or sorted)
t=0
for ((r=0;r<rows;r++)) ; do
  ((i=r*columns))
  # this is MUCH faster than doing it one cell at a time
  x="${cell_data[i]}${spaces:0:${print_width[0]}-${#cell_data[i]}}"
  for ((c=1;c<columns;c++)) ; do
    ((i=r*columns+c))
    x="$x$column_spacing${cell_data[i]}${spaces:0:${print_width[c]}-${#cell_data[i]}}"
  done
  echo "$x" >> "$f"
  # progress indicator for large tables
  ((t++))
  if [ $((t/progress_interval*progress_interval)) == $t ] ; then
    draw_notice "exporting row $t/$rows"
  fi
done
clear_notice

popup_message "EXPORT TABLE" "table \"$table\" exported to $f"

}



#########################################
###  SORT BY COLUMN
#########################################

sort_by_column () {
# sort display by 1, 2, or 3 columns - this is one reason why we have to keep track of row numbers

local pi c r i ii alpha alpha_index x

# alphabetize column names
echo -n > "$temp_file"
# create a list of name,index
for ((c=0;c<columns;c++)) ; do
  echo "${column_name[c]},$c" >> "$temp_file"
done
sort "$temp_file" > "$temp_file2"
for ((c=0;c<columns;c++)) ; do
  read x
  alpha[c]=${x%,*}
  alpha_index[c]=${x#*,}
  debug "sort option $c = \"${alpha[c]}\" / \"${alpha_index[c]}\""
done < "$temp_file2"
rm "$temp_file"
rm "$temp_file2"

# populate popup with column names
new_popup_menu "SELECT FIRST COLUMN"
for ((c=0;c<columns;c++)) ; do
  new_popup_option "${alpha[c]}"
done

# select first column
if [ $columns == 1 ] ; then
  # there's only one column, automatically select it and sort without any prompt
  sort_col_index[0]=0
  sort_cols=1
  by=${column_name[0]}
else
  display_popup_menu
  debug "got menu option $popup_index \"$popup_result\""
  if [ $popup_index == -1 ] ; then
    # user cancelled
    draw_notice "sort cancelled"
    return
  fi
  sort_col_index[0]=$popup_index
  sort_cols=1
  by="$popup_result"
  now=
fi

# select second column
if [ $columns -gt 1 ] ; then
  # populate popup with column names
  new_popup_menu "SELECT SECOND COLUMN"
  new_popup_option "(SORT NOW)"
  for ((c=0;c<columns;c++)) ; do
    if [ $c == ${sort_col_index[0]} ] ; then
      new_popup_option "${alpha[c]}" 1  # disable first selection
    else
      new_popup_option "${alpha[c]}"
    fi
  done
  # select second column
  display_popup_menu
  debug "got menu option $popup_index \"$popup_result\""
  if [ $popup_index == -1 ] ; then
    # user cancelled
    draw_notice "sort cancelled"
    return
  elif [ $popup_index != 0 ] ; then
    ((sort_col_index[1]=popup_index-1))  # -1 to skip "(select now)"
    sort_cols=2
    by="$by,$popup_result"
  fi
fi

# select third column
if [[ ($columns -gt 2) && ($sort_cols == 2) ]] ; then
  # populate popup with column names
  new_popup_menu "SELECT THIRD COLUMN"
  new_popup_option "(SORT NOW)"
  for ((c=0;c<columns;c++)) ; do
    if [[ ($c == ${sort_col_index[0]}) || ($c == ${sort_col_index[1]}) ]] ; then
      new_popup_option "${alpha[c]}" 1  # disable first and second selections
    else
      new_popup_option "${alpha[c]}"
    fi
  done
  # select third column
  display_popup_menu
  debug "got menu option $popup_index \"$popup_result\""
  if [ $popup_index == -1 ] ; then
    # user cancelled
    draw_notice "sort cancelled"
    return
  elif [ $popup_index != 0 ] ; then
    ((sort_col_index[2]=popup_index-1))  # -1 to skip "(select now)"
    sort_cols=3
    by="$by,$popup_result"
  fi
fi

debug "sort_cols = \"$sort_cols\""
debug "by = \"$by\""
for ((i=0;i<sort_cols;i++)) ; do
  debug "sort_col_index[$i] = \"${sort_col_index[i]}\""
  debug "alpha_index[sort_col_index[$i]] = \"${alpha_index[sort_col_index[i]]}\""
  debug "alpha[sort_col_index[$i]] = \"${alpha[sort_col_index[i]]}\""
done

# generate sortable file for SORT to process
echo -n > "$temp_file"
for ((r=0;r<rows;r++)) ; do
  # concatinate all columns to be sorted, in specified order
  ((i=columns*r+alpha_index[sort_col_index[0]]))
  x="${cell_data[i]}"
  if [ $sort_cols -ge 2 ] ; then
    ((i=columns*r+alpha_index[sort_col_index[1]]))
    x="${x} ${cell_data[i]}"
    if [ $sort_cols -ge 3 ] ; then
      ((i=columns*r+alpha_index[sort_col_index[2]]))
      x="${x} ${cell_data[i]}"
    fi
  fi
  # and add on record number last, both as a sorting key and as an identifier so we can tell what record this was after it has been sorted
  # (this is reord number, NOT rowid)
  j="    $r"
  j=${j:${#j}-4}
  echo "$x"$'\t'"$j" >> "$temp_file"
done
debug "created sort file at \"$temp_file\" with $rows rows"
#cp "$temp_file" "$temp_file2"

# sort it
x=$(cat "$temp_file")
rm "$temp_file"
echo "$x" | sort > "$temp_file"
debug "sort complete"
# now we can read the file back in and look at the order the record numbers are in to determine how to shuffle the data from previ back to current

# read in sort
for ((r=0;r<rows;r++)) ; do
  read x
  sorted[r]=${x#*$'\t'}  # we only care about record numbers
done < "$temp_file"
#echo "SORT INDEX LIST" > "$temp_file"
#for ((r=0;r<rows;r++)) ; do
#  echo "${sorted[r]}" >> "$temp_file"
#done
rm "$temp_file"
debug "read back in sort file at \"$temp_file\""

# backup table
((ii=rows*columns))
t=0
((pi=progress_interval*columns))
for ((i=0;i<ii;i++)) ; do
  # we can just blow straight through the entire table since we don't care about row and column boundaries in the 2d array when backing it up
  prev_cell[i]=${cell_data[i]}
  prev_status[i]=${cell_status[i]}
  # update progress
  ((t++))
  if [ $((t/pi*pi)) == $t ] ; then
    draw_notice "backing up row $t/$rows"
  fi
done
for ((r=0;r<rows;r++)) ; do
  prev_rowid[r]=${rowid[r]}
done
clear_notice
debug "table backed up prior to sorting"

# we don't need to backup the column information because that won't get changed
# same goes for the END row
# any actual changes are also unaffected by sorting the display
# that's the wonderful thing about databases...  the actual order the records are in doesn't have to matter

# copy table back in the sorted order
t=0
for ((r=0;r<rows;r++)) ; do
  pr=${sorted[r]}
  ((i=r*columns))  # index of first new cell in row
  ((ip=pr*columns))  # index of first previous cell in row
  for ((c=0;c<columns;c++)) ; do
    cell_data[i]=${prev_cell[ip]}
    cell_status[i]=${prev_status[ip]}
    ((i++))
    ((ip++))
  done
  rowid[r]=${prev_rowid[pr]}
  # update progress
  ((t++))
  if [ $((t/progress_interval*progress_interval)) == $t ] ; then
    draw_notice "sorting row $t/$rows"
  fi
done
clear_notice

debug "table restored in sorted order"
# now since we edit via rowid, and the rowid still tracks with the cell data, this doesn't do anything to the sql table
# the only possible issues now are things that affect rowids, such as appending a record
# (and tables that need vacuuming would make this a mess)
# so we just need to keep in mind the largest rowid may not be at the bottom anymore when appending a record,
# because we have to predict the new record's rowid when adding the record

# make sure this memory gets freed immediately
unset prev_cell
unset prev_status
unset prev_rowid

# and of course we need to refresh the window
refresh_window "table sorted by $by"

}



#########################################
###  IMPORT TABLE
#########################################

import_table () {
# import table to file - create new table or append to existing name

local newtable t

# select a TABLE file from current directory (created with EXPORT TABLE which .dump's a table as a text file)
select_file "IMPORT TABLE" "\.\(\(TABLE\)\|\(table\)\)$"
if [ -z "$selected_file" ] ; then
  # they didn't pick a file
  draw_notice "Import table file cancelled"
  return
fi

# get table name (may differ from filename)
newtable=$(cat "$selected_file" | grep "^CREATE TABLE ")  # "CREATE TABLE Jobs (job_id CHAR(10) PRIMARY KEY, name CHAR(20), type CHAR(4), reboots INT(7), every INT(10));"
newtable=${newtable:13}  # "Jobs (job_id CHAR(10) PRIMARY KEY, name CHAR(20), type CHAR(4), reboots INT(7), every INT(10));"
newtable=${newtable%% *}  # "Jobs"
if [ -z "$newtable" ] ; then
  popup_message "IMPORT TABLE" "ERROR: no table found in \"$selected_file\""
  return
fi

# check to see if we are appending to an existing table or creating a new table
catalog_tables  # refresh dtable[dtables], probably not necessary
for ((t=0;t<dtables;t++)) ; do
  if [ "${dtable[t]}" == "$newtable" ] ; then
    break
  fi
done

# add or append table
if [ $t == $dtables ] ; then
  # new table - add to table list
  dtable[dtables]="$newtable"
  cat "$selected_file" > "$temp_file"
else
  # append to existing table - strip table creation entry
  cat "$selected_file" | grep -v "^CREATE TABLE " > "$temp_file"
fi
do_sql $LINENO "append table" "$(cat "$temp_file")"

# switch to imported table
debug "switching to table \"$newtable\""
browsing_new_table "$newtable"

}



#########################################
###  MONITOR TABLE
#########################################

monitor_table () {
# monitor a table for changes made to saved database
# is only capable of detecting changes to fields in existing records (does not detect deletes or inserts)

local spotted r c k i n cr ch h kl kn rr

repaint_me=1

clear_notice
changes_detected=0
((cr=rows/20))
hh="                   *                   "

rr=0
kl=99
k="no"
while [ "$k" == "no" ] ; do

  # if user has resized window, repaint some fields
  if [ $repaint_me ] ; then
    repaint_me=
    #(re)draw the footer
    goto_xy 0 $((LINES-1))
    echo -ne "${table_color_header}[                    ]  ${pop_color_bren}    0 changes spotted - press any key top stop monitoring"
    # make sure the selected cell isn't showign as selected
    ((i=sel_row*columns+sel_col))
    draw_cell "${cell_data[i]}" $sel_row $sel_col ${cell_status[i]} $cell_mode_browsing
  fi

  debug "load the entire table to result"
  do_sql $LINENO "download one record" "SELECT ROWID,$field_list FROM $table ORDER BY ROWID"

  # loop through all records
  for ((r=0;r<rows;r++)) ; do

    # peel off record $r
    record="${result%%$'\n'*}"
    result=${result#*$'\n'}

    # confirm rowid has not changed
    ri=${record%%|*}
    record=${record#*|}
    if [ ${rowid[r]} != $ri ] ; then
      # we PROBABLY should abort the script completely since we don't support someone inserting/deleting/appending records while we browse it...
      draw_error "row id has changed on record index $r from ${rowid[r]} to $ri"
      return
    fi

    # update animation if needed
    if [ $cr == 0 ] ; then
      # fewer than 20 rows
      ((kn=rr%20))  # use refresh count as a seed instead of row number
    else
      # at leat 20 rows
      ((kn=r/cr))    # DIVISION BY 0 ERROR ON TABLES WITH FEWER THAN 20 ROWS
    fi
    if [ $kn != $kl ] ; then
      # increment monitor status animation
      kl=$kn
      goto_xy 1 $((LINES-1))
      echo -ne "${table_color_header}${hh:19-kl:20}"
    fi

    # check all fields in this row
    for ((c=0;c<columns;c++)) ; do
      ((i=r*columns+c))

      # fetch next field
      n=${record%%|*}
      record=${record#*|}

      if [ "${cell_data[i]}" == "$n" ] ; then
        # hasn't changed (or hasn't changed AGAIN)
        continue
      fi

      # reload changed field
      cell_status[i]=$cell_status_reloaded
      debug "change $changes_detected at ($r,$c,$i) \"${cell_data[i]}\" -> \"$n\""
      cell_data[i]=$n

      # update changes detected
      ((changes_detected++))
      goto_xy $((29-${#changes_detected})) $((LINES-1))
      echo -ne "${pop_color_bren}$changes_detected"

      # if it's visible on-screen, redraw it
      if [ $r -lt $window_top_row ] ; then
        # off screen to-top
        continue
      elif [ $r -ge $((window_top_row+window_lines)) ] ; then
        # cell is off-screen to bottom
        continue
      elif [ $c -lt $window_left_column ] ; then
        # off screel to left
        continue
      elif [ $c -ge $((window_left_column+window_columns)) ] ; then
        # off screen to right
        continue
      fi

      # reloaded cell is visible on screen, redraw it
      draw_cell  "${cell_data[i]}" $r $c $cell_status_reloaded $cell_mode_browsing

    done  # next field

  done  # next record
  ((rr++))  # increment the animtion for tables with fewer than 21 rows
  set +e  # allow read to return nonzero exit code (for read timeout)
  read -n1 -t1 k
  rc=$?
  set -e

  debug "monitor record loop done"

done  # loop back to starting record
debug "done monitoring"
draw_notice "monitoring stopped with $changes_detected changes detected"

}



#########################################
###  SAVE TABLE
#########################################

save_table () {
# save changes to table, if any

# dump change array into temp_file   
create_change_file

# try to execute changes to the database
chmod +x "$temp_file"
((retries=max_db_attempts))
while [ $retries -gt 0 ] ; do
  set +e ; "$temp_file" ; rc=$? ; set -e
  debug "change file returned exit code $rc"
  if [ $rc == 0 ] ; then
    break
  fi
  # got an error trying to save.  sqlite should have rolled back any partial changes, but it's probably a db locked error so nothing would be changed anyway
  ((retries--))
  # display retry progress
  draw_error "CODE $rc TRYING TO SAVE CHANGES, RETRY $retries"
  if [ $retries -gt 0 ] ; then
    sleep 1
  fi
done
rm "$temp_file"

# handle error-out
if [ $retries == 0 ] ; then
  # reached limit
  # popup error
  popup_message "TABLE SAVE FAILED" "SQL returned code $rc trying to save"
  return
fi

# database was updated, now we need to update our local data (it's faster than reloading the database)

# commit changes to internal data structures
((s2=sel_row))

# shift data up if any rows were deleted
if [ $rows_deleted != 0 ] ; then
  # row(s) were deleted, shift data up
  r1=0  # row copying to
  for ((r2=0;r2<rows;r2++)) ; do  # row copying from
    # we will assume ROWIDs do not change.  we cannot vacuum because there's no way to know for sure what it will do with the ROWIDs (we'd have to reload the database to see)
    #((rowid[r1]=r1+1))
    if [ ${row_deleted[r2]} ] ; then
      row_deleted[r2]=""
      # row r2 is being deleted, do not copy it
      if [ $r2 -le $sel_row ] ; then
        # move row selection up for each row deleted above selected row
        ((s2--))
      fi
      continue  # just increment r2, not r1
    elif [ $r1 == $r2 ] ; then
      # no deletes occurring earlier than r1 no need to copy anything yet
      ((r1++))
      continue
    fi
    # row r2 needs to be shifted up, copy row r2 to row r1's array position (data and cell color/status)
    for ((c=0;c<columns;c++)) ; do
      # shift up row r2 cell data and default cell color to row r1
      ((i=r1*columns+c))
      ((j=r2*columns+c))
      cell_data[i]="${cell_data[j]}"
      cell_status[i]="${cell_status[j]}"
    done
    rowid[r1]=${rowid[r2]}
    ((r1++))
  done
fi

# update row count
((rows-=rows_deleted))

# shift up selected row for rows deleted at/before it
((sel_row=s2))
if [ $sel_row -lt 0 ] ; then
  #deleted the first row which was also selected
  sel_row=0
fi

# recreate the END markers since rows may have been deleted
create_end_markers

# redraw window to remove changed cell highlights and dirty flag
changes=0
rows_deleted=0
for ((r=0;r<rows;r++)) ; do
  for ((c=0;c<columns;c++)) ; do
    ((i=r*columns+c))
    cell_status[i]=$cell_status_unchanged
  done
done

# may need to move the cursor, or even scroll the screen
scroll_check  1
refresh_window "database saved"

}



#########################################
###  CHANGE TABLE
#########################################

change_table () {
# select a table from the available tables in the active database

local t

# list tables
catalog_tables

# if this database has no tables, make one
if [ $dtables == 0 ] ; then
  debug "no tables to select from, will create newtable"
  do_sql $LINENO "create default table" "CREATE TABLE newtable (key CHAR(10), value INT(8))"
  catalog_tables
fi

# if there's only one table in the database, this must be a startup call. autoselect it
if [ $dtables == 1 ] ; then
  debug "selected only table in database: ${dtable[0]}"
  browsing_new_table "${dtable[0]}"
  return
fi

# populate popup with table names
new_popup_menu "SELECT TABLE"

# find longest table name
n=0
for ((t=0;t<dtables;t++)) ; do
  if [ ${#dtable[t]} -gt $n ] ; then
    n=${#dtable[t]}
  fi
done

# build popup of table names
# normally we'd let the popup menu handle normalizing the widths, but we want to include record counts to the right of the names, right-justified
for ((t=0;t<dtables;t++)) ; do
  #new_popup_option "${dtable[t]}"
  new_popup_option "${dtable[t]}${spaces:0:n-${#dtable[t]}+2}  ${spaces:0:5-${#dtable_count[t]}}${dtable_count[t]}"
done

# select a table
display_popup_menu
debug "got menu option $popup_index \"$popup_result\""

# load selected table
if [ -n "$popup_result" ] ; then
  browsing_new_table "${dtable[popup_index]}"  # use index because popup result will have count tacked on
fi

k="NOOP"
return

}





########################################################################################################################
########################################################################################################################
###
###  EDIT FUNCTIONS
###
########################################################################################################################
########################################################################################################################


#########################################
###  SAVE EDIT
#########################################

save_edit () {
# save any change to a cell

local i br
if [ ${#@} != 0 ] ; then
  br=1
else
  br=
fi

# prepare to store changed cell in array
edit_buffer=$(echo "$edit_buffer" | sed 's/[ ]*$//g')  # trim spaces off right
((i=sel_row*columns+sel_col))

# only make changes if the cell is actually different than it was before
if [ "${cell_data[i]}" != "$edit_buffer" ] ; then
  # the cell was changed
  cell_data[i]="$edit_buffer"
  cell_status[i]=$cell_status_changed
  change[changes]="UPDATE $table SET ${column_name[sel_col]}='$edit_buffer' WHERE ROWID IS ${rowid[sel_row]}"
  ((changes++))
  if [ $changes == 1 ] ; then
    # immediately indicate the first cell change of this session
    draw_rowinfo
  fi
  # might want to visually flag the "dirty" state on the bottom menu bar?
fi

# remove cell highlight
if ! [ $br ] ; then
  # cell edit (not browse edit)
  draw_cell "$edit_buffer" $sel_row $sel_col ${cell_status[i]} $cell_status_unchanged
fi

}



#########################################
###  EDIT START
#########################################

edit_start () {
# prepare to edit a cell

# grab cell data
((i=sel_row*columns+sel_col))
edit_width=${column_size[sel_col]}
edit_buffer="${cell_data[i]}"  # is probably NOT right-padded with spaces

# pad to column width
edit_buffer="${edit_buffer}${spaces}"
edit_buffer=${edit_buffer:0:edit_width}

# start edit at start of whitespace on end of cell (or at end of cell if there is no whitespace on the right)
e="${edit_buffer%"${edit_buffer##*[![:space:]]}"}"  # ugly but fast.  using shell substitution only to trim right whitespace.  e=${e%% } does not work for some reason, behaves like =${e% }
debug "trimmed e = \"$e\" length ${#e}"
edit_index=${#e}
debug "initialize edit buffer at $sel_row,$sel_col [$i] with \"$edit_buffer\", cursor at index $edit_index"

echo -ne "$ansi_cmd_cursoron"

}



#########################################
###  EDIT CELL
#########################################

edit_cell () {
# user has pressed RETURN while browsing, edit the cell

local i
edit_start
((i=sel_row*columns+sel_col))

# move the cursor around and get key inputs
while true ; do
  # redraw cell in editing color
  draw_cell "$edit_buffer" $sel_row $sel_col ${cell_status[i]]} $cell_mode_editing
  # position the cursor
  goto_cell $((sel_row+1)) $sel_col $edit_index
  k=""   
  read -n1 -s -r k
  #debug_parser "parsing key sequence (length ${#k}): \$$(echo -n "$k" | xxd -u -p)"

  ####################
  ###  ESC SEQUENCE
  ####################

  if [ "$k" == $escape ] ; then  # escape sequence starting
    parse_esc 1  # ESC keypress alone will return "ESC" instead of opening the menu
    if [ -z "$k" ] ; then
      # parse unsuccessful
      unsupported_sequence $LINENO
      continue
    fi
    # $k is set to some text command like PGUP or NOOP
    #debug_parser "parsed: $k"
  fi
  # we have a keypress (possibly an ESC sequence label) of some sort now.  it MAY be something we don't support while editing though, like PGUP or END
  #debug_parser "editor got k = \$$(echo -n "$k" | xxd -u -ps)"

  ####################
  ###  LEFT
  ####################

  if [ "$k" == "LEFT" ] ; then
    # move left one character
    if [ $edit_index == 0 ] ; then
      # can't arrow left past leftmost character in cell
      invalid_command $LINENO
      continue
    fi
    ((edit_index--))

  ####################
  ###  RIGHT
  ####################

  elif [ "$k" == "RIGHT" ] ; then
    # move right one character
    if [ $edit_index == $edit_width ] ; then
      # can't arrow right past righmtost character in cell
      invalid_command $LINENO
      continue
    fi
    ((edit_index++))
    # this may be as large as $edit_width, which is one character past the cell's data (not editable)

  ####################
  ###  CTRL-A
  ####################

  elif [ "$k" == $ctrl_a ] ; then
    # move cursor to first character
    if [ $edit_index == 0 ] ; then
      # you're already at the start of the cell, silly
      k="CTRL-A"
      invalid_command $LINENO
      continue
    fi
    edit_index=0

  ####################
  ###  CTRL-E
  ####################

  elif [ "$k" == $ctrl_e ] ; then
    # move cursir to last character
    if [ $edit_index == $edit_width ] ; then
      # you're already at the end of the cell, silly
      k="CTRL-E"
      invalid_command $LINENO
      continue
    fi
    e="${edit_buffer%"${edit_buffer##*[![:space:]]}"}"
    edit_index=${#e}

  ####################
  ###  UP
  ####################

  elif [ "$k" == "UP" ] ; then
    # move selection up one cell
    save_edit
    if [ $sel_row == 0 ] ; then
      invalid_command $LINENO
      continue
    fi
    ((sel_row--))
    scroll_check
    draw_rowinfo
    edit_start
    continue

  ####################
  ###  DOWN
  ####################

  elif [ "$k" == "DOWN" ] ; then
    # move selection down one cell
    save_edit
    if [ $sel_row -ge $((rows-1)) ] ; then
      invalid_command $LINENO
      continue
    fi
    ((sel_row++))
    scroll_check
    draw_rowinfo
    edit_start
    continue

  ####################
  ###  SHIFT+TAB
  ####################

  elif [ "$k" == "UNTAB" ] ; then
   # move selection left one cell
   if [ $sel_col == 0 ] ; then
      invalid_command $LINENO
      continue
    fi
    save_edit
    ((sel_col--))
    scroll_check
    draw_rowinfo
    edit_start
    continue

  ####################
  ###  TAB
  ####################

  elif [ "$k" == $tab ] ; then
    # move selection right one cell
    if [ $sel_col == $((columns-1)) ] ; then
      invalid_command $LINENO
      continue
    fi
    save_edit
    ((sel_col++))
    scroll_check
    draw_rowinfo
    edit_start
    continue

# I have decided not to support BOLN and EOLN while editing a cell (only works while browsing)
# mainly because the user is already dealing with a beginning-of-cell and end-of-cell mechanic while editing a cell
#
#  ####################
#  ###  SHIFT+LEFT
#  ####################
#
#  elif [ "$k" == "BOLN" ] ; then
#   # move selection to the far left cell
#   if [ $sel_col == 0 ] ; then
#      invalid_command $LINENO
#      continue
#    fi
#    save_edit
#    sel_col=0
#    scroll_check
#    draw_rowinfo
#    edit_start
#    continue
#
#  ####################
#  ###  SHIFT+RIGHT
#  ####################
#
#  elif [ "$k" == "EOLN" ] ; then
#    # move selection to the far right cell
#    if [ $sel_col == $((columns-1)) ] ; then
#      invalid_command $LINENO
#      continue
#    fi
#    save_edit
#    ((sel_col=columns-1))
#    scroll_check
#    draw_rowinfo
#    edit_start
#    continue

  ####################
  ###  ESC
  ####################

  elif [ "$k" == "ESC" ] ; then
    # discard changes and return to browsing
    echo -ne "$ansi_cmd_cursoroff"
    return

  ####################
  ###  RETURN
  ####################

  elif [ -z "$k" ] ; then
    # accept cell changes if any and return to browsing
    save_edit
    echo -ne "$ansi_cmd_cursoroff"
    return

  ####################
  ###  DELETE (delete-backward)
  ####################

  elif [ "$k" == $delete ] ; then
    # delete character left of cursor and move cursor left one character
    if [ $edit_index == 0 ] ; then
      # you're already at the start of the cell, silly
      k="DELETE"
      invalid_command $LINENO
      continue
    fi
    # delete the character to the left of the index, shift in a space on the far right, and move the index left one position
    edit_buffer="${edit_buffer:0:edit_index-1}${edit_buffer:edit_index} "
    ((edit_index--))

  ####################
  ###  DEL (delete-forward)
  ####################

  elif [ "$k" == "DEL" ] ; then
    # delete character at cursor
    if [ $edit_index == $edit_width ] ; then
      # you're already at the end of the cell, silly
      k="DEL"
      invalid_command $LINENO
      continue
    fi
    # delete the character at the index, shift in a space on the far right, and leave the index where it was
    edit_buffer="${edit_buffer:0:edit_index}${edit_buffer:edit_index+1} "

  ####################
  ###  (some other unsupported escape sequence)
  ####################

  elif [ ${#k} != 1 ] ; then
    # escape sequences use 2+ character names, so this is probably an escape sequence we don't support (like "HOME" or "F2")
    invalid_command $LINENO

  ####################
  ###  (cell overflow)
  ####################

  elif [ $edit_index == $edit_width ] ; then
    # they're trying to type another character at the end of the cell, there's no more room
    echo -n $'\a'

  ####################
  ###  unsupported control (nonprintable) character
  ####################

  elif [[ "$k" =~ [[:cntrl:]] ]] ; then   # don't ask where I found this, because I really can't remember.  it's an odd bird
    #k="echo -n "$k" | xxd -u -ps)"  # "04"
    #k="\$$(echo -n "$k" | xxd -u -ps)"  # "$04"
    k="CTRL-$(echo "0: $(echo "obase=16;$(echo "ibase=16;$(echo -n "$k" | xxd -u -ps)" | bc)+64" | bc)" | xxd -r)"  # "CTRL-D"
    invalid_command $LINENO

  ####################
  ###  (any printable character)
  ####################

  else
    # insert the character into the buffer, shifting right at the insert, deleting the overflow character at the end
    #debug_parser "inserting character: \$$(echo -n "$k" | xxd -u -ps)"
    edit_buffer="${edit_buffer:0:edit_index}$k${edit_buffer:edit_index}"
    edit_buffer=${edit_buffer:0:edit_width}
    ((edit_index++))

  fi
done

# done editing - when we return to the browse loop, it will redraw this cell in browse highlight so we don't need to do that here
echo -ne "$ansi_cmd_cursoron"

}





########################################################################################################################
########################################################################################################################
###
###  BROWSING FUNCTIONS
###
########################################################################################################################
########################################################################################################################


#########################################
###  DEBUG PARSER
#########################################

debug_parser () {
# parser debugging, usually disabled

if [ $switch_debug_parser ] ; then
  debug "$1"
fi

}



#########################################
###  CLIPBOARD COPY
#########################################

clipboard_copy () {
# copy selected cell to clipboard

clipboard=${cell_data[i]}
clipboard=$(echo "$clipboard" | sed 's/[ ]*$//g')  # trim spaces off right
draw_notice "copied \"$clipboard\""

}



#########################################
###  CLIPBOARD PASTE
#########################################

clipboard="|UNDEFINED"
clipboard_paste () {
# paste clipboard to selected cell

if [ "$clipboard" == "|UNDEFINED" ] ; then
  draw_error "CLIPBOARD NOT DEFINED"
  return
fi
# paste into buffer, padding with spaces and truncating to column width
debug "clipboard = \"$clipboard\""
edit_buffer="$clipboard$spaces"
edit_buffer=${edit_buffer:0:${column_size[sel_col]}}
save_edit
draw_notice "pasted \"$clipboard\""

}



#########################################
###  FIND STRING
#########################################

previous_search=""
find_string () {
# find a specified search pattern in any cell
# search starts at selected cell, will wrap if needed
# specify $1=1 to repeat previous search without prompt
# search is case-sensitive

local wrapped i x t p again

if [ ${#@} != 0 ] ; then
  again=1
else
  again=
fi

# get search string input.  preload edit buffer with prior search if we have done a search previously
if [ $again ] ; then
  if [ -z "$previous_search" ] ; then
    # can't do it again until we've done it at least once
    draw_error "NO PREVIOUS SEARCH TO FIND AGAIN"
    return
  fi
  # repeating previous search
  draw_notice "repeating previous search for \"$previous_search\""
else
  # accept user entry of search string
  popup_entry "ENTER SEARCH STRING" 40 "$previous_search"
  if [[ $entry_escaped || (-z "$entry_result") ]] ; then
    # user hit ESC, or hit RETURN with a blank search string
    refresh_window "search cancelled"
    return
  fi
  # store search string because it will be our default when the user tries to search again
  previous_search=$entry_result
  # paint over the search entry popup
  refresh_window "searching for \"$previous_search\" ... "
fi

# adjust pattern if necessary
p="$previous_search"
p="$(echo "$p" | sed 's/\\/\\\\/g')"  # escape the escapes
if [ "${p:0:1}" == "-" ] ; then
  # escape a leading dash
  p="\\$p"
fi

# first search from current row/cell
debug "searching from current cell"
((i=sel_row*columns+sel_col+1))  # start search on NEXT cell (not CURRENT cell)
((x=columns*rows))
t=0

while [ $i -lt $x ] ; do
  h=${cell_data[i]#*$p}  # this is much faster than calling GREP a bunch of times, but has to be case-sensitive
  h=${cell_data[i]%%$p*}
  if [ "$h" != "${cell_data[i]}" ] ; then
    # found it
    debug "hit at \"${cell_data[i]}\""
    break
  fi
  ((i++))
  # progress indicator for large tables
  ((t++))
  if [ $((t/progress_interval*progress_interval)) == $t ] ; then
    draw_notice "searching row $((i/columns+1))/$rows"
  fi
done

# if not found, resume search at beginning of table
wrapped=
if [ $i == $x ] ; then
  # search hit the bottom, wrap and search back to selected cell
  debug "searching from top"
  wrapped=1
  i=0
  ((x=sel_row*columns+sel_col+1))
  while [ $i -lt $x ] ; do
    h=${cell_data[i]#*$p}  # this is much faster
    h=${cell_data[i]%%$p*}
    if [ "$h" != "${cell_data[i]}" ] ; then
      debug "hit at \"${cell_data[i]}\""
      # found it
      break
    fi
    ((i++))
    # progress indicator for large tables
    ((t++))
    if [ $((t/progress_interval*progress_interval)) == $t ] ; then
      draw_notice "searching row $((i/columns+1))/$rows"
    fi
  done
  if [ $i == $x ] ; then
    # did not find after wrap either.  not found anywhere in table.
    draw_error "\"$previous_search\" not found anywhere in table"
    return
  fi
fi

# found at i, go there
clear_notice
((sel_row=i/columns))
((sel_col=i-sel_row*columns))
debug "moving to cell at row $sel_row col $sel_col"
#refresh_window "\"$previous_search\" found at row $((sel_row+1)), column \"${column_name[sel_col]}\""
scroll_check
draw_rowinfo  # since row probably changed
if [ $wrapped ] ; then
  draw_notice "search wrapped, \"$previous_search\" found at row $((sel_row+1)), column \"${column_name[sel_col]}\""
else
  draw_notice "\"$previous_search\" found at row $((sel_row+1)), column \"${column_name[sel_col]}\""
fi

}



#########################################
###  RELOAD DATABASE
#########################################

reload_database () {
# reload the database and repaint the screen
# does not clear the screen, so you can see the values update

local r

# prevent reload if there are unsaved changes
if [[ ($changes != 0) || ($rows_deleted != 0) ]] ; then
  draw_error "can't reload database with unsaved changes"
  return
fi

# clear changes
changes=0
((i2=rows*columns))
for ((i=0;i<i2;i++)) ; do
  cell_status[i]=$cell_status_unchanged
done

# load database into array   # remember we need ROWID also since we will be making changes by ROWID when modifying or deleting records
do_sql $LINENO "download all records" "SELECT ROWID,$field_list FROM $table ORDER BY ROWID"
# the above is occasionally failing, I assume due to concurrent DB access.  but it's not erroring out for some reason  - do_sql was recoded so this may be fixed
changes_detected=0
for ((r=0;r<rows;r++)) ; do
  if [ $r == $((r/progress_interval*progress_interval)) ] ; then
    draw_notice "loading row $r/$rows"
  fi
  # these shell subs are about equally expensive as using a bunch of ROWID selects
  record="${result%%$'\n'*}"
  result=${result#*$'\n'}
  debug "loading record $r: \"$record\""
  rowid[r]=${record%%|*}
  record=${record#*|}
  for ((c=0;c<columns;c++)) ; do
    ((i=r*columns+c))

    if [ "${cell_data[i]}" == "${record%%|*}" ] ; then
      cell_status[i]=$cell_status_unchanged
    else
      cell_status[i]=$cell_status_reloaded
      ((changes_detected++))
    fi

    cell_data[i]=${record%%|*}
    record=${record#*|}
#    # grow column_size and column_width if necessary (fields like INTEGER and TEXT may have defaulted to 8 because size was not specified)
#    w=${#cell_data[i]}
#    if [ ${column_flex[c]} ] ; then
#      # this is a flexible column, check to see if it's gotten bigger
#      if [ $w -gt ${column_size[c]} ] ; then
#        column_flex[c]=$w
#        column_size[c]=$w
#        if [ $w -gt ${column_width[c]} ] ; then
#          column_width[c]=$w
#          debug "increasing width of column ${column_name[c]} to $w to accomodate \"${cell_data[i]}\" at row $r"
#        fi
#      fi
#    fi
  done
done
debug "table $table has $rows records"


# redraw table with reload indicators
draw_table
draw_rowinfo  # gets rid of the "*" changes made indicator if it was lit

draw_notice "table reloaded, $changes_detected changes detected"

}





########################################################################################################################
########################################################################################################################
###
###  BEGIN BROWSING
###
########################################################################################################################
########################################################################################################################

begin_browsing () {
# begin browsing a table after loading it

draw_rowinfo
database_up=1  # now popups will try to deselect selected cells when opening box
while true ; do

  # browse at this cell

  #debug "editing cell [$sel_row,$sel_col]"
  # highlight selected cell, turn cursor off, move (hidden) cursor to bottm left of window
  ((i=sel_row*columns+sel_col))
  draw_cell "${cell_data[i]}" $sel_row $sel_col ${cell_status[i]} $cell_mode_selected

  #  get key or escape sequence
  if [ -z "$seq" ] ; then
    k=""
    read -n1 -s k
    #debug_parser "parsing key sequence: \$$(echo -n "$k" | xxd -u -p)"
  else
    k=${seq:0:1}
    seq=${seq:1}
    #echo -n $'\a'
  fi

  ####################
  ###  ESC SEQUENCE
  ####################

  if [ "$k" == $escape ] ; then  # escape sequence starting
    parse_esc
    if [ -z "$k" ] ; then
      # parse unsuccessful
      unsupported_sequence $LINENO
      seq=
      continue
    fi
    # $k is set to some text command like PGUP or NOOP
    #debug_parser "parsed: $k"
  fi

  # remove highlight from seleted cell
  ((i=sel_row*columns+sel_col))
  draw_cell "${cell_data[i]}" $sel_row $sel_col ${cell_status[i]} $cell_mode_browsing

  ####################
  ###  UP
  ####################

  if [ "$k" == "UP" ] ; then
    if [ $sel_row -le 0 ] ; then
      invalid_command $LINENO
      continue
    fi
    ((sel_row--))
    scroll_check
    draw_rowinfo


  ####################
  ###  DOWN
  ####################

  elif [ "$k" == "DOWN" ] ; then
    if [ $sel_row -ge $((rows-1)) ] ; then
      invalid_command $LINENO
      continue
    fi
    ((sel_row++))
    scroll_check
    draw_rowinfo

  ####################
  ###  LEFT
  ####################

  elif [ "$k" == "LEFT" ] ; then
    if [ $sel_col -le 0 ] ; then
      invalid_command $LINENO
      continue
    fi
    ((sel_col--))
    scroll_check
    draw_rowinfo

  ####################
  ###  RIGHT
  ####################

  elif [ "$k" == "RIGHT" ] ; then
    if [ $sel_col -ge $((columns-1)) ] ; then
      invalid_command $LINENO
      continue
    fi
    ((sel_col++))
    scroll_check
    draw_rowinfo

  ####################
  ###  PGDN
  ####################

  elif [ "$k" == "PGDN" ] ; then
    if [ $sel_row -ge $((rows-1)) ] ; then
      invalid_command $LINENO
      continue
    fi
    ((sel_row+=window_lines))
    if [ $sel_row -ge $rows ] ; then
      ((sel_row=rows-1))
    fi

    ((r=window_top_row+window_lines))
    if [ $r -lt $rows ] ; then
      # we can scroll a full page down
      define_window_at $LINENO $r $window_left_column
      refresh_window
    else
      # otherwise we will just move the selection to the bottom of the table, which is visible in the current window
      draw_rowinfo
    fi

  ####################
  ###  PGUP
  ####################

  elif [ "$k" == "PGUP" ] ; then
    if [ $sel_row == 0 ] ; then
      # already at top of table
      invalid_command $LINENO
      continue
    fi
    if [ $sel_row != $window_top_row ] ; then
      # move to top of window before we start scrolling
      sel_row=$window_top_row
      draw_rowinfo
      continue
    fi
    ((sel_row-=window_lines))
    ((new_top_row=window_top_row-window_lines))
    if [ $new_top_row -lt 0 ] ; then
      # stop scrolling at top of table
      new_top_row=0
    fi
    if [ $sel_row -lt 0 ] ; then
      # don't move selection past start of table either
      sel_row=0
      new_top_row=0
    fi
    if [ $window_top_row != $new_top_row ] ; then
      # we need to scroll the window
      define_window_at $LINENO $new_top_row $window_left_column
      refresh_window
    else
      # just going to top of current page
      draw_rowinfo
    fi

  ####################
  ###  END
  ####################

  elif [ "$k" == "END" ] ; then
    if [ $sel_row -ge $((rows-1)) ] ; then
      invalid_command $LINENO
       continue
    fi
    ((sel_row=rows-1))
    scroll_check
    draw_rowinfo

  ####################
  ###  HOME
  ####################

  elif [ "$k" == "HOME" ] ; then
    if [ $sel_row == 0 ] ; then
      invalid_command $LINENO
      continue
    fi
    sel_row=0
    scroll_check
    draw_rowinfo

  ####################
  ###  BOLN
  ####################

  elif [ "$k" == "BOLN" ] ; then
    if [ $sel_col == 0 ] ; then
      invalid_command $LINENO
      continue
    fi
    sel_col=0
    scroll_check
    draw_rowinfo

  ####################
  ###  EOLN
  ####################

  elif [ "$k" == "EOLN" ] ; then
    if [ $sel_col -ge $((columns-1)) ] ; then
      invalid_command $LINENO
      continue
    fi
    ((sel_col=columns-1))
    scroll_check
    draw_rowinfo

  ####################
  ###  RETURN
  ####################

  elif [ -z "$k" ] ; then
    # blank input means we got a return keystart editing cell contents
    draw_rowinfo # clear the notice early, we may get another one immediately
    if [ $switch_readonly ] ; then
      invalid_command $LINENO
      continue
    fi
    if [ $sel_row == $rows ] ; then
      # can't do this on the END row
      k="RETURN"
      invalid_command $LINENO
      continue
    fi
    edit_blocking_resize=1
    edit_cell
    edit_blocking_resize=

  ####################
  ###  NOOP
  ####################

  elif [ "$k" == "NOOP" ] ; then
    # probably went into a menu that doesn't need us to do anything ("NO OPeration")
    # so don't do anything, but also don't create an error
    debug "ESC command finished, returning to browser"
    continue

  ####################
  ###  CTRL-C
  ####################

  elif [ "$k" == $ctrl_c ] ; then
    # copy selected cell to clipboard
    # you can't input ctrl-c without redefining what generates SIGINT in termainl via stty
    if [ $sel_row == $rows ] ; then
      # can't do this on the END row
      invalid_command $LINENO
      continue
    fi
    clipboard_copy

  ####################
  ###  CTRL-V
  ####################

  elif [ "$k" == $ctrl_v ] ; then
    # paste from clipboard into selected cell
    # you can't input ctrl-v without redefining or disabling what key allows inserting of control characters in termainl via stty
    if [ $sel_row == $rows ] ; then
      # can't do this on the END row
      invalid_command $LINENO
      continue
    fi
    clipboard_paste

  ####################
  ###  CTRL-F
  ####################

  elif [ "$k" == $ctrl_f ] ; then
    # find specified pattern
    find_string

  ####################
  ###  CTRL-W
  ####################

  elif [ "$k" == $ctrl_w ] ; then
    # find specified pattern (no history)
    previous_search=""
    find_string

  ####################
  ###  CTRL-G
  ####################

  elif [ "$k" == $ctrl_g ] ; then
    # find next occurrence of previously specified pattern
    find_string 1

  ####################
  ###  CTRL-D
  ####################

  elif [ "$k" == $ctrl_d ] ; then
    # delete/undelete row
    delete_row

  ####################
  ###  CTRL-B
  ####################

  elif [ "$k" == $ctrl_b ] ; then
    # append row
    append_row

  ####################
  ###  CTRL-R
  ####################

  elif [ "$k" == $ctrl_r ] ; then
    # refresh the screen - useful if terminal pollutes the display with control garbage
    # also if you hold an arrow you are likely to get escape garbage printing on the screen that this will clear up
    clear_reloads
    refresh_window
    draw_rowinfo

  ####################
  ###  CTRL-L
  ####################

  elif [ "$k" == $ctrl_l ] ; then
    # reload the database and repaint the screen (without clearing)
    reload_database

  ####################
  ###  CTRL-X
  ####################

  elif [ "$k" == $ctrl_x ] ; then
    # quit if there are no unsaved changes
    fast_quit 0

    # user cancelled fast-quit
    continue

  ####################
  ###  CTRL-O
  ####################

  elif [ "$k" == $ctrl_o ] ; then
    # quicksave
    if [[ ($changes == 0) && ($rows_deleted == 0) ]] ; then
      # there are no changes to save
      draw_error "NO CHANGES TO SAVE"
      echo -n $'\a'
      continue
    fi
    # save
    save_table

  ####################
  ###  DELELE (left-delete)
  ####################

  elif [ "$k" == $delete ] ; then
    if [ $switch_readonly ] ; then
      invalid_command $LINENO
      continue
    fi
    if [ $sel_row == $rows ] ; then
      # can't do this on the END row
      invalid_command $LINENO
      continue
    fi
    # blank the cell
    edit_buffer=""
    save_edit

  ####################
  ###  ESC
  ####################

  elif [ "$k" == "ESC" ] ; then
    main_menu
    continue

  ####################
  ###  INVALID single character
  ####################

  elif [ ${#k} == 1 ] ; then
    # single character command (not an escape sequence), could be a control-character
    if [[ "$k" =~ [[:cntrl:]] ]] ; then
      # it's a non-printable
      #k="echo -n "$k" | xxd -u -ps)"  # "04"
      #k="\$$(echo -n "$k" | xxd -u -ps)"  # "$04"
      k="CTRL-$(echo "0: $(echo "obase=16;$(echo "ibase=16;$(echo -n "$k" | xxd -u -ps)" | bc)+64" | bc)" | xxd -r) (\$$(echo -n "$k" | xxd -u -ps))"  # "CTRL-D ($04)"
    fi
    invalid_command $LINENO

  ####################
  ###  INVALID escape sequence
  ####################

  else
    invalid_command $LINENO

  fi
done

}





########################################################################################################################
########################################################################################################################
###
###  SETUP
###
########################################################################################################################
########################################################################################################################


###  terminal setup (restore these on return_to_caller)

IFS=$'\n'  # set input delimiter to exclusively unix linefeed (otherwise "read -n1" can't input a space)

# use "stty -a" to display defined control characters
stty intr    \^p   # change  ctrl-c to ctrl-p so we can use ctrl-c for copy (and still interrupt the script with ctrl-p)
stty lnext   "^-"  # disable ctrl-v so we can use ctrl-v for paste
stty susp    "^-"  # disable ctrl-z from suspending the job, as a safety (a stopped job is extremely unfriendly to users unfamiliar with terminal)
stty dsusp   "^-"  # disable ctrl-y for the same reason as ctrl-z
stty discard "^-"  # disable ctrl-o so we can use it for quicksave

# side-note: this happened to me YEARS ago, when I was used to using ctrl-z to exit out of the vax word processor, and ended
# up getting a stopped job on a unix terminal I was trying out, and was unable to logout before leaving the lab... not good!

# cap terminal width
if [ $COLUMNS -gt $max_terminal_width ] ; then
  $COLUMNS=$max_terminal_width
fi

### parse switches
switch_readonly=
database=
initial_table=
while [ ${#@} != 0  ] ; do
  if [[ ("$1" == "-r") || ("$1" == "-readonly") ]] ; then
    # -r or -readonly disables cell/row editing functions to prevent accidental changes
    shift
    switch_readonly=1
  elif [ "${1:0:1}" != "-" ] ; then
    # encounterd parameter not starting with "-", will assume it's a database filename, possibly followed by a table name
    if [ -z "$database" ] ; then
      # first non-switch is database file name (if blank, will auto-open only table or prompt for table selection if more than one table in database)
      database=$1
    elif [ -z "$table" ] ; then
      # second non-switch is (optional) table name
      initial_table=$1
    else
      # more than two non-switch parameters is a syntax error
      abort $LINENO "encountered more than two non-switch options"
    fi
    shift
  else
    abort $LINENO "Encountered unexpected parameter \"$1\"" 1
  fi
done

if [ -z "$database" ] ; then
  abort $LINENO "Supply name of database to browse" 1
fi

# verify starting database
if [ ! -r "$database" ] ; then
  abort $LINENO "unable to access database at \"$database\"" 1
fi

# disable key echoes - prevents echo in popup selection or when user holds key down with fast repeat
stty -echo

# get starting table (if specified, otherwise popup a selection)
echo -ne "$ansi_cmd_cursoroff"
if [ -n "$initial_table" ] ; then
  # need to catalog tables even if a table was specified, we may need this list later
  catalog_tables
  started_up=1  # so abort will display actual error if table is not found
  # open specified table
  browsing_new_table "$initial_table"
else
  debug "user specified database but not table"
  home
  change_table  # will auto select table if there's only one in the database
  if [ -z "$table" ] ; then
    # user did not select a table (hit esc)
    return_to_caller
  fi
  if [ -z "$table" ] ; then
    do_sql $LINENO "display database schema" ".schema"
    return_to_caller "$result"
  fi
  # selected table should be open now
fi





########################################################################################################################
########################################################################################################################
###
###  MAIN
###
########################################################################################################################
########################################################################################################################


# at this point, ALL functions should be defined.  so the order of the fuctions above isn't important because everything is now in scope

# arm abort
started_up=1

# browse
begin_browsing

# never gets here - return_to_caller is called when it's time for the script to end


