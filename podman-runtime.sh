# Configuring podman for rootless:
# The files /etc/sub{uid,gid} need id mappings. Single line in each file as:
# bashlund:10000:6553
#
# That allocates 6553 IDs to be used by containers.
# Run `podman system migrate` to have podman pick that up.

# If any rootless containers are binding to host ports <1024, then we must set on the host machines `sysctl net.ipv4.ip_unprivileged_port_start=80`

# Rootless pods and containers cannot be paused/unpaused.
# We don't either support stop/start without having the containers recreated.

# We don't rely on the --restart flag for restarting containers. This module handles all logic.
# The Simplenetes Daemon could repeatedly call this script so that it can make sure the pod is in the expected state.
# If the pod is to be in the 'running' state then the daemon will constantly call `./pod run` which
# is an idempotent command and makes sure all containers are in their right state.

# Restart policies are:
# always (no matter exit code restart container)
# on-config (restart when config files on disk are changed or when container exited with error code)
# on-interval:x (as on-config, but also restart on successful exists after x seconds have passed)
# on-failure (restart container when exit -ne 0)
# never (never restart container)
#
# Containers set to restart-policy "on-config" it will also restart for failures.

# Role of daemon:
# The daemon runs as root and as before it invokes this script it creates the ramdisks if not
# already existing. The daemon spawn an unpriviligied process to run the pod script.
# If the pod is not existing as the script exits back to the daemon the daemon will remove the ram disks.
# This script can be run without the daemon preparing the ramdisks but then the contents will be persisted to the host disk instead of a ramdisk, which is fine for development but not for production.
# States: running -> stopped -> removed

# Do not run the pod script concurrently. If the daemon is managing the pod then we should not call the pod script ourselves.

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

    eval "${outname}=\"\${POD_CONTAINER_${varname}_${container_nr}}\""
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
        STRING_SUBST "data" " -p " "" 1
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
_POD_STATUS()
{
    #SPACE_ENV="POD"

    # Note: podman pod ps in this version does not filter using regex, so --filter name matches
    # all pods who has part of the name in them, hence the grep/awk crafting.
    podman pod ps --format "{{.Name}} {{.Status}}" |grep "^${POD}\>" |awk '{print $2}'
}

_KILL_POD()
{
    #SPACE_ENV="POD"
    SPACE_DEP="_GET_CONTAINER_VAR _CONTAINER_EXISTS _CONTAINER_STATUS _CONTAINER_KILL PRINT"

    local container=
    local container_nr=
    for container_nr in $(seq 1 "${POD_CONTAINER_COUNT}"); do
        _GET_CONTAINER_VAR "${container_nr}" "NAME" "container"
        if _CONTAINER_EXISTS "${container}"; then
            if [ "$(_CONTAINER_STATUS "${container}")" = "running" ]; then
                PRINT "Stopping container ${container}" "info" 0
                _CONTAINER_KILL "${container}"
            fi
        fi
    done

    PRINT "Pod ${POD} killing..." "info" 0
    local id=
    if id=$(podman pod kill ${POD} 2>&1); then
        PRINT "Pod ${POD} killed: ${id}" "ok" 0
    else
        PRINT "Pod ${POD} could not be killed: ${id}" "error" 0
        return 1
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

_STOP_POD()
{
    SPACE_DEP="_GET_CONTAINER_VAR _CONTAINER_EXISTS _CONTAINER_STATUS _CONTAINER_STOP PRINT"
    #SPACE_ENV="POD"

    local container=
    local container_nr=
    for container_nr in $(seq 1 "${POD_CONTAINER_COUNT}"); do
        _GET_CONTAINER_VAR "${container_nr}" "NAME" "container"
        if _CONTAINER_EXISTS "${container}"; then
            if [ "$(_CONTAINER_STATUS "${container}")" = "running" ]; then
                PRINT "Stopping container ${container}" "info" 0
                _CONTAINER_STOP "${container}"
            fi
        fi
    done

    PRINT "Pod ${POD} stopping..." "info" 0
    local id=
    if id=$(podman pod stop ${POD} 2>&1); then
        PRINT "Pod ${POD} stopped: ${id}" "ok" 0
    else
        PRINT "Pod ${POD} could not be stopped: ${id}" "error" 0
        return 1
    fi
}

# Remove the pod and all containers, ramdisks (if created by us), but leave volumes and configs.
_DESTROY_POD()
{
    SPACE_DEP="_DESTROY_RAMDISKS PRINT _GET_CONTAINER_VAR _RM_CONTAINER _CONTAINER_EXISTS"

    local container=
    local container_nr=
    for container_nr in $(seq 1 "${POD_CONTAINER_COUNT}"); do
        _GET_CONTAINER_VAR "${container_nr}" "NAME" "container"
        if _CONTAINER_EXISTS "${container}"; then
            _RM_CONTAINER "${container}"
        fi
    done

    local id=
    if ! id="$(podman pod rm -f "${POD}" 2>&1)"; then
        PRINT "Pod ${POD} could not be destroyed: ${id}" "error" 0
        return 1
    else
        PRINT "Pod ${POD} destroyed" "ok" 0
    fi

    _DESTROY_RAMDISKS
}

# If the ramdisks were actually regular directories created by the pod script then we purge them.
# If the dirs are actual ramdisks then they will get purged by the daemon.
_DESTROY_RAMDISKS()
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
# The outside daemon must create these with root priviligies.
# However, if they do not exist in the case this pod is not orchestrated but ran directly by the user,
# we create fake ramdisks on disk by creating the directories. This not at all ramdisks and are not safe for sensitive informaion.
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
        fi
    done
}

# Create the pod.
_CREATE_POD()
{
    #SPACE_ENV="POD_CREATE"

    local id=
    if id=$(podman pod create ${POD_CREATE}); then
        PRINT "Pod ${POD} created with id: ${id}" "ok" 0
    else
        PRINT "Pod ${POD} could not be created" "error" 0
        return 1
    fi
}

# Start the pod
_START_POD()
{
    SPACE_DEP="PRINT"
    #SPACE_ENV="POD"

    local id=
    if id=$(podman pod start ${POD}); then
        PRINT "Pod ${POD} started: ${id}" "ok" 0
    else
        PRINT "Pod ${POD} could not be started" "error" 0
    fi
}

# Start the pod and run the containers, only if the pod is in the Created state.
_START()
{
    SPACE_DEP="PRINT _POD_EXISTS _POD_STATUS _START_POD _START_CONTAINERS"

    if _POD_EXISTS; then
        local podstatus="$(_POD_STATUS)"
        if [ "${podstatus}" = "Running" ]; then
            PRINT "Pod ${POD} is already running" "debug" 0
            return 0
        fi
        if [ "${podstatus}" = "Created" ]; then
            if ! _START_POD; then
                return 1
            fi
            _START_CONTAINERS
        else
            PRINT "Pod ${POD} is not in the \"Created\" state. Stopping and starting (resuming) pods is not supported. Try and rerun the pod" "error" 0
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

    local at="$(podman inspect ${container} --format "{{.State.FinishedAt}}")"
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
    if ! code="$(podman inspect ${container} --format "{{.State.ExitCode}}" 2>/dev/null)"; then
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
        if _CONTAINER_EXISTS "${container}"; then
            # Kill it first, because it is quicker
            _CONTAINER_KILL "${container}"
            _RM_CONTAINER "${container}"
        fi
    fi
}

_RM_CONTAINER()
{
    SPACE_SIGNATURE="container"
    SPACE_DEP="PRINT"

    local container="${1}"
    shift

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
    SPACE_DEP="_SIGNAL_CONTAINER _CONTAINER_EXISTS _CONTAINER_EXITCODE _CONTAINER_STATUS PRINT NETWORK_LOCAL_IP _PULL_IMAGE FILE_STAT _LOG_FILE _RUN_PROBE"

    local container="${1}"
    shift

    local container_nr="${1}"
    shift

    PRINT "Run container ${container}" "info" 0

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

    local run=
    _GET_CONTAINER_VAR "${container_nr}" "RUN" "run"

    local stdoutLog="${container}-stdout.log"
    local stderrLog="${container}-stderr.log"

    local pid=
    # Run the container from a subshell, so we can capture stdout and stderr separately.
    (
        local ts="$(date +%s)"
        local status=
        printf "%s [SNT] Run %s: podman run %s\\n" "${ts}" "${container}" "${run}" >>"${stderrLog}"
        { eval "podman run ${run}" |_LOG_FILE "${stdoutLog}" "${MAX_LOG_FILE_SIZE}"; } 2>&1 |
            _LOG_FILE "${stderrLog}" "${MAX_LOG_FILE_SIZE}"
        # Container has exited
        status="$?"
        local containerstatus="$(_CONTAINER_STATUS "${container}")"
        if [ "${containerstatus}" = "exited" ]; then
            printf "%s [SNT] %s exited with exit code %s\\n" "${ts}" "${container}" "${status}" >>"${stderrLog}"
        else
            printf "%s [SNT] %s ended, with state %s\\n" "${ts}" "${container}" "${containerstatus}" >>"${stderrLog}"
        fi
    ) >/dev/null 2>/dev/null &
    pid="$!"
    PRINT "Subshell PID is ${pid} for container ${container}" "debug" 0

    # Wait for container to be running or exited, if it timeoutes then the startup failed
    local now=$(date +%s)
    local timeout=$((now + 3))
    # Small risk here is if container starts, exits and is removed within the same second,
    # then this logic will fail.
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
        :
    fi

    # Fire the signalling to other containers that this container is started (which could mean started and successfully exited).
    local signals=
    _GET_CONTAINER_VAR "${container_nr}" "STARTUPSIGNAL" "signals"
    if [ -n "${signals}" ]; then
        local container_nr=
        local container=
        for container_nr in ${signals}; do
            _GET_CONTAINER_VAR "${container_nr}" "NAME" "container"

            # Only signal a container which is running
            if _CONTAINER_EXISTS "${container}"; then
                if [ "$(_CONTAINER_STATUS "${container}")" = "running" ]; then
                    _SIGNAL_CONTAINER "${container}" "${container_nr}"
                else
                    PRINT "Container ${container} is not running, will not signal it" "info" 0
                fi
            fi
        done
    fi
}

# Read on STDIN and write to "file",
# when file grows over "ywaxFileSize" "file" is rotated out
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

# Expects the container to be running.
_SIGNAL_CONTAINER()
{
    SPACE_SIGNATURE="container container_nr"
    SPACE_DEP="PRINT _GET_CONTAINER_VAR"

    local container="${1}"
    shift

    local container_nr="${1}"
    shift

    local cmd=
    _GET_CONTAINER_VAR "${container_nr}" "SIGNALCMD" "cmd"

    local sig=
    _GET_CONTAINER_VAR "${container_nr}" "SIGNALSIG" "sig"

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
        PRINT "Container ${container} does not define any signals and cannot be signalled" "info" 0
    fi
}

# Check if volume exists.
_VOLUME_EXISTS()
{
    SPACE_SIGNATURE="volume"

    local volume="${1}"
    shift

    podman volume inspect "${volume}" >/dev/null 2>&1
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
        if ! podman volume rm "${volume}"; then
            PRINT "Volume ${volume} could not be removed" "error" 0
        fi
    done

    PRINT "All volumes for pod ${POD} removed" "info" 0
}


_VERSION()
{
    #SPACE_ENV="POD_VERSION"

    printf "podVersion: %s\\npodRuntime: %s\\n" "${POD_VERSION}" "${RUNTIME_VERSION}"
}

_SHOW_USAGE()
{
    printf "%s\\n" "Usage:
    help
        Output this help.

    version
        Output podVersion and podRuntime type and version.

    info
        Output information about this pod's configuration.

    status
        Output current runtime status for this pod.

    download [-f]
        Perform pull on images for all containers.
        If -f option is set then always pull for updated images, even if they already exist locally.

    create
        Create the pod and the volumes, but not the containers. Will not start the pod.

    start
        Start the pod and run the containers, as long as the pod is already created.

    stop
        Stop the pod and all containers.

    kill
        Kill the pod and all containers.

    run
        Create and start the pod and all containers.
        This command is safe to run over and over and it will then recreate and failed
        containers, depending on their restart policy.
        Note that containers which crash will only be restarted when issuing this run command.

    rm
        Remove the pod and all containers, but leave volumes intact.
        If the pod and containers are running they will be stopped first and then removed.

    rerun
        Remove the pod and all containers then recreate and start them.
        Same effect as issuing rm and run in sequence.

    signal [container1 container2 etc]
        Send a signal to one, many or all containers.
        The signal sent is the SIG defined in the containers YAML specification.
        Invoking without arguments will invoke signals all all containers which have a SIG defined.

    logs [containers] [-t timestamp] [-s streams] [-l limit] [-d details]
        Output logs for one, many or all containers. If none given then show for all.
        -t timestamp=UNIX timestamp to get logs from, defaults to 0
        -s streams=[stdout|stderr|stdout,stderr], defaults to \"stdout,stderr\".
        -l limit=nr of lines to get in total from the top, negative gets from the bottom (latest).
        -d details=[ts|name|stream|none], comma separated if many.
            if \"ts\" set will show the UNIX timestamp for each row,
            if \"name\" is set will show the container name for each row.
            if \"stream\" is set will show the std stream the logs came on.
            To not show any details set to \"none\".
            Defaults to \"ts,name\".

    create-volumes
        Create the volumes used by this pod, if they do not exist already.
        Volumes are always created when running the pod, this command can be used
        to first create the volumes and possibly populate them with data, before running the pod.

    reload-configs config1 [config2 config3 etc]
        When a "config" has been updated on disk, this command should be invoked to signal the container
        who mount the specific config(s).
        Each container mounting the config will be signalled as defined in the YAML specification.

    purge
        Remove all volumes for a pod.
        the pod must first have been removed.

    readiness
        Run the readiness probe on the containers who has one defined.
        An exit code of 0 means the readiness fared well and all applicable containers are ready to receive traffic.
        The readiness probe is defined in the YAML describing each container.

    liveness
        Run the liveness probe on the containers who has one defined.
        If the probe fails on a container the container will be stopped.
        It is up to the daemon or the user to issue the 'run' command again to have that container started up again.
        An exit code of 1 means that at least one container was found in a bad state and stopped.
        The liveness probe is defined in the YAML describing each container.

    ramdisk-config
        Output information about what ramdisks this pod wants.
        This command is ran be the Daemon so it can prepare the ramdisks needed for this pod.
        If ramdisks are not prepared prior to the pod starting up then the pod will it self
        create regular directories instead of real ramdisks.
        This means that for applications where the security of ramdisks are important then
        the lifecycle of the pods should be managed by the Daemon.
"
}

# Show basic config about this pod, it's containers and volumes.
# This is not runtime status
_SHOW_INFO()
{
    SPACE_DEP="_OUTPUT_CONTAINER_INFO _GET_CONTAINER_VAR"

    # TODO: this output needs to be structured and prettified
    # also, alot of things are missing.

    #printf "%s\\n" "Podname
#CONTAINER   RESTART   MOUNTS   PORTS   IMAGE
#"
    local container_nr=
    for container_nr in $(seq 1 "${POD_CONTAINER_COUNT}"); do
        local name=
        _GET_CONTAINER_VAR "${container_nr}" "NAME" "name"
        printf "Container: %s\\n" "${name}"

        printf "Mounts: "
        _OUTPUT_CONTAINER_INFO "${container_nr}" "mounts"

        printf "Ports: "
        _OUTPUT_CONTAINER_INFO "${container_nr}" "ports"
    done
}

# Show the current status of the pod and it's containers and volumes
_SHOW_STATUS()
{
    SPACE_DEP="_GET_CONTAINER_VAR _CONTAINER_STATUS"
    # TODO: fields missing and needs to be structured.
    #printf "%s\\n" "Podname
#CONTAINER   STATE   RESTART   MOUNTS   PORTS   IMAGE
#"

    local container_nr=
    for container_nr in $(seq 1 "${POD_CONTAINER_COUNT}"); do
        local name=
        _GET_CONTAINER_VAR "${container_nr}" "NAME" "name"
        printf "Container: %s\\n" "${name}"

        printf "Status: "
        _CONTAINER_STATUS "${name}"
    done
}

# Idempotent command.
# Create the pod and the volumes (not the containers), but do not start the pod.
# If the pod exists and is in the created or running state then this function does nothing.
# If the pod exists but is not in created nor running state then the whole pod is removed with all containers (volumes are not removed) and the pod is recreated.
_CREATE()
{
    SPACE_DEP="_CHECK_HOST_MOUNTS _CHECK_HOST_PORTS _CREATE_POD _CREATE_VOLUMES _CHECK_RAMDISKS _DESTROY_POD _POD_STATUS PRINT _POD_EXISTS"

    if _POD_EXISTS; then
        PRINT "Pod ${POD} already exists" "debug" 0
        local podstatus="$(_POD_STATUS)"
        if [ "${podstatus}" = "Created" ] || [ "${podstatus}" = "Running" ]; then
            # Do nothing
            return 0
        else
            # Destroy pod and all containers
            PRINT "Pod ${POD} is in a bad state, destroy it and all containers (leave volumes)" "info" 0
            if ! _DESTROY_POD; then
                return 1
            fi
            # Fall through
        fi
    fi

    if ! _CHECK_HOST_PORTS; then
        return 1
    fi

    if ! _CHECK_HOST_MOUNTS; then
        return 1
    fi

    PRINT "Check ramdisks" "info" 0
    if ! _CHECK_RAMDISKS; then
        return 1
    fi

    if ! _CREATE_VOLUMES; then
        PRINT "Could not create volumes" "error" 0
        return 1
    fi

    PRINT "Create pod" "info" 0
    _CREATE_POD
}


# Idempotent commands which makes sure that the pod and all containers are running as expected.
# It will rerun containers which have exited but should be running according to the policy.
# First call create() to make sure the pod is created or recreated if needed,
# start the pod if in created state,
# call _START_CONTAINERS to make sure each indivudal container is running as expected.
_RUN()
{
    SPACE_DEP="_START_CONTAINERS _DESTROY_POD PRINT _START_POD _POD_STATUS _CREATE _POD_EXISTS"

    local podexists=
    _POD_EXISTS
    podexists="$?"

    if ! _CREATE; then
        return 1
    fi

    local podstatus="$(_POD_STATUS)"
    if [ "${podstatus}" != "Running" ]; then
        if ! _START_POD; then
            _DESTROY_POD
            return 1
        fi
    else
        PRINT "Pod ${POD} is already running" "debug" 0
    fi

    if ! _START_CONTAINERS && [ "${podexists}" -ne 0 ]; then
        # If a container fails to start in the pod creation phase,
        # then we don't allow the pod to run.
        # In the creation phase we expect the pod and all containers to successfully run.
        _DESTROY_POD
        return 1
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

# Stop the pod and all containers.
_STOP()
{
    SPACE_DEP="_STOP_POD"

    _STOP_POD
}

# Kill the pod and all containers.
_KILL()
{
    SPACE_DEP="_KILL_POD"

    _KILL_POD
}

# Remove the pod and all it's containers if the pod is not in it's running state (if so stop it first).
_RM()
{
    SPACE_DEP="_DESTROY_POD _POD_EXISTS PRINT _STOP_POD"

    if _POD_EXISTS; then
        _STOP_POD
        _DESTROY_POD
    else
        PRINT "Pod does not exist" "info" 0
    fi
}

# Output logs for one or many containers
_LOGS()
{
    SPACE_SIGNATURE="timestamp limit streams details [container]"
    SPACE_DEP="_GET_CONTAINER_VAR PRINT STRING_IS_NUMBER STRING_SUBST"

    local timestamp="${1:-0}"
    shift

    local limit="${1:-0}"
    shift

    local streams="${1:-stdout,stderr}"
    shift

    local details="${1:-ts,name}"
    shift

    STRING_SUBST "streams" ',' ' ' 1
    STRING_SUBST "details" ',' ' ' 1


    if ! STRING_IS_NUMBER "${timestamp}"; then
        PRINT "timeout must be a positive number (seconds since epoch)" "error" 0
        return 1
    fi

    if ! STRING_IS_NUMBER "${limit}" 1; then
        PRINT "limit must be a number" "error" 0
        return 1
    fi

    local container_nr=
    local containers=""
    if [ "$#" -eq 0 ]; then
        # Get all containers
        for container_nr in $(seq 1 "${POD_CONTAINER_COUNT}"); do
            _GET_CONTAINER_VAR "${container_nr}" "NAME" "container"
            containers="${containers} ${container}"
        done
    else
        local container=
        for container in "$@"; do
            container="${container}-${POD}"
            for container_nr in $(seq 1 "${POD_CONTAINER_COUNT}"); do
                local container2=
                _GET_CONTAINER_VAR "${container_nr}" "NAME" "container2"
                if [ "${container2}" = "${container}" ]; then
                    containers="${containers} ${container}"
                    continue 2
                fi
            done
            PRINT "Container ${container} does not exist in this pod" "error" 0
            #return 1
            containers="${containers} ${container}"
        done
    fi

    # For each container, check if there are logfiles for the streams chosen,
    # check rotated out logfiles and choose the ones older than ts given.
    local files=""
    for container in ${containers}; do
        local stream=
        for stream in ${streams}; do
            # Check current file
            local file="${container}-${stream}.log"
            if [ -f "${file}" ]; then
                files="${files} ${file}"
            fi
            # Check older files
            for file in $(find . -maxdepth 1 -name "${container}-${stream}.log.*" |cut -b3-); do
                local ts="${file##*.}"
                if [ "${timestamp}" -le "${ts}" ]; then
                    files="${files} ${file}"
                fi
            done
        done
    done

    # For all applicable files, filter each line on timestamp and prepend with container
    # name and stream name.
    # Cat all files together, with prefixes, filter out on time, Sort on time
    local file=
    for file in ${files}; do
        local container="${file%%-${POD}*}"
        local stream="${file%%.log*}"
        stream="${stream##*-}"
        awk '{if ($1 >= '"${timestamp}"') {print "'${container}' '${stream}' " $0}}' ${file}
    done |sort -k3,3n -k4,4n |
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
            local columns=""
            local detail=
            for detail in ${details}; do
                local arg=""
                if [ "${detail}" = "ts" ]; then
                    arg='\3'
                elif [ "${detail}" = "name" ]; then
                    arg='\1'
                elif [ "${detail}" = "stream" ]; then
                    arg='\2'
                fi
                columns="${columns}${columns:+ }${arg}"
            done
            columns="${columns}${columns:+ }\\5"
            sed "s/\\([^ ]\+\\) \\([^ ]\\+\\) \\([^ ]\\+\\) \\([^ ]\\+\\) \\(.*\\)/${columns}/"
        }
}

# Signal one or many containers.
_SIGNAL()
{
    SPACE_SIGNATURE="[containers]"
    SPACE_DEP="_CONTAINER_EXISTS _GET_CONTAINER_VAR _SIGNAL_CONTAINER _CONTAINER_STATUS PRINT"

    local container=
    local containerNames=

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
        if [ "$(_CONTAINER_STATUS "${container}")" = "running" ]; then
            # If the container is running then signal it, if it has a signal system setup
            # Find the container nr and then signal
            local container2=
            for container_nr in $(seq 1 "${POD_CONTAINER_COUNT}"); do
                _GET_CONTAINER_VAR "${container_nr}" "NAME" "container2"
                if [ "${container}" = "${container2}" ]; then
                    _SIGNAL_CONTAINER "${container}" "${container_nr}"
                    break
                fi
            done
        fi
    done
}

# If pod is running it and all containers will be stopped.
# Make sure the pod and containers are removed, volumes are not removed.
# Create pod and all containers and start it all up.
_RERUN()
{
    SPACE_DEP="_STOP_POD _DESTROY_POD _RUN _POD_EXISTS"

    if _POD_EXISTS; then
        _STOP_POD
        _DESTROY_POD
    fi

    _RUN
}

# Whenever a config on disk has changed
# we call this function to notify containers who mount the particular config.
_RELOAD_CONFIG()
{
    SPACE_SIGNATURE="configs"
    SPACE_DEP="_POD_EXISTS _POD_STATUS PRINT _GET_CONTAINER_VAR _CONTAINER_EXISTS _CONTAINER_EXISTS _CYCLE_CONTAINER _CONTAINER_STATUS STRING_ITEM_INDEXOF"

    local configs="$*"
    shift

    if ! _POD_EXISTS; then
        PRINT "Pod ${POD} does not exist" "error" 0
        return 1
    fi

    local podstatus="$(_POD_STATUS)"
    if [ "${podstatus}" != "Running" ]; then
        PRINT "Pod ${POD} is not running" "error" 0
        return 1
    fi

    PRINT "Cycle/signal containers who mount the configs ${configs}" "info" 0

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
                if _CONTAINER_EXISTS "${container}" && [ "$(_CONTAINER_STATUS "${container}")" = "running" ]; then
                    # If the container is running then signal it, if it has a signal system setup
                    _SIGNAL_CONTAINER "${container}" "${container_nr}"
                else
                    # If container is not running, cycle it as long as its restart policy allows
                    local restartpolicy=
                    _GET_CONTAINER_VAR "${container_nr}" "RESTARTPOLICY" "restartpolicy"
                    # Restart on always, on-config and on-interval:x
                    # Do not restart on never or on-failure
                    if [ "${restartpolicy}" = "always" ] || [ "${restartpolicy}" = "on-config" ] || [ "${restartpolicy%:*}" = "on-interval" ]; then
                        _CYCLE_CONTAINER "${container}" "${container_nr}"
                    else
                        PRINT "Container ${container} is not restarted due to its restart policy" "info" 0
                    fi
                fi
            fi
        done
    done
}

# Remove pod, containers, configs, ramdisks (if created by us) and all volumes.
# Make sure pod and containers have already been removed then remove volumes created.
# Do not remove configs, because those are not created by this runtime and we cannot be sure it is ok to delete them.
_PURGE()
{
    SPACE_DEP="_DESTROY_POD _DESTROY_VOLUMES _POD_EXISTS PRINT"

    if _POD_EXISTS; then
        PRINT "Pod ${POD} exists. Remove it before purging" "error" 0
        return 1
    fi

    _DESTROY_VOLUMES
}

# Enter shell in a container
_SHELL()
{
    SPACE_SIGNATURE="container useBash"
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

    if [ "${useBash}" = "true" ]; then
        podman exec -ti ${containerName} bash
    else
        podman exec -ti ${containerName} sh
    fi
}

# Exec a command inside a container, repeatedly if not getting exit code 0.
# Sleep 1 second between each exec and timeout eventually (killing the command if necessary.
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

# Check each container it is healthy, if not stop the container.
# The container will restart according to it's restart-policy.
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

# Output the ramdisks configuration for this pod's containers.
# This is used by the daemon to create ramdisks.
_RAMDISK_CONFIG()
{
    #SPACE_ENV="POD_RAMDISKS"
    printf "%s\\n" "${POD_RAMDISKS}"
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

    return 0
    # Disabled for now since CentOS currently is on podman 1.6.4

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

_GETOPTS()
{
    SPACE_SIGNATURE="simpleSwitches richSwitches minPositional maxPositional [args]"
    SPACE_DEP="PRINT STRING_SUBSTR STRING_INDEXOF STRING_ESCAPE"

    local simpleSwitches="${1}"
    shift

    local richSwitches="${1}"
    shift

    local minPositional="${1:-0}"
    shift

    local maxPositional="${1:-0}"
    shift

    _out_rest=""

    local options=""
    local option=
    for option in ${richSwitches}; do
        options="${options}${option}:"
    done

    local posCount="0"
    while [ "$#" -gt 0 ]; do
        local flag="${1#-}"
        if [ "${flag}" = "${1}" ]; then
            # Non switch
            posCount="$((posCount+1))"
            if [ "${posCount}" -gt "${maxPositional}" ]; then
                PRINT "Too many positional argumets, max ${maxPositional}" "error" 0
                return 1
            fi
            _out_rest="${_out_rest}${_out_rest:+ }${1}"
            shift
            continue
        fi
        local flag2=
        STRING_SUBSTR "${flag}" 0 1 "flag2"
        if STRING_ITEM_INDEXOF "${simpleSwitches}" "${flag2}"; then
            if [ "${#flag}" -gt 1 ]; then
                PRINT "Invalid option: -${flag}" "error" 0
                return 1
            fi
            eval "_out_${flag}=\"true\""
            shift
            continue
        fi

        local OPTIND=1
        getopts ":${options}" "flag"
        case "${flag}" in
            \?)
                PRINT "Unknown option ${1-}" "error" 0
                return 1
                ;;
            :)
                PRINT "Option -${OPTARG-} requires an argument" "error" 0
                return 1
                ;;
            *)
                STRING_ESCAPE "OPTARG"
                eval "_out_${flag}=\"${OPTARG}\""
                ;;
        esac
        shift $((OPTIND-1))
    done

    if [ "${posCount}" -lt "${minPositional}" ]; then
        PRINT "Too few positional argumets, min ${minPositional}" "error" 0
        return 1
    fi
}

POD_ENTRY()
{
    SPACE_SIGNATURE="action [args]"
    SPACE_DEP="_VERSION _SHOW_USAGE _CREATE _RUN _PURGE _RELOAD_CONFIG _RM _RERUN _SIGNAL _LOGS _STOP _START _KILL _CREATE_VOLUMES _DOWNLOAD _SHOW_INFO _SHOW_STATUS _READINESS_PROBE _LIVENESS_PROBE _RAMDISK_CONFIG _CHECK_PODMAN _GET_CONTAINER_VAR _GETOPTS _SHELL"

    # This is for display purposes only and shows the runtime type and the version of the runtime impl.
    local RUNTIME_VERSION="podman 0.1"

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

    local action="${1:-help}"
    shift $(($# > 0 ? 1 : 0))

    if [ "${action}" = "help" ]; then
        _SHOW_USAGE
    elif [ "${action}" = "version" ]; then
        _VERSION
    elif [ "${action}" = "info" ]; then
        _SHOW_INFO
    elif [ "${action}" = "ramdisk-config" ]; then
        _RAMDISK_CONFIG
    else
        # Commands below all need podman, so we check the version first.
        if ! _CHECK_PODMAN; then
            return 1
        fi

        if [ "${action}" = "status" ]; then
            _SHOW_STATUS
        elif [ "${action}" = "download" ]; then
            local _out_f="false"

            if ! _GETOPTS "f" "" 0 0 "$@"; then
                printf "Usage: pod download [-f]\\n" >&2
                return 1
            fi
            _DOWNLOAD "${_out_f}"
        elif [ "${action}" = "create" ]; then
            _CREATE
        elif [ "${action}" = "start" ]; then
            _START
        elif [ "${action}" = "stop" ]; then
            _STOP
        elif [ "${action}" = "kill" ]; then
            _KILL
        elif [ "${action}" = "run" ]; then
            _RUN
        elif [ "${action}" = "rerun" ]; then
            _RERUN
        elif [ "${action}" = "signal" ]; then
            _SIGNAL "$@"
        elif [ "${action}" = "logs" ]; then
            local _out_rest=
            local _out_t=
            local _out_s=
            local _out_l=
            local _out_d=

            if ! _GETOPTS "" "t s l d" 0 999 "$@"; then
                printf "Usage: pod logs [container] [-t timestamp] [-l limit] [-s streams] [-d details]\\n" >&2
                return 1
            fi
            set -- ${_out_rest}
            _LOGS "${_out_t}" "${_out_l}" "${_out_s}" "${_out_d}" "$@"
        elif [ "${action}" = "create-volumes" ]; then
            _CREATE_VOLUMES
        elif [ "${action}" = "reload-configs" ]; then
            if ! _GETOPTS "" "" 1 999 "$@"; then
                printf "Usage: pod reload-configs container1 [container2...]\\n" >&2
                return 1
            fi
            _RELOAD_CONFIG "$@"
        elif [ "${action}" = "rm" ]; then
            _RM
        elif [ "${action}" = "purge" ]; then
            _PURGE
        elif [ "${action}" = "readiness" ]; then
            _READINESS_PROBE
        elif [ "${action}" = "liveness" ]; then
            _LIVENESS_PROBE
        elif [ "${action}" = "shell" ]; then
            local _out_B="false"

            if ! _GETOPTS "B" "" 0 1 "$@"; then
                printf "Usage: pod shell [container] [-B]\\n" >&2
                return 1
            fi
            _SHELL "${_out_rest}" "${_out_B}"
        else
            PRINT "Unknown command" "error" 0
            return 1
        fi
    fi

    local status=$?
    cd "${start_dir}"
    return "${status}"
}
