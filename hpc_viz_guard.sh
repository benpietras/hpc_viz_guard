#!/bin/bash

# hpc_viz_guard.sh
# B.Pietras Jan '25

# This checks for processes on the viz nodes which exceed 8 CPU-hours
# CPU-hours = (%CPU/100) * runtime_hours
# Examples of limits:
# - 800%CPU for 1 hour = 8 CPU-hours
# - 100%CPU for 8 hours = 8 CPU-hours
# - 400%CPU for 2 hours = 8 CPU-hours

# If found, it emails the user to stop, suggesting better methods.

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

# threshold in CPU-hours (8 cores for 1 hour or 1 core for 8 hours)
cpu_hours_thresh=8

# Some tmpfiles to use & lose
tempo=$(mktemp)          # The initial data grab
processes=$(mktemp)      # Process data per user
mailo=$(mktemp)         # Email template
trap 'rm -f "$tempo" "$processes" "$mailo"; exit' ERR EXIT

# The nodes to scan over
boxes=("viz01.pri.barkla.alces.network" "viz02.pri.barkla.alces.network")

# Some common non-clusterusers to filter out
undesirables="root|alces|rtkit|polkitd|avahi|colord|gdm|rpc|rpcuser|ganglia|nobody|chrony|dbus|munge|postfix|wazuh|zabbix"

for i in ${!boxes[@]}; do
  boxcut=$(echo ${boxes[i]} | cut -d '.' -f1)

  # We consider only the top 20 %CPU processes (probably overkill)
  ssh ${boxes[i]} 'top -bn1 | head -26 | tail -19' >$tempo
  
  # ONLY FOR TESTING
  #cat /home/bpietras/dummy_tempo.txt > $tempo

  # Get unique users
  users=$(cat $tempo | grep -Ev "$undesirables" | awk '{print $2}' | sort -u)

  # Process each user
  for user in $users; do
    # Skip non-system users and wrong GID
    if ! ssh -n ${boxes[i]} id "$user" >/dev/null 2>&1; then
      continue
    fi

    gid=$(check_gid "$user" ${boxes[i]})
    if [ "$gid" != "1653000001" ]; then
      continue
    fi

    # Get all processes for this user
    grep "$user" "$tempo" > "$processes" || true

    # Calculate total CPU-hours for all processes
    total_cpu_hours=0
    while IFS= read -r line; do
      # Extract CPU percentage and runtime
      cpu_percent=$(echo "$line" | awk '{print $9}')
      runtime=$(echo "$line" | awk '{print $11}')
      
      # Convert HH:MM.SS to hours
      if [[ $runtime =~ ([0-9]+):([0-9]+)\.([0-9]+) ]]; then
        hours=$(echo "scale=3; ${BASH_REMATCH[1]} + ${BASH_REMATCH[2]}/60" | bc)
      else
        hours=0
      fi
      
      # Calculate CPU-hours for this process
      process_cpu_hours=$(echo "scale=3; $cpu_percent * $hours / 100" | bc)
      total_cpu_hours=$(echo "scale=3; $total_cpu_hours + $process_cpu_hours" | bc)
    done < "$processes"

    # Check if total CPU-hours exceeds threshold
    if (( $(echo "$total_cpu_hours > $cpu_hours_thresh" | bc -l) )); then
      echo "User $user exceeded CPU-hours limit ($total_cpu_hours CPU-hours)"
      
      # Get user's full name
      name=$(ssh -n ${boxes[i]} getent passwd $user | cut -d ':' -f 5 | cut -d ' ' -f1)

      # Prepare email
      echo -e "Hi ${name^},\n\nI'm writing to you as we have detected your processes have exceeded our CPU-hours limit of $cpu_hours_thresh CPU-hours (currently using $total_cpu_hours CPU-hours):\n" > "$mailo"
      echo -e "Current processes:\n" >> "$mailo"
      echo -e "TIME     %CPU    PID    USER    COMMAND" >> "$mailo"
      cat "$processes" | awk '{print $11, $9, $1, $2, $NF}' >> "$mailo"
      echo -e "\nPlease note that visualization nodes are limited to either:\n- 8 cores for up to 1 hour\n- 1 core for up to 8 hours\n- Or any equivalent combination\n" >> "$mailo"
      echo -e "Please delete the processes on << $boxcut >> and consider using the batch system for longer or more intensive computations.\n\nFrom the welcome email:\nUsers are recommended to submit all jobs to compute nodes via Slurm job scheduler on Barkla. Users could test and debug short (less than 8 hours), lightweight (no more than 8 CPU cores) applications (including GPU, Graphical User Interface applications) directly on the two visualisation nodes of Barkla (viz01 and viz02, or barkla6.liv.ac.uk and barkla7.liv.ac.uk), only if the users are able to monitor the system loading and their jobs don't overload the nodes.\n\nMany thanks,\nResearch IT" >> "$mailo"
      # Uncomment to enable email sending
      #mail -s 'Visualisation node CPU-hours exceeded' -r hpc-support@liverpool.ac.uk -c $user@liv.ac.uk hpc-support@liv.ac.uk < "$mailo"
      mail -s '[TESTING] Visualisation node CPU-hours exceeded' -r hpc-support@liverpool.ac.uk -c bpietras@liv.ac.uk hpc-support@liv.ac.uk < "$mailo"
    fi
  done
done
