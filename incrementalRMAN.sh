#!/bin/bash

#########################################################################
# Name          : EDCIncrementalRMAN.sh                                 #
# Author        : Joshua Webster                                        #
# Description   : This script backs up the L8 PRODUCTION  Oracle        #
#	          database (CROPS) and cleans up archive logs that are      #
#                 no longer needed.  				                    #
#		  This script will run a full (Level 0) backup or an            #
#	 	  incremental (Level 1) backup for the database CROPS.          #
#		  This script will maintain 3 image copies of the               #
#		  database for rapid recovery.                                  #
#		  The locations of the backups are as follows:		            #
#		  (1) +FRA/CRDEMO					                            #
#		  (2) /hsm/ldcm/backup/onsite/dba/cdbs/crdemo		            #
#		  (3) /hsm/ldcm/backup/offsite/dba/cdbs/crdemo		            #
#########################################################################
#                                                                       #
#  Date         Who             What                                    #
#  -----------  -----------     -------------------                     #
#  22-AUG-2014	J. Lemig	Initial Version				                #
#  01-APR-2015  J. Webster      Updated to new version                  #
#  04-APR-2015	J. Webster	Added Table of Contents (TOC)		        #
#  09-APR-2015  J. Webster	Added HSM Directory check		            #
#  08-MAY-2015	J. Webster	Added image copy validation     	        #
#  14-MAY-2015  J. Webster	Added passsword redirection		            #
#									                                    #
#########################################################################
#########################################################################
########################   TABLE OF CONTENTS   ########################## 
#########################################################################
#   (1)  Password redirection........................................60.#
#   (2)  Check command line argument.................................74.#
#   (3)  Functions...................................................95.#
#	     (3a) chsid..................................................99.#
#	     (3b) check_db_open.........................................113.#
#	     (3c) check_bctf............................................138.#
#            (3d) level_0_backup_fra................................162.#
#            (3e) level_0_backup_on.................................185.#
#	     (3f) level_0_backup_off....................................208.#
#	     (3g) level_1_backup_fra....................................232.#
#	     (3h) level_1_backup_on.....................................254.#
#	     (3i) level_1_backup_off....................................280.#
#	     (3j) delete_obsolete_bkup..................................305.#
#	     (3k) cat_resync............................................321.#
#   (4)  Begin execution of script..................................331.#
#   (5)  Variables..................................................332.#
#   (6)  Set up Environment.........................................343.#
#   (7)  Backup CRDEMO..............................................356.#
#   (8)  HSM Check..................................................367.#
#   (9)  Resync RMAN catalog if available...........................422.#
#   (10) Level 0 Backup.............................................440.#
#   (11) Level 1 Backup.............................................476.#
#   (12) Check For Errors And Cleanup...............................536.#
#   (13) Mail report to DBAs........................................555.#
#   (14) Validate Backups...........................................570.#
#########################################################################
#########################################################################
####################### Password redirection ############################
#########################################################################
# Description :                                                         #
# This block will redirect username and password information to a       #
# variable.                                                             #
#########################################################################
FILE=/home/oracle/access/.pword
ENTRY1=$(grep "P1" $FILE)
SYSTEM=${ENTRY1##*=}
ENTRY2=$(grep "P2" $FILE)
SYS=${ENTRY2##*=}
ENTRY3=$(grep "P3" $FILE)
RCAT=${ENTRY3##*=}

#########################################################################
#################### Check command line argument ########################
#########################################################################
# Description : 							                            #
# This logic block will check the command line arguments given to the	# 
#									                                    #
# invocation of this script. There are only 2 valid command line 	    #
# arguments for this script. 						                    #
#       1 -- Signifies the request for a Level 1 backup			        #
#       0 -- Signifies the request for a Level 0 backup		        	#
#########################################################################
if [ $# != 1 ]; then
   echo "Backup Level of 0 or 1 must be specified."
   echo "Usage: $0 <Backup Level>"
   exit 1;
elif [ $1 -ne 0 ] && [ $1 -ne 1 ]; then
   echo "Backup Level of 0 or 1 must be specified."
   echo "Usage: $0 <Backup Level>"
   exit 1;
fi

#############################################################
######################## FUNCTIONS  #########################
#############################################################

chsid() {
# chsid()
# Use         : chsid <ORACLE_SID>
# Description :
#		The chsid function simply provides an easy way to switch between
#		or to ensure you are on a particular ORACLE_SID. It will export
# 		the supplied SID, use the oraenv and then output what your SID
#		is to the terminal screen.
	export ORACLE_SID=$1
	. /usr/local/bin/oraenv
	export ORACLE_SID=${1}2
	echo "Your new SID is "$ORACLE_SID
}

check_db_open() {
# check_db_open()
# Use		  : check_db_open <system_password>
# Description :
#		The check_db_open function will open an sqlplus session, query the
#		v$instance table to determine the status of the database of the 
#		ORACLE_SID you are currently connected to.
#	chsid "crdemo"
	db_status=$(
		sqlplus -s /nolog <<-EOF 2>&1
		connect $1
		-- Setup error catching
		WHENEVER SQLERROR EXIT SQL.SQLCODE;
		-- Get Status
		set heading off
		set feedback off
		set pause off
		set linesize 32767
		set pagesize 0
		select status from v\$instance;
		quit
EOF
	)
}

check_bctf() {
# check_bctf()
# Use		  : check_bctf <system_password>
# Description : 
# The check_bctf function will open an sqlplus session, query the v$instance
# table to determine the status of the block change tracking setup within
# this database.
	bctf_status=$(
		sqlplus -s /nolog <<-EOF 2>&1
		connect / as sysdba
		-- Setup error catching
		WHENEVER SQLERROR EXIT SQL.SQLCODE;
		-- Get black change tracking status
		set heading off
		set feedback off
		set pause off
		set linesize 32767
		set pagesize 0
		select status from v\$block_change_tracking;
		quit;
EOF
	)
}

level_0_backup_fra() {
# level_0_backup_fra()
# Use		  : level_0_backup_fra
# Description : 
# This level_0_backup_fra function will run a Level 0 (full image copy) 
# backup of the database and send that backup to its default FRA location.
	$rman_cmd >> $LOG << EOF
	sql 'alter system checkpoint';
	sql 'alter system archive log current';
	run {
			CONFIGURE CONTROLFILE AUTOBACKUP ON;
			CONFIGURE CONTROLFILE AUTOBACKUP FORMAT FOR DEVICE TYPE DISK TO '%F';
			ALLOCATE CHANNEL ch1 TYPE DISK;
			BACKUP INCREMENTAL LEVEL 0 AS COPY DATABASE TAG 'L0_COPY';
			BACKUP AS COPY CURRENT CONTROLFILE;
			RELEASE CHANNEL ch1;
		}
	LIST COPY TAG 'L0_COPY';
	SHOW ALL;
	QUIT;
EOF
}

level_0_backup_on() {
# level_0_backup_on()
# Use		  : level_0_backup_on
# Description : 
# This level_0_backup_on function will run a Level 0 (full image copy)
# backup of the database and send that backup to the onsite hsm directory
# HSM ONSITE ::: /hsm/ldcm/backup/onsite/dba/cdbs/crdemo
	$rman_cmd >> $LOG << EOF
	sql 'alter system checkpoint';
	sql 'alter system archive log current';
	run {
			CONFIGURE CONTROLFILE AUTOBACKUP ON;
			CONFIGURE CONTROLFILE AUTOBACKUP FORMAT FOR DEVICE TYPE DISK TO '%F';
			ALLOCATE CHANNEL ch1 TYPE DISK;
			BACKUP INCREMENTAL LEVEL 0 AS COPY DATABASE TAG 'L0_COPY_ONSITE' TO DESTINATION '/hsm/ldcm/backup/onsite/dba/cdbs/crdemo';

			RELEASE CHANNEL ch1;
		}
	LIST COPY TAG 'L0_COPY_ONSITE';
	SHOW ALL;
	QUIT;
EOF
}
level_0_backup_off() {
# level_0_backup_off()
# Use		  : level_0_backup_off
# Description : 
# This level_0_backup_on function will run a Level 0 (full image copy)
# backup of the database and send that backup to the offsite hsm directory
# HSM OFFSITE ::: /hsm/ldcm/backup/offsite/dba/cdbs/crdemo
	$rman_cmd >> $LOG << EOF
	sql 'alter system checkpoint';
	sql 'alter system archive log current';
	run {
			CONFIGURE CONTROLFILE AUTOBACKUP ON;
			CONFIGURE CONTROLFILE AUTOBACKUP FORMAT FOR DEVICE TYPE DISK TO '%F';
			ALLOCATE CHANNEL ch1 TYPE DISK;
			BACKUP INCREMENTAL LEVEL 0 AS COPY DATABASE TAG 'L0_COPY_OFFSITE' TO DESTINATION '/hsm/ldcm/backup/offsite/dba/cdbs/crdemo';
			BACKUP AS COPY CURRENT CONTROLFILE TO DESTINATION '/hsm/ldcm/backup/offsite/dba/cdbs/crdemo';
			RELEASE CHANNEL ch1;
		}
	LIST COPY TAG 'L0_COPY_OFFSITE';
	SHOW ALL;
	QUIT;
EOF
}

level_1_backup_fra() {
# level_1_backup_fra()
# Use		  : level_1_backup_fra
# Description : 
# This level_1_backup_fra function will run a Level 1 (incremental image copy) 
# backup of the database and send that backup to its default FRA location.
	$rman_cmd >> $LOG << EOF
	sql 'alter system checkpoint';
	sql 'alter system archive log current';
	run {
			CONFIGURE CONTROLFILE AUTOBACKUP ON;
			CONFIGURE CONTROLFILE AUTOBACKUP FORMAT FOR DEVICE TYPE DISK TO '%F';
			RECOVER COPY OF DATABASE WITH TAG 'L0_COPY' UNTIL TIME 'SYSDATE';
			BACKUP INCREMENTAL LEVEL 1 FOR RECOVER OF COPY WITH TAG 'L0_COPY' DATABASE;
			DELETE NOPROMPT OBSOLETE DEVICE TYPE DISK;
		}
	LIST COPY TAG 'L0_COPY';
	SHOW ALL;
	QUIT;
EOF
}

level_1_backup_on() {
# level_1_backup_on()
# Use		  : level_1_backup_on
# Description : 
# This level_1_backup_on function will run a Level 1 (incremental image copy)
# backup of the database and send that backup to the onsite hsm directory
# where it will be applied to the existing Level 0 backup to bring it to a 
# more current state.
# HSM ONSITE ::: /hsm/ldcm/backup/onsite/dba/cdbs/crdemo
	$rman_cmd >> $LOG << EOF
	sql 'alter system checkpoint';
	sql 'alter system archive log current';
	run {
			CONFIGURE CONTROLFILE AUTOBACKUP ON;
			CONFIGURE CONTROLFILE AUTOBACKUP FORMAT FOR DEVICE TYPE DISK TO '%F';
			RECOVER COPY OF DATABASE WITH TAG 'L0_COPY_ONSITE' UNTIL TIME 'SYSDATE';
			BACKUP INCREMENTAL LEVEL 1 FOR RECOVER OF COPY WITH TAG 'L0_COPY_ONSITE' DATABASE;
			DELETE NOPROMPT OBSOLETE DEVICE TYPE DISK;
		}
	LIST COPY TAG 'L0_COPY_ONSITE';
	SHOW ALL;
	QUIT;
EOF
}


level_1_backup_off() {
# level_1_backup_off()
# Use		  : level_1_backup_off
# Description : 
# This level_1_backup_on function will run a Level 1 (incremental image copy)
# backup of the database and send that backup to the offsite hsm directory
# where it will be applied to the existing Level 0 backup to bring it to a 
# more current state.
# HSM OFFSITE ::: /hsm/ldcm/backup/offsite/dba/cdbs/crdemo
	$rman_cmd >> $LOG << EOF
	sql 'alter system checkpoint';
	sql 'alter system archive log current';
	run {
			CONFIGURE CONTROLFILE AUTOBACKUP ON;
			CONFIGURE CONTROLFILE AUTOBACKUP FORMAT FOR DEVICE TYPE DISK TO '%F';
			RECOVER COPY OF DATABASE WITH TAG 'L0_COPY_OFFSITE' UNTIL TIME 'SYSDATE';
			BACKUP INCREMENTAL LEVEL 1 FOR RECOVER OF COPY WITH TAG 'L0_COPY_OFFSITE' DATABASE;
			DELETE NOPROMPT OBSOLETE DEVICE TYPE DISK;
		}
	LIST COPY TAG 'L0_COPY_OFFSITE';
	SHOW ALL;
	QUIT;
EOF
}

delete_obsolete_bkup() {
# delete_obsolete_bkup()
# Use	  	  : delete_obsolete_bkup
# Description :
# This delete_obsolete_bkup function will run run through the RMAN backups and 
# delete all backups marked as 'obsolete.' 
	$rman_cmd >> $LOG << EOF 2>&1
	crosscheck copy;
        delete NOPROMPT expired backup;
        delete NOPROMPT archivelog until time 'sysdate-4';
        delete NOPROMPT expired copy;
        list copy tag 'L0_COPY';
        quit;
EOF
}

cat_resync () {
# cat_resync()
# Use		  : cat_resync
# Description : 
# The cat_resync function will simply resync the RMAN catalog.
        $rman_cmd >> $LOG << EOF 2>&1
        resync catalog;
        quit;
EOF
}

################################
####### GLOBAL VARIABLES #######
################################
backupSID='crdemo';
dirObj_gen='HSM_DIR';
dirObj_on='HSM_ONSITE';
dirObj_off='HSM_OFFSITE';
fra_tag='L0_COPY';
on_tag='L0_COPY_ONSITE';
off_tag='L0_COPY_OFFSITE';

########################
## Set up environment ##
########################
export PATH=$PATH:/bin:/usr/bin:/usr/sbin:/usr/local/bin
chsid "crdemo"
export NLS_LANG=AMERICAN
export NLS_DATE_FORMAT='MON-DD-YYYY HH24:MI:SS'
export MAILCOMM='/usr/bin/Mail';
maillist="jrwebster@usgs.gov"
script_dir=/home/oracle/scripts/backup
log_dir=$script_dir/logs
hostname=`uname -n`;

################$##
## Backup CRDEMO ##
#################$#

date=`date +%d%h%Y_%H%M%S`
report_date=`date +"%m-%d-%Y"`  ##Used for email subjects

LOG=$log_dir/EdcCropsRman_Level_$1_Backup_$date.log
LOGCMD="tee -a $LOG"
echo "$0 started at $date." | $LOGCMD

#########################################################################
###########################    HSM Check     ############################
#########################################################################
#									#
# Description :							        #
# This block is going use an Oracle directory object stored within the	#
# database to use during verification that the HSM drive is 		#
# indeed mounted and ready for use, prior to beginning the		#
# execution of this script.  						#
#########################################################################

## Check if drive is mounted
if [ ! -f /hsm/ldcm/backup/onsite/dba/DO_NOT_DELETE.txt ]; then
	echo "HSM Drive not mounted" | $LOGCMD
	$MAILCOMM -s "Error: HSM Drive not mounted" $maillist < $LOG
	exit 1;
else
	echo "HSM Mounted" | $LOGCMD
fi
## Check if drive is stale
 # COMING SOON

############################################
## Generate RMAN connection command based ##
## on availability of RMAN Catalog        ##
############################################

echo $PATH | $LOGCMD
echo $ORACLE_SID | $LOGCMD

check_db_open $SYSTEM
export TWO_TASK=RMANCAT


## Check return code to make sure it's 0 (SUCCESS).  If not log an error and continue on to the next SID
let ERROR_CODE=$?

if [ $ERROR_CODE -ne 0 ]; then
   echo "ERROR: Unable to login to database $ORACLE_SID to retrieve state."
   echo "ERROR: Backup script will need to be re-run for the $ORACLE_SID database once it is available and open."
fi

## Check if database is open.  If not log an error and continue on to the next SID
if [ "$db_status" != "OPEN" ]; then
   echo "ERROR: $ORACLE_SID database is not open. Status is $db_status"
   echo "ERROR: Backup script will need to be re-run for the $ORACLE_SID database once it is available and open."
fi

if [ "$db_status" = "OPEN" ]; then
		rman_cmd="rman target / catalog $RCAT@rmancat"
else
	rman_cmd="rman target / nocatalog"
fi
unset TWO_TASK

######################################
## Resync RMAN catalog if available ##
######################################
if [ "$rman_cmd" = "rman target $SYS@rmandemo catalog $RCAT@rmancat" ]; then
   echo "Resynchronizing RMAN catalog for $ORACLE_SID database." | $LOGCMD
   cat_resync
else
   echo "Catalog not available for resynchronization." | $LOGCMD
fi

## Check return code to make sure it's 0 (SUCCESS).  If not log an error.
let ERROR_CODE=$?

if [ $ERROR_CODE -ne 0 ]; then
   echo "ERROR: Function call to cat_resync failed." | $LOGCMD
   echo "Unable to resynchronize RMAN catalog for $ORACLE_SID database." | $LOGCMD
fi

####################
## Level 0 Backup ##
####################
if [ $1 -eq 0 ]; then
	echo "Beginning Level 0 Backup..." | $LOGCMD
	echo "SID is $ORACLE_SID" | $LOGCMD
	echo "Calling check_db_open..." | $LOGCMD
	check_db_open $SYSTEM
	echo "" | $LOGCMD
	
	## Check return code to make sure it's 0 (SUCCESS).  If not log an error and continue on to the next SID
	let ERROR_CODE=$?

	if [ $ERROR_CODE -ne 0 ]; then
	  echo "ERROR: Unable to login to database $ORACLE_SID to retrieve state." | $LOGCMD
	  echo "ERROR: Backup script will need to be re-run for the $ORACLE_SID database once it is available and open." | $LOGCMD
	  $MAILCOMM -s "Errors in RMAN Level 0 Backup Report for $ORACLE_SID on $report_date" $maillist < $LOG
	  continue
	fi

	## Check if database is open.  If not log an error and continue on to the next SID
	if [ "$db_status" != "OPEN" ]; then
	  echo "ERROR: $ORACLE_SID database is not open. Status is $db_status" | $LOGCMD
	  echo "ERROR: Backup script will need to be re-run for the $ORACLE_SID database once it is available and open." | $LOGCMD
	  $MAILCOMM -s "Errors in RMAN Level 0 Backup Report for $ORACLE_SID on $report_date" $maillist < $LOG
	  continue
	fi

	## Call level 0 backup functions
	echo "Calling level 0 FRA backup function" | $LOGCMD
	level_0_backup_fra
	echo "Calling level 0 HSM Onsite backup function" | $LOGCMD
	level_0_backup_on
	echo "Calling level 0 HSM Offsite backup function" | $LOGCMD
	level_0_backup_off

####################
## Level 1 Backup ##
####################
elif [ $1 -eq 1 ]; then
	echo "Beginning Level 1 Backup..." | $LOGCMD
	echo "SID is $ORACLE_SID" | $LOGCMD
	echo "Calling check_db_open..." | $LOGCMD
	check_db_open $SYSTEM
	echo "" | $LOGCMD
	
	## Check return code to make sure it's 0 (SUCCESS).  If not log an error and continue on to the next SID
	let ERROR_CODE=$?
	if [ $ERROR_CODE -ne 0 ]; then
	  echo "ERROR: Unable to login to database $ORACLE_SID to retrieve state." | $LOGCMD
	  echo "ERROR: Backup script will need to be re-run for the $ORACLE_SID database once it is available and open." | $LOGCMD
	  $MAILCOMM -s "Errors in RMAN Level 1 Backup Report for $ORACLE_SID on $report_date" $maillist < $LOG
	  continue
	fi

	## Check if database is open.  If not log an error and continue on to the next SID
	if [ "$db_status" != "OPEN" ]; then
	  echo "ERROR: $ORACLE_SID database is not open. Status is $db_status" | $LOGCMD
	  echo "ERROR: Backup script will need to be re-run for the $ORACLE_SID database once it is available and open." | $LOGCMD
	  continue
	fi

	echo "Calling check_bctf" | $LOGCMD
	check_bctf
	echo "" | $LOGCMD

	#Check return code to make sure it's 0 (SUCCESS).  If not log an error and continue on to the next SID
	let ERROR_CODE=$?
	if [ $ERROR_CODE -ne 0 ]; then
	  echo "ERROR: Unable to login to database $ORACLE_SID to check BCTF." | $LOGCMD
	  echo "ERROR: Backup script will need to be re-run for the $ORACLE_SID database once it is available and open." | $LOGCMD
	  $MAILCOMM -s "Errors in RMAN Level 1 Backup Report for $ORACLE_SID on $report_date" $maillist < $LOG
	  continue
	fi
	
	#Check if BCTF is enabled.  If not log an error and continue on to the next SID
	if [ "$bctf_status" != "ENABLED" ]; then
	  echo "ERROR: BCTF is not enabled for the $ORACLE_SID database. Status is $bctf_status" | $LOGCMD
	  echo "ERROR: Enable Block Change Tracking for the $ORACLE_SID database and re-run backup script for this database." | $LOGCMD
	  $MAILCOMM -s "Errors in RMAN Level 1 Backup Report for $ORACLE_SID on $report_date" $maillist < $LOG
	  continue
	fi
	
	## Call level 1 backup functions
	echo "Calling level 1 FRA backup function" | $LOGCMD
	level_1_backup_fra
	echo "Calling level 1 HSM On-site backup function" | $LOGCMD
	level_1_backup_on
	echo "Calling level 1 HSM Off-site backup function" | $LOGCMD
	level_1_backup_off
else
	echo "Backup level is set to $1.  It must be 0 or 1." | $LOGCMD
	$MAILCOMM -s "Errors in RMAN Backup Report for $ORACLE_SID on $report_date" $maillist < $LOG
	continue
fi

###############################################################
## CHECK FOR ERRORS AND CLEANUP OLD BACKUPS AND ARCHIVE LOGS ##
###############################################################
## This block will check for errors during the backup process and mail out some error messages
## if there was any. Otherwise, it will execute the delete_obsolete_bkup function to clean up
## any old backups that are still left lying around.
let ERROR_CODE=$?
if [ $ERROR_CODE -ne 0 ]; then
   echo "ERROR: Hot Backup encountered a failure." | $LOGCMD
   echo "ERROR: Check log and then re-run the backup for the $ORACLE_SID database." | $LOGCMD
   $MAILCOMM -s "Errors in RMAN Level $1 Backup Report for $ORACLE_SID on $report_date" $maillist < $LOG
   continue
else
   ## Perform cleanup of old backups 
   echo "Calling delete_obsolete_bkup" | $LOGCMD
   echo "" | $LOGCMD
   delete_obsolete_bkup
fi

#########################
## Mail report to DBAs ##
#########################

## This block will take the variable $maillist, which consists of the list of email addresses of the 
## DBA's to mail the logs to. This logic block will either mail an Error message or a Success message
## to the recipients held within the $maillist.
report_date=`date +"%m-%d-%Y"`
errors_present=$(grep -i error $LOG)
if [ "${#errors_present}" -gt 0 ]; then
   $MAILCOMM -s "Errors in RMAN Level $1 Backup Report for $ORACLE_SID on $report_date" $maillist < $LOG
else
   $MAILCOMM -s "Successful RMAN Level $1 Backup Report for $ORACLE_SID on $report_date" $maillist < $LOG
fi

##########################
#### Validate Backups ####
##########################

## Call validation script
echo "Calling backup validation function..." | $LOGCMD
$script_dir/EDCValidateRMAN.sh

exit 0;

