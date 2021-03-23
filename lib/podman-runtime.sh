_GET_CONTAINER_VAR()
{
    SPACE_SIGNATURE="container_nr varname outname"
    # The SPACE_DEP for this function is dynamic and we
    # provide it from outside as -e SPACE_DEP.

    local container_nr="${1}"
    shift

    local varname="${1}"
    shift

    local outname="${1}"
    shift

    eval "${outname}=\"\${POD_CONTAINER_${varname}_${container_nr}:-}\""
}

_SET_CONTAINER_VAR()
{
    SPACE_SIGNATURE="container_nr varname value"

    local container_nr="${1}"
    shift

    local varname="${1}"
    shift

    local value="${1}"
    shift

    eval "POD_CONTAINER_${varname}_${container_nr}=\${value}"
}

# A function to retrieve and clean container information.
_OUTPUT_CONTAINER_INFO()
{
    SPACE_SIGNATURE="container_nr field"
    SPACE_DEP="_GET_CONTAINER_VAR STRING_SUBST"

    local container_nr="${1}"
    shift

    local field="${1}"
    shift

    if [ "${field}" = "name" ]; then
        _GET_CONTAINER_VAR "${container_nr}" "NAME" "data"
        printf "%s\\n" "${data}"
    fi

    if [ "${field}" = "image" ]; then
        _GET_CONTAINER_VAR "${container_nr}" "IMAGE" "data"
        printf "%s\\n" "${data}"
    fi

    if [ "${field}" = "restartpolicy" ]; then
        _GET_CONTAINER_VAR "${container_nr}" "RESTARTPOLICY" "data"
        printf "%s\\n" "${data}"
    fi

    if [ "${field}" = "configs" ]; then
        local data=
        _GET_CONTAINER_VAR "${container_nr}" "CONFIGS" "data"
        STRING_SUBST "data" " -v " "" 1
        data="${data#-v }"
        printf "%s\\n" "${data}"
    fi

    if [ "${field}" = "mounts" ]; then
        local data=
        _GET_CONTAINER_VAR "${container_nr}" "MOUNTS" "data"
        STRING_SUBST "data" " -v " "" 1
        data="${data#-v }"
        printf "%s\\n" "${data}"
    fi

    if [ "${field}" = "ports" ]; then
        local data=
        _GET_CONTAINER_VAR "${container_nr}" "PORTS" "data"
        STRING_SUBST "data" " -p " " " 1
        data="${data#-p }"
        printf "%s\\n" "${data}"
    fi
}

# Check if a pod with the given name exists.
_POD_EXISTS()
{
    #SPACE_ENV="POD"

    podman pod exists "${POD}"
}

# Get the current pod status
# Return values are: "Running", "Created", "Exited"
_POD_STATUS()
{
    #SPACE_ENV="POD"

    # Note: podman pod ps in some versions does not filter using regex, so --filter name matches
    # all pods who has part of the name in them, hence the grep/awk crafting.
    podman pod ps --format "{{.Name}} {{.Status}}" | grep "^${POD}\>" |awk '{print $2}'
}

_KILL_POD()
{
    SPACE_DEP="_GET_CONTAINER_VAR _CONTAINER_EXISTS _CONTAINER_STATUS _CONTAINER_KILL PRINT _POD_EXISTS _POD_STATUS"
    #SPACE_ENV="POD"

    local container=
    local container_nr=
    for container_nr in $(seq 1 "${POD_CONTAINER_COUNT}"); do
        _GET_CONTAINER_VAR "${container_nr}" "NAME" "container"
        if _CONTAINER_EXISTS "${container}"; then
            if [ "$(_CONTAINER_STATUS "${container}")" = "running" ]; then
                PRINT "Killing container ${container}" "debug" 0
                _CONTAINER_KILL "${container}"
            fi
        fi
    done

    if _POD_EXISTS; then
        local podstatus="$(_POD_STATUS)"
        if [ "${podstatus}" = "Running" ]; then
            local id=
            if id=$(podman pod kill "${POD}" 2>&1); then
                PRINT "Pod ${POD} killed: ${id}" "debug" 0
            else
                PRINT "Pod ${POD} could not be killed: ${id}" "error" 0
                return 1
            fi
        fi
    fi
}

_CONTAINER_KILL()
{
    SPACE_SIGNATURE="container"

    local container="${1}"

    podman kill "${container}"
}

_CONTAINER_STOP()
{
    SPACE_SIGNATURE="container"

    local container="${1}"

    podman stop "${container}" >/dev/null
}

# Stop all running containers and the pod
_STOP_POD()
{
    SPACE_DEP="_GET_CONTAINER_VAR _CONTAINER_EXISTS _CONTAINER_STATUS _CONTAINER_STOP PRINT _POD_EXISTS _POD_STATUS"
    #SPACE_ENV="POD"

    local container=
    local container_nr=
    for container_nr in $(seq 1 "${POD_CONTAINER_COUNT}"); do
        _GET_CONTAINER_VAR "${container_nr}" "NAME" "container"
        if _CONTAINER_EXISTS "${container}"; then
            if [ "$(_CONTAINER_STATUS "${container}")" = "running" ]; then
                PRINT "Stopping container ${container}" "debug" 0
                _CONTAINER_STOP "${container}"
            fi
        fi
    done

    if _POD_EXISTS; then
        local podstatus="$(_POD_STATUS)"
        if [ "${podstatus}" = "Running" ]; then
            local id=
            if id=$(podman pod stop "${POD}" 2>&1); then
                PRINT "Pod ${POD} stopped: ${id}" "debug" 0
            else
                PRINT "Pod ${POD} could not be stopped: ${id}" "error" 0
                return 1
            fi
        fi
    fi
}

# Remove the pod and all containers, ramdisks (if created by us), but leave volumes and configs.
_DESTROY_POD()
{
    SPACE_DEP="_DESTROY_FAKE_RAMDISKS PRINT _GET_CONTAINER_VAR _RM_CONTAINER _CONTAINER_EXISTS _POD_EXISTS _WRITE_STATUS_FILE"

    local container=
    local container_nr=
    for container_nr in $(seq 1 "${POD_CONTAINER_COUNT}"); do
        _GET_CONTAINER_VAR "${container_nr}" "NAME" "container"
        if _CONTAINER_EXISTS "${container}"; then
            _RM_CONTAINER "${container}"
        fi
    done

    if _POD_EXISTS; then
        local id=
        if ! id="$(podman pod rm -f "${POD}" 2>&1)"; then
            PRINT "Pod ${POD} could not be destroyed: ${id}" "error" 0
            return 1
        else
            PRINT "Pod ${POD} destroyed" "debug" 0
        fi

        _WRITE_STATUS_FILE "" "" "removed" "0" ""
    fi

    _DESTROY_FAKE_RAMDISKS
}

_CREATE_RAMDISKS()
{
    SPACE_SIGNATURE="delete list"
    SPACE_DEP="PRINT FILE_STAT"

    local delete="${1}"
    shift

    local list="${1}"
    shift

    if [ "${list}" = "true" ]; then
        if [ -n "${POD_RAMDISKS}" ]; then
            printf "%s\\n" "${POD_RAMDISKS}" |tr ' ' '\n'
        fi
        return
    fi

    if [ "$(id -u)" != 0 ]; then
        PRINT "Must be root to create/delete ramdisks" "error" 0
        return 1
    fi

    if [ "${delete}" = "true" ]; then
        local ramdisk=
        for ramdisk in ${POD_RAMDISKS}; do
            local diskname="${ramdisk%:*}"
            local dir="${POD_DIR}/ramdisk/${diskname}"
            if mountpoint -q "${dir}"; then
                umount "${dir}"
            fi
        done
        return
    fi

    local _USERUID=
    if ! _USERUID="$(FILE_STAT "${POD_DIR}" "%u")"; then
        PRINT "Could not stat owner of directory ${POD_DIR}, will not run this instance" "error" 0
        return 1
    fi

    local _USERGID=
    if ! _USERGID="$(FILE_STAT "${POD_DIR}" "%g")"; then
        PRINT "Could not stat owner group of directory ${POD_DIR}, will not run this instance" "error" 0
        return 1
    fi

    local ramdisk=
    for ramdisk in ${POD_RAMDISKS}; do
        local name="${ramdisk%:*}"
        local size="${ramdisk#*:}"

        if [ ! -d "${POD_DIR}/ramdisk" ]; then
            mkdir "${POD_DIR}/ramdisk"
            chown "${_USERUID}:${_USERGID}" "${POD_DIR}/ramdisk"
        fi

        if [ ! -d "${POD_DIR}/ramdisk/${name}" ]; then
            mkdir "${POD_DIR}/ramdisk/${name}"
            chown "${_USERUID}:${_USERGID}" "${POD_DIR}/ramdisk/${name}"
        fi

        if mountpoint -q "${POD_DIR}/ramdisk/${name}"; then
            # Already exists.
            continue
        fi
        if ! mount -t tmpfs -o size="${size}" tmpfs "${POD_DIR}/ramdisk/${name}"; then
            PRINT "Could not create ramdisk" "error" 0
            return 1
        fi

        chown "${_USERUID}:${_USERGID}" "${POD_DIR}/ramdisk/${name}"
        chmod 700 "${POD_DIR}/ramdisk/${name}"

    done
}

# If the ramdisks were actually regular directories created by the pod script then we purge them.
# If the dirs are actual ramdisks then they will get purged by the outside process which created them.
_DESTROY_FAKE_RAMDISKS()
{
    SPACE_DEP="PRINT"
    #SPACE_ENV="POD_RAMDISKS"

    local ramdisk=
    for ramdisk in ${POD_RAMDISKS}; do
        local diskname="${ramdisk%:*}"
        local dir="${POD_DIR}/ramdisk/${diskname}"
        if ! mountpoint -q "${dir}"; then
            PRINT "Fake ramdisk ${diskname} being removed: ${dir}" "info" 0
            rm -rf "${dir}"
        fi
    done
}

# Check that the ramdisks exist.
# The outside daemon must create these with root privileges.
# However, if they do not exist in the case this pod is not orchestrated but ran directly by the user,
# we create fake ramdisks on disk by creating the directories. This not at all ramdisks and are not safe for sensitive information.
_CHECK_RAMDISKS()
{
    SPACE_DEP="PRINT"
    #SPACE_ENV="POD_RAMDISKS"

    local ramdisk=
    for ramdisk in ${POD_RAMDISKS}; do
        local diskname="${ramdisk%:*}"
        local dir="${POD_DIR}/ramdisk/${diskname}"
        if [ ! -d "${dir}" ]; then
            PRINT "Ramdisk ${diskname} does not exists, creating fake ramdisk as regular directory: ${dir}" "warning" "info" 0
            if ! mkdir -p "${dir}"; then
                PRINT "Could not create directory ${dir}" "error" 0
                return 1
            fi
        elif ! mountpoint -q "${dir}"; then
            # This can happen on a abrupt shutdown.
            PRINT "Ramdisk ${diskname} already exists as regular dir (fake ramdisk), was expected to not exist. Directory: ${dir}" "warning" "info" 0
        fi
    done
}

# Create the pod.
_CREATE_POD()
{
    SPACE_SIGNATURE="daemonPid"
    SPACE_DEP="PRINT"
    #SPACE_ENV="POD_CREATE"

    local pid="${1}"
    shift

    # TODO: make ps work with busybox
    local starttime=
    if ! starttime="$(ps --no-headers -p "${pid}" -o lstart)"; then
        PRINT "Cannot get ps --no-headers -p "${pid}" -o lstart" "error" 0
        return 1
    fi

    # We concat pid and start time so that we have a unique fingerprint of the process.
    # If only using pid there is a minimal risk that another process with the same pid
    # can be addressed after a reboot.
    local daemonId="${pid}-${starttime}"

    local id=
    # shellcheck disable=2086
    if id=$(podman pod create --label daemonid="${daemonId}" ${POD_LABELS} ${POD_CREATE}); then
        PRINT "Pod ${POD} created with id: ${id}, daemin pid: ${pid}" "ok" 0
    else
        PRINT "Pod ${POD} could not be created" "error" 0
        return 1
    fi
}

# Get the pod pid and check so that it is valid (it is not valid after a reboot).
_POD_PID()
{

    local label=
    if ! label="$(podman pod inspect ${POD} 2>/dev/null | grep "\"daemonid\": .*" -o | cut -d' ' -f2- | tr -d '"')"; then
        return 1
    fi

    local pid="${label%%-*}"
    local starttime="${label#*-}"

    # TODO: make ps work with busybox
    local starttime2=
    if ! starttime2="$(ps --no-headers -p "${pid}" -o lstart 2>/dev/null)"; then
        return 1
    fi

    if [ "${starttime}" != "${starttime2}" ]; then
        return 1
    fi

    printf "%s\\n" "${pid}"
}

# Start the pod
_START_POD()
{
    SPACE_DEP="PRINT"
    #SPACE_ENV="POD"

    local id=
    if id=$(podman pod start "${POD}"); then
        PRINT "Pod ${POD} started: ${id}" "info" 0
    else
        PRINT "Pod ${POD} could not be started" "error" 0
    fi
}

# CLI COMMAND
# Start the pod and run the containers, only if the pod is in the Created state.
_START()
{
    SPACE_DEP="PRINT _POD_EXISTS _POD_STATUS _START_POD _POD_PID"

    if _POD_EXISTS; then
        local podstatus="$(_POD_STATUS)"
        if [ "${podstatus}" = "Running" ]; then
            local podPid=
            if podPid="$(_POD_PID)"; then
                # All is good
                PRINT "Pod ${POD} is already running" "info" 0
                return 0
            else
                PRINT "Pod ${POD} does not have it's daemon process alive. Try and rerun the pod" "error" 0
                return 1
            fi
        fi
        if [ "${podstatus}" = "Created" ]; then
            local podPid=
            if podPid="$(_POD_PID)"; then
                # All is good
                if ! _START_POD; then
                    return 1
                fi
                PRINT "Start pod ${POD}, signal daemon ${podPid}" "ok" 0
                # Signal daemon to start
                kill -s USR1 "${podPid}"
                return
            else
                PRINT "Pod ${POD} does not have it's daemon process alive. Try and rerun the pod" "error" 0
                return 1
            fi
        else
            PRINT "Pod ${POD} is not in the \"Created\" state. Stopping and starting (resuming) a pod is not supported. Try and rerun the pod" "error" 0
            return 1
        fi
    else
        PRINT "Pod ${POD} does not exist" "error" 0
        return 1
    fi
}

# Check POD_CONTAINER_MOUNTS_x so that all targets exist before starting containers to get more sane error messages.
_CHECK_HOST_MOUNTS()
{
    SPACE_DEP="PRINT STRING_SUBST _GET_CONTAINER_VAR"

    local container_nr=
    for container_nr in $(seq 1 "${POD_CONTAINER_COUNT}"); do
        local mounts=
        _GET_CONTAINER_VAR "${container_nr}" "MOUNTS" "mounts"
        STRING_SUBST "mounts" " -v " "" 1
        mounts="${mounts#-v }"
        local mount=
        for mount in ${mounts}; do
            local left="${mount%%:*}"
            # Check if it is a directory
            if [ "${left#*/}" != "${left}" ]; then
                # Check if ramdisk
                if [ "${left#./ramdisk/}" != "${left}" ]; then
                    # Fake ramdisk will be created
                    continue
                elif [ ! -d "${left}" ]; then
                    PRINT "Directory to be mounted '${left}' does not exist" "error" 0
                    return 1
                fi
            fi
        done
    done
}

_CHECK_HOST_PORTS()
{
    SPACE_DEP="PRINT NETWORK_PORT_FREE"
    #SPACE_ENV="POD_HOSTPORTS"

    local port=
    for port in ${POD_HOSTPORTS}; do
        if ! NETWORK_PORT_FREE "${port}"; then
            PRINT "Host port ${port} is busy, can't create the pod ${POD}" "error" 0
            return 1
        fi
    done
}

# CLI COMMAND
# Idempotent command to create all volumes for this pod.
# If a volume already exists, leave it as it is.
_CREATE_VOLUMES()
{
    SPACE_DEP="_CREATE_VOLUME PRINT _VOLUME_EXISTS"
    #SPACE_ENV="POD_VOLUMES"

    PRINT "Create volumes" "info" 0

    local volume=
    for volume in ${POD_VOLUMES}; do
        if _VOLUME_EXISTS "${volume}"; then
            PRINT "Volume ${volume} already exists" "info" 0
            continue
        else
            if ! _CREATE_VOLUME "${volume}"; then
                PRINT "Volume ${volume} could not be created" "error" 0
                return 1
            fi
        fi
    done
}

# Pull all images
_DOWNLOAD()
{
    SPACE_SIGNATURE="[refresh]"
    SPACE_DEP="_GET_CONTAINER_VAR PRINT _PULL_IMAGE"
    #SPACE_ENV="POD_CONTAINER_COUNT"

    local refresh="${1:-false}"

    local container=
    local image=
    local container_nr=
    for container_nr in $(seq 1 "${POD_CONTAINER_COUNT}"); do
        _GET_CONTAINER_VAR "${container_nr}" "NAME" "container"
        _GET_CONTAINER_VAR "${container_nr}" "IMAGE" "image"
        _PULL_IMAGE "${image}" "${refresh}"
    done
}

# Pull down an image
# if refresh is true, then always attempt to pull.
_PULL_IMAGE()
{
    SPACE_SIGNATURE="image [refresh]"
    SPACE_DEP="PRINT"

    local image="${1}"
    shift

    local refresh="${1:-false}"

    local imageExists="false"
    if podman image exists "${image}"; then
        imageExists="true"
        PRINT "Image: ${image} exists" "debug" 0
    fi

    if [ "${imageExists}" = "false" ] || [ "${refresh}" = "true" ]; then
        PRINT "Pull image ${image}" "info" 0
        if ! podman pull "${image}"; then
            PRINT "Could not pull image ${image}" "error" 0
            return 1
        fi
    fi
}

# Check if a container with the given name exists.
_CONTAINER_EXISTS()
{
    SPACE_SIGNATURE="container"

    local container="${1}"
    shift

    podman container exists "${container}"
}

_CONTAINER_STATUS()
{
    SPACE_SIGNATURE="container"

    local container="${1}"
    shift

    if ! podman inspect "${container}" --format "{{.State.Status}}" 2>/dev/null; then
        printf "%s\\n" "non-existent"
    fi
}

_CONTAINER_FINISHEDAT()
{
    SPACE_SIGNATURE="container"
    SPACE_DEP="PRINT"

    local container="${1}"
    shift

    local at="$(podman inspect "${container}" --format "{{.State.FinishedAt}}")"
    # The format returned is as: 2020-03-04 22:58:50.380309603 +0100 CET
    # Make it into a format which both GNU date and BSD date utlities can work with.
    # Cut away ".micros +0100 TZ"
    local timedate="${at%[.]*}"
    local tz="${at##*[ ]}"
    local newDate="${timedate} ${tz}"
    local ts=
    # First try BSD date (because the error is easier to mute on a GNU system)
    if ! date -j -f "%Y-%m-%d %T %Z" "${newDate}" "+%s" 2>/dev/null; then
        # Try GNU date
        if ! ts="$(date +%s --date "${newDate}")"; then
            PRINT "Could not convert container FinishedAt into UNIX ts. Expecting format of '2020-03-04 22:58:50.380309603 +0100 CET'. Got this: '${at}'" "error" 0
            ts=0
        fi
    fi

    printf "%s\\n" "${ts}"
}

_CONTAINER_EXITCODE()
{
    SPACE_SIGNATURE="container"

    local container="${1}"
    shift

    local code
    if ! code="$(podman inspect "${container}" --format "{{.State.ExitCode}}" 2>/dev/null)"; then
        return 1
    fi
    printf "%d\\n" "${code}"
}

_CYCLE_CONTAINER()
{
    SPACE_SIGNATURE="container container_nr"
    SPACE_DEP="_RUN_CONTAINER _RM_CONTAINER _CONTAINER_EXISTS _CONTAINER_KILL"

    local container="${1}"
    shift

    local container_nr="${1}"
    shift

    _RM_CONTAINER "${container}"
    if ! _RUN_CONTAINER "${container}" "${container_nr}"; then
        # Clean up
        if _CONTAINER_EXISTS "${container}"; then
            # Kill it so rm is quicker
            _CONTAINER_KILL "${container}"
            _RM_CONTAINER "${container}"
        fi
    fi
}

_RM_CONTAINER()
{
    SPACE_SIGNATURE="container"
    SPACE_DEP="PRINT _CONTAINER_STOP _CONTAINER_STATUS _GET_CONTAINER_VAR"

    local container="${1}"
    shift

    # At this point we expect the container to already be stopped,
    # but if it is running we stop it gracefully.
    local containerstatus="$(_CONTAINER_STATUS "${container}")"
    if [ "${containerstatus}" = "running" ]; then
        _CONTAINER_STOP "${container}"
    fi

    # If there is/was a process wrapping the running container, we await its exit before continuing.
    local pid=
    _GET_CONTAINER_VAR "${container_nr}" "PID" "pid"
    if [ -n "${pid}" ]; then
        while kill -0 "${pid}" 2>/dev/null; do
            sleep 1
        done
        wait "${pid}" 2>/dev/null >&2
    fi

    local id=
    if id=$(podman rm -f "${container}" 2>&1); then
        PRINT "Container ${container} removed, id: ${id}" "info" 0
    else
        PRINT "Container ${container} could not be removed: ${id}" "error" 0
        return 1
    fi
}

# Run a container with the given properties.
# The container must not already exist, in any state.
_RUN_CONTAINER()
{
    SPACE_SIGNATURE="container container_nr"
    SPACE_DEP="_SIGNAL_CONTAINER _CONTAINER_EXISTS _CONTAINER_EXITCODE _CONTAINER_STATUS PRINT NETWORK_LOCAL_IP _PULL_IMAGE FILE_STAT _LOG_FILE _RUN_PROBE _SET_CONTAINER_VAR"

    local container="${1}"
    shift

    local container_nr="${1}"
    shift

    # We need to supply the container with a PROXY address, which it uses to communicate with other Pods
    # via the proxy process running outside the containers, on the host.
    # First check if "proxy" is defined in /etc/hosts, then leave it at that because the hosts file is automatically copied into the container.
    # If not present then supply the podman run with the --add-hosts
    # Get the local IP address, the variable is referenced from the container strings when running the container.
    local ADD_PROXY_IP=
    if ! grep -iq "^proxy " "/etc/hosts"; then
        local proxy_ip=
        if ! proxy_ip="$(NETWORK_LOCAL_IP)"; then
            PRINT "Cannot get the local IP of the host, which is needed for the internal proxying to work. You could add it manually to the hosts /etc/hosts file as 'proxy: hostlocalip', and try again" "error" 0
            return 1
        fi
        ADD_PROXY_IP="--add-host=proxy:${proxy_ip}"
    fi

    local image=
    _GET_CONTAINER_VAR "${container_nr}" "IMAGE" "image"
    if ! _PULL_IMAGE "${image}"; then
        return 1
    fi

    local startCount=
    _GET_CONTAINER_VAR "${container_nr}" "STARTCOUNT" "startCount"
    startCount="${startCount:-0}"
    startCount="$((startCount+1))"
    _SET_CONTAINER_VAR "${container_nr}" "STARTCOUNT" "${startCount}"

    local run=
    _GET_CONTAINER_VAR "${container_nr}" "RUN" "run"

    local stdoutLog="${POD_LOG_DIR}/${container}-stdout.log"
    local stderrLog="${POD_LOG_DIR}/${container}-stderr.log"

    local pid=
    # Run the container from a subshell, so we can capture stdout and stderr separately.
    # There is a concurrent write to STDERR here, but the main process is waiting for
    # this process to finish, so the risk of interleving output is not huge.
    (
        local ts="$(date +%s)"
        { eval "podman run ${run}" |_LOG_FILE "${stdoutLog}" "${MAX_LOG_FILE_SIZE}"; } 2>&1 |
            _LOG_FILE "${stderrLog}" "${MAX_LOG_FILE_SIZE}"
        # Container has exited or run command failed
        local containerstatus="$(_CONTAINER_STATUS "${container}")"
        if [ "${containerstatus}" = "exited" ]; then
            local exitcode="$(_CONTAINER_EXITCODE "${container}")"
            PRINT "Container ${container} exited with exit code: ${exitcode}" "info" 0
        else
            PRINT "Container ${container} ended with state: ${containerstatus}" "info" 0
        fi
    ) &
    pid="$!"
    _SET_CONTAINER_VAR "${container_nr}" "PID" "${pid}"
    PRINT "Subshell PID is ${pid} for container ${container}" "debug" 0

    # Wait for container to be running or exited, if it timeouts then the startup failed
    local now=$(date +%s)
    local timeout=$((now + 3))
    # Small risk here is if container starts, exits and is removed within the same second,
    # then this logic will fail, meaning that the container will be treated as if it failed to start.
    # However, we do not automatically remove containers after they exit so risk is non real.
    # A second minimal risk is that if the subprocess never gets prio and run, then the logic will timeout.
    while true; do
        sleep 1
        local containerstatus="$(_CONTAINER_STATUS "${container}")"
        if [ "${containerstatus}" = "exited" ] || [ "${containerstatus}" = "running" ]; then
            break
        fi

        now=$(date +%s)
        if [ "${now}" -ge "${timeout}" ]; then
            # Signal that container run failed
            PRINT "Container ${container} could not run. Possibly you need to tear down and recreate the pod by issuing the 'rerun' command" "error" 0
            return 1
        fi
    done

    # Wait for startup probe on container
    local startupProbe=
    _GET_CONTAINER_VAR "${container_nr}" "STARTUPPROBE" "startupProbe"
    local startupTimeout=
    _GET_CONTAINER_VAR "${container_nr}" "STARTUPTIMEOUT" "startupTimeout"
    startupTimeout="${startupTimeout:-120}"
    if [ -n "${startupProbe}" ]; then
        local now=$(date +%s)
        local timeout=$((now + startupTimeout))
        PRINT "Container ${container} waiting to startup" "info" 0
        while true; do
            local containerstatus="$(_CONTAINER_STATUS "${container}")"
            if [ "${startupProbe}" = "exit" ]; then
                if [ "${containerstatus}" != "running" ]; then
                    local exitcode="$(_CONTAINER_EXITCODE "${container}")"
                    if [ "${exitcode}" = "0" ]; then
                        break
                    else
                        # Wrong exit code
                        PRINT "Container ${container} exited with exit code: ${exitcode} (expected 0)" "error" 0
                        return 1
                    fi
                fi
            else
                # Run shell command in container
                if [ "${containerstatus}" != "running" ]; then
                    PRINT "Container ${container} exited unexpectedly" "error" 0
                    return 1
                fi

                # Run this in subprocess and kill it if it takes too long.
                if _RUN_PROBE "${container}" "${startupProbe}" "${timeout}"; then
                    # Probe succeded
                    PRINT "Startup probe successful for ${container}" "info" 0
                    break
                fi
            fi

            now=$(date +%s)
            if [ "${now}" -ge "${timeout}" ]; then
                 # The container did not start up properly, it will be up to the caller to decide if to destroy it or not.
                PRINT "Container ${container} timeouted waiting to exit/become ready" "error" 0
                return 1
            fi
            sleep 1
        done
    else
        # No startup probe, we assume the container is ready already
        PRINT "Container ${container} started" "info" 0
    fi

    # Fire the signalling to other containers that this container is started (which could mean started and successfully exited).
    local signals=
    _GET_CONTAINER_VAR "${container_nr}" "STARTUPSIGNAL" "signals"
    if [ -n "${signals}" ]; then
        local container_nr=
        local container=
        for container_nr in ${signals}; do
            _GET_CONTAINER_VAR "${container_nr}" "NAME" "container"
            _SIGNAL_CONTAINER "${container}" "${container_nr}"
        done
    fi
}

# Read on STDIN and write to "file",
# when file grows over "maxFileSize" "file" is rotated out
# and a new "file" is created.
_LOG_FILE()
{
    SPACE_SIGNATURE="file [maxFileSize]"
    SPACE_DEP="FILE_STAT"

    local file="${1}"
    shift

    local maxFileSize="${1:-0}"

    local prevTS=""
    local ts=""

    local index="0"
    local line=
    while IFS='' read -r line; do
        # Check if regular file and if size if overdue
        if [ "${maxFileSize}" -gt 0 ] && [ -f "${file}" ]; then
            local size="$(FILE_STAT "${file}" "%s")"
            if [ "${size}" -gt "${maxFileSize}" ]; then
                mv "${file}" "${file}.$(date +%s)"
            fi
        fi
        ts="$(date +%s)"
        if [ "${ts}" = "${prevTS}" ]; then
            index="$((index+1))"
        else
            index="0"
            prevTS="${ts}"
        fi
        printf "%s %s %s\\n" "${ts}" "${index}" "${line}" >>"${file}"
    done
}

# If the container has defined a signal and it is running, signal it.
# If the container is not running but it exists then restart it if its restart policy is on-config or on-interval.
# If the container does not exist do nothing.
_SIGNAL_CONTAINER()
{
    SPACE_SIGNATURE="container container_nr"
    SPACE_DEP="PRINT _GET_CONTAINER_VAR _CONTAINER_EXISTS _CONTAINER_STATUS _RERUN"

    local container="${1}"
    shift

    local container_nr="${1}"
    shift

    local cmd=
    _GET_CONTAINER_VAR "${container_nr}" "SIGNALCMD" "cmd"

    local sig=
    _GET_CONTAINER_VAR "${container_nr}" "SIGNALSIG" "sig"

    if ! _CONTAINER_EXISTS "${container}"; then
        PRINT "Container ${container} does not exist and cannot be signalled nor restarted" "debug" 0
        return
    fi

    if [ "$(_CONTAINER_STATUS "${container}")" = "running" ]; then
        # If the container is running then signal it
        if [ -n "${sig}" ]; then
            PRINT "Container ${container} signalled ${sig}" "ok" 0
            local msg=
            if ! msg=$(podman kill --signal "${sig}" "${container}" 2>&1); then
                PRINT "Container ${container} could not be signalled: ${msg}" "error" 0
                return 1
            fi
        elif [ -n "${cmd}" ]; then
            PRINT "Container ${container} executing: ${cmd}" "info" 0
            if ! eval "podman exec ${container} ${cmd} >/dev/null 2>&1"; then
                PRINT "Container ${container} could not execute command" "error" 0
                return 1
            fi
        else
            PRINT "Container ${container} does not define any signal and cannot be signalled" "debug" 0
            return
        fi
    else
        # If container is not running, cycle it as long as its restart policy allows
        local restartpolicy=
        _GET_CONTAINER_VAR "${container_nr}" "RESTARTPOLICY" "restartpolicy"
        # Restart on on-config and on-interval:x
        # Do not restart on never or on-failure
        if [ "${restartpolicy}" = "on-config" ] || [ "${restartpolicy%:*}" = "on-interval" ]; then
            PRINT "Container ${container} is not running but is rerun according to it's restart policy" "ok" 0
            # We split away the -POD part of the container name here, because it will get added in _RERUN.
            _RERUN "false" "${container%-${POD}}"
        else
            PRINT "Container ${container} is not restarted due to its restart policy" "debug" 0
        fi
    fi
}

# Check if volume exists.
_VOLUME_EXISTS()
{
    SPACE_SIGNATURE="volume"

    local volume="${1}"
    shift

    local volumeFullname=
    if ! volumeFullname=$(podman volume inspect "${volume}" --format  "{{.Name}}" 2>/dev/null); then
        return 1
    fi
    if [ "${volume}" != "${volumeFullname}" ]; then
        return 1
    fi
    return 0
}

# Create a volume with the given name and properties.
_CREATE_VOLUME()
{
    SPACE_SIGNATURE="volume"

    local volume="${1}"
    shift

    podman volume create "${volume}"
}

_DESTROY_VOLUMES()
{
    SPACE_DEP="PRINT"
    #SPACE_ENV="POD_VOLUMES"

    local volume=
    for volume in ${POD_VOLUMES}; do
        # We need to get the full name for the exact volume since podman happily removes a volume on part of its name, which can make it dangerous
        # since multiple calls might delete other volumes.
        local volumeFullname=
        if ! volumeFullname=$(podman volume inspect "${volume}" --format  "{{.Name}}" 2>/dev/null); then
            continue
        fi
        if [ "${volume}" != "${volumeFullname}" ]; then
            continue
        fi
        if ! podman volume rm "${volumeFullname}"; then
            PRINT "Volume ${volume} could not be removed" "error" 0
        fi
    done

    PRINT "All volumes for pod ${POD} removed" "info" 0
}


_VERSION()
{
    #SPACE_ENV="POD_VERSION"

    printf "apiVersion %s\\nruntime %s\\npodVersion %s\\n" "${API_VERSION}" "${RUNTIME}" "${POD_VERSION}"
}

_SHOW_USAGE()
{
    printf "%s\\n" "Usage:
    help
        Output this help.

    version
    -V
        Output version information on stdout.

    info
        Output information about this pod's configuration.

    ps
        Output current runtime status for this pod.
        This function outputs the \"pod.status\" file if it exists and the daemon process exists,
        otherwise status outputted is \"unknown\" if the daemon process does not exist.
        If the status file is not existing the pod is assumed to not exist and the output is \"non-existing\".

    readiness
        Check the readiness of the pod.
        Exit with code 0 if ready, code 1 if not ready.

    download [-f|--force]
        Perform pull on images for all containers.
        If -f option is set then always pull for updated images, even if they already exist locally.

    create
        Create the pod and the volumes, but not the containers. Will not start the pod.
        Will create the main persistent process.

    start
        Start the pod and run the containers, as long as the pod is already created.
        Signals the daemon process to start.

    stop
        Stop the pod and all containers.

    kill
        Kill the pod and all containers.

    run
        Create and start the pod and all containers.
        The pod daemon will make sure all containers are kept according to their state and
        react to config changes.

    rm [-k|--kill]
        Remove the pod and all containers, but leave volumes intact.
        If the pod and containers are running they will be stopped first and then removed.
        If -k|--kill option is set then containers will be killed instead of stopped.

    rerun [-k|--kill] [container1 container2 etc]
        Remove the pod and all containers then recreate and start them.
        Same effect as issuing rm and run in sequence.
        If container name(s) are provided then only cycle the containers, not the full pod.
        If -k option is set then pod will be killed instead of stopped (not valid when defining individual containers).

    signal [container1 container2 etc]
        Send a signal to one, many or all containers.
        The signal sent is the SIG defined in the containers YAML specification.
        Invoking without arguments will invoke signals all all containers which have a SIG defined.

    logs [containers] [-p|--daemon-process] [-t|--timestamp=] [-l|--limit=] [-s|--stream=] [-d|--details=]
        Output logs for one, many or all [containers]. If none given then show for all.
        -p, --daemon-process    Show pod daemon process logs (can also be used in combination with [containers])
        -t, --timestamp         timestamp=UNIX timestamp to get logs from, defaults to 0
                                If negative value is given it is seconds relative to now (now-ts).
        -s, --streams           stdout|stderr|stdout,stderr, defaults to 'stdout,stderr'.
        -l, --limit             limit=nr of lines to get in total from the top, negative gets from the bottom (latest).
        -d, --details           ts|name|stream|none, comma separated if many.
            if 'ts' set will show the UNIX timestamp for each row.
            if 'age' set will show age as seconds for each row.
            if 'name' is set will show the container name for each row.
            if 'stream' is set will show the std stream the logs came on.
            To not show any details set to 'none'.
            Defaults to 'ts,name'.

    create-volumes
        Create the volumes used by this pod, if they do not exist already.
        Volumes are always created when running the pod, this command can be used
        to first create the volumes and possibly populate them with data, before running the pod.

    create-ramdisks [-l|--list] [-d|--delete]
        If run as sudo/root create the ramdisks used by this pod.
        If -d|--delete option is set then delete existing ramdisks, requires sudo/root.
        If -l|--list option is provided then list ramdisks configuration (used by external tools to provide the ramdisks).
        If ramdisks are not prepared prior to the pod starting up then the pod will it self
        create regular directories (fake ramdisks) instead of real ramdisks. This is a fallback
        strategy in the case sudo/root priviligies are not available or if just running in dev mode.
        For applications where the security of ramdisks are important then ramdisks should be properly created.

    reload-configs config1 [config2 config3 etc]
        When a \"config\" has been updated on disk, this command is automatically invoked to signal the container who mount the specific config(s).
        It can also be manually run from command line to trigger a config reload.
        Each container mounting the config will be signalled as defined in the YAML specification.

    purge
        Remove all volumes for a pod.
        The pod must first have been removed.

    shell [-b|--bash] [-c|--container=] [<commands>]
        Enter interactive shell or execute commands if given.
        If --container is not given then target the last container in the pod spec.

        <commands>
            Commands are optional and will be run instead of entering the interactive shell.
            Commands must be places after any option switches and after a pair of dashes '--', so that arguments are not parsed as options.
"
}

# Show basic config about this pod, it's containers and volumes.
# This is not runtime status
_SHOW_INFO()
{
    SPACE_DEP="_OUTPUT_CONTAINER_INFO _GET_CONTAINER_VAR"

    local data=

    printf "pod: %s\\n" "${POD}"
    printf "podVersion: %s\\n" "${POD_VERSION}"
    printf "hostPorts: %s\\n" "${POD_HOSTPORTS}"

    data="${POD_LABELS}"
    STRING_SUBST "data" " --label " " " 1
    data="${data#--label }"
    printf "labels: %s\\n" "${data}"

    printf "volumes: %s\\n" "${POD_VOLUMES}"
    printf "ramdisks: %s\\n" "${POD_RAMDISKS}"

    printf "containers:\\n"

    local container_nr=
    for container_nr in $(seq 1 "${POD_CONTAINER_COUNT}"); do

        printf "    - name: "
        _GET_CONTAINER_VAR "${container_nr}" "NAME" "data"
        data="${data%-${POD}}"
        printf "%s\\n" "${data}"

        printf "      container: "
        _OUTPUT_CONTAINER_INFO "${container_nr}" "name"

        printf "      image: "
        _OUTPUT_CONTAINER_INFO "${container_nr}" "image"

        printf "      configs: "
        _OUTPUT_CONTAINER_INFO "${container_nr}" "configs"

        printf "      restart: "
        _OUTPUT_CONTAINER_INFO "${container_nr}" "restartpolicy"

        printf "      mounts: "
        _OUTPUT_CONTAINER_INFO "${container_nr}" "mounts"

        printf "      ports: "
        _OUTPUT_CONTAINER_INFO "${container_nr}" "ports"
    done
}

# Show the current status of the pod and its containers and volumes
# This function output the pod.status file (if it is fresh) otherwise it outputs a new summary.
_SHOW_STATUS()
{
    SPACE_DEP="_GET_CONTAINER_VAR STRING_TRIM _POD_PID"
    #SPACE_ENV="POD_FILE"

    local statusFile="${POD_FILE}.status"
    # Make into dotfile
    statusFile="${statusFile%/*}/.${statusFile##*/}"

    if [ ! -f "${statusFile}" ]; then
        printf "%s\\n" "pod: ${POD}
status: non-existing"
        return
    fi

    # Read the file
    local contents=
    contents="$(cat "${statusFile}")"

    # Check so that PID still exists
    local podPid=
    if ! podPid="$(_POD_PID)"; then
        # Check if the status file is marked as exited, then we output it.
        local status="$(printf "%s\\n" "${contents}" | grep "^status:")"
        status="${status#*:}"
        STRING_TRIM "status"
        if [ "${status}" = "exited" ] || [ "${status}" = "removed" ]; then
            printf "%s\\n" "${contents}"
            return 0
        fi
    else
        printf "%s\\n" "${contents}"
        return 0
    fi

    printf "%s\\n" "pod: ${POD}
status: unknown"
}

_GET_READINESS()
{
    SPACE_DEP="_GET_CONTAINER_VAR STRING_TRIM"

    local statusFile="${POD_FILE}.status"
    # Make into dotfile
    statusFile="${statusFile%/*}/.${statusFile##*/}"

    if [ ! -f "${statusFile}" ]; then
        return 1
    fi

    # Read the file
    local contents=
    contents="$(cat "${statusFile}")"

    # Check so that PID still exists
    local podPid=
    if ! podPid="$(_POD_PID)"; then
        return 1
    fi
    local readiness="$(printf "%s\\n" "${contents}" | grep "^readiness:")"
    readiness="${readiness#*:}"
    STRING_TRIM "readiness"
    if [ "${readiness}" = "1" ]; then
        return 0
    fi
    return 1
}

# CLI COMMAND
# Idempotent command.
# Check if pod exists
# Create the pod and the volumes (not the containers), but do not start the pod.
# If the pod exists and is in the created or running state then this function does nothing.
# If the pod exists but is not in created nor running state then the whole pod is removed with all containers (volumes are not removed) and the pod is recreated.
_CREATE()
{
    SPACE_DEP="_CHECK_HOST_MOUNTS _CHECK_HOST_PORTS _CREATE_POD _CREATE_VOLUMES _CHECK_RAMDISKS _DESTROY_POD _POD_STATUS PRINT _POD_EXISTS _POD_PID _DESTROY_FAKE_RAMDISKS"

    if _POD_EXISTS; then
        PRINT "Pod ${POD} already exists, checking status" "debug" 0
        local podstatus="$(_POD_STATUS)"
        if [ "${podstatus}" = "Created" ] || [ "${podstatus}" = "Running" ]; then
            local podPid=
            if podPid="$(_POD_PID)"; then
                # All is good
                PRINT "Pod ${POD} already created" "info" 0
                return
            fi
            # Fall through if we need to recreate the pod
        fi

        # Destroy pod and all containers
        PRINT "Pod ${POD} is in a bad state, destroying it and all containers (leaving volumes)" "info" 0
        if ! _DESTROY_POD; then
            return 1
        fi
        # Fall through
    fi

    if ! _CHECK_HOST_PORTS; then
        return 1
    fi

    if ! _CHECK_HOST_MOUNTS; then
        return 1
    fi

    if ! _CREATE_VOLUMES; then
        PRINT "Could not create volumes" "error" 0
        return 1
    fi

    PRINT "Check ramdisks" "info" 0
    if ! _CHECK_RAMDISKS; then
        return 1
    fi

    # Create the daemon process, in a new session (setsid)
    local pid=
    if ! pid="$(setsid $0 porcelain-create)"; then
        PRINT "Could not create daemon process" "error" 0
        _DESTROY_FAKE_RAMDISKS
        return 1
    fi

    PRINT "Create pod" "info" 0
    if ! _CREATE_POD "${pid}"; then
        _DESTROY_FAKE_RAMDISKS
        return 1
    fi
}

# Create the daemon process and outputs its pid on stdout.
#
# The script must have been invoked using `setsid` when calling this function.
# setsid creates a new session id for this process.
# When forking our new pid is != gpid and != sid, meaning we can become a daemon process.
# We need to close stdin/out/err also,
# we are already cd'd to pod dir, which is expected to never be unmounted.
_CREATE_FORK()
{
    SPACE_SIGNATURE="logdir"
    SPACE_DEP="_DAEMON_PROCESS _LOG_FILE"

    local stdoutLog="${POD_LOG_DIR}/${POD}-stdout.log"
    local stderrLog="${POD_LOG_DIR}/${POD}-stderr.log"

    # Need a way of getting the (right) PID out,
    # which is non trivial since we have some piping action going on.
    local pipe="$(mktemp -u)"
    mkfifo "${pipe}"
    exec 3<>"${pipe}"

    (
        # Close file descriptors
        exec 0<&-
        exec 1>&-
        exec 2>&-
        { _DAEMON_PROCESS |_LOG_FILE "${stdoutLog}" "${MAX_LOG_FILE_SIZE}"; } 2>&1 |
            _LOG_FILE "${stderrLog}" "${MAX_LOG_FILE_SIZE}"
    ) &

    local pid=
    while IFS= read -r pid; do
        break
    done <"${pipe}"
    exec 3>&-
    rm "${pipe}"

    printf "%s\\n" "${pid}"
}

# Process which will tend to the state of the pod
# Listen to signal USR1 which means start all containers.
# Listen to signal TERM which means term all containers.
# Listen to signal USR2 which means kill all containers.
# If containers (other than infra) are manually stopped/killed/removed then the restart policy will be enforced.
# If the pod infra container is stopped/killed/removed the daemon will clean up and exit.
_DAEMON_PROCESS()
{
    SPACE_DEP="_START_CONTAINERS _CHECK_CONFIG_CHANGES _CYCLE_CONTAINER _GET_CONTAINER_VAR _POD_EXISTS _POD_STATUS _RELOAD_CONFIGS2 _KILL_POD _STOP_POD _LIVENESS_PROBE _READINESS_PROBE _WRITE_STATUS_FILE _CONTAINER_STOP"

    local _CONFIGCHKSUMS=""

    local created="$(date +%s)"
    local started=""

    # $$ does not work in a forked process using shell,
    # so we use this trick to get our PID.
    local pid="$(sh -c 'echo $PPID')"

    # The caller is awaiting the pid on FD 3
    printf "%s\\n" "${pid}" >&3

    local signalStart=0
    local signalStop=0
    local signalKill=0

    trap 'signalStart=1' USR1
    trap 'signalStop=1' TERM HUP
    trap 'signalKill=1' USR2

    # Setup container rerun traps
    local index=
    for index in $(seq 34 64); do
        eval "local signal${index}=0"
        eval "trap \"signal${index}=1\" ${index}"
    done

    PRINT "Pod daemon started with pid ${pid}, waiting on start signal" "info" 0

    _WRITE_STATUS_FILE "${created}" "" "created" "0" "${pid}"

    # Wait for signal to start (or quit).
    while [ "${signalStart}" = "0" ] && [ "${signalStop}" = "0" ] && [ "${signalKill}" = "0" ]; do
        sleep 1
    done

    if [ "${signalStart}" = "1" ]; then
        PRINT "Daemon got start signal" "info" 0
        started="$(date +%s)"
        _WRITE_STATUS_FILE "${created}" "${started}" "starting" "0" "${pid}"
    fi

    while [ "${signalStop}" = "0" ] && [ "${signalKill}" = "0" ]; do
        # Check pod state
        # If pod was manually stopped/removed/changed then we take that as a hint to self destruct.
        if ! _POD_EXISTS; then
            # Pod mas manually removed, TERM ourselves.
            signalStop="1"
            break
        fi

        local podstatus="$(_POD_STATUS)"
        if [ "${podstatus}" != "Running" ]; then
            # Pod mas manually halted, TERM ourselves.
            signalStop="1"
            break
        fi

        # Start/restart containers
        # This can potentially take many minutes before done.
        if ! _START_CONTAINERS; then
            # If some container can't be created we sleep some extra and try again.
            # Set readiness to 0.
            _WRITE_STATUS_FILE "${created}" "${started}" "starting" "0" "${pid}"
            sleep 10
            continue
        fi

        ## Check config changes
        local _out_changedList=""
        if ! _CHECK_CONFIG_CHANGES; then
            PRINT "Could not lookup config directories" "error" 0
            signalStop="1"
            break
        fi
        # Act on config changes
        local configDir=
        for configDir in ${_out_changedList}; do
            local config="${configDir#${POD_DIR}/config/}"
            PRINT "Reloading config ${config}" "info" 0
            _RELOAD_CONFIGS2 "${config}"
        done

        local readiness=0
        # Check readiness
        if _READINESS_PROBE; then
            readiness=1
        fi

        # Default sleep period
        local sleepSeconds=6

        # Check liveness
        if ! _LIVENESS_PROBE; then
            # If some container failed, don't sleep for very long
            # so it can quickly get restarted
            sleepSeconds=1
        fi

        _WRITE_STATUS_FILE "${created}" "${started}" "running" "${readiness}" "${pid}"

        # Check container cycle signals, while we sleep
        while [ "${sleepSeconds}" -gt 0 ]; do
            local index=
            for index in $(seq 34 64); do
                local cycle=0
                eval "cycle=\$signal${index}"
                if [ "${cycle}" = "1" ]; then
                    eval "signal${index}=0"
                    local container_nr="$((index-33))"
                    local container=
                    _GET_CONTAINER_VAR "${container_nr}" "NAME" "container"
                    if [ -z "${container}" ]; then
                        PRINT "Got restart signal ${index} but no container for given index: ${container_nr}" "error" 0
                        break
                    fi
                    PRINT "Got restart signal for container: ${container}" "info" 0
                    _CONTAINER_STOP "${container}"
                    _CYCLE_CONTAINER "${container}" "${container_nr}"
                fi
            done
            if [ "${signalStop}" = "1" ] || [ "${signalKill}" = "1" ]; then
                break 2
            fi
            sleep 1
            sleepSeconds="$((sleepSeconds-1))"
        done
    done

    ## End pod and daemon

    # Clear container traps
    trap - USR1 USR2 TERM HUP
    local index=
    for index in $(seq 34 64); do
        eval "trap - ${index}"
    done

    # Check whether to stop or kill containers and pod
    if [ "${signalKill}" = "1" ]; then
        _KILL_POD
    else
        _STOP_POD
    fi

    PRINT "Daemon with pid ${pid} exited" "info" 0

    local status="exited"
    local podstatus="$(_POD_STATUS)"
    if [ "${podstatus}" = "" ]; then
        status="removed"
    fi

    _WRITE_STATUS_FILE "${created}" "${started}" "${status}" "0" ""
}

# Write to status file 
_WRITE_STATUS_FILE()
{
    SPACE_SIGNATURE="created started status readiness pid"
    SPACE_DEP="_CONTAINER_STATUS _GET_CONTAINER_VAR _CONTAINER_EXITCODE "

    local created="${1}"
    shift

    local started="${1}"
    shift

    local status="${1}"
    shift

    local readiness="${1}"
    shift

    local pid="${1}"
    shift

    local statusFile="${POD_FILE}.status"
    # Make into dotfile
    statusFile="${statusFile%/*}/.${statusFile##*/}"
    local updated="$(date +%s)"

    local contents="pod: ${POD}
podVersion: ${POD_VERSION}
hostPorts: ${POD_HOSTPORTS}
created: ${created}
started: ${started}
updated: ${updated}
status: ${status}
pid: ${pid}
readiness: ${readiness}
"

    local containers=""

    # Showing container info for all states now.
    if true || [ "${status}" = "started" ] || [ "${status}" = "running" ]; then
        # started/running
        # Get container statuses
        containers="containers:
"
        local container_nr=
        for container_nr in $(seq 1 "${POD_CONTAINER_COUNT}"); do
            local container=
            _GET_CONTAINER_VAR "${container_nr}" "NAME" "container"

            local name="${container%-${POD}}"

            local image=
            _GET_CONTAINER_VAR "${container_nr}" "IMAGE" "image"

            local imageExists="false"
            if podman image exists "${image}"; then
                imageExists="true"
            fi

            local restart=
            _GET_CONTAINER_VAR "${container_nr}" "RESTARTPOLICY" "restart"

            local mounts="$(_OUTPUT_CONTAINER_INFO "${container_nr}" "mounts")"
            local ports="$(_OUTPUT_CONTAINER_INFO "${container_nr}" "ports")"

            local startCount=
            _GET_CONTAINER_VAR "${container_nr}" "STARTCOUNT" "startCount"
            local containerstatus="$(_CONTAINER_STATUS "${container}")"
            local exitcode=""
            if [ "${containerstatus}" != "running" ]; then
                exitcode="$(_CONTAINER_EXITCODE "${container}")"
            fi

            containers="${containers}    - name: ${name}
      container: ${container}
      image: ${image}
      imageExists: ${imageExists}
      restart: ${restart}
      mounts: ${mounts}
      ports: ${ports}
      startCount: ${startCount:-0}
      status: ${containerstatus}
"
            if [ -n "${exitcode}" ]; then
                containers="${containers}      exitCode: ${exitcode}
"
            fi
        done
    fi

    printf "%s%s" "${contents}" "${containers}" >"${statusFile}.tmp"
    mv -f "${statusFile}.tmp" "${statusFile}"
}

# Check if any configs have changed for the given pods.
_CHECK_CONFIG_CHANGES()
{
    SPACE_DEP="FILE_DIR_CHECKSUM STRING_ITEM_INDEXOF STRING_ITEM_GET"

    local _changedList=""
    local newList=""

    local configsDir="${POD_DIR}/config"

    # Get the checksum of each config dir in the pod dir.
    local configDir=
    for configDir in $(find "${configsDir}" -maxdepth 1 -mindepth 1 -type d 2>/dev/null); do
        # Get previous checksum, if any
        local chksumPrevious=
        local index=
        if STRING_ITEM_INDEXOF "${_CONFIGCHKSUMS}" "${configDir}" "index"; then
            STRING_ITEM_GET "${_CONFIGCHKSUMS}" "$((index+1))" "chksumPrevious"
        fi

        local chksum=
        if ! chksum=$(FILE_DIR_CHECKSUM "${configDir}"); then
            return 1
        fi

        if ! [ "${chksum}" = "${chksumPrevious}" ]; then
            # Mismatch, store it in changed list, unless this was the first time
            if [ -n "${chksumPrevious}" ]; then
                _out_changedList="${_out_changedList}${_out_changedList:+ }${configDir}"
            fi
        fi
        newList="${newList}${newList:+ }${configDir} ${chksum}"
    done

    _CONFIGCHKSUMS="${newList}"
}

# CLI COMMAND
# Idempotent commands which makes sure that the pod is created and started.
_RUN()
{
    SPACE_DEP="PRINT _START _CREATE"

    if ! _CREATE; then
        return 1
    fi

    if ! _START; then
        return 1
    fi
}

# CLI COMMAND
# If pod is running it and all containers will be stopped/killed.
# Make sure the pod and containers are removed, volumes are not removed.
# Create pod and all containers and start it all up.
_RERUN()
{
    SPACE_SIGNATURE="kill [containers]"
    SPACE_DEP="PRINT _GET_CONTAINER_VAR _RM _RUN _POD_EXISTS _POD_STATUS _POD_PID"

    local kill="${1:-false}"
    shift

    if [ "$#" -gt 0 ]; then
        # Rerun specific containers only
        if ! _POD_EXISTS; then
            PRINT "Pod does not exist" "error" 0
            return 1
        fi

        local podstatus="$(_POD_STATUS)"
        if [ "${podstatus}" != "Running" ]; then
            PRINT "Pod is not running, try to rerun the whole pod" "error" 0
            return 1
        fi

        local podPid=
        if ! podPid="$(_POD_PID)"; then
            PRINT "Pod daemon does not exist, try and rerun the whole pod" "error" 0
            return 1
        fi

        local container=
        local container_nr=
        for container in "$@"; do
            container="${container}-${POD}"
            local container2=
            for container_nr in $(seq 1 "${POD_CONTAINER_COUNT}"); do
                _GET_CONTAINER_VAR "${container_nr}" "NAME" "container2"
                if [ "${container}" = "${container2}" ]; then
                    # Calculate the signal index for the container
                    # Real time signals start at index 34 and end at 64.
                    local restartIndex="$((33+container_nr))"
                    if [ "${restartIndex}" -gt 64 ]; then
                        PRINT "Cannot restart container ${container} because we are out of signals. You have too many containers in the pod. Try to rearrange containers you want to restart to be earlier in the list" "error" 0
                        continue 2
                    fi
                    PRINT "Cycle container ${container}" "info" 0
                    # Signal daemon.
                    kill -s "${restartIndex}" "${podPid}"
                    continue 2
                fi
            done
            PRINT "Container ${container} does not exist in this pod" "error" 0
        done
    else
        # Rerun the whole pod
        _RM "${kill}"
        _RUN
    fi
}

# Internal function to start and restart containers in a pod.
# For each container belonging to a pod, check it's status and if
# it does not exist start it,
# if it does exist but is exited, then depending on the restart policy of the pod:
# if policy is always or restart-on-error and exit code >0 then recreate the container.
# else let it be in its exited state.
_START_CONTAINERS()
{
    SPACE_DEP="_RUN_CONTAINER _CYCLE_CONTAINER _CONTAINER_EXITCODE _CONTAINER_STATUS PRINT _CONTAINER_EXISTS _GET_CONTAINER_VAR _CONTAINER_FINISHEDAT"
    #SPACE_ENV="POD_CONTAINER_COUNT"

    local container=
    local container_nr=
    for container_nr in $(seq 1 "${POD_CONTAINER_COUNT}"); do
        _GET_CONTAINER_VAR "${container_nr}" "NAME" "container"
        if _CONTAINER_EXISTS "${container}"; then
            PRINT "Container ${container} exists, check status" "debug" 0
            # Check status
            local containerstatus="$(_CONTAINER_STATUS "${container}")"
            if [ "${containerstatus}" != "running" ]; then
                PRINT "Container ${container} is not running, check restart policy" "debug" 0
                # Container is not running anymore, check what our restart policy says.
                local restartpolicy=
                _GET_CONTAINER_VAR "${container_nr}" "RESTARTPOLICY" "restartpolicy"
                # Get exit status of container
                local exitcode="$(_CONTAINER_EXITCODE "${container}")"
                local restart="no"
                if [ "${restartpolicy}" = "always" ]; then
                    restart="yes"
                    PRINT "Container ${container} is being cycled" "info" 0
                elif [ "${exitcode}" = "0" ] && [ "${restartpolicy%:*}" = "on-interval" ]; then
                    local interval="${restartpolicy#*:}"
                    local ts="$(_CONTAINER_FINISHEDAT "${container}")"
                    local now="$(date +%s)"
                    if [ "$((now-ts))" -ge "${interval}" ]; then
                        restart="yes"
                        PRINT "Container ${container} restarting now on its interval of ${interval} seconds" "info" 0
                    fi
                elif [ "${restartpolicy}" = "on-failure" ] || [ "${restartpolicy}" = "on-config" ] || [ "${restartpolicy%:*}" = "on-interval" ]; then
                    if [ "${exitcode}" != "0" ]; then
                        PRINT "Container ${container} exit code: ${exitcode}, cycle it" "info" 0
                        restart="yes"
                    else
                        PRINT "Container ${container} exit code: ${exitcode}, do not cycle it" "debug" 0
                    fi
                else
                    PRINT "Container ${container} will not be cycled" "debug" 0
                fi

                if [ "${restart}" = "yes" ]; then
                    _CYCLE_CONTAINER "${container}" "${container_nr}"
                    # Allow failure and fall through.
                fi
            else
                PRINT "Container ${container} is running" "debug" 0
            fi
        else
            PRINT "Container ${container} does not exist, run it" "info" 0
            # Container does not exist, run it.
            if ! _RUN_CONTAINER "${container}" "${container_nr}"; then
                # If a container cannot startup properly we abort the creation process.
                # We do not automatically remove any created containers, that is up to the caller
                # to decide.
                return 1
            fi
        fi
    done
}

# CLI COMMAND
# Stop the pod and all containers.
_STOP()
{
    SPACE_DEP="_STOP_POD _POD_PID"

    local podPid=
    if podPid="$(_POD_PID)"; then
        # Ask the daemon to stop the pod
        kill -s TERM "${podPid}"
        while kill -0 "${podPid}" 2>/dev/null; do
            sleep 1
        done
        return 0
    else
        # Make sure it is stopped
        _STOP_POD
    fi
}

# CLI COMMAND
# Kill the pod and all containers.
_KILL()
{
    SPACE_DEP="_KILL_POD _POD_PID"

    local podPid=
    if podPid="$(_POD_PID)"; then
        # Ask the daemon to kill the pod
        kill -s USR2 "${podPid}"
        while kill -0 "${podPid}" 2>/dev/null; do
            sleep 1
        done
        return 0
    else
        # Daemon not alive.
        # Make sure it is killed
        _KILL_POD
    fi
}

# CLI COMMAND
# Remove the pod and all it's containers.
# If the pod is running, stop/kill it first.
_RM()
{
    SPACE_SIGNATURE="[kill]"
    SPACE_DEP="_DESTROY_POD _POD_EXISTS PRINT _STOP _KILL"

    local kill="${1-false}"
    shift $(($# > 0 ? 1 : 0))

    if _POD_EXISTS; then
        if [ "${kill}" = "true" ]; then
            _KILL
        else
            _STOP
        fi
    else
        PRINT "Pod does not exist" "debug" 0
        # Fall through, because there might be containers lingering and ramdisks to clean up even if someone removed the pod infra container.
    fi

    _DESTROY_POD
}

# CLI COMMAND
# Output logs for one or many containers and the daemon log
# If no containers nor daemon log specified then show for all.
_LOGS()
{
    SPACE_SIGNATURE="timestamp limit streams details showProcessLog [container]"
    SPACE_DEP="_GET_CONTAINER_VAR PRINT STRING_IS_NUMBER STRING_SUBST"

    local timestamp="${1:-0}"
    shift

    local limit="${1:-0}"
    shift

    local streams="${1:-stdout,stderr}"
    shift

    local details="${1:-ts,name}"
    shift

    local showProcessLog="${1:-}"
    shift

    STRING_SUBST "streams" ',' ' ' 1
    STRING_SUBST "details" ',' ' ' 1


    if ! STRING_IS_NUMBER "${timestamp}" "1"; then
        PRINT "timeout must be number (positive is seconds since epoch, negative is age as seconds from now)" "error" 0
        return 1
    fi

    # Check if time is given as relative age
    # and transform it to UNIX time.
    if [ "${timestamp#-}" != "${timestamp}" ]; then
        timestamp=$(($(date +%s)+${timestamp}))
    fi

    if ! STRING_IS_NUMBER "${limit}" 1; then
        PRINT "limit must be a number" "error" 0
        return 1
    fi

    local containers=""
    if [ "${showProcessLog}" = "true" ]; then
        # The daemon process logs
        containers="${POD}"
    fi
    if [ "$#" -eq 0 ]; then
        # If no containers were specified nor any daemon logs,
        # then add all containers and the daemon log.
        # If daemon log was specifiec then do not add anything.
        if [ "${showProcessLog}" != "true" ]; then
            # Get all containers
            local container_nr=
            for container_nr in $(seq 1 "${POD_CONTAINER_COUNT}"); do
                _GET_CONTAINER_VAR "${container_nr}" "NAME" "container"
                containers="${containers} ${container}"
            done
            containers="${containers} ${POD}"
        fi
    else
        local container=
        for container in "$@"; do
            container="${container}-${POD}"
            local container_nr=
            for container_nr in $(seq 1 "${POD_CONTAINER_COUNT}"); do
                local container2=
                _GET_CONTAINER_VAR "${container_nr}" "NAME" "container2"
                if [ "${container2}" = "${container}" ]; then
                    containers="${containers} ${container}"
                    continue 2
                fi
            done
            PRINT "Container ${container} does not exist in this pod" "error" 0
            return 1
        done
    fi

    # For each container, check if there are logfiles for the streams chosen,
    # check rotated out logfiles and choose the ones older than ts given.
    local files=""
    for container in ${containers}; do
        local stream=
        for stream in ${streams}; do
            # Check current file
            local filePath="${POD_LOG_DIR}/${container}-${stream}.log"
            if [ -f "${filePath}" ]; then
                files="${files} ${filePath}"
            fi
            # Check older files
            for filePath in $(find . -maxdepth 1 -wholename "${POD_LOG_DIR}/${container}-${stream}.log.*" |cut -b3-); do
                local ts="${file##*.}"
                if [ "${timestamp}" -le "${ts}" ]; then
                    files="${files} ${filePath}"
                fi
            done
        done
    done

    local columns=""
    local detail=
    for detail in ${details}; do
        local arg=""
        if [ "${detail}" = "ts" ]; then
            arg='\4'
        elif [ "${detail}" = "name" ]; then
            arg='\1'
        elif [ "${detail}" = "stream" ]; then
            arg='\2'
        elif [ "${detail}" = "age" ]; then
            arg='\3'
        fi
        columns="${columns}${columns:+ }${arg}"
    done
    columns="${columns}${columns:+ }\\6"

    local now="$(date +%s)"

    # For all applicable files, filter each line on timestamp and prepend with container
    # name and stream name.
    # Cat all files together, with prefixes, filter out on time, Sort on time
    local filePath=
    for filePath in ${files}; do
        local file="${filePath##*/}"
        local container="${file%-${POD}*}"
        if [ "${container}" = "${file}" ]; then
            # This happens for the pod
            container="<pod>"
        fi
        local stream="${file%.log*}"
        stream="${stream##*-}"
        # Columns: container stream age timestamp index rest-of-line
        awk '{if ($1 >= '"${timestamp}"') {age='"${now}"'-$1; print "'"${container}"' '"${stream}"' " age " " $0}}' "${filePath}"
    done |sort -k4,4n -k5,5n |
        {
            if [ "${limit}" = 0 ]; then
                :
                cat
            else
                if [ "${limit}" -lt 0 ]; then
                    tail -n"${limit#-}"
                else
                    head -n"${limit}"
                fi
            fi
        } |
        {
            # Only show the relevant columns
            sed "s/\\([^ ]\+\\) \\([^ ]\\+\\) \\([^ ]\\+\\) \\([^ ]\\+\\) \\([^ ]\\+\\) \\(.*\\)/${columns}/"
        }
}

# CLI COMMAND
# Signal one or many containers.
_SIGNAL()
{
    SPACE_SIGNATURE="[containers]"
    SPACE_DEP="_CONTAINER_EXISTS _GET_CONTAINER_VAR _SIGNAL_CONTAINER _CONTAINER_STATUS PRINT"

    local container=
    local containerNames=""

    if [ "$#" -gt 0 ]; then
        # Iterate over each name and append the POD name
        for container in "$@"; do
            container="${container}-${POD}"
            if ! _CONTAINER_EXISTS "${container}"; then
                PRINT "Container ${container} does not exist in this pod" "error" 0
                return 1
            fi
            containerNames="${containerNames} ${container}"
        done
    else
        # Get all containers
        local container_nr=
        for container_nr in $(seq 1 "${POD_CONTAINER_COUNT}"); do
            _GET_CONTAINER_VAR "${container_nr}" "NAME" "container"
            containerNames="${containerNames} ${container}"
        done
    fi

    for container in ${containerNames}; do
        local container2=
        for container_nr in $(seq 1 "${POD_CONTAINER_COUNT}"); do
            _GET_CONTAINER_VAR "${container_nr}" "NAME" "container2"
            if [ "${container}" = "${container2}" ]; then
                _SIGNAL_CONTAINER "${container}" "${container_nr}"
                break
            fi
        done
    done
}

# CLI COMMAND
_RELOAD_CONFIGS()
{
    SPACE_SIGNATURE="configs"
    SPACE_DEP="_RELOAD_CONFIGS2 _POD_EXISTS _POD_STATUS PRINT"

    if ! _POD_EXISTS; then
        PRINT "Pod ${POD} does not exist" "error" 0
        return 1
    fi

    local podstatus="$(_POD_STATUS)"
    if [ "${podstatus}" != "Running" ]; then
        PRINT "Pod ${POD} is not running" "error" 0
        return 1
    fi

    PRINT "Cycle/signal containers who mount the configs $*" "info" 0

    _RELOAD_CONFIGS2 "$@"
}

# Is automatically called whenever a config on disk has changed
# we call this function to notify containers who mount the particular config.
_RELOAD_CONFIGS2()
{
    SPACE_SIGNATURE="configs"
    SPACE_DEP="PRINT _GET_CONTAINER_VAR _CONTAINER_STATUS STRING_ITEM_INDEXOF"

    local config=
    local containersdone=""
    for config in "$@"; do
        local container=
        local container_nr=
        for container_nr in $(seq 1 "${POD_CONTAINER_COUNT}"); do
            # Check if this container already got signalled
            if STRING_ITEM_INDEXOF "${containersdone}" "${container_nr}"; then
                continue
            fi

            _GET_CONTAINER_VAR "${container_nr}" "NAME" "container"
            local usedconfigs=
            _GET_CONTAINER_VAR "${container_nr}" "CONFIGS" "usedconfigs"
            # Test if $config exists in list of used configs
            if STRING_ITEM_INDEXOF "${usedconfigs}" "${config}"; then
                containersdone="${containersdone} ${container_nr}"
                PRINT "Container ${container} mounts config ${config}" "info" 0
                # Signal or potentially restart container (depending on restart policy).
                _SIGNAL_CONTAINER "${container}" "${container_nr}"
            fi
        done
    done
}

# Remove pod, containers, configs, ramdisks (if created by us) and all volumes.
# Make sure pod and containers have already been removed then remove volumes created.
# Do not remove configs, because those are not created by this runtime and we cannot be sure it is ok to delete them.
_PURGE()
{
    SPACE_DEP="_DESTROY_VOLUMES _POD_EXISTS PRINT _RM"

    if _POD_EXISTS; then
        PRINT "Pod ${POD} exists. Remove it before purging" "error" 0
        return 1
    fi

    # Make sure all containers are removed
    _RM

    _DESTROY_VOLUMES
}

# Enter shell in a container
_SHELL()
{
    SPACE_SIGNATURE="container useBash [commands]"
    SPACE_DEP="_GET_CONTAINER_VAR _CONTAINER_EXISTS"

    local container="${1}"
    shift

    local useBash="${1:-false}"
    shift

    local containerName=
    if [ -n "${container}" ]; then
        containerName="${container}-${POD}"
        if ! _CONTAINER_EXISTS "${containerName}"; then
            PRINT "Container ${containerName} does not exist in this pod" "error" 0
            return 1
        fi
    else
        _GET_CONTAINER_VAR "${POD_CONTAINER_COUNT}" "NAME" "containerName"
    fi

    local sh=sh
    if [ "${useBash}" = "true" ]; then
        sh="bash"
    fi
    if [ "$#" -gt 0 ]; then
        local cmds="$*"
        STRING_ESCAPE "cmds" '"'
        podman exec -i "${containerName}" ${sh} -c "${cmds}"
    else
        podman exec -ti "${containerName}" ${sh}
    fi
}

# Exec a command inside a container, repeatedly if not getting exit code 0.
# Sleep 1 second between each exec and timeout eventually (killing the command if necessary).
_RUN_PROBE()
{
    SPACE_SIGNATURE="container command timeout"
    SPACE_DEP="PRINT"

    local container="${1}"
    shift

    local command="${1}"
    shift

    local timeout="${1}"
    shift

    PRINT "podman exec ${container} ${command}" "debug" 0

    eval "podman exec ${container} ${command} >/dev/null 2>&1"&
    local pid="$!"
    while true; do
        if ! kill -0 "${pid}" 2>/dev/null; then
            # Process ended, get exit code.
            if wait "${pid}"; then
                # exit code 0, success.
                return 0
            else
                # Probe did not succeed.
                return 1
            fi
        fi

        # Process still alive, check overall timeout.
        now=$(date +%s)
        if [ "${now}" -ge "${timeout}" ]; then
            # Probe did not succeed.
            # Kill process.
            kill -9 "${pid}"
            return 1
        fi

        sleep 1
    done
}

# Check if the pod is ready to receive traffic.
# Run the readiness probe on the containers who has one defined.
# An exit code of 0 means the readiness fared well and all applicable containers are ready to receive traffic.
# The readiness probe is defined in the YAML describing each container.
_READINESS_PROBE()
{
    SPACE_DEP="_RUN_PROBE _CONTAINER_STATUS PRINT _POD_EXISTS _POD_STATUS"

    if ! _POD_EXISTS; then
        PRINT "Pod ${POD} does not exist" "debug" 0
        return 1
    fi

    local podstatus="$(_POD_STATUS)"
    if [ "${podstatus}" != "Running" ]; then
        PRINT "Pod ${POD} is not in the running state" "debug" 0
        return 1
    fi

    local container_nr=
    for container_nr in $(seq 1 "${POD_CONTAINER_COUNT}"); do
        local container=
        _GET_CONTAINER_VAR "${container_nr}" "NAME" "container"
        local probe=
        _GET_CONTAINER_VAR "${container_nr}" "READINESSPROBE" "probe"
        local timeout=
        _GET_CONTAINER_VAR "${container_nr}" "READINESSTIMEOUT" "timeout"
        if [ -n "${probe}" ]; then
            local containerstatus="$(_CONTAINER_STATUS "${container}")"
            if [ "${containerstatus}" != "running" ]; then
                PRINT "Probe for container ${container} failed because container is not running" "debug" 0
                return 1
            fi
            local now=$(date +%s)
            local expire="$((now + timeout))"
            if ! _RUN_PROBE "${container}" "${probe}" "${expire}"; then
                # Probe failed
                PRINT "Probe for container ${container} failed" "debug" 0
                return 1
            fi
        fi
    done
}

# Run the liveness probe on the containers which have liveness probes defined.
# If the probe fails on a container the container will be stopped and then subject to its restart policy.
# An exit code of 1 means that at least one container was found in a bad state and stopped.
# The liveness probe is defined in the YAML describing each container.
_LIVENESS_PROBE()
{
    SPACE_DEP="_RUN_PROBE _CONTAINER_STATUS PRINT _CONTAINER_STOP"

    local container_nr=
    for container_nr in $(seq 1 "${POD_CONTAINER_COUNT}"); do
        local container=
        _GET_CONTAINER_VAR "${container_nr}" "NAME" "container"
        local probe=
        _GET_CONTAINER_VAR "${container_nr}" "LIVENESSPROBE" "probe"
        local timeout=
        _GET_CONTAINER_VAR "${container_nr}" "LIVENESSTIMEOUT" "timeout"
        if [ -n "${probe}" ]; then
            local containerstatus="$(_CONTAINER_STATUS "${container}")"
            if [ "${containerstatus}" != "running" ]; then
                PRINT "Liveness probe for container ${container} is skipped because container is not running" "debug" 0
                continue
            fi
            local now=$(date +%s)
            local expire="$((now + timeout))"
            if ! _RUN_PROBE "${container}" "${probe}" "${expire}"; then
                # Probe failed
                PRINT "Liveness probe for container ${container} failed. Stopping container" "debug" 0
                _CONTAINER_STOP "${container}"
            fi
        fi
    done
}

_CHECK_PODMAN()
{
    SPACE_DEP="PRINT"

    if ! command -v podman >/dev/null 2>/dev/null; then
        PRINT "podman is not installed" "error" 0
        return 1
    fi

    PRINT "Checking podman version" "debug" 0

    local podverstring="$(podman --version)"
    local ver="${podverstring##*[ ]}"
    local major="${ver%%[.]*}"
    local minor="${ver%[.]*}"
    minor="${minor#*[.]}"
    local patch="${ver##*[.]}"

    if [ "${ver}" = "1.8.0" ]; then
        PRINT "Podman 1.8.0 is not supported" "error" 0
        return 1
    fi

    if [ "${major}" -gt 1 ]; then
        return 0
    fi

    if [ "${major}" -lt 1 ]; then
        PRINT "podman must be at least version 1.8.1. Current version is ${major}.${minor}.${patch}" "error" 0
        return 1
    fi

    if [ "${minor}" -lt 8 ]; then
        PRINT "podman must be at least version 1.8.1. Current version is ${major}.${minor}.${patch}" "error" 0
        return 1
    fi

    if [ "${minor}" -gt 8 ]; then
        return 0
    fi

    if [ "${patch}" -lt 1 ]; then
        PRINT "podman must be at least version 1.8.1. Current version is ${major}.${minor}.${patch}" "error" 0
        return 1
    fi
}

# options are on the format:
# "_out_all=-a,--all/ _out_state=-s,--state/arg1|arg2|arg3"
# For non argument options the variable will be increased by 1 for each occurrence.
# The variable _out_arguments is reserved for positional arguments.
# Expects _out_arguments and all _out_* to be defined.
_GETOPTS()
{
    SPACE_SIGNATURE="options minPositional maxPositional [args]"
    SPACE_DEP="_GETOPTS_SWITCH PRINT STRING_SUBSTR STRING_INDEXOF STRING_ESCAPE"

    local options="${1}"
    shift

    local minPositional="${1:-0}"
    shift

    local maxPositional="${1:-0}"
    shift

    _out_arguments=""
    local posCount="0"
    local skipOptions="false"
    while [ "$#" -gt 0 ]; do
        local option=
        local value=
        local _out_VARNAME=
        local _out_ARGUMENTS=

        if [ "${skipOptions}" = "false" ] && [ "${1}" = "--" ]; then
            skipOptions="true"
            shift
            continue
        fi

        if [ "${skipOptions}" = "false" ] && [ "${1#--}" != "${1}" ]; then # Check if it is a double dash GNU option
            local l=
            STRING_INDEXOF "=" "${1}" "l"
            if [ "$?" -eq 0 ]; then
                STRING_SUBSTR "${1}" 0 "${l}" "option"
                STRING_SUBSTR "${1}" "$((l+1))" "" "value"
            else
                option="${1}"
            fi
            shift
            # Fill _out_VARNAME and _out_ARGUMENTS
            _GETOPTS_SWITCH "${options}" "${option}"
            # Fall through to handle option
        elif [ "${skipOptions}" = "false" ] && [ "${1#-}" != "${1}" ] && [ "${#1}" -gt 1 ]; then # Check single dash OG-style option
            option="${1}"
            shift
            if [ "${#option}" -gt 2 ]; then
                PRINT "Invalid option '${option}'" "error" 0
                return 1
            fi
            # Fill _out_VARNAME and _out_ARGUMENTS
            _GETOPTS_SWITCH "${options}" "${option}"
            # Do we expect a value to the option? If so take it and shift it out
            if [ -n "${_out_ARGUMENTS}" ]; then
                if [ "$#" -gt 0 ]; then
                    value="${1}"
                    shift
                fi
            fi
            # Fall through to handle option
        else
            # Positional args
            posCount="$((posCount+1))"
            if [ "${posCount}" -gt "${maxPositional}" ]; then
                PRINT "Too many arguments. Max ${maxPositional} argument(s) allowed." "error" 0
                return 1
            fi
            _out_arguments="${_out_arguments}${_out_arguments:+ }${1}"
            shift
            continue
        fi

        # Handle option argument
        if [ -z "${_out_VARNAME}" ]; then
            PRINT "Unrecognized option: '${option}'" "error" 0
            return 1
        fi

        if [ -n "${_out_ARGUMENTS}" ] && [ -z "${value}" ]; then
            # If we are expecting a option arguments but none was provided.
            STRING_SUBST "_out_ARGUMENTS" " " ", " 1
            PRINT "Option ${option} is expecting an argument like: ${_out_ARGUMENTS}" "error" 0
            return 1
        elif [ -z "${_out_ARGUMENTS}" ] && [ -z "${value}" ]; then
            # This was a simple option without argument, increase counter of occurrences
            eval "value=\"\$${_out_VARNAME}\""
            if [ -z "${value}" ]; then
                value=0
            fi
            value="$((value+1))"
        elif [ "${_out_ARGUMENTS}" = "*" ] || STRING_ITEM_INDEXOF "${_out_ARGUMENTS}" "${value}"; then
            # Value is OK, fall through
            :
        else
            # Invalid argument
            if [ -z "${_out_ARGUMENTS}" ]; then
                PRINT "Option ${option} does not take any arguments" "error" 0
            else
                PRINT "Invalid ${option} argument '${value}'. Valid arguments are: ${_out_ARGUMENTS}" "error" 0
            fi
            return 1
        fi

        # Store arguments in variable
        STRING_ESCAPE "value"
        eval "${_out_VARNAME}=\"\${value}\""
    done

    if [ "${posCount}" -lt "${minPositional}" ]; then
        PRINT "Too few arguments provided. Minimum ${minPositional} argument(s) required." "error" 0
        return 1
    fi
}

# Find a match in options and fill _out_VARNAME and _out_ARGUMENTS
_GETOPTS_SWITCH()
{
    SPACE_SIGNATURE="options option"
    SPACE_DEP="STRING_SUBST STRING_ITEM_INDEXOF STRING_ITEM_GET STRING_ITEM_COUNT"

    local options="${1}"
    shift

    local option="${1}"
    shift

    local varname=
    local arguments=

    local count=0
    local index=0
    STRING_ITEM_COUNT "${options}" "count"
    while [ "${index}" -lt "${count}" ]; do
        local item=
        STRING_ITEM_GET "${options}" ${index} "item"
        varname="${item%%=*}"
        arguments="${item#*/}"
        local allSwitches="${item#*=}"
        allSwitches="${allSwitches%%/*}"
        STRING_SUBST "allSwitches" "," " " 1
        if STRING_ITEM_INDEXOF "${allSwitches}" "${option}"; then
            STRING_SUBST "arguments" "|" " " 1
            _out_VARNAME="${varname}"
            _out_ARGUMENTS="${arguments}"
            return 0
        fi
        index=$((index+1))
    done

    # No such option found
    return 1
}

POD_ENTRY()
{
    SPACE_SIGNATURE="action [args]"
    SPACE_DEP="_VERSION _SHOW_USAGE _CREATE _CREATE_FORK _RUN _PURGE _RELOAD_CONFIGS _RM _RERUN _SIGNAL _LOGS _STOP _START _KILL _CREATE_RAMDISKS _CREATE_VOLUMES _DOWNLOAD _SHOW_INFO _SHOW_STATUS _GET_READINESS _CHECK_PODMAN _GET_CONTAINER_VAR _GETOPTS _SHELL"

    # This is for display purposes only and shows the runtime type and the version of the runtime impl.
    local API_VERSION="1.0.0-beta1"
    local RUNTIME="podman"

    local MAX_LOG_FILE_SIZE="10485760"  # 10 MiB large log files, then rotating.

    # Set POD_DIR
    local POD_DIR="${0%/*}"
    if [ "${POD_DIR}" = "${0}" ]; then
        # This is weird, not slash in path, but we will handle it.
        if [ -f "./${0}" ]; then
            # This happens when the script is invoked as `sh pod`.
            POD_DIR="${PWD}"
        else
            PRINT "Could not determine the base dir for the pod" "error" 0
            return 1
        fi
    fi
    POD_DIR="$(cd "${POD_DIR}" && pwd)"
    local start_dir="$(pwd)"

    if [ "${POD_DIR}" != "${start_dir}" ]; then
        PRINT "Changing CWD to pod dir: ${POD_DIR}" "debug" 0
        cd "${POD_DIR}"
    fi

    # Absolute path to the pod executable. The status functions use this to reference the pod.status file.
    local POD_FILE="${POD_DIR}/${0##*/}"

    local POD_LOG_DIR="${POD_DIR}/log"

    local action="${1:-help}"
    shift $(($# > 0 ? 1 : 0))

    if [ "${action}" = "help" ] || [ "${action}" = "-h" ] || [ "${action}" = "--help" ]; then
        _SHOW_USAGE
    elif [ "${action}" = "version" ] || [ "${action}" = "-V" ] || [ "${action}" = "--version" ]; then
        _VERSION
    elif [ "${action}" = "info" ]; then
        _SHOW_INFO
    else
        # Commands below all need podman, so we check the version first.
        if ! _CHECK_PODMAN; then
            return 1
        fi

        mkdir -p "${POD_LOG_DIR}"

        if [ "${action}" = "ps" ]; then
            _SHOW_STATUS
        elif [ "${action}" = "readiness" ]; then
            _GET_READINESS
        elif [ "${action}" = "download" ]; then
            local _out_f=

            if ! _GETOPTS "_out_f=-f,--force/" 0 0 "$@"; then
                printf "Usage: pod download [-f|--force]\\n" >&2
                return 1
            fi
            _DOWNLOAD "${_out_f:+true}"
        elif [ "${action}" = "create" ]; then
            _CREATE
        elif [ "${action}" = "porcelain-create" ]; then
            # Undocumented internal method used to fork
            _CREATE_FORK
        elif [ "${action}" = "start" ]; then
            _START
        elif [ "${action}" = "stop" ]; then
            _STOP
        elif [ "${action}" = "kill" ]; then
            _KILL
        elif [ "${action}" = "run" ]; then
            _RUN
        elif [ "${action}" = "rerun" ]; then
            local _out_arguments=
            local _out_k=

            if ! _GETOPTS "_out_k=-k,--kill/" 0 999 "$@"; then
                printf "Usage: pod rerun [-k|--kill] [containers]\\n" >&2
                return 1
            fi
            if [ -n "${_out_arguments}" ] && [ -n "${_out_k}" ]; then
                printf "Error: -k|--kill switch not valid when providing containers. Only the pod as a whole can be killed\\nUsage: pod rerun [-k|--kill] [containers]\\n" >&2
                return 1
            fi
            set -- ${_out_arguments}
            _RERUN "${_out_k:+true}" "$@"
        elif [ "${action}" = "signal" ]; then
            _SIGNAL "$@"
        elif [ "${action}" = "logs" ]; then
            local _out_arguments=
            local _out_p=
            local _out_t=
            local _out_s=
            local _out_l=
            local _out_d=

            if ! _GETOPTS "_out_p=-p,--daemon-process/ _out_t=-t,--timestamp/* _out_l=-l,--limit/* _out_s=-s,--stream/* _out_d=-d,--details/*" 0 999 "$@"; then
                printf "Usage: pod logs pod[:version][@host] [-p|-daemon-process] [-t|--timestamp=] [-l|--limit=] [-s|--stream=] [-d|--details=] [containers]\\n" >&2
                return 1
            fi
            set -- ${_out_arguments}
            _LOGS "${_out_t}" "${_out_l}" "${_out_s}" "${_out_d}" "${_out_p:+true}" "$@"
        elif [ "${action}" = "create-volumes" ]; then
            _CREATE_VOLUMES
        elif [ "${action}" = "create-ramdisks" ]; then
            local _out_d=
            local _out_l=

            if ! _GETOPTS "_out_d=-d,--delete/ _out_l=-l,--list/" 0 0 "$@"; then
                printf "Usage: pod create-ramdisks [-l|--list] [-d|--delete]\\n" >&2
                return 1
            fi
            _CREATE_RAMDISKS "${_out_d:+true}" "${_out_l:+true}"
        elif [ "${action}" = "reload-configs" ]; then
            local _out_arguments=
            if ! _GETOPTS "" 1 999 "$@"; then
                printf "Usage: pod reload-configs config1 [config2...]\\n" >&2
                return 1
            fi
            set -- ${_out_arguments}
            _RELOAD_CONFIGS "$@"
        elif [ "${action}" = "rm" ]; then
            local _out_k=

            if ! _GETOPTS "_out_k=-k,--kill/" 0 0 "$@"; then
                printf "Usage: pod rm [-k|==kill]\\n" >&2
                return 1
            fi
            _RM "${_out_k:+true}"
        elif [ "${action}" = "purge" ]; then
            _PURGE
        elif [ "${action}" = "shell" ]; then
            local _out_arguments=
            local _out_b=
            local _out_c=

            if ! _GETOPTS "_out_b=-b,--bash/ _out_c=-c,--container/*" 0 99999 "$@"; then
                printf "Usage: pod shell [container] [-b|--bash] [-c|--container=] [-- <commands>]\\n" >&2
                return 1
            fi
            set -- ${_out_arguments}
            _SHELL "${_out_c}" "${_out_b:+true}" "$@"
        else
            PRINT "Unknown command" "error" 0
            return 1
        fi
    fi

    local status=$?
    cd "${start_dir}" 2>/dev/null
    return "${status}"
}
