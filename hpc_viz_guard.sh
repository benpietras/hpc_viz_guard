#!/bin/bash

# hpc_viz_guard.sh
# B.Pietras, Jan '25

# This checks for processes with %CPU use over ${cpu_trigger}
# and run time over 8 hours on the viz nodes.
# If found, it emails the user to stop, suggesting better methods.

# There are so many ~0% processes for huge amounts of time
# Do we bother about that? Guess not.

# %CPU to care about:
cpu_trigger=0.1
# 0.1 for testing, for real use - 90?

# over-engineered gid check
check_gid() {
  check_1=$(ssh -n $2 "(id $1 | cut -d '(' -f2 | cut -d '=' -f2) 2>&1" 2>/dev/null)
  check_2=$(ssh -n $2 "(getent passwd $1 | cut -d ':' -f4) 2>&1" 2>/dev/null)
  check_3=$(ssh -n $2 "(lslogins -u $1 | sed -n '8p' | sed 's/[^0-9]*//g') 2>&1" 2>/dev/null)
  if [ -n "$check_1" ] &&
    [ "$check_1" == "$check_2" ] &&
    [ "$check_1" == "$check_3" ]; then
    echo "$check_1"
  fi
}

# Some tmpfiles to use & lose
tempo=$(mktemp)
tempo2=$(mktemp)
mailo=$(mktemp)
trap 'rm -rf "$tempo" "$tempo2" "$mailo"; exit' ERR EXIT

# The nodes to scan over (just add/remove as you like - will work)
boxes=("viz01.pri.barkla.alces.network" "viz02.pri.barkla.alces.network")

for i in ${!boxes[@]}; do

  boxcut=$(echo ${boxes[i]} | cut -d '.' -f1)

  ssh ${boxes[i]} 'ps -eo etimes,pcpu,pid,user' >$tempo
  # As I couldn't figure a way to escape the quotes, we grab the data in the line above and process after.

  # drop the header
  sed -i '1d' $tempo

  # This bit takes the processes running over 8 hours with %CPU over cpu_trigger
  cat $tempo |
    grep -Ev 'root|alces|rtkit|polkitd|avahi|colord|gdm|rpc|rpcuser|ganglia|nobody|chrony|dbus|munge|postfix|wazuh' |
    awk -F' ' -v limit=28800 '$1 >= limit' |
    awk -F' ' -v limit=$cpu_trigger '$2 >= limit' |
    awk '{print $1/3600 "\t" $2 "\t" $3 "\t" $4}' >$tempo2

  # (The output in $tempo2: Time(h) %CPU PID USER)

  # Let's loop over this $tempo2 data and send some emails.

  while read p; do

    hrs=$(echo $p | cut -d ' ' -f 1)
    cpu=$(echo $p | cut -d ' ' -f 2)
    pid=$(echo $p | cut -d ' ' -f 3)
    usr=$(echo $p | cut -d ' ' -f 4)

    # Drop any non-system users, like alces-c+
    if ! ssh -n ${boxes[i]} id "$usr" >/dev/null 2>&1; then
      break
    fi

    # Should the process not belong to a user in 'clusterusers' primary group, skip this line
    gid=$(check_gid $usr ${boxes[i]})

    if [ "$gid" != "1653000001" ]; then
      break
      echo break
    fi

    # Here we send an email

    name=$(ssh -n ${boxes[i]} getent passwd $usr | cut -d ':' -f 5 | cut -d ' ' -f1)

    echo -e "Hi ${name^},\n\nI'm writing to you as we have detected your process below has been running for over 8 hours:\n" >$mailo
    echo -e "Time (h) %CPU PID user\n" >>$mailo
    echo -e "(testing - the real cpu threshold won't be 0.1 ;)\n" >>$mailo
    echo -e $p"\n" >>$mailo
    echo -e "Please delete the process on << $boxcut >> using\n\n\x27pkill $pid\x27\n\nand consider using the batch system.\n\nFrom the welcome email:\nUsers are recommended to submit all jobs to compute nodes via Slurm job scheduler on Barkla. Users could test and debug short (less than 8 hours), lightweight (no more than 8 CPU cores) applications (including GPU, Graphical User Interface applications) directly on the two visualisation nodes of Barkla (viz01 and viz02, or barkla6.liv.ac.uk and barkla7.liv.ac.uk), only if the users are able to monitor the system loading and their jobs don’t overload the nodes.\n\nMany thanks,\nResearch IT" >>$mailo
    ## mail -s 'Visualisation node, time exceeded' -r hpc-support@liverpool.ac.uk -c $usr@liv.ac.uk hpc-support@liv.ac.uk <$mailo
    mail -s 'TESTING Visualisation node, time exceeded' -r hpc-support@liverpool.ac.uk -c bpietras@liv.ac.uk bpietras@liv.ac.uk <$mailo

  done <$tempo2

done
