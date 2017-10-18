Patchwork
=========

What is it?
-----------

Patchwork is a lightweight solution for:
1. Bare metal configuration management for a few very targeted use cases
2. Bare metal package manager orchestration

What problems does it solve?
----------------------------

The needs identified for divingbell were:
1. To plug gaps in day 1 tools (e.g., drydock) for node configuration
2. To provide a day 2 solution for managing these configurations going forward
3. To provide a day 2 solution for system level host patching

Design and Implementation
-------------------------

Patchwork daemonsets run as priviledged containers mount the host filesystem
and chroot into that filesystem to enforce configuration and package state.

We use the daemonset construct as a way of getting a copy of each pod on every
node, but the work done by this chart's pods behaves like an event-driven job.
In practice this means that the chart internals run once on pod startup,
followed by an infinite sleep such that the pods always report a "Running"
status that k8s recognizes as the healthy (expected) result for a daemonset.

In order to keep configuration as isolated as possible from other systems that
manage common files like /etc/fstab and /etc/sysctl.conf, divingbell daemonsets
manage all of their configuration in separate files (e.g. by writing unique
files to /etc/sysctl.d or defining unique Systemd units) to avoid potential
conflicts.

To maximize robustness and utility, the daemonsets in this chart are made to be
idempotent. In addition, they are designed to implicitly restore the original
system state after previously defined states are undefined. (e.g., removing a
previously defined mount from the yaml manifest, with no record of the original
mount in the updated manifest).

Node configurations
-------------------

Although we expect these deamonsets to run indiscriminately on all nodes in the
infrastrutcure, we also expect that different nodes will need to be given a
different set of data depending on the node role/function. To avoid creating
additional dependencies between this chart and other components, the running
assumption is that a single configmap will be published containing the full set
of data for all nodes in the environment, empowering the chart to perform the
appropriate label or hostname filtering in a self-contained capacity.

Lifecycle management
--------------------

This chart's daemonsets will be spawned by Armada. They run in an event-driven
fashion: the idempotent automation for each daemonset will only re-run when
Armada spawns/respawns the container, or if information relevant to the host
changes in the configmap.

For upgrades, a decision was taken not to use any of the built-in kubernetes
update strategies such as RollingUpdate. Instead, we are putting this on
Armada to handle the orchestration of how to do upgrades (e.g., rack by rack).

Daemonset configs
-----------------

### sysctl ###

Used to manage host level sysctl tunables. Ex:

``` yaml
conf:
  sysctl:
    net/ipv4/ip_forward: 1
    net/ipv6/conf/all/forwarding: 1
```

### mounts ###

used to manage host level mounts (outside of those in /etc/fstab). Ex:

``` yaml
conf:
  mounts:
    mnt:
      mnt_tgt: /mnt
      device: tmpfs
      type: tmpfs
      options: 'defaults,noatime,nosuid,nodev,noexec,mode=1777,size=1024M'
```

### ethtool ###

Used to manage host level NIC tunables. Ex:

``` yaml
conf:
  ethtool:
    ens3:
      tx-tcp-segmentation: off
      tx-checksum-ip-generic: on
```

### packages ###

Not implemented

### users ###

Not implemented

