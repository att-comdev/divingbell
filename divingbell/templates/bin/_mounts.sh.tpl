#!/bin/bash

{{/*
Copyright 2017 The Openstack-Helm Authors.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

   http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/}}

set -e

cat <<'EOF' > {{ .Values.conf.chroot_mnt_path | quote }}/tmp/mounts_host.sh
#!/bin/bash

set -o errtrace
set -o pipefail

declare -Ax __log_types=(
  [ERROR]='fd=2, color=\e[01;31m'
  [TRACE]='fd=2, color=\e[01;31m'
  [WARN]='fd=1, color=\e[01;93m'
  [INFO]='fd=1, color=\e[01;37m'
  [DEBUG]='fd=1, color=\e[01;90m'
)
for __log_type in "${!__log_types[@]}"; do
  alias log.${__log_type}="echo ${__log_type}"
done
shopt -s expand_aliases

__text_formatter(){
  local log_prefix='None'
  local default_log_type='INFO'
  local default_xtrace_type='DEBUG'
  local log_type
  local color_prefix
  local fd
  for log_type in "${!__log_types[@]}"; do
    if [[ ${1} == ${log_type}* ]]; then
      log_prefix=''
      color_prefix="$(echo ${__log_types["${log_type}"]} |
                      cut -d',' -f2 | cut -d'=' -f2)"
      fd="$(echo ${__log_types["${log_type}"]} |
            cut -d',' -f1 | cut -d'=' -f2)"
      break
    fi
  done
  if [ "${log_prefix}" = "None" ]; then
    # xtrace output usually begins with "+" or "'", mark as debug
    if [[ ${1} = '+'* ]] || [[ ${1} = \'* ]]; then
      log_prefix="${default_xtrace_type} "
      log_type="${default_xtrace_type}"
    else
      log_prefix="${default_log_type} "
      log_type="${default_log_type}"
    fi
    color_prefix="$(echo ${__log_types["${log_type}"]} |
                    cut -d',' -f2 | cut -d'=' -f2)"
    fd="$(echo ${__log_types["${log_type}"]} |
          cut -d',' -f1 | cut -d'=' -f2)"
  fi
  local color_suffix=''
  if [ -n "${color_prefix}" ]; then
    color_suffix='\e[0m'
  fi
  echo -e "${color_prefix}${log_prefix}${1}${color_suffix}" >&${fd}
}
# Due to this unresolved issue: http://bit.ly/2xPmOY9 we choose preservation of
# message ordering at the expense of applying appropriate tags to stderr. As a
# result, stderr from subprocesses will still display as INFO level messages.
# However we can still log ERROR messages using the aliased log handlers.
exec >& >(while read line; do __text_formatter "${line}"; done)

die(){
  set +x
  # write to stderr any passed error message
  if [[ $@ = *[!\ ]* ]]; then
    log.ERROR "$@"
  fi
  log.TRACE "Backtrace:"
  for ((i=0;i<${#FUNCNAME[@]}-1;i++)); do
    log.TRACE $(caller $i)
  done
  # allow enough time to finish stacktrace print before exiting
  sleep 1
  exit 1
}
export -f die
trap 'die' ERR
set -x

###############################################################################

old_mounts_path='/var/divingbell/mounts'
persist_path='/etc/systemd/system'

if [ ! -d "${old_mounts_path}" ]; then                                          
  mkdir -p "${old_mounts_path}"                                                 
fi

die_if_null(){
  local var="${1}"
  shift
  [ -n "${var}" ] || die "Null variable exception $@"
}

add_mounts_param(){
  die_if_null "${device}" ", 'device' env var not initialized"
  die_if_null "${mnt_tgt}" ", 'mnt_tgt' env var not initialized"
  die_if_null "${type}" ", 'type' env var not initialized"
  : ${options:=None}
  : ${before:=docker.service}
  : ${after=network-online.target}

  # Create mount target
  if [ ! -d "${mnt_tgt}" ]; then
    mkdir -p "${mnt_tgt}"
  fi

  # Call systemd-escapae to get systemd required filename for the mount
  local systemd_name
  systemd_name="$(systemd-escape -p --suffix=mount "${mnt_tgt}")"

  # Prepare systemd entry

  local mnt_opts_systemd=''
  if [ ! "${options}" = 'None' ]; then
    mnt_opts_systemd="Options=${options}"
  fi

  file_content="[Unit]
Conflicts=umount.target
Before=${before}
After=${after}

[Mount]
What=${device}
Where=${mnt_tgt}
Type=${type}
${mnt_opts_systemd}

[Install]
WantedBy=local-fs.target"

  local mountfile_path="${persist_path}/${systemd_name}"
  local restart_mount=''
  local mnt_updates=''

  if [ ! -f "${mountfile_path}" ] ||
     [ "$(cat ${mountfile_path})" != "${file_content}" ]
  then
    echo "${file_content}" > "${mountfile_path}"
    restart_mount=true
    mnt_updates=true
    systemctl daemon-reload
  fi

  systemctl is-active "${systemd_name}" > /dev/null || restart_mount=true

  # Perform the mount
  if [ -n "${restart_mount}" ]; then
    systemctl restart "${systemd_name}" || die "Mount failed: ${systemd_name}"
  fi

  # Mark the mount for auto-start on boot
  systemctl is-enabled "${systemd_name}" > /dev/null ||
    systemctl enable "${systemd_name}" ||
    die "Mount persisting failed: ${systemd_name}"

  # Store orchestrated mount info in the event the mount is
  # later reverted (removed) from the configmap
  if [ -n "${mnt_updates}" ]; then
    cp "${mountfile_path}" "${old_mounts_path}"
  fi

  log.INFO "Mount successfully verified: ${mnt_tgt}"

  curr_mounts="${curr_mounts}${systemd_name}"$'\n'
}

{{- range .Values.conf.mounts }}
  {{- range $key, $value := . }}
    {{ $key }}={{ $value | quote }} \
  {{- end }}
  add_mounts_param
{{- end }}

# TODO: We should purge all old mounts first (umount them) before applying
# new mounts
# Revert any previously applied mounts which are now absent
prev_files="$(find "${old_mounts_path}" -type f)"
if [ -n "${prev_files}" ]; then
  basename -a ${prev_files} | sort > /tmp/prev_mounts
  echo "${curr_mounts}" | sort > /tmp/curr_mounts
  revert_list="$(comm -23 /tmp/prev_mounts /tmp/curr_mounts)"
  IFS=$'\n'
  for prev_mount in ${revert_list}; do
    if [ -f "${persist_path}/${prev_mount}" ]; then
      systemctl stop "${prev_mount}"
      systemctl disable "${prev_mount}"
      rm "${persist_path}/${prev_mount}"
    fi
    rm "${old_mounts_path}/${prev_mount}"
    log.INFO "Reverted mount: ${prev_mount}"
  done
fi

if [ -n "${curr_mounts}" ]; then
  log.INFO 'All mounts successfully validated on this node.'
else
  log.WARN 'No mounts defined for this node.'
fi

exit 0
EOF

chmod 755 {{ .Values.conf.chroot_mnt_path | quote }}/tmp/mounts_host.sh
chroot {{ .Values.conf.chroot_mnt_path | quote }} /tmp/mounts_host.sh

sleep 1
echo 'INFO Putting the daemon to sleep.'

while [ 1 ]; do
  sleep 300
done

exit 0

