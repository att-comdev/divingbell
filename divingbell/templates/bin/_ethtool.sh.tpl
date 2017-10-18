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

cat <<'EOF' > {{ .Values.conf.chroot_mnt_path | quote }}/tmp/ethtool_host.sh
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

old_ethtool_path='/var/divingbell/ethtool'
persist_path='/etc/systemd/system'

if [ ! -d "${old_ethtool_path}" ]; then
  mkdir -p "${old_ethtool_path}"
fi

validate_operation(){
  local param="${1}"
  shift
  [ "${param}" = 'on' ] || [ "${param}" = 'off' ] ||
    die "Expected 'on' or 'off', got '${param}' $@"
}

die_if_null(){
  local var="${1}"
  shift
  [ -n "${var}" ] || die "Null variable exception $@"
}

ethtool_bin="$(type -p ethtool)"

add_ethtool_param(){
  die_if_null "${device}" ", 'device' env var not initialized"
  ifconfig "${device}" > /dev/null # verify interface is here
  die_if_null "${user_key}" ", 'user_key' env var not initialized"
  die_if_null "${user_val}" ", 'user_val' env var not initialized"
  # YAML parser converts unquoted 'on' and 'off' to boolean values
  # ethtool only works with 'on' and 'off', not 'true' or 'false'
  if [ "${user_val}" = 'true' ]; then
    user_val='on'
  elif [ "${user_val}" = 'false' ]; then
    user_val='off'
  fi
  validate_operation "${user_val}"
  : ${before:=docker.service}
  : ${after=network-online.target}

  # Call systemd-escapae to get systemd required filename
  local systemd_name
  systemd_name="$(systemd-escape \
                  -p --suffix=service "${device}.${user_key}")"

  # look for user requested value for this device
  local param_data
  param_data="$(${ethtool_bin} -k ${device} | grep "${user_key}:")" ||
    die "Could not find requested param ${user_key} for ${device}"

  local audit_item
  audit_item="${device},${user_key},${user_val}"
  audit_items="${audit_items}${audit_item}"$'\n'

  # extract existing setting for device
  local current_val_raw
  current_val_raw="$(echo "${param_data}" | cut -d':' -f2)"
  [ "$(echo "${current_val_raw}" | wc -l)" -le 1 ] ||
    die "More than one match for '${user_key}'"
  [[ ! ${current_val_raw} = *fixed* ]] ||
    die "'${deivce}' does not permit changing the '${user_key}' setting"
  if [[ ${current_val_raw} = *off\ \[requested\ on\] ]]; then
    current_val_raw='off'
  elif [[ ${current_val_raw} = *on\ \[requested\ off\] ]]; then
    current_val_raw='on'
  fi
  local current_val
  current_val="$(echo "${current_val_raw}" |
                       cut -d':' -f2 | tr -d '[:space:]')"
  die_if_null "${current_val}" "Value parse error on '${param_data}'"
  validate_operation "${current_val}" "for '${user_key}' on '${device}'"

  # write the original system setting for this device parameter
  local path_to_orig_val
  path_to_orig_val="${old_ethtool_path}/${systemd_name}"
  if [ ! -f "${path_to_orig_val}" ]; then
    echo "${device} ${user_key} ${current_val}" > "${path_to_orig_val}"
  fi

  # Read the original system setting for this device parameter and use it to
  # build the service 'stop' command (i.e. revert to original state)
  local stop_val
  stop_val="$(cat "${path_to_orig_val}" | cut -d' ' -f3)"
  validate_operation "${stop_val}" "from '${path_to_orig_val}'"
  local stop_cmd
  stop_cmd="${ethtool_bin} -K ${device} ${user_key} ${stop_val}"

  # Build service start command
  local start_cmd
  start_cmd="${ethtool_bin} -K ${device} ${user_key} ${user_val}"

  # Build the systemd unit file
  file_content="[Unit]
Before=${before}
After=${after}

[Service]
ExecStart=${start_cmd}
#ExecStop=${stop_cmd}

[Install]
WantedBy=multi-user.target"

  local systemd_path="${persist_path}/${systemd_name}"
  local restart_service=''
  local service_updates=''

  if [ ! -f "${systemd_path}" ] ||
     [ "$(cat ${systemd_path})" != "${file_content}" ]
  then
    echo "${file_content}" > "${systemd_path}"
    restart_service=true
    service_updates=true
    systemctl daemon-reload
  fi

  if [ "${current_val}" != "${user_val}" ]; then
    restart_service=true
  fi

  if [ -n "${restart_service}" ]; then
    systemctl restart "${systemd_name}" || die "Start failed: ${systemd_name}"
  fi

  # Mark the service for auto-start on boot
  systemctl is-enabled "${systemd_name}" > /dev/null ||
    systemctl enable "${systemd_name}" ||
    die "systemd persist failed: ${systemd_name}"

  log.INFO "Service successfully verified: ${systemd_name}"

  curr_ethtool="${curr_ethtool}${systemd_name}"$'\n'
}

{{- range $iface, $unused := .Values.conf.ethtool }}
  {{- range $ethtool_key, $ethtool_val := . }}
    device={{ $iface | quote }} \
    user_key={{ $ethtool_key | quote }} \
    user_val={{ $ethtool_val | quote }} \
    add_ethtool_param
  {{- end }}
{{- end }}

# TODO: This should be done before applying new settings rather than after
# Revert any previously applied services which are now absent
prev_files="$(find "${old_ethtool_path}" -type f)"
if [ -n "${prev_files}" ]; then
  basename -a ${prev_files} | sort > /tmp/prev_ethtool
  echo "${curr_ethtool}" | sort > /tmp/curr_ethtool
  revert_list="$(comm -23 /tmp/prev_ethtool /tmp/curr_ethtool)"
  IFS=$'\n'
  for prev_setting in ${revert_list}; do
    unset IFS
    args="$(cat "${old_ethtool_path}/${prev_setting}")"
    set -- $args
    ${ethtool_bin} -K "$@"
    if [ -f "${persist_path}/${prev_setting}" ]; then
      systemctl disable "${prev_setting}"
      rm "${persist_path}/${prev_setting}"
    fi
    rm "${old_ethtool_path}/${prev_setting}"
    log.INFO "Reverted ethtool settings: ${prev_setting}"
  done
fi

# Perform another pass on ethtool settings to identify any conflicting settings
# among those specified by the user. Enabling/disabling some NIC settings will
# implicitly enable/disable others. Ethtool reports conflicts for such
# parameters as 'off [requested on]' and 'on [requested off]'
for audit_item in ${audit_items}; do
  device="$(echo "${audit_item}" | cut -d',' -f1)"
  user_key="$(echo "${audit_item}" | cut -d',' -f2)"
  user_val="$(echo "${audit_item}" | cut -d',' -f3)"
  param_data="$(${ethtool_bin} -k ${device} | grep "${user_key}:")"
  current_val="$(echo "${param_data}" | cut -d':' -f2 | tr -d '[:space:]')"
  if [[ ${current_val} != ${user_val}* ]]; then
    if [[ ${param_data} = *\[requested\ on\] ]] ||
       [[ ${param_data} = *\[requested\ off\] ]]
    then
      log.ERROR 'There is a conflict between settings chosen for this device.'
    fi
    die "Validation failure: Requested '${user_key}' to be set to" \
        "'${user_val}' on '${device}'; got '${param_data}'."
  fi
done

if [ -n "${curr_ethtool}" ]; then
  log.INFO 'All ethtool successfully validated on this node.'
else
  log.WARN 'No ethtool overrides defined for this node.'
fi

exit 0
EOF

chmod 755 {{ .Values.conf.chroot_mnt_path | quote }}/tmp/ethtool_host.sh
chroot {{ .Values.conf.chroot_mnt_path | quote }} /tmp/ethtool_host.sh

sleep 1
echo 'INFO Putting the daemon to sleep.'

while [ 1 ]; do
  sleep 300
done

exit 0

