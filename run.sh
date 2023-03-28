#!/usr/bin/env bash

# A bridge of this name will be created to host the TAP interface created for
# the VM
QEMU_BRIDGE='qemubr0'

# DHCPD must have an IP address to run, but that address doesn't have to
# be valid. This is the dummy address dhcpd is configured to use.
DUMMY_DHCPD_IP='10.0.0.1'

# These scripts configure/deconfigure the VM interface on the bridge.
QEMU_IFUP='/run/qemu-ifup'
QEMU_IFDOWN='/run/qemu-ifdown'

# The name of the dhcpd config file we make
DHCPD_CONF_FILE='dhcpd.conf'

function default_intf() {
    ip -json route show |
        jq -r '.[] | select(.dst == "default") | .dev'
}

# First step, we run the things that need to happen before we start mucking
# with the interfaces. We start by generating the DHCPD config file based
# on our current address/routes. We "steal" the container's IP, and lease
# it to the VM once it starts up.
/run/generate-dhcpd-conf $QEMU_BRIDGE > $DHCPD_CONF_FILE 
default_dev=`default_intf`

# Now we start modifying the networking configuration. First we clear out
# the IP address of the default device (will also have the side-effect of
# removing the default route)
ip addr flush dev $default_dev

# Next, we create our bridge, and add our container interface to it.
ip link add $QEMU_BRIDGE type bridge
ip link set dev $default_dev master $QEMU_BRIDGE

# Then, we toggle the interface and the bridge to make sure everything is up
# and running.
ip link set dev $default_dev up
ip link set dev $QEMU_BRIDGE up

# Finally, start our DHCPD server
udhcpd -I $DUMMY_DHCPD_IP -f $DHCPD_CONF_FILE &

# Configure QEMU for graceful shutdown
QEMU_MONPORT=7100
QEMU_POWERDOWN_TIMEOUT=30

_graceful_shutdown() {

  local COUNT=0
  local QEMU_MONPORT="${QEMU_MONPORT:-7100}"
  local QEMU_POWERDOWN_TIMEOUT="${QEMU_POWERDOWN_TIMEOUT:-120}"

  echo "Trying to shut down the VM gracefully"
  echo 'system_powerdown' | nc -q 1 localhost ${QEMU_MONPORT}>/dev/null 2>&1
  echo ""
  while echo 'info version'|nc -q 1 localhost ${QEMU_MONPORT:-7100}>/dev/null 2>&1 && [ "${COUNT}" -lt "${QEMU_POWERDOWN_TIMEOUT}" ]; do
    let COUNT++
    echo "QEMU still running. Retrying... (${COUNT}/${QEMU_POWERDOWN_TIMEOUT})"
    sleep 1
  done

  if echo 'info version'|nc -q 1 localhost ${QEMU_MONPORT:-7100}>/dev/null 2>&1; then
    echo "Killing the VM"
    echo 'quit' | nc -q 1 localhost ${QEMU_MONPORT}>/dev/null 2>&1 || true
  fi
  echo "Exiting..."
}

trap _graceful_shutdown SIGINT SIGTERM SIGHUP

# And run the VM! A brief explaination of the options here:
# -enable-kvm: Use KVM for this VM (much faster for our case).
# -nographic: disable SDL graphics.
# -serial mon:stdio: use "monitored stdio" as our serial output.
# -nic: Use a TAP interface with our custom up/down scripts.
# -drive: The VM image we're booting.
exec qemu-system-x86_64 -enable-kvm -nographic -serial mon:stdio \
    -nic tap,id=qemu0,script=$QEMU_IFUP,downscript=$QEMU_IFDOWN \
    -monitor telnet:localhost:${QEMU_MONPORT:-7100},server,nowait,nodelay \
    "$@" \
    -drive format=raw,file=/image &

wait $!
