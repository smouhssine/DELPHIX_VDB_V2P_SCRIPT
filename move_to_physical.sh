#!/bin/sh
#
# Copyright (c) 2019 by MSA.
# 12/11/2019 Initial vesion
# All rights reserved.
#
# move-to-physical.sh
# Script to move a VDB to a physical database running on Oracle physical directories.
# Applies to Single Instance and RAC databases.
#
# Usage: move-to-physical.sh [-noask] [-parallel #] [-dbunique db_unique_name] ["<data_file_destination>"] ["<redo_file_destination>"]
#
# Description of arguments:
#   -noask    = Do not prompt for confirmation before moving the VDB. Default is to prompt.
#   -parallel = Number of RMAN channels used to backup the VDB to ASM. Default is 8.
#   -dbunique = Database unique name for the resulting physical database. Default is VDB unique name.
#   <data_file_destination> = Target path directory for datafiles and control files, e.g. /app/oradata/datafile.
#   <redo_file_destination> = Target path directory for redo log files. Default is data_file_destination.
#
# VDB must be provisioned on the target host where the new instance will run.
# There are two ways to use this script:
#  1) VDB Provision post-script: provision and move as a single provision job.
#  2) Execute against a VDB: move a VDB into an ASM instance running on the same target host.
#
# Important: post-steps to complete the move to physical directory are displayed in move-to-physical.sh_<SID>_run<XXX>.log
#
# Example : move a single instance VDB to an physical instance
# There is one /app/oradata/datafile destination to contain all files for the database.
# a) specify post-script for provision on the host where ASM is running
#   <path>/move-to-physical.sh -noask "/app/oradata/datafile"
#
# This script handles offline and read-only tablespaces in the source database. Offline tablespaces
# are dropped, read-only tablespaces are made temporarily read-write in the VDB for the move.
#

echo_and_log()
{
    echo "$@" | tee -a $MOVE2PHYSLOG
}

cat_and_log()
{
    cat "$@" | tee -a $MOVE2PHYSLOG
}

die()
{
    for error_message in "$@"; do
        echo_and_log "$error_message"
    done
    exit 1
}

# Initialize basic variables
script=`basename $0`
here=`dirname $0`
MOVE2PHYSLOG=

# Without ORACLE_SID nothing works
[ -z "$ORACLE_SID" ] && die "$script: ORACLE_SID is not set"

# Now more basic variables
RUNID="${ORACLE_SID}_run$$"
MOVE2PHYSLOG="$here/${script}_$RUNID.log"
PFILE="$here/pfile_$RUNID.ora"

# Various logs created by the script
RESTARTLOG1="$here/restart_$RUNID.log"
RESTARTLOG2="$here/restart2_$RUNID.log"
RMANLOG="$here/rman_$RUNID.log"
MOUNTLOG2="$here/mount2_$RUNID.log"
MOVEREDOLOG="$here/move_redo_$RUNID.log"
MOVETEMPLOG="$here/move_temp_$RUNID.log"
DROPTEMPLOG="$here/drop_temp_$RUNID.log"
DROPOFFLOG="$here/drop_offline_$RUNID.log"
READWRITELOG="$here/read_write_$RUNID.log"
READONLYLOG="$here/read_only_$RUNID.log"
PARAMLOG="$here/param_$RUNID.log"

# check for other environment vars
[ -z "$ORACLE_HOME" ] && die "$script: ORACLE_HOME is not set"

# check that current directory is writable
touch $MOVE2PHYSLOG && rm -f $MOVE2PHYSLOG || die "Directory $here must be writable: please fix permissions"

# set Oracle bin and library path if necessary
echo "$PATH" | grep "$ORACLE_HOME/bin" >/dev/null 2>&1 || \
PATH=$ORACLE_HOME/bin:$PATH
echo "$LD_LIBRARY_PATH" | grep "$ORACLE_HOME/lib" >/dev/null 2>&1 || \
LD_LIBRARY_PATH=$ORACLE_HOME/lib:$LD_LIBRARY_PATH

# set default logon string if not set
if [ -z "$LOGON_STR" ]; then
   LOGON_STR="/ as sysdba"
   export LOGON_STR
fi

# check command line arguments
[ $# -eq 0 -o $# -gt 7 ] && \
die "Usage: $script [-noask] [-parallel #] [-dbunique db_unique_name] <data_diskgroup> [<redo_diskgroup>]"

# parse command line arguments
ask=true
parallelism=8
doloop=true
badarg=false
dbunique=

while $doloop
do
   case $1 in
        -noask) ask=false; shift;;
        -parallel) if [ $# -lt 3 ] || [ "$2" -ne "$2" ] 2>/dev/null; then
                      badarg=true; doloop=false;
                   else
                      parallelism=$2; shift; shift;
                   fi ;;
        -dbunique) if [ $# -lt 3 ]; then
                      badarg=true; doloop=false;
                   else
                      dbunique=$2; shift; shift;
                   fi ;;
        -*) echo_and_log "Error: no such option $1"; badarg=true; doloop=false;;
         *) doloop=false;;
   esac
done

([ $# -eq 0 ] || $badarg) && \
die "Usage: $script [-noask] [-parallel #] [-dbunique <db_unique_name>] <datafile data_diskgroup> [<redo_diskgroup>]"

if [ $# -eq 2 ]; then
   addredodest=true
   datafile_dest=$1
   redo_dest=$2
else
   addredodest=false
   datafile_dest=$1
   redo_file=$1
fi

################################
Replace with a dest check test
################################
# validate redo disk group name
if $addredodest; then
   echo $redo_file | grep '^+' >/dev/null 2>&1 || \
   die "$script: Diskgroup for online redo ($redodg) must start with '+'"
fi

# validate data disk group name
echo $datadg | grep '^+' >/dev/null 2>&1 || \
die "$script: Diskgroup for data ($datadg) needs to start with '+'"

formatdatadg="'"$datafile_dest"'"

# Generated sql scripts
MOVETEMP="$here/move_tempfiles_$RUNID.sql"
DROPTEMP="$here/drop_tempfiles_$RUNID.sql"
DROPOFF="$here/drop_offline_$RUNID.sql"
READWRITE="$here/read_write_$RUNID.sql"
READONLY="$here/read_only_$RUNID.sql"

# Generated shell scripts
ADDINST="$here/add_instances_$RUNID.sh"

# initialization parameters for moved database
NEWINITORA="$here/init${RUNID}_moveasm.ora"

# initialization parameters for original source database
SOURCEINITCOPY="$here/source_init${ORACLE_SID}.ora"

FILESTOREMOVE="$RESTARTLOG1 $RESTARTLOG2 $RMANLOG $MOUNTLOG2 $MOVEREDOLOG \
 $MOVETEMPLOG $DROPTEMP $DROPTEMPLOG $MOVETEMP $DROPOFF $DROPOFFLOG $PARAMLOG \
 $READWRITE $READWRITELOG $READONLY $READONLYLOG $PFILE $ADDINST"
 
vdbunique=`sqlplus -S -R 3 "$LOGON_STR" <<EOF
    SET ECHO OFF NEWP 0 SPA 0 PAGES 0 FEED OFF HEAD OFF TRIMS ON TAB OFF
    whenever sqlerror exit 1;
    select db_unique_name from v\\$database;
    exit;
EOF`

[ $? -ne 0 ] && die "$script: VDB query to obtain db_unique_name failed!"

# use VDB db_unique_name if physical db_unique_name not specified
[ -z "$dbunique" ] && dbunique=$vdbunique

echo_and_log " "
echo_and_log "Moving database $vdbunique to physical: started at `date`"
$ask && echo_and_log "Verify the following settings..."
echo_and_log "    db_unique_name => $dbunique"
echo_and_log "    ORACLE_SID => $ORACLE_SID"
echo_and_log "    ORACLE_HOME => $ORACLE_HOME"
echo_and_log "    Datafile destination => $datafile_dest"
$addredodest && echo_and_log "    Online redo destination => $redo_dest"
echo_and_log "    RMAN Channels => $parallelism"
echo_and_log " "

proceed=true
if $ask; then
    proceed=false
    echo -n "Do you want to proceed (Y/[N]) => " | tee -a $V2ASMLOG
    read ans
    if [ "$ans" == "y" -o "$ans" == "Y" ]; then
        proceed=true
    fi
fi

$proceed || die "Cancelling script as requested by the user..."

catalogdir="'"$datafile_dest/$dbunique"'"

# Validate as much as possible before doing anything

INITORA="$ORACLE_HOME/dbs/init$ORACLE_SID.ora"
[ ! -f "$INITORA" ] && die "$script: Cannot find initialization parameter file: $INITORA"

# check that the VDB still uses an SPFILE
vdbspfile=`sqlplus -S -R 3 "$LOGON_STR" <<EOF
    SET ECHO OFF NEWP 0 SPA 0 PAGES 0 FEED OFF HEAD OFF TRIMS ON TAB OFF
    whenever sqlerror exit 1;
    select value from v\\$parameter where name = 'spfile';
    exit;
EOF`

if [ $? -ne 0 ] || [ -z "$vdbspfile" ]; then
    die "$script: VDB $vdbunique must use SPFILE for this procedure to work"
fi

# initialization parameters for original source database
SOURCEINITORA=`dirname $vdbspfile`"/source_init.ora"

# obtain name of current controlfile
currcf=`sqlplus -S -R 3 "$LOGON_STR" <<EOF
    SET ECHO OFF NEWP 0 SPA 0 PAGES 0 FEED OFF HEAD OFF TRIMS ON TAB OFF
    whenever sqlerror exit 1;
    select max(name) from v\\$controlfile;
    exit;
EOF`

if [ $? -ne 0 ]; then
    echo_and_log $currcf
    die "$script: Failed to obtain name of current controlfile"
fi

cf="'$currcf'"
local_lad=`sqlplus -S -R 3 "$LOGON_STR" <<EOF
    SET ECHO OFF NEWP 0 SPA 0 PAGES 0 FEED OFF HEAD OFF TRIMS ON TAB OFF
    whenever sqlerror exit 1;
    select max(name) from v\\$parameter where name like 'log_archive_dest%' \
       and lower(value) like 'location%mandatory';
    exit;
EOF`

if [ $? -ne 0 ] || [ -z "$local_lad" ]; then
    local_lad=log_archive_dest_1
fi

rac=`sqlplus -S -R 3 "$LOGON_STR" <<EOF
   SET ECHO OFF NEWP 0 SPA 0 PAGES 0 FEED OFF HEAD OFF TRIMS ON TAB OFF
   whenever sqlerror exit 1;
   select upper(value) from v\\$parameter where name = 'cluster_database';
   exit;
EOF`

# check for the existence of RAC utilities
if [ "$rac" = "TRUE" ]; then
    [ -z "$CRS_HOME" ] && die "$script: CRS_HOME is not set"
    [ -x $CRS_HOME/bin/srvctl ] || \
       die "$script: RAC support requires access to the $CRS_HOME/bin/srvctl utility."

    [ -x $CRS_HOME/bin/olsnodes ] || \
       die "$script: RAC support requires access to the $CRS_HOME/bin/olsnodes utility."

    # add CRS_HOME to execution path if necessary
    echo "$PATH" | grep "$CRS_HOME/bin" >/dev/null 2>&1 || \
       PATH=$CRS_HOME/bin:$PATH

    vdbname=`sqlplus -S -R 3 "$LOGON_STR" <<EOF
        SET ECHO OFF NEWP 0 SPA 0 PAGES 0 FEED OFF HEAD OFF TRIMS ON TAB OFF
        whenever sqlerror exit 1;
        select value from v\\$parameter where name = 'db_name';
        exit;
EOF`

# verify that any target RAC database is registered with the cluster
    [ $vdbunique = $dbunique ] || srvctl status database -d $dbunique >/dev/null
    [ $? -ne 0 ] && \
        die "$script: target RAC DB $dbunique is not registered with Oracle CRS"

# verify that target RAC database instance names match our ORACLE_SID
    [ $vdbunique = $dbunique ] || \
        srvctl config database -d $dbunique | grep 'Database instances' | \
        grep $ORACLE_SID
    [ $? -ne 0 ] && \
        die "$script: VDB instance names must match target RAC DB $dbunique"

# add VDB to Oracle RAC configuration
    srvctl remove database -d $vdbunique -f -y >$RESTARTLOG1 2>&1
    srvctl add database -d $vdbunique -o $ORACLE_HOME -n $vdbname -p $vdbspfile >>$RESTARTLOG1 2>&1
    [ $? -eq 0 ] || die "$script: Use Oracle install user to run this script"

    # generate script to add instance configuration
    sqlplus -S -R 3 "$LOGON_STR" >$ADDINST <<EOF
        SET ECHO OFF NEWP 0 PAGES 0 FEED OFF HEAD OFF TRIMS ON TAB OFF
        whenever sqlerror exit 1;
        select 'srvctl remove instance -d $vdbunique -i ' || instance_name ||\
        ' -f -y ' from gv\$instance;
        select 'srvctl add instance -d $vdbunique -i ' || instance_name ||\
        ' -n ' || host_name || ' -f ' from gv\$instance;
        exit;
EOF

    sh $ADDINST >>$RESTARTLOG1 2>&1
    srvctl start database -d $vdbunique >>$RESTARTLOG1 2>&1
    srvctl stop database -d $vdbunique -o abort >>$RESTARTLOG1 2>&1
fi

sqlplus -S -R 3 "$LOGON_STR" >> $RESTARTLOG1 <<EOF
   whenever sqlerror exit 1;
   startup force pfile="$INITORA"
EOF

if [ $? -ne 0 ]; then
    cat_and_log "$RESTARTLOG1"
    die "$script: Failed to restart the database"
fi

echo_and_log "Generate script to move tempfiles to physical destination"
sqlplus -S -R 3 "$LOGON_STR" >> $MOVETEMP <<EOF
    SET ECHO OFF NEWP 0 PAGES 0 FEED OFF HEAD OFF TRIMS ON TAB OFF
    whenever sqlerror exit 1;
    select 'alter tablespace ' || tablespace_name || ' add tempfile size ' || bytes ||';'
    from dba_temp_files;
    exit;
EOF

if [ $? -ne 0 ]; then
    cat_and_log "$MOVETEMP"
    die "$script: Failed to obtain tempfiles to move"
fi

echo_and_log "Generate script to drop old tempfiles"
sqlplus -S -R 3 "$LOGON_STR" >> $DROPTEMP <<EOF
    SET ECHO OFF NEWP 0 PAGES 0 FEED OFF HEAD OFF TRIMS ON TAB OFF
    whenever sqlerror exit 1;
    select 'alter database tempfile ''' || file_name || ''' drop;'
    from dba_temp_files;
    exit;
EOF

if [ $? -ne 0 ]; then
    cat_and_log "$DROPTEMP"
    die "$script: Failed to obtain old tempfiles to drop"
fi

echo_and_log "Generate script to drop offline tablespaces"
sqlplus -S -R 3 "$LOGON_STR" >> $DROPOFF <<EOF
    SET ECHO OFF NEWP 0 PAGES 0 FEED OFF HEAD OFF TRIMS ON TAB OFF
    whenever sqlerror exit 1;
    select 'drop tablespace ' || tablespace_name || ' including contents;'
    from dba_tablespaces where status = 'OFFLINE';
    exit;
EOF

if [ $? -ne 0 ]; then
    cat_and_log "$DROPOFF"
    die "$script: Failed to obtain tablespaces to drop"
fi

echo_and_log "Generate script to make read-only tablespaces read-write"
sqlplus -S -R 3 "$LOGON_STR" >> $READWRITE <<EOF
    SET ECHO OFF NEWP 0 PAGES 0 FEED OFF HEAD OFF TRIMS ON TAB OFF
    whenever sqlerror exit 1;
    select 'alter tablespace ' || tablespace_name || ' read write;'
      from dba_tablespaces where status = 'READ ONLY';
    exit;
EOF

if [ $? -ne 0 ]; then
    cat_and_log "$READWRITE"
    die "$script: Failed to obtain read-only tablespaces"
fi

# now generate the script to make the tablespaces read-only again
sed 's/read write/read only/' $READWRITE >$READONLY

echo_and_log "Make read-only tablespaces read-write"
sqlplus -S -R 2 "$LOGON_STR" >$READWRITELOG <<EOF
    whenever sqlerror exit 1;
    @"$READWRITE"
    exit;
EOF

if [ $? -ne 0 ]; then
    cat_and_log "$READWRITELOG"
    die "$script: Failed to make read-only tablespaces read-write"
fi

echo_and_log "Remove offline tablespaces"
sqlplus -S -R 2 "$LOGON_STR" >$DROPOFFLOG <<EOF
    whenever sqlerror exit 1;
    @"$DROPOFF"
    exit;
EOF

#Update initialization parameter file with physical directories
echo_and_log "Updating server parameter file with physical locations"
sqlplus -S -R 3 "$LOGON_STR" > $PARAMLOG <<EOF
   whenever sqlerror exit 1;
   alter system set db_unique_name='$dbunique' scope=spfile sid='*';
   alter system set db_create_file_dest='$datafile_dest' scope=spfile sid='*';
   alter system set "$local_lad"='location=/apps/orafra/${dbunique}' scope=spfile sid='*';
   alter system set db_create_online_log_dest_1='$redo_dest' scope=spfile sid='*';
   alter system set control_files='${datafile_dest}/${dbunique}/cfile1.f' scope=spfile sid='*';
   alter system reset filesystemio_options scope=spfile sid='*';
   startup force nomount;
   exit;
EOF

[ $? -ne 0 ] && die "$script: Failed to update spfile"

echo_and_log "Move spfile to physical destination"
sqlplus -S -R 3 "$LOGON_STR" >$PARAMLOG <<EOF
   whenever sqlerror exit 1;
   create pfile='$PFILE' from spfile;
   create spfile='${ORACLE_HOME}/dbs/spfile${dbunique}.ora' from pfile='$PFILE';
   exit;
EOF

echo "spfile='${ORACLE_HOME}/dbs/spfile${dbunique}.ora'" >$NEWINITORA

# snapshot controlfile must be in a shared location for 11.2
snapshotcfile="'"${ORACLE_HOME}/dbs/snapshot_cfile.f"'"

echo_and_log "Move datafiles to physical destination: started at `date`"
rman target / >$RMANLOG <<EOF
   restore controlfile from $cf;
   alter database mount;
   configure device type disk parallelism $parallelism;
   # skip offline datafiles on the backup
   backup as copy format $formatdatadg database skip offline;
   # use datafilecopies in destination
   switch database to copy;
   configure snapshot controlfile name to $snapshotcfile;
EOF

grep RMAN-00571 $RMANLOG 2>&1 > /dev/null
if [ $? -eq 0 ]; then
    cat_and_log "$RMANLOG"
    die "$script: Failed to move datafiles into ASM"
fi

echo_and_log "Move datafiles to physical destination : completed at `date`"

echo_and_log "Startup database with updated parameters"
sqlplus -S -R 3 "$LOGON_STR" >$RESTARTLOG2 <<EOF
   whenever sqlerror exit 1;
   shutdown abort;
EOF

if [ "$rac" = "TRUE" ]; then
    # set ORACLE_SID correctly for the local instance (may have changed)
    myinstname=
    mynode=`olsnodes -l`
    mystatus=`srvctl status instance -d $dbunique -n $mynode`
    [ $? -ne 0 ] || myinstname=`echo "$mystatus" | sed -n 's/^Instance \(.*\) is .*/\1/p'`
    [ -z "$myinstname" ] || ORACLE_SID="$myinstname"
    export ORACLE_SID
    # configure spfile location for target RAC database
    srvctl modify database -d $dbunique -p ${datadg}/${dbunique}/spfile${dbunique}.ora
    # startup all RAC instances with updated parameters
    srvctl start database -d $dbunique >>$RESTARTLOG2 2>&1
else
    # use sqlplus to startup database with new parameters
    sqlplus -S -R 3 "$LOGON_STR" >>$RESTARTLOG2 <<EOF
        whenever sqlerror exit 1;
        startup force pfile="$NEWINITORA";
EOF
fi

if [ $? -ne 0 ]; then
    cat_and_log "$RESTARTLOG2"
    die "$script: Failed to startup database with new parameter file"
fi

echo_and_log "Move tempfiles into p^hysical destination"
sqlplus -S -R 2 "$LOGON_STR" > $MOVETEMPLOG <<EOF
    whenever sqlerror exit 1;
    @"$MOVETEMP"
    exit;
EOF

vtable='v$log'
echo_and_log "Move Online logs"
sqlplus -S -R 3 "$LOGON_STR" > $MOVEREDOLOG <<EOF
    set serveroutput on
    whenever sqlerror exit 1;
    declare
        cursor onl is
            select group# grp, thread# thr, bytes/1024 kbytes
              from $vtable
            order by 1;
        stmt      varchar2(2048);
        swtchstmt varchar2(1024) := 'alter system archive log current';
        ckpstmt   varchar2(1024) := 'alter system checkpoint global';
    begin
        for olog in onl loop
            stmt := 'alter database add logfile thread ' ||
                    olog.thr || ' ''$redodg'' size ' ||
                    olog.kbytes || 'K';
            dbms_output.put_line(stmt);
            execute immediate stmt;
            begin
                stmt := 'alter database drop logfile group ' || olog.grp;
                execute immediate stmt;
            exception
                when others then
                    dbms_output.put_line(swtchstmt);
                    execute immediate swtchstmt;
                    dbms_output.put_line(ckpstmt);
                    execute immediate ckpstmt;
                    dbms_output.put_line(stmt);
                    execute immediate stmt;
            end;
        end loop;
    end;
/
EOF

if [ $? -ne 0 ]; then
    cat_and_log "$MOVEREDO"
    die "$script: Failed to move online log files"
fi

echo_and_log "Restore any read-only tablespaces"
sqlplus -S -R 2 "$LOGON_STR" >$READONLYLOG <<EOF
    whenever sqlerror exit 1;
    @"$READONLY"
    exit;
EOF

f [ $? -ne 0 ]; then
    cat_and_log "$READONLYLOG"
    die "$script: Failed to restore read-only tablespaces"
fi

# shutdown all RAC instances
if [ "$rac" = "TRUE" ]; then
    srvctl stop database -d $dbunique -o abort >/dev/null 2>&1
    if [ "$vdbunique" != "$dbunique" ]; then
        srvctl remove database -d $vdbunique -f -y >/dev/null 2>&1
    fi
fi

#Startup mount database after open
sqlplus -S -R 3 "$LOGON_STR" > $MOUNTLOG2 <<EOF
    whenever sqlerror exit 1;
    startup force mount pfile="$NEWINITORA"
EOF

if [ $? -ne 0 ]; then
    cat_and_log "$MOUNTLOG2"
    die "$script: Failed to mount database after open"
fi

echo_and_log "Remove old tempfiles"
#Remove tempfiles
sqlplus -S -R 2 "$LOGON_STR" >> $DROPTEMPLOG <<EOF
    whenever sqlerror exit 1;
    @"$DROPTEMP"
    exit;
EOF

if [ $? -ne 0 ]; then
    cat_and_log "$DROPTEMPLOG"
    die "$script: Failed to drop old tempfiles"
fi

rm -f $FILESTOREMOVE

echo "Shutdown database"
sqlplus -S -R 3 "$LOGON_STR" 2>&1 >/dev/null <<EOF
   shutdown immediate
EOF

# fetch the source initialization parameters if published by provisioning
if [ -f $SOURCEINITORA ]; then
   cp -f $SOURCEINITORA $SOURCEINITCOPY 2>&1 >/dev/null
fi

if [ "$rac" = "TRUE" ]; then
# now finally startup all RAC instances for the target database in ASM
   echo_and_log "Starting up RAC database ${dbunique}..."
   srvctl start database -d $dbunique 2>&1 >>$MOVE2PHYSLOG
fi

echo_and_log "Database $dbunique moved to physical directory: completed at `date`"
echo_and_log " "
echo_and_log "Final Steps to complete the move to physical directory:"
echo_and_log "  1) Delete VDB on Delphix."
if [ "$rac" = "FALSE" ]; then
   echo_and_log "  2) Copy new init.ora: cp $NEWINITORA $INITORA"
   echo_and_log "  3) Startup database instance."
   echo_and_log "  4) Modify initialization parameters to match source and restart."
else
   echo_and_log "  2) Modify initialization parameters to match source and restart."
fi
if [ -f $SOURCEINITORA ]; then
   echo_and_log "     Source parameters are restored at $SOURCEINITCOPY"
fi
exit 0
