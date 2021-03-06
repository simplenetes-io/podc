PODC_CMDLINE()
{
    SPACE_SIGNATURE="[action args]"
    SPACE_DEP="USAGE _GETOPTS COMPILE_ENTRY SHOW_VERSION"

    local _out_arguments=""
    local _out_h=
    local _out_V=
    local _out_p="true"

    local _out_e=
    local _out_f=""
    local _out_o=""
    local _out_d=""

    if ! _GETOPTS "_out_e=-e,--source-env/ _out_h=-h,--help/ _out_V=-V,--version/ _out_f=-f,--file/* _out_o=-o,--outfile/* _out_d=-d,--dir/* _out_p=-p,--preprocess/true|false" 0 1 "$@"; then
        printf "Usage: pod [podname] [-f|--file=] [-o|--outfile=] [-d|--dir=] [-p|--preprocess=true|false]\\n" >&2
        return 1
    fi

    if [ -n "${_out_h}" ]; then
        USAGE
        return
    fi

    if [ -n "${_out_V}" ]; then
        SHOW_VERSION
        return
    fi

    COMPILE_ENTRY "${_out_arguments}" "${_out_f}" "${_out_o}" "${_out_d}" "${_out_p}" "${_out_e:+true}"
}

SHOW_VERSION()
{
    SPACE_ENV="API_VERSION VERSION"

    printf "podc %s\\napi %s\\n" "${VERSION}" "${API_VERSION}"
}

# options are on the format:
# "_out_all=-a,--all/ _out_state=-s,--state/arg1|arg2|arg3"
# For non argument options the variable will be increased by 1 for each occurrence.
# The variable _out_arguments is reserved for positional arguments.
# Expects _out_arguments and all _out_* to be defined.
_GETOPTS()
{
    SPACE_SIGNATURE="options minPositional maxPositional [args]"
    SPACE_DEP="_GETOPTS_SWITCH PRINT STRING_SUBSTR STRING_INDEXOF"

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


USAGE()
{
    printf "%s\\n" "Usage:

    podc -h | --help
        Output this help

    podc -V | --version
        Output version

    podc [podname] [-f infile] [-o outfile] [-d srcdir] [-p]

        podname
            The name of the pod, default is to take the directory name,
            but which might not be a valid name. Only a-z0-9 and underscore allowed.
            Must start with a letter.

        -f | --file=infile
            Optional path to the pod.yaml file.
            Default is to look for pod.yaml in the current directory.

        -o | --outfile=path
            Optional path where to write the executable pod file.
            Default is \"pod\" in the same directory as the pod yaml file.

        -p | --preprocess=true | false (default true)
            Optional flag do perform preprocessing on the pod.yaml file or not.

        -e | --source-env
            Set to allow sourcing variables from the environment if they are not provided in the .env file.

        -d srcdir
            Optional directory path to use as source directory if \"infile\"
            is inside another directory.
            This feature is used by other tools who do preprocessing
            on the original pod.yaml file and place a temporary file elsewhere.
            It can also be used to override the home directory of host volumes with relative mount points,
            then the srcdir is the basedir, otherwise it is the dir of infile.

"
}

COMPILE_ENTRY()
{
    SPACE_SIGNATURE="[podName inFile outFile srcDir doPreprocessing allowSourceEnv]"
    SPACE_DEP="_COMPILE_POD PRINT TEXT_EXTRACT_VARIABLES TEXT_VARIABLE_SUBST TEXT_FILTER TEXT_GET_ENV FILE_REALPATH"

    local podName="${1:-}"
    shift $(($# > 0 ? 1 : 0))

    local inFile="${1:-}"
    shift $(($# > 0 ? 1 : 0))

    local outFile="${1:-}"
    shift $(($# > 0 ? 1 : 0))

    local srcDir="${1:-}"
    shift $(($# > 0 ? 1 : 0))

    local doPreprocessing="${1:-true}"
    shift $(($# > 0 ? 1 : 0))

    local allowSourceEnv="${1:-}"
    shift $(($# > 0 ? 1 : 0))

    if [ -z "${podName}" ]; then
        podName="${PWD##*/}"
        #podName="$(printf "%s\\n" "${podName}" |tr '[:upper:]' '[:lower:]')"
        PRINT "No pod name given as first argument, assuming: ${podName}" "info" 0
    fi

    if [ -z "${inFile}" ]; then
        inFile="pod.yaml"
        PRINT "No in file given as second argument, assuming: ${inFile}" "info" 0
    fi

    inFile="$(FILE_REALPATH "${inFile}")"

    if [ ! -f "${inFile}" ]; then
        PRINT "Yaml file does not exist." "error" 0
        printf "Usage: pod [podname] [-f infile] [-o outfile] [-d srcdir] [-p true|false]\\n" >&2
        return 1
    fi

    if [ -z "${outFile}" ]; then
        outFile="${inFile%.yaml}"
    fi
    if [ "${inFile}" = "${outFile}" ]; then
        outFile="${inFile}.out"
    fi
    local buildDir="${inFile%/*}"

    local filename="${inFile##*/}"
    local yamlfile=
    if [ "${doPreprocessing}" = "true" ]; then
        yamlfile="${buildDir}/.${filename}"
        local text="$(cat "${inFile}")"
        local variablestosubst="$(TEXT_EXTRACT_VARIABLES "${text}")"
        # Load .env env file, if any
        local envfile="${inFile%.yaml}.env"
        # Preinject the podVersion as a value loaded from .env file
        local podVersion="$(grep -m1 "^podVersion:" "${inFile}" | awk -F: '{print $2}' | tr -d " \"'")"
        local values="podVersion=${podVersion}"
        local newline="
"
        if [ -f "${envfile}" ]; then
            PRINT "Loading variables from .env file." "info" 0
            values="${values}${newline}$(cat "${envfile}")"
        else
            PRINT "No .env file present." "info" 0
        fi

        # Fill in missing variables from environment
        local varname=
        local varnames=""
        for varname in ${variablestosubst}; do
            if ! printf "%s\\n" "${values}" | grep -q "^${varname}="; then
                varnames="${varnames}${varnames:+ }${varname}"
            fi
        done
        if [ -n "${varnames}" ]; then
            if [ "${allowSourceEnv}" = "true" ]; then
                PRINT "Sourcing variables from environment since they are not defined in .env file, for variables: ${varnames}" "info" 0
                if ! values="${values}${values:+${newline}}$(TEXT_GET_ENV "${varnames}" "1")"; then
                    PRINT "There are missing variables in .env file or environment." "warning" 0
                fi
            else
                PRINT "There are missing variables in .env file." "warning" 0
            fi
        fi

        text="$(TEXT_VARIABLE_SUBST "${text}" "${variablestosubst}" "${values}")"

        # Parse contents
        printf "%s\\n" "${text}" |TEXT_FILTER >"${yamlfile}"
    else
        yamlfile="${inFile}"
    fi

    if ! _COMPILE_POD "${podName}" "${yamlfile}" "${outFile}" "${srcDir}"; then
        return 1
    fi
}

_COMPILE_POD()
{
    SPACE_SIGNATURE="podName inFile outFile [srcDir]"
    SPACE_DEP="PRINT YAML_PARSE _CONTAINER_VARS _CONTAINER_SET_VAR _QUOTE_ARG STRING_ITEM_INDEXOF STRING_ITEM_GET _GET_CONTAINER_NR _COMPILE_INGRESS _COMPILE_RUN _COMPILE_LABELS _COMPILE_ENTRYPOINT _COMPILE_CPUMEM STRING_SUBST _GET_CONTAINER_VAR _COMPILE_PODMAN _COMPILE_EXECUTABLE FILE_REALPATH _COMPILE_ENV _COMPILE_MOUNTS _COMPILE_STARTUP_PROBE_SIGNAL _COMPILE_STARTUP_PROBE _COMPILE_STARTUP_PROBE_TIMEOUT _COMPILE_READINESS_PROBE _COMPILE_READINESS_PROBE_TIMEOUT  _COMPILE_LIVENESS_PROBE _COMPILE_LIVENESS_PROBE_TIMEOUT _COMPILE_SIGNALEXEC _COMPILE_IMAGE _COMPILE_RESTART"
    SPACE_ENV="API_VERSION SUPPORTED_API_VERSIONS"

    local podName="${1}"
    shift

    if [[ ! $podName =~ ^[a-z]([_a-z0-9]*[a-z0-9])?$ ]]; then
        PRINT "Podname '${podName}' is malformed. only lowercase letters [a-z], numbers [0-9] and underscore is allowed. First character must be lowercase letter" "error" 0
        return 1
    fi

    local inFile="${1}"
    shift

    local outFile="${1}"
    shift

    if [ -d "${outFile}" ]; then
        PRINT "${outFile} is a directory" "error" 0
        return 1
    fi

    local srcDir="${1}"
    shift $(($# > 0 ? 1 : 0))

    if [ ! -f "${inFile}" ]; then
        PRINT "Yaml file does not exist." "error" 0
        return 1
    fi

    if [ -z "${srcDir}" ]; then
        srcDir="${inFile%/*}"
    fi

    # Output the fill YAML file if in debug mode
    local dbgoutput="$(cat "${inFile}")"
    PRINT "Pod YAML: "$'\n'"${dbgoutput}" "debug" 0

    # Load and parse YAML
    # Bashism
    local evals=()
    YAML_PARSE "${inFile}" "evals"
    eval "${evals[@]}"

    # get api version
    local api=
    _copy "api" "/api"

    if ! STRING_ITEM_INDEXOF "${SUPPORTED_API_VERSIONS}" "${api}"; then
        PRINT "API version \"${api}\" not supported. \"api:\" must be set to \"${API_VERSION}\"" "error" 0
    fi

    # get runtime
    local runtime=
    _copy "runtime" "/runtime"
    if [ -z "${runtime}" ]; then
        runtime="podman"
    fi

    # get podVersion
    local podVersion=
    _copy "podVersion" "/podVersion"
    if [[ ! $podVersion =~ ^([0-9]+\.[0-9]+\.[0-9]+(-[-a-z0-9\.]*)?)$ ]]; then
        PRINT "podVersion is missing/invalid. Must be on semver format (major.minor.patch[-tag])." "error" 0
        return 1
    fi

    local runtimeDir=""
    local runtimeDir="${0%/*}"
    if [ "${runtimeDir}" = "${0}" ]; then
        # This is weird, not slash in path, but we will handle it.
        if [ -f "./${0}" ]; then
            # This happens when the script is invoked as `bash pod.sh`.
            runtimeDir="${PWD}"
        else
            PRINT "Could not determine the base dir podc." "error" 0
            return 1
        fi
    fi
    runtimeDir="$(FILE_REALPATH "${runtimeDir}")"

    PRINT "Compiling \"${podName}-${podVersion}\" for api version: \"${API_VERSION}\" and runtime \"${runtime}\", YAML file: ${inFile}." "info" 0

    if [ "${runtime}" = "podman" ]; then
        # Get path to runtime
        local runtimePath=""
        while true; do
            for runtimePath in "${runtimeDir}/podc-podman-runtime" "${runtimeDir}/lib/podc-podman-runtime" "${runtimeDir}/release/podc-podman-runtime" "/opt/podc/podc-podman-runtime"; do
                if [ -f "${runtimePath}" ]; then
                    break 2
                fi
            done
            PRINT "Could not locate podc-podman-runtime" "error" 0
            return 1
        done
        local buildDir="${outFile%/*}"
        local POD_PROXYCONF=""
        local POD_INGRESSCONF=""
        local _out_pod=""
        if ! _COMPILE_PODMAN "${podName}" "${podVersion}" "${runtimePath}" "${buildDir}"; then
            PRINT "Could not compile pod for podman runtime." "error" 0
            return 1
        fi
        PRINT "Writing pod executable to ${outFile}" "ok" 0
        printf "%s\\n" "${_out_pod}" >"${outFile}"
        chmod +x "${outFile}"
        local portmappingsFile="${outFile}.portmappings.conf"

        local ingressFile="${outFile}.ingress.conf"

        if [ -n "${POD_PROXYCONF}" ]; then
            printf "%s\\n" "${POD_PROXYCONF}" >"${portmappingsFile}"
        else
            rm -f "${portmappingsFile}"
        fi
        if [ -n "${POD_INGRESSCONF}" ]; then
            printf "%s\\n" "${POD_INGRESSCONF}" >"${ingressFile}"
        else
            rm -f "${ingressFile}"
        fi
    elif [ "${runtime}" = "executable" ]; then
        if ! _COMPILE_EXECUTABLE "${podName}" "${podVersion}" "${srcDir}" "${outFile}"; then
            PRINT "Could not compile pod for executable runtime." "error" 0
            return 1
        fi
        PRINT "Writing pod executable to ${outFile}" "ok" 0
    else
        PRINT "Unknown runtime \"${runtime}\" . Only \"podman\" or \"executable\" runtimes are supported." "error" 0
        return 1
    fi
}

# Inherits YAML varibles
# Compiles for a single executable pod.
_COMPILE_EXECUTABLE()
{
    SPACE_SIGNATURE="podName podVersion srcDir outFile"

    local podName="${1}"
    shift

    local podVersion="${1}"
    shift

    local srcDir="${1}"
    shift

    local outFile="${1}"
    shift

    local buildDir="${outFile%/*}"

    # Find out what file to copy as the `pod` executable.
    local executable=
    _copy "executable" "/executable/file"
    executable="${srcDir}/${executable}"
    executable="$(FILE_REALPATH "${executable}")"
    if [ ! -f "${executable}" ]; then
        PRINT "The executable file '${executable}' does not exist." "error" 0
        return 1
    fi

    # Copy the executable
    cp "${executable}" "${outFile}"
    chmod +x "${outFile}"
}

# Inherits YAML varibles
# Take the YAML, analyze it and create space shell script which we then use space to export as a standalone sh file.
# Expects:
#   POD_PROXYCONF
#   POD_INGRESSCONF
#
_COMPILE_PODMAN()
{
    local podName="${1}"
    shift

    local podVersion="${1}"
    shift

    local runtimePath="${1}"
    shift

    local buildDir="${1}"
    shift

    ## Output header of runtime template file
    _out_pod="$(awk 'BEGIN {show=1} /^[^#]/ { show=0 } {if(show==1) {print}}' "${runtimePath}")"

    local POD="${podName}-${podVersion}"
    local POD_VERSION="${podVersion}"  # Part of the pod name.
    local POD_LABELS=""
    local POD_CREATE="--name \${POD}"
    local POD_VOLUMES=""       # Used by runtime to create container volumes.
    local POD_RAMDISKS=""      # Read by the Daemon to create ramdisks.
    local POD_HOSTPORTS=""     # Used by runtime to check that hosts ports are free before starting the pod.
    local POD_CONTAINER_COUNT=0

    local volumes_host=""
    local volumes_config=""
    local volumes_config_encrypted=""
    local volumes_host_bind=""

    # Go over all volumes
    #

    local valid_types="ramdisk config volume host"
    local all_volumes=""
    local volumes=()
    _list "volumes" "/volumes/"
    local index=
    local volume=
    local space=""
    local encrypted=
    local bind=
    for index in "${volumes[@]}"; do
        _copy "volume" "/volumes/${index}/name"
        STRING_SUBST "volume" "'" "" 1
        STRING_SUBST "volume" '"' "" 1
        _copy "type" "/volumes/${index}/type"
        STRING_SUBST "type" "'" "" 1
        STRING_SUBST "type" '"' "" 1
        # Check so type is recognized:
        if ! STRING_ITEM_INDEXOF "${valid_types}" "${type}"; then
            PRINT "Wrong type for volume ${volume}. Must be ramdisk, config, volume or host." "error" 0
            return 1
        fi

        # If config volume then allow to start with underscore.
        if [ "${type}" = "config" ]; then
            if [[ ! $volume =~ ^[_a-z]([_a-z0-9]*[a-z0-9])?$ ]]; then
                PRINT "Volume name '${volume}' is malformed. only lowercase letters [a-z], numbers [0-9] and underscore is allowed. First character must be lowercase letter or underscore for config volumes." "error" 0
                return 1
            fi
        else
            if [[ ! $volume =~ ^[a-z]([_a-z0-9]*[a-z0-9])?$ ]]; then
                PRINT "Volume name '${volume}' is malformed. only lowercase letters [a-z], numbers [0-9] and underscore is allowed. First character must be lowercase letter" "error" 0
                return 1
            fi
        fi


        # Check for duplicates
        if STRING_ITEM_INDEXOF "${all_volumes}" "${volume}"; then
            # Duplicate
            PRINT "Volume name ${volume} is already defined." "error" 0
            return 1
        fi

        _copy "encrypted" "/volumes/${index}/encrypted"
        STRING_SUBST "encrypted" "'" "" 1
        STRING_SUBST "encrypted" '"' "" 1
        _copy "bind" "/volumes/${index}/bind"
        STRING_SUBST "bind" "'" "" 1
        STRING_SUBST "bind" '"' "" 1

        if [ "${type}" = "ramdisk" ]; then
            local size=
            _copy "size" "/volumes/${index}/size"
            STRING_SUBST "size" "'" "" 1
            STRING_SUBST "size" '"' "" 1
            size="${size:-1M}"
            if [[ ! $size =~ ^[0-9]+M$ ]]; then
                PRINT "Ramdisk size must be in megabytes and followed by a capital M, such as: 2M" "error" 0
                return 1
            fi
            POD_RAMDISKS="${POD_RAMDISKS}${POD_RAMDISKS:+ }${volume}:${size}"
        elif [ "${type}" = "volume" ]; then
            # Add suffix
            local shared=
            _copy "shared" "/volumes/${index}/shared"
            STRING_SUBST "shared" "'" "" 1
            STRING_SUBST "shared" '"' "" 1
            local volumesuffix=""
            if [ -z "${shared}" ] || [ "${shared}" = "no" ]; then
                volumesuffix="-${podName}-${podVersion}"
            elif [ "${shared}" = "pod" ]; then
                volumesuffix="-${podName}"
            elif [ "${shared}" = "host" ]; then
                # Do nothing
                :
            else
                PRINT "Host volume must have shared set to \"no\" (default), \"pod\" or \"host\"." "error" 0
                return 1
            fi
            POD_VOLUMES="${POD_VOLUMES}${POD_VOLUMES:+ }${volume}${volumesuffix}"
        elif [ "${type}" = "config" ]; then
            if [ ! -d "${buildDir}/config/${volume}" ]; then
                PRINT "Config '${volume}' does not exist as: ${buildDir}/config/${volume}." "error" 0
                return 1
            fi
            volumes_config="${volumes_config} ${volume}"
            volumes_config_encrypted="${volumes_config_encrypted} ${encrypted:-false}"
        elif [ "${type}" = "host" ]; then
            volumes_host="${volumes_host} ${volume}"
            bind="$(FILE_REALPATH "${bind}" "${srcDir}")"
            volumes_host_bind="${volumes_host_bind} ${bind}"
        fi

        # Check if encrypted config drive, if so then create matching ramdisk for it
        if [ -n "${encrypted}" ]; then
            if [ "${encrypted}" = "true" ]; then
                if [ "${type}" = "config" ]; then
                    # Create ramdisk, check so it doesn't exist already
                    local newramdisk="${volume}-unencrypted"
                    if STRING_ITEM_INDEXOF "${all_volumes}" "${newramdisk}"; then
                        # Duplicate
                        PRINT "Volume name ${newramdisk} is already defined." "error" 0
                        return 1
                    fi
                    all_volumes="${all_volumes}${space}${newramdisk}"

                    # Create decrypter container
                    local decrypterimage="simplenetes/secret-decrypter:1.0"
                    POD_CONTAINER_COUNT=$((POD_CONTAINER_COUNT+1))
                    eval "$(_CONTAINER_VARS "${POD_CONTAINER_COUNT}")"
                    local decryptername="${volume}-decrypter"
                    _CONTAINER_SET_VAR "${POD_CONTAINER_COUNT}" "NAME" "decryptername"
                    _CONTAINER_SET_VAR "${POD_CONTAINER_COUNT}" "IMAGE" "decrypterimage"
                    local v="on-config"
                    _CONTAINER_SET_VAR "${POD_CONTAINER_COUNT}" "RESTARTPOLICY" "v"
                    v="exit"
                    _CONTAINER_SET_VAR "${POD_CONTAINER_COUNT}" "STARTUPPROBE" "v"
                    v="120"
                    _CONTAINER_SET_VAR "${POD_CONTAINER_COUNT}" "STARTUPTIMEOUT" "v"
                    v="${volume}"
                    _CONTAINER_SET_VAR "${POD_CONTAINER_COUNT}" "CONFIGS" "v"
                    v="${volume}-unencrypted"
                    POD_RAMDISKS="${POD_RAMDISKS}${POD_RAMDISKS:+ }${v}:1M"
                    # Only this container should be able to access this config, hence the capital Z in :options.
                    local mounts="-v ./config/${volume}:/mnt/config:Z,ro -v ./ramdisk/${v}:/mnt/ramdisk:z:rw"
                    _CONTAINER_SET_VAR "${POD_CONTAINER_COUNT}" "MOUNTS" "mounts"
                    _COMPILE_RUN
                else
                    PRINT "Only config volumes can be encrypted" "error" 0
                    return 1
                fi
            elif [ "${encrypted}" != "false" ]; then
                PRINT "Unknown value for 'encrypted' for volume ${volume}, ignoring" "warning" 0
            fi
        fi

        all_volumes="${all_volumes}${space}${volume}"
        space=" "
    done

    # Go over all containers
    #

    local containers=()
    _list "containers" "/containers/"

    # Check all container names and check for duplicates.
    local container_names=""
    local index=
    for index in "${containers[@]}"; do
        local container_name=
        _copy "container_name" "/containers/${index}/name"
        STRING_SUBST "container_name" "'" "" 1
        STRING_SUBST "container_name" '"' "" 1
        if [[ ! $container_name  =~ ^[a-z]([_a-z0-9]*[a-z0-9])?$ ]]; then
            PRINT "Container name '${container_name}' is malformed. only lowercase letters [a-z], numbers [0-9] and underscore is allowed. First character must be lowercase letter" "error" 0
            return 1
        fi
        if STRING_ITEM_INDEXOF "${container_names}" "${container_name}"; then
            PRINT "Container name ${container_name} already defined, change the name." "error" 0
            return 1
        fi
        container_names="${container_names} ${container_name}"
    done

    local lines=()
    local value=
    for index in "${containers[@]}"; do
        POD_CONTAINER_COUNT=$((POD_CONTAINER_COUNT+1))
        eval "$(_CONTAINER_VARS "${POD_CONTAINER_COUNT}")"

        ## name
        #
        local container_name=
        _copy "container_name" "/containers/${index}/name"
        STRING_SUBST "container_name" "'" "" 1
        STRING_SUBST "container_name" '"' "" 1
        _CONTAINER_SET_VAR "${POD_CONTAINER_COUNT}" "NAME" "container_name"

        ## network
        #
        local network=
        _copy "network" "/containers/${index}/network"
        STRING_SUBST "network" "'" "" 1
        STRING_SUBST "network" '"' "" 1
        if [ -n "${network}" ]; then
            if [ "${network}" != "host" ]; then
                PRINT "Unknown network \"${network}\". Network if set must be set to \"host\"." "error" 0
                return 1
            fi
            PRINT "Network set to host. Any expose section will be ignored." "info" 0
            network="--network=${network}"
        fi
        _CONTAINER_SET_VAR "${POD_CONTAINER_COUNT}" "NETWORK" "network"

        ## restart:
        #
        local value=""
        if ! _COMPILE_RESTART; then
            return 1
        fi
        _CONTAINER_SET_VAR "${POD_CONTAINER_COUNT}" "RESTARTPOLICY" "value"

        ## image:
        #
        local value=""
        if ! _COMPILE_IMAGE; then
            return 1
        fi
        _CONTAINER_SET_VAR "${POD_CONTAINER_COUNT}" "IMAGE" "value"

        ## signal:
        #
        local sig=""
        local cmd=""
        if ! _COMPILE_SIGNALEXEC; then
            return 1
        fi
        _CONTAINER_SET_VAR "${POD_CONTAINER_COUNT}" "SIGNALSIG" "sig"
        _CONTAINER_SET_VAR "${POD_CONTAINER_COUNT}" "SIGNALCMD" "cmd"

        ## startupProbe/timeout:
        #
        local value=""
        if ! _COMPILE_STARTUP_PROBE_TIMEOUT; then
            return 1
        fi
        _CONTAINER_SET_VAR "${POD_CONTAINER_COUNT}" "STARTUPTIMEOUT" "value"

        ## startupProbe/exit or startupProbe/cmd
        local value=""
        if ! _COMPILE_STARTUP_PROBE; then
            return 1
        fi
        _CONTAINER_SET_VAR "${POD_CONTAINER_COUNT}" "STARTUPPROBE" "value"

        ## startupProbe/signal
        #
        local value=""
        if ! _COMPILE_STARTUP_PROBE_SIGNAL; then
            return 1
        fi
        _CONTAINER_SET_VAR "${POD_CONTAINER_COUNT}" "STARTUPSIGNAL" "value"

        ## readinessProbe/timeout
        #
        local value=""
        if ! _COMPILE_READINESS_PROBE_TIMEOUT; then
            return 1
        fi
        _CONTAINER_SET_VAR "${POD_CONTAINER_COUNT}" "READINESSTIMEOUT" "value"

        ## livenessProbe/cmd
        #
        local value=""
        if ! _COMPILE_LIVENESS_PROBE; then
            return 1
        fi
        _CONTAINER_SET_VAR "${POD_CONTAINER_COUNT}" "LIVENESSPROBE" "value"

        ## livenessProbe/timeout
        #
        local value=""
        if ! _COMPILE_LIVENESS_PROBE_TIMEOUT; then
            return 1
        fi
        _CONTAINER_SET_VAR "${POD_CONTAINER_COUNT}" "LIVENESSTIMEOUT" "value"

        ## livenessProbe/cmd
        #
        local value=""
        if ! _COMPILE_READINESS_PROBE; then
            return 1
        fi
        _CONTAINER_SET_VAR "${POD_CONTAINER_COUNT}" "READINESSPROBE" "value"

        ## mounts:
        #
        local mounts=""
        if ! _COMPILE_MOUNTS; then
            return 1
        fi
        _CONTAINER_SET_VAR "${POD_CONTAINER_COUNT}" "MOUNTS" "mounts"

        ## env
        #
        local value=""
        if ! _COMPILE_ENV; then
            return 1
        fi
        _CONTAINER_SET_VAR "${POD_CONTAINER_COUNT}" "ENV" "value"

        ## ingress
        #
        local _out_container_ports=""
        if [ -z "${network}" ]; then
            if ! _COMPILE_INGRESS "/containers/${index}/expose/" "true"; then
                return 1
            fi
        fi
        _CONTAINER_SET_VAR "${POD_CONTAINER_COUNT}" "PORTS" "_out_container_ports"

        if !  _COMPILE_ENTRYPOINT; then
            return 1
        fi

        if !  _COMPILE_CPUMEM; then
            return 1
        fi

        if !  _COMPILE_RUN; then
            return 1
        fi
    done

    # Extract all labels.
    if ! _COMPILE_LABELS; then
        return 1
    fi

    ## Postfix
    # All STARTUPSIGNAL must be transformed to their number.
    local container_nr=
    for container_nr in $(seq 1 ${POD_CONTAINER_COUNT}); do
        local sendsignals=
        local sendsignals_nrs=""
        _GET_CONTAINER_VAR "${container_nr}" "STARTUPSIGNAL" "sendsignals"
        local targetcontainer=
        for targetcontainer in ${sendsignals}; do
            # Get the container nr for this name
            local nr=
            if ! nr="$(_GET_CONTAINER_NR "${targetcontainer}")"; then
                PRINT "Could not find container ${targetcontainer} referenced in startupProbe/signal." "error" 0
                return 1
            fi
            sendsignals_nrs="${sendsignals_nrs}${sendsignals_nrs:+ }${nr}"
        done
        # Overwrite with new string
        _CONTAINER_SET_VAR "${container_nr}" "STARTUPSIGNAL" "sendsignals_nrs"
    done

    ## Postfix
    # All container names must be suffixed with the podName-version
    for container_nr in $(seq 1 ${POD_CONTAINER_COUNT}); do
        local containername=
        _GET_CONTAINER_VAR "${container_nr}" "NAME" "containername"
        containername="${containername}-${POD}"
        # Overwrite with new string
        _CONTAINER_SET_VAR "${container_nr}" "NAME" "containername"
    done

    ## Output all generated variables
    local newline="
"
    local var=
    for var in POD POD_VERSION POD_LABELS POD_CREATE POD_VOLUMES POD_RAMDISKS POD_HOSTPORTS POD_CONTAINER_COUNT; do
        local value="${!var}"
        STRING_ESCAPE "value" '"'
        _out_pod="${_out_pod}${newline}$(printf "%s=\"%s\"\\n" "${var}" "${value}")"
    done

    local index=
    for index in $(seq 1 ${POD_CONTAINER_COUNT}); do
        for var in NAME RESTARTPOLICY NETWORK IMAGE STARTUPPROBE STARTUPTIMEOUT STARTUPSIGNAL LIVENESSPROBE LIVENESSTIMEOUT READINESSPROBE READINESSTIMEOUT SIGNALSIG SIGNALCMD CONFIGS MOUNTS ENV COMMAND ARGS WORKINGDIR CPUMEM PORTS RUN; do
            local varname="POD_CONTAINER_${var}_${index}"
            local value="${!varname}"
            _out_pod="${_out_pod}${newline}$(printf "%s=\"%s\"\\n" "${varname}" "${value}")"
        done
        _out_pod="${_out_pod}${newline}"
    done

    ## Output rest of runtime template file
    _out_pod="${_out_pod}${newline}$(awk 'BEGIN {show=0} /^[^#]/ { show=1 } {if(show==1) {print}}' "${runtimePath}")"
}

_COMPILE_LABELS()
{
    SPACE_SIGNATURE="[extralabels]"
    SPACE_DEP="STRING_IS_ALL STRING_SUBST PRINT"

    local extraLabels="${1:-}"

    local labels=""
    local index=()
    _list "index" "/labels/"
    local index0=
    # TODO: validate keys and values, as: https://kubernetes.io/docs/concepts/overview/working-with-objects/labels/#syntax-and-character-set
    for index0 in "${index[@]}"; do
        local name=
        _copy "name" "/labels/${index0}/name"
        STRING_SUBST "name" "'" "" 1
        STRING_SUBST "name" '"' "" 1
        local value=
        _copy "value" "/labels/${index0}/value"
        STRING_SUBST "value" "'" "" 1
        STRING_SUBST "value" '"' "" 1
        if ! STRING_IS_ALL "${value}" "A-Za-z0-9_./-"; then
            PRINT "Invalid characters in labels. Only [A-Za-z0-9._-/] allowed" "error" 0
            return 1
        fi
        labels="${labels}${labels:+ }--label ${name}=${value}"
    done

    POD_LABELS="${labels}${labels:+ }${extraLabels}"
}

_COMPILE_ENTRYPOINT()
{
    # Internal "macro" function. We don't define any SPACE_ headers for this.

    # --entrypoint of container
    # if this is set then the default CMD will get nullified and if wanted has to be
    # provided as "args" parameter in the pod.yaml. As extracted below.
    local subarg=
    local arg=
    local args=
    local value=""
    _list "args" "/containers/${index}/command/" "" 1
    for arg in "${args[@]}"; do
        _copy "subarg" "/containers/${index}/command/${arg}"
        _QUOTE_ARG "subarg"
        value="${value}${value:+, }${subarg}"
    done

    value="${value:+--entrypoint='[$value]'}"
    _CONTAINER_SET_VAR "${POD_CONTAINER_COUNT}" "COMMAND" "value"

    local subarg=
    local arg=
    local args=
    local value=""
    _list "args" "/containers/${index}/args/" "" 1
    for arg in "${args[@]}"; do
        _copy "subarg" "/containers/${index}/args/${arg}"
        _QUOTE_ARG "subarg"
        value="${value}${value:+ }${subarg}"
    done

    _CONTAINER_SET_VAR "${POD_CONTAINER_COUNT}" "ARGS" "value"

    local value=
    _copy "value" "/containers/${index}/workingDir"
    if ! STRING_IS_ALL "${value}" "A-Za-z0-9_./-"; then
        PRINT "Invalid characters in workingDir. Only [A-Za-z0-9._-/] allowed" "error" 0
        return 1
    fi
    value="${value:+--workdir=$value}"
    _CONTAINER_SET_VAR "${POD_CONTAINER_COUNT}" "WORKINGDIR" "value"
}

# Macro helper function
_COMPILE_MOUNTS()
{
    local args=()
    _list "args" "/containers/${index}/mounts/"

    if [ "${#args[@]}" -gt 0 ]; then
        local arg=
        local dest=
        local volume=
        local indexof=
        for arg in "${args[@]}"; do
            _copy "dest" "/containers/${index}/mounts/${arg}/dest"
            STRING_SUBST "dest" "'" "" 1
            STRING_SUBST "dest" '"' "" 1
            # Check so valid destination path
            if [ "${dest#/}" = "${dest}" ]; then
                PRINT "Dest path in mount must start with a slash." "error" 0
                return 1
            fi

            _copy "volume" "/containers/${index}/mounts/${arg}/volume"
            STRING_SUBST "volume" "'" "" 1
            STRING_SUBST "volume" '"' "" 1
            # Check so volume exists and get the type
            local type=""
            local bind=""
            local encrypted=

                # Need to compare when stripped away the :size parameter from the diskname
                local isRamdisk=0
                local ramdisk=
                for ramdisk in ${POD_RAMDISKS}; do
                    local diskname="${ramdisk%:*}"
                    if [ "${diskname}" = "${volume}" ]; then
                        isRamdisk=1
                        break
                    fi
                done

                if STRING_ITEM_INDEXOF "${POD_VOLUMES}" "${volume}" "indexof"; then
                    type="volume"
                elif STRING_ITEM_INDEXOF "${POD_VOLUMES}" "${volume}-${podName}" "indexof"; then
                    type="volume"
                elif STRING_ITEM_INDEXOF "${POD_VOLUMES}" "${volume}-${podName}-${podVersion}" "indexof"; then
                    type="volume"
                fi
                if [ "${type}" = "volume" ]; then
                    STRING_ITEM_GET "${POD_VOLUMES}" "${indexof}" "volume"
                    mounts="${mounts}${mounts:+ }-v ${volume}:${dest}:z,rw"
                elif [ "${isRamdisk}" = "1" ]; then
                    type="ramdisk"
                    bind="./ramdisk/${volume}"
                    mounts="${mounts}${mounts:+ }-v ${bind}:${dest}:z,rw"
                elif STRING_ITEM_INDEXOF "${volumes_host}" "${volume}" "indexof"; then
                    type="host"
                    STRING_ITEM_GET "${volumes_host_bind}" "${indexof}" "bind"
                    # dev option so that we can mount devices.
                    mounts="${mounts}${mounts:+ }-v ${bind}:${dest}:z,rw,dev"
                elif STRING_ITEM_INDEXOF "${volumes_config}" "${volume}" "indexof"; then
                    type="config"
                    # Check if encrypted
                    STRING_ITEM_GET "${volumes_config_encrypted}" "${indexof}" "encrypted"
                    if [ "${encrypted}" = "true" ]; then
                        bind="./ramdisk/${volume}-unencrypted"
                        mounts="${mounts}${mounts:+ }-v ${bind}:${dest}:z,ro"

                        # Add to unencrypter container to signal this container
                        local container_nr=
                        local containername="${volume}-decrypter"
                        if ! container_nr="$(_GET_CONTAINER_NR "${containername}")"; then
                            PRINT "Could not find container ${containername}." "error" 0
                            return 1
                        fi
                        # Add this container name to the decrypter containers send signals value
                        local sendsignals=
                        _GET_CONTAINER_VAR "${container_nr}" "STARTUPSIGNAL" "sendsignals"
                        sendsignals="${sendsignals}${sendsignals:+ }${container_name}"
                        _CONTAINER_SET_VAR "${container_nr}" "STARTUPSIGNAL" "sendsignals"
                    else
                        bind="./config/${volume}"
                        mounts="${mounts}${mounts:+ }-v ${bind}:${dest}:z,ro"
                        local configs=
                        _GET_CONTAINER_VAR "${POD_CONTAINER_COUNT}" "CONFIGS" "configs"
                        configs="${configs}${configs:+ }${volume}"
                        _CONTAINER_SET_VAR "${POD_CONTAINER_COUNT}" "CONFIGS" "configs"
                    fi
                else
                    PRINT "Volume ${volume} is not defined." "error" 0
                    return 1
                fi
            done
    fi

}

# Macro helper function
_COMPILE_RESTART()
{
    _copy "value" "/containers/${index}/restart"
    STRING_SUBST "value" "'" "" 1
    STRING_SUBST "value" '"' "" 1

    value="${value:-never}"
    local value2="${value%:*}"  # Cut away the :x for on-interval:x
    if [[ $value2 = "on-interval" ]] && [[ ! $value =~ ^on-interval:[0-9]+$ ]]; then
        PRINT "Restart policy on-interval must be on format on-interval:seconds" "error" 0
        return 1
    fi
    if ! STRING_ITEM_INDEXOF "always on-interval on-config on-failure never" "${value2}"; then
        PRINT "Restart policy '${value}' for container ${container_name} is invalid. Must be always, on-interval:x, on-config, on-failure or never." "error" 0
        return 1
    fi
}

# Macro helper function
_COMPILE_IMAGE()
{
    _copy "value" "/containers/${index}/image"
    STRING_SUBST "value" "'" "" 1
    STRING_SUBST "value" '"' "" 1
    if [ -z "${value}" ]; then
        PRINT "Image for container ${container_name} is invalid." "error" 0
        return 1
    fi
}

# Macro helper function
_COMPILE_SIGNALEXEC()
{
    local args=()
    _list "args" "/containers/${index}/signal/" "" 1
    if [ "${#args[@]}" -gt 1 ]; then
        PRINT "Only one of signal/sig and signal/cmd can be defined, for container ${container_name}." "error" 0
        return 1
    fi

    _copy "sig" "/containers/${index}/signal/0/sig"
    STRING_SUBST "sig" "'" "" 1
    STRING_SUBST "sig" '"' "" 1
    if [ -n "${sig}" ]; then
        return
    else
        _list "args" "/containers/${index}/signal/0/cmd/" "" 1
        if [ "${#args[@]}" -gt 0 ]; then
            local arg=
            local subarg=
            local space=""
            for arg in "${args[@]}"; do
                _copy "subarg" "/containers/${index}/signal/0/cmd/${arg}"
                _QUOTE_ARG "subarg"
                cmd="${cmd}${space}${subarg}"
                space=" "
            done
        fi
    fi
}

# Macro helper function
_COMPILE_STARTUP_PROBE()
{
    _copy "value" "/containers/${index}/startupProbe/exit"
    STRING_SUBST "value" "'" "" 1
    STRING_SUBST "value" '"' "" 1
    local args=()
    _list "args" "/containers/${index}/startupProbe/cmd/" "" 1
    if [ "${value}" = "true" ] && [ "${#args[@]}" -gt 0 ]; then
        PRINT "Only startupProbe/exit or startupProbe/cmd can be defined, for container ${container_name}." "error" 0
        return 1
    fi

    if [ "${value}" = "true" ]; then
        value="exit"
        return
    else
        value=""
        if [ "${#args[@]}" -gt 0 ]; then
            local arg=
            local subarg=
            local space=""
            for arg in "${args[@]}"; do
                _copy "subarg" "/containers/${index}/startupProbe/cmd/${arg}"
                _QUOTE_ARG "subarg"
                value="${value}${space}${subarg}"
                space=" "
            done
        fi
    fi
}


# Macro helper function
_COMPILE_STARTUP_PROBE_TIMEOUT()
{
    _copy "value" "/containers/${index}/startupProbe/timeout"
    STRING_SUBST "value" "'" "" 1
    STRING_SUBST "value" '"' "" 1
    value="${value:-120}"
    if [[ ! $value =~ ^[0-9]+$ ]]; then
        PRINT "Startup timeout for container ${container_name} must be an integer." "error" 0
        return 1
    fi
}

# Macro helper function
_COMPILE_STARTUP_PROBE_SIGNAL()
{
    local args=()
    _list "args" "/containers/${index}/startupProbe/signal/"

    if [ "${#args[@]}" -gt 0 ]; then
        local arg=
        local containername=
        local space=""
        local container_nr=
        for arg in "${args[@]}"; do
            # Note: Don't have to check for validity here because
            # these names will be checked and mapped into nrs further down.
            _copy "containername" "/containers/${index}/startupProbe/signal/${arg}/container"
            STRING_SUBST "containername" "'" "" 1
            STRING_SUBST "containername" '"' "" 1
            value="${value}${space}${containername}"
            space=" "
        done
    fi
}

# Macro helper function
_COMPILE_READINESS_PROBE()
{
    local args=()
    _list "args" "/containers/${index}/readinessProbe/cmd/" "" 1
    value=""
    if [ "${#args[@]}" -gt 0 ]; then
        local arg=
        local subarg=
        local space=""
        for arg in "${args[@]}"; do
            _copy "subarg" "/containers/${index}/readinessProbe/cmd/${arg}"
            _QUOTE_ARG "subarg"
            value="${value}${space}${subarg}"
            space=" "
        done
    fi
}

# Macro helper function
_COMPILE_READINESS_PROBE_TIMEOUT()
{
    _copy "value" "/containers/${index}/readinessProbe/timeout"
    STRING_SUBST "value" "'" "" 1
    STRING_SUBST "value" '"' "" 1
    value="${value:-120}"
    if [[ ! $value =~ ^[0-9]+$ ]]; then
        PRINT "Readiness timeout for container ${container_name} must be an integer." "error" 0
        return 1
    fi
}

# Macro helper function
_COMPILE_LIVENESS_PROBE()
{
    local args=()
    _list "args" "/containers/${index}/livenessProbe/cmd/" "" 1
    value=""
    if [ "${#args[@]}" -gt 0 ]; then
        local arg=
        local subarg=
        local space=""
        for arg in "${args[@]}"; do
            _copy "subarg" "/containers/${index}/livenessProbe/cmd/${arg}"
            _QUOTE_ARG "subarg"
            value="${value}${space}${subarg}"
            space=" "
        done
    fi
}

# Macro helper function
_COMPILE_LIVENESS_PROBE_TIMEOUT()
{
    _copy "value" "/containers/${index}/livenessProbe/timeout"
    STRING_SUBST "value" "'" "" 1
    STRING_SUBST "value" '"' "" 1
    value="${value:-120}"
    if [[ ! $value =~ ^[0-9]+$ ]]; then
        PRINT "Liveness timeout for container ${container_name} must be an integer." "error" 0
        return 1
    fi
}

# Macro helper function
_COMPILE_ENV()
{
    local args=()
    _list "args" "/containers/${index}/env/" 1 1

    if [ "${#args[@]}" -gt 0 ]; then
        local arg=
        local subarg=
        local space=""
        for arg in "${args[@]}"; do
            _copy "subarg" "/containers/${index}/env/${arg}/name"
            STRING_SUBST "subarg" "'" "" 1
            STRING_SUBST "subarg" '"' "" 1
            if [[ ! $subarg =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
                PRINT "Env variable name contains illegal characters: ${subarg}. a-zA-Z0-9_, ha sto start with a letter." "error" 0
                return 1
            fi
            local subarg2=
            _copy "subarg2" "/containers/${index}/env/${arg}/value"
            _QUOTE_ARG "subarg2"
            value="${value}${space}-e ${subarg}=${subarg2}"
            space=" "
        done
    fi
}

_COMPILE_CPUMEM()
{
    # Internal "macro" function. We don't define any SPACE_ headers for this.
    # TODO only do --memory=M for now.
    :
}

_COMPILE_RUN()
{
    # Internal "macro" function. We don't define any SPACE_ headers for this.
    local run="\\\${ADD_PROXY_IP:-} --name \${POD_CONTAINER_NAME_${POD_CONTAINER_COUNT}} \${POD_CONTAINER_ENV_${POD_CONTAINER_COUNT}} \${POD_CONTAINER_NETWORK_${POD_CONTAINER_COUNT}} \${POD_CONTAINER_PORTS_${POD_CONTAINER_COUNT}} \${POD_CONTAINER_COMMAND_${POD_CONTAINER_COUNT}} \${POD_CONTAINER_MOUNTS_${POD_CONTAINER_COUNT}} \${POD_CONTAINER_WORKINGDIR_${POD_CONTAINER_COUNT}} \${POD_CONTAINER_IMAGE_${POD_CONTAINER_COUNT}} \${POD_CONTAINER_ARGS_${POD_CONTAINER_COUNT}}"
    _CONTAINER_SET_VAR "${POD_CONTAINER_COUNT}" "RUN" "run"
}

_COMPILE_INGRESS()
{
    SPACE_SIGNATURE="prefix useTargetPorts"

    local prefix="${1}"
    shift

    local useTargetPorts="${1:-true}"
    shift $(($# > 0 ? 1 : 0))

    # Internal "macro" function. We don't define any SPACE_ headers for this.

    local portmappings=""
    local lines=()

    local exposeindex=()
    _list "exposeindex" "${prefix}"
    local index0=
    for index0 in "${exposeindex[@]}"; do
        # Get targetPort, clusterPort, hostPort
        local targetPort=
        _copy "targetPort" "${prefix}${index0}/targetPort"
        STRING_SUBST "targetPort" "'" "" 1
        STRING_SUBST "targetPort" '"' "" 1
        local clusterPort=
        _copy "clusterPort" "${prefix}${index0}/clusterPort"
        STRING_SUBST "clusterPort" "'" "" 1
        STRING_SUBST "clusterPort" '"' "" 1
        local hostPort=
        _copy "hostPort" "${prefix}${index0}/hostPort"
        STRING_SUBST "hostPort" "'" "" 1
        STRING_SUBST "hostPort" '"' "" 1
        local hostInterface=
        _copy "hostInterface" "${prefix}${index0}/hostInterface"
        STRING_SUBST "hostInterface" "'" "" 1
        STRING_SUBST "hostInterface" '"' "" 1
        local sendproxy=
        _copy "sendproxy" "${prefix}${index0}/sendProxy"
        STRING_SUBST "sendproxy" "'" "" 1
        STRING_SUBST "sendproxy" '"' "" 1
        local maxconn=
        _copy "maxconn" "${prefix}${index0}/maxConn"
        STRING_SUBST "maxconn" "'" "" 1
        STRING_SUBST "maxconn" '"' "" 1

        if [ -n "${maxconn}" ]; then
            if [[ ! $maxconn =~ ^([0-9])+$ ]]; then
                PRINT "maxconn must be an integer." "error" 0
                return 1
            fi
        else
            maxconn=4096  # Default value
        fi
        if [ -n "${sendproxy}" ]; then
            if [ "${sendproxy}" = "true" ] || [ "${sendproxy}" = "false" ]; then
                :
            else
                PRINT "Illegal value for sendProxy. Must be set to true or false, default is false." "error" 0
                return 1
            fi
        else
            sendproxy="false"
        fi

        if [ "${useTargetPorts}" = "false" ]; then
            if [ -n "${targetPort}" ]; then
                PRINT "targetPort not allowed for this pod runtime." "error" 0
                return 1
            fi
            targetPort="0"
        fi

        if [ -n "${hostInterface}" ]; then
            if [[ ! $hostInterface =~ ^([0-9])+[.]([0-9])+[.]([0-9])+[.]([0-9])+$ ]]; then
                PRINT "hostInterface must be an IP address." "error" 0
                return 1
            fi
        fi

        if [ -n "${hostPort}" ]; then
            if [[ ! $hostPort =~ ^([0-9])+$ ]]; then
                PRINT "hostPort must be an integer." "error" 0
                return 1
            fi

            if [ "${hostPort}" -lt "1" ] || [ "${hostPort}" -gt "65535" ]; then
                PRINT "Host port must be between 1 and 65535 (but typically not between 61000-63999 and 32767)." "error" 0
                return 1
            fi

            if [ "${useTargetPorts}" = "true" ]; then
                if [[ ! $targetPort =~ ^([0-9])+$ ]]; then
                    PRINT "targetPort must be an integer." "error" 0
                    return 1
                fi

                if [ "${targetPort}" -lt "1" ] || [ "${targetPort}" -gt "65535" ]; then
                    PRINT "Target port must be between 1 and 65535." "error" 0
                    return 1
                fi
            fi

            if [ -n "${clusterPort}" ]; then
                if [[ ! $clusterPort =~ ^([0-9])+$ ]]; then
                    PRINT "clusterPort must be an integer." "error" 0
                    return 1
                fi

                if [ "${clusterPort}" -lt "1024" ] || [ "${clusterPort}" -gt "65535" ]; then
                    PRINT "Cluster port must be between 1024 and 65535, but not between 30000-32767." "error" 0
                    return 1
                fi

                if [ "${clusterPort}" -ge "30000" ] && [ "${clusterPort}" -le "32767" ]; then
                    PRINT "Cluster port cannot be in the reserved range of 30000-32767." "error" 0
                    return 1
                fi
            else
                clusterPort="0"
            fi

            portmappings="${portmappings} ${clusterPort}:${hostInterface}-${hostPort}:${targetPort}:${maxconn}:${sendproxy}"

            if STRING_ITEM_INDEXOF "${POD_HOSTPORTS}" "${hostPort}"; then
                PRINT "A hostPort can only be defined once in ingress (even for different interfaces), for hostPort ${hostPort} and targetPort ${targetPort}." "error" 0
                return 1
            fi
            POD_HOSTPORTS="${POD_HOSTPORTS}${POD_HOSTPORTS:+ }${hostPort}"
        else
            clusterPort="0"
        fi

        local prefix2="${prefix}${index0}/ingress/"
        local ingressindex=()
        _list "ingressindex" "${prefix2}"
        local index1=
        for index1 in "${ingressindex[@]}"; do
            local domain=
            local bind=
            local protocol=
            local weight=
            local path_beg=
            local path_end=
            local path=
            local redirect_to_https=
            local redirect_location=
            local redirect_prefix=
            local errorfile=
            _copy "protocol" "${prefix2}${index1}/protocol"
            STRING_SUBST "protocol" "'" "" 1
            STRING_SUBST "protocol" '"' "" 1
            _copy "bind" "${prefix2}${index1}/bind"
            STRING_SUBST "bind" "'" "" 1
            STRING_SUBST "bind" '"' "" 1
            _copy "domain" "${prefix2}${index1}/domain"
            STRING_SUBST "domain" "'" "" 1
            STRING_SUBST "domain" '"' "" 1
            _copy "weight" "${prefix2}${index1}/weight"
            STRING_SUBST "weight" "'" "" 1
            STRING_SUBST "weight" '"' "" 1
            _copy "path_beg" "${prefix2}${index1}/pathBeg"
            STRING_SUBST "path_beg" "'" "" 1
            STRING_SUBST "path_beg" '"' "" 1
            _copy "path_end" "${prefix2}${index1}/pathEnd"
            STRING_SUBST "path_end" "'" "" 1
            STRING_SUBST "path_end" '"' "" 1
            _copy "path" "${prefix2}${index1}/path"
            STRING_SUBST "path" "'" "" 1
            STRING_SUBST "path" '"' "" 1
            _copy "redirect_to_https" "${prefix2}${index1}/redirectToHttps"
            STRING_SUBST "redirect_to_https" "'" "" 1
            STRING_SUBST "redirect_to_https" '"' "" 1
            _copy "redirect_location" "${prefix2}${index1}/redirectLocation"
            STRING_SUBST "redirect_location" "'" "" 1
            STRING_SUBST "redirect_location" '"' "" 1
            _copy "redirect_prefix" "${prefix2}${index1}/redirectPrefix"
            STRING_SUBST "redirect_prefix" "'" "" 1
            STRING_SUBST "redirect_prefix" '"' "" 1
            _copy "errorfile" "${prefix2}${index1}/errorfile"
            STRING_SUBST "errorfile" "'" "" 1
            STRING_SUBST "errorfile" '"' "" 1

            if ! STRING_ITEM_INDEXOF "http https tcp" "${protocol}"; then
                PRINT "Unknown protocol ${protocol} in ingress. Only: http, https and tcp allowed" "error" 0
                return 1
            fi

            if [ -z "${bind}" ]; then
                if [ "${protocol}" = "http" ]; then
                    bind="80"
                elif [ "${protocol}" = "https" ]; then
                    bind="443"
                elif [ "${protocol}" = "tcp" ]; then
                    PRINT "For tcp protocol a bind port must be provided." "error" 0
                    return 1
                fi
            else
                # Check so bind is valid
                if [[ ! $bind =~ ^([0-9])+$ ]]; then
                    PRINT "Bind must be an integer." "error" 0
                    return 1
                fi
            fi

            if [ -z "${weight}" ]; then
                weight="100"
            else
                if [[ ! $weight =~ ^([0-9])+$ ]]; then
                    PRINT "Importance must be an integer." "error" 0
                    return 1
                fi
            fi

            lines+=("bind ${bind}")
            lines+=("protocol ${protocol}")
            lines+=("host ${domain}")
            lines+=("weight ${weight}")

            local httpSpecific=0
            if [ -n "${path}" ]; then
                lines+=("path ${path}")
                httpSpecific=1
            fi

            if [ -n "${path_beg}" ]; then
                lines+=("path_beg ${path_beg}")
                httpSpecific=1
            fi

            if [ -n "${path_end}" ]; then
                lines+=("path_end ${path_end}")
                httpSpecific=1
            fi

            if [ "${redirect_to_https}" = "true" ]; then
                lines+=("redirect_to_https true")
                httpSpecific=1
            elif [ -n "${redirect_location}" ]; then
                lines+=("redirect_location ${redirect_location}")
                httpSpecific=1
            elif [ -n "${redirect_prefix}" ]; then
                lines+=("redirect_prefix ${redirect_prefix}")
                httpSpecific=1
            elif [ -n "${errorfile}" ]; then
                lines+=("errorfile ${errorfile}")
                httpSpecific=1
            else
                # server backend.
                # This requires that any http psecific criteria has been set, of http/s
                if [ "${httpSpecific}" = "0" ] && { [ "${protocol}" = "http" ] || [ "${protocol}" = "https" ]; }; then
                    PRINT "Missing http/s specific criterion. Ex: path, pathBeg, pathEnd, etc" "error" 0
                    return 1
                fi


                # This requires a hostPort
                if [ -z "${hostPort}" ]; then
                    PRINT "This pod yaml ingress is lacking a hostPort definition." "error" 0
                    return 1
                fi
                # This requires a clusterPort >0
                if [ "${clusterPort}" -eq 0 ]; then
                    PRINT "This pod yaml ingress is lacking a clusterPort definition." "error" 0
                    return 1
                fi
                lines+=("clusterport ${clusterPort}")
            fi

            if [ "${httpSpecific}" = "1" ] && [ "${protocol}" = "tcp" ]; then
                PRINT "Cannot have HTTP specific matching and actions for TCP protocol. Such as path, pathBeg, redirect, etc." "error" 0
                return 1
            fi

        done
    done

    if [ -n "${POD_INGRESSCONF}" ]; then
        local nl="
"
        POD_INGRESSCONF="${POD_INGRESSCONF}${nl}$(printf "%s\\n" "${lines[@]}")"
    else
        POD_INGRESSCONF="$(printf "%s\\n" "${lines[@]}")"
    fi

    # Create the port mapping for the container.
    local arg=
    for arg in ${portmappings}; do
        local clusterPort="${arg%%:*}"
        local hostPort="${arg%:*:*:*}"
        hostPort="${hostPort#*:}"
        hostInterface="${hostPort%-*}"
        hostPort="${hostPort#*-}"
        local targetPort="${arg%:*:*}"
        targetPort="${targetPort#*:*:}"
        local maxConn="${arg%:*}"
        maxConn="${maxConn#*:*:*:}"
        local sendProxy="${arg##*:}"
        if [ "${clusterPort}" -gt 0 ]; then
            # Only expose in cluster if clusterPort >0
            local nl="
"
            # This gets written to the portmappings file.
            POD_PROXYCONF="${POD_PROXYCONF}${POD_PROXYCONF:+$nl}${clusterPort}:${hostPort}:${maxConn}:${sendProxy}"
        fi
        # hostInterface set value of escaped varname
        if [ -z "${hostInterface}" ]; then
            hostInterface='\${HOST_INTERFACE}'
        else
            hostInterface="${hostInterface}:"
        fi
        _out_container_ports="${_out_container_ports}${_out_container_ports:+ }-p ${hostInterface}${hostPort}:${targetPort}"
    done
}

# Go thrugh all containers and find the one matching name
_GET_CONTAINER_NR()
{
    SPACE_SIGNATURE="containername"
    SPACE_DEP="_GET_CONTAINER_VAR"

    local containername="${1}"
    shift

    local index=
    local name=
    for index in $(seq 1 ${POD_CONTAINER_COUNT}); do
        _GET_CONTAINER_VAR "${index}" "NAME" "name"
        if [ "${containername}" = "${name}" ]; then
            printf "%s\\n" "${index}"
            return 0
        fi
    done
    return 1
}

# argname is the name of a variable which we want to quote in place
_QUOTE_ARG()
{
    SPACE_SIGNATURE="argname"
    SPACE_DEP="STRING_ESCAPE STRING_SUBSTR"

    local argname="${1}"
    shift

    # Dereference the variable, bashism
    local argvalue="${!argname}"

    local firstchar=
    local lastchar=
    STRING_SUBSTR "${argvalue}" 0 1 "firstchar"
    STRING_SUBSTR "${argvalue}" -1 1 "lastchar"

    local addquotes=0
    if [ "${firstchar}" = "${argvalue}" ]; then
        # Empty string or single char
        addquotes=1
    elif [ "${firstchar}" = "${lastchar}" ] && [ "${firstchar}" = "\"" ]; then
        # Properly formatted string, do nothing
        :
    elif [ "${firstchar}" = "${lastchar}" ] && [ "${firstchar}" = "'" ]; then
        # String enclosed in single quotes,
        # remove single quotes
        STRING_SUBSTR "${argvalue}" 1 -1 "${argname}"
        addquotes=1
    else
        # Whatever this is, add quotes
        addquotes=1
    fi

    # Check if we need to enclose the argument in quotes
    if [ "${addquotes}" = "1" ]; then
        STRING_ESCAPE "${argname}"
        eval "${argname}=\"\\\"\${${argname}}\\\"\""
    fi

    # Now lift the whole argument.
    STRING_ESCAPE "${argname}"
}

_CONTAINER_SET_VAR()
{
    SPACE_SIGNATURE="container_nr varname valuevarname [quote]"
    SPACE_DEP="STRING_ESCAPE"

    local container_nr="${1}"
    shift

    local varname="${1}"
    shift

    local valuevarname="${1}"
    shift

    local quote="${1:-0}"
    shift

    if [ "${quote}" = "1" ]; then
        STRING_ESCAPE "${valuevarname}" '"'
    fi

    eval "POD_CONTAINER_${varname}_${container_nr}=\"\${${valuevarname}}\""
}

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

_CONTAINER_VARS()
{
    SPACE_SIGNATURE="container_nr"

    local container_nr="${1}"
    shift

    printf "%s\\n" "
local POD_CONTAINER_NAME_${container_nr}=
local POD_CONTAINER_STARTUPPROBE_${container_nr}=
local POD_CONTAINER_STARTUPTIMEOUT_${container_nr}=
local POD_CONTAINER_STARTUPSIGNAL_${container_nr}=
local POD_CONTAINER_READINESSPROBE_${container_nr}=
local POD_CONTAINER_READINESSTIMEOUT_${container_nr}=
local POD_CONTAINER_LIVENESSPROBE_${container_nr}=
local POD_CONTAINER_LIVENESSTIMEOUT_${container_nr}=
local POD_CONTAINER_SIGNALSIG_${container_nr}=
local POD_CONTAINER_SIGNALCMD_${container_nr}=
local POD_CONTAINER_RESTARTPOLICY_${container_nr}=
local POD_CONTAINER_NETWORK_${container_nr}=
local POD_CONTAINER_CONFIGS_${container_nr}=
local POD_CONTAINER_MOUNTS_${container_nr}=
local POD_CONTAINER_ENV_${container_nr}=
local POD_CONTAINER_COMMAND_${container_nr}=
local POD_CONTAINER_ARGS_${container_nr}=
local POD_CONTAINER_WORKINGDIR_${container_nr}=
local POD_CONTAINER_CPUMEM_${container_nr}=
local POD_CONTAINER_PORTS_${container_nr}=
local POD_CONTAINER_RUN_${container_nr}="
}
