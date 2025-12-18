#!/bin/bash

wget "https://raw.githubusercontent.com/Jipok/void-infect/refs/heads/master/sysctl.conf" -O /etc/sysctl.d/99-default.conf

# Calculate total memory (in MB)
mem_total_kb=$(grep '^MemTotal:' /proc/meminfo | awk '{print $2}')
TOTAL_MEM=$((mem_total_kb / 1024))

# Determine selected memory section based on total memory
if [ "$TOTAL_MEM" -le 1024 ]; then
    SELECTED="MEM_1GB"
elif [ "$TOTAL_MEM" -le 2048 ]; then
    SELECTED="MEM_2GB"
elif [ "$TOTAL_MEM" -le 4096 ]; then
    SELECTED="MEM_3-4GB"
elif [ "$TOTAL_MEM" -le 8192 ]; then
    SELECTED="MEM_5-8GB"
else
    SELECTED="MEM_16+GB"
fi

# Remove the 'MEM_' prefix for pretty logging
SELECTED_PRETTY=${SELECTED#MEM_}
echo "Applying sysctl configuration for $SELECTED_PRETTY RAM"

# Remove unselected memory markers from the sysctl configuration
for marker in MEM_1GB MEM_2GB MEM_3-4GB MEM_5-8GB MEM_16+GB; do
    if [ "$marker" != "$SELECTED" ]; then
        sed -i "/# --- BEGIN $marker/,/# --- END $marker/d" /etc/sysctl.d/99-default.conf
    else
        sed -i "/# --- BEGIN $marker/d" /etc/sysctl.d/99-default.conf
        sed -i "/# --- END $marker/d" /etc/sysctl.d/99-default.conf
    fi
done