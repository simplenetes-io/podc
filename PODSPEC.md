# Simplenetes Pod specification

## Background
Simplenetes pods are managed by a daemon process. This process is created on `create` together with the pod. The process PID is put as a label on the pod so the commands know where to find it.
The process is signalled TERM/USR2 to terminate/kill it self, done by the `stop` and `kill` commands (or using `kill` directly).
The daemon process constantly is updating the `.pod.status` file with the current runtime information.

Each container run is wrapped in a process which is used to separate stdout/stderr logging per container. Logs are stored in `./logs`.

Motivation for this project:

 - We use podman because:
    - containers are run root-less
    - No Docker daemon
    - Docker compatible images
    - podman has fine grained pod features exposed in the tool
 - We want more sophisticated restart policies than podman offers, such as `on-interval`.
 - We want to manage log files with rotation and separate stdout/stderr properly.
 - We want a single executable as the pod
 - We want the concept of ramdisks in the pod
 - We want the concept of configs in the pod
 - We want the concept of containers signalling each other on start events

## Noteworthy
Rootless pods and containers cannot be paused/unpaused.

`podc` does not either support stop/start without having the containers recreated. So always store important files on volumes.

We don't rely on the native `--restart` flag for restarting containers. This module persistent process handles all restart logic.


## Logs
Each container has a separate log for its stdout and its stderr.

The daemon process has its own logs.

## Naming
Pod names, container names and volume names must all match `a-z`, `0-9` and underscore `(_)`, and has to start with a letter.

Container names are internally always automatically suffixed with `-podname-version` as they are created with podman. When referring to a container when calling the pod script the suffix is not to be used but is always automatically added.

However is running `podman inspect` or similar you will need to add the suffix.

Volume names can be configured so they are shared per host, per pod or even per pod and version (this is managed using naming suffixes).

## Configs
A config directory in a pod is something which the pod can mount to a container.
When files in a config are modified the containers mounting those configs will get signalled (if a signal is defined) or restarted (depending on restart policy). This is a neat way of updating configs for a running pod without taking it down.
An example is the Ingress pod running `haproxy` which gets automatically signalled to reload the `haproxy.conf` when the file gets updated.

### Configs and Simplenetes cluster projects
The config dirs in a pod repo can be `imported` into the cluster project and from there they are available to the pod after it is compiled.
Underscore prefixed dirs are copied to the cluster project but are then not copied to pod releases nor synced to hosts in cluster.
Such underscores configs are used as templates for the cluster projects, such as the `ingress pod's` templates `(_tpl/)` for haproxy configuration snippets.  
Note that only directories in the pod config directory are after import copied to pod releases, any files in the root config directory will never be part of a release.  
This procedure does not apply to standalone pods.

## Ramdisks
If a pod is leveraging ramdisks (for sensitive data) those must be created by root before creating the pod.
You can call `sudo pod create-ramdisks` to have the ramdisks created and `sudo pod create-ramdisks -d` to have them deleted.
If not supplying ramdisks from the outside (by root) the pod will automatically create fake ramdisks (plain directories), which are useful when developing.

Ramdisks is most useful when running pods inside a cluster, then most often simplenetesd is run as root and will create any ramdisks requested.

Note that this is the only root priviligie needed for all of Simplenetes, to create ramdisks.

## Restart policies
Simplenetes pods have their own restart policies.
Containers are always created with the `podman` option `--restart=never`, then all restarting is managed by the pod daemon process (not simplenetesd, each pod has a daemon process taking care of business).

In `podman` a root-less container cannot be paused/resumed, Simplenetes is even more harsh and saying that containers which are stopped cannot be started again.
So when restarting a container it is actually removed and recreated as a new container. This is to force a behaviour which makes upgrading pods smoother
as containers can never rely on temporary data inside the container, they must always use volumes for that, which then also can be used by next version of released pods.

Restart policy for when a container exits:

    - always - no matter exit code restart container)
    - on-config - restart when i) config files on disk have changed, ii) when container exited with error code or iii) when in exited state and signalled by another container or manually by user
    - on-interval:x - as on-config, but also restart on successful exists after x seconds has passed
    - on-failure - restart container when exit code is not equal to 0
    - never - never restart container, unless manually restarted by user using "pod rerun <container>"

## Configuring podman
Configuring podman for rootless:
The files /etc/sub{uid,gid} need id mappings. Single line in each file as:
bashlund:10000:6553

The above allocates 6553 IDs to be used by containers.
Run `podman system migrate` to have podman pick that up.

If any (rootless) containers are binding to host ports lower than 1024, then we must set on the host machines `sysctl net.ipv4.ip_unprivileged_port_start=80` (or whatever the lowest port number is).

## Probes
There are three different probe supported for pods:

    - Startup probes
    - Readiness probes
    - Liveness probes

All probes run a command in the container to determine if the probe was successful or not. The startup probe can also wait for a clean exit (code 0) of the container and consider it a successful startup.

Each probe has a timeout for how long the command or the repeated invocations (for startup) of the command is allowed to take.

A probe is always run inside the container, so when wanting to do TCP/HTTP probes, that would mean that `curl`, `wget` or `netcat` have to be installed in the container for the probe to be able to run.

Simplenetes does not define a special case for command, HTTP or TCP probes, they are all command probes, and they all run inside the containers using `podman exec`.

If having to delay the Liveness probe then use a Startup probe to either determine that liveness is safe to run now or which simply sleeps a number of seconds before letting the pod creation continue.

## Proxy and Ingress confs
When a Pod is compiled, the compiler outputs alongside the `pod` executable possibly two extra files.  
These files only make sense when using pods not as standalone pods but within the Simplenetes pod orchestrator.

    - pod.portmappings.conf
        A conf file which describes the clusterPort->HostPort relations for the Pod, and some more.
        Each entry is as:
        clusterPort:hostPort:maxConn:sendProxy
        This file is later accessed by the `sns` project manager when finding new unused host ports to delegate when compiling.
        Also the `simplenetesd` accesses this file to configure the host-global `portmappings.conf` file, so that internal routing between pods on different hosts work.
        This file is synced to the cluster together with the pod executable.

    - pod.ingress.conf
        A conf file which describes the ingress configuration for the compiled pod.
        This file is used only by the `sns` project manager when generating the ingress configuration (haproxy.conf) for the ingress pod.
        This file is not synced to the cluster.

## The Simplenetes pod YAML specification
There are a couple of different types of Pods supported so far in Simplenetes.

    - Container Pods (using podman)
        These are what most people refer to as pods, a collection of containers on the same container network.
        Just as Kuberenetes Pods.
    - Executable Pods
        These are single executables which conform to the Pod API.
        The Proxy Pod is an executable, not a real pod.

Very important to note is the `podc` yaml interpretor has a few restrictions compared to other yaml
processors (because it is implemented in Bash). The most notable is that lists *must be indented*.
This will NOT work:  
```yaml
parent:
- item1
- item2
```
This will work:  
```yaml
parent:
 - item1
 - item2
```

### Container Pod Spec (using podman)

```yaml
# For the podcompiler to know what the yaml structure is supposed to look like and how to compile the output.
api: 1.0.0-beta1

# The runtime the pod will be built for.
# Options are: podman or executable
# Podman runs a container pod using podman.
# Executable is an executable file which inplements the API interface for pod interactions on command line.
# Default is podman.
runtime: podman

# The current version of this pod. This is used by the Simplenetes cluster project manager `(sns)` to distinguish different version of the same pod from eachother.
# It is also suffixed to the pod name, so that pod instances of different version will not collide.
# Must be on semver format: major.minor.patch[-tag]
# This variable is also automatically made available by podc in the preproceesing stage. It cannot be defined in the .env file.
podVersion: 0.0.1

# Define any pod labels
labels:
    - name: labelname
      value: labelvalue

# Define the volumes which this pod can use.
volumes:
    # Ramdisk volumes can be created
    - name: tmpstorage
      type: ramdisk
      size: 10M

    # Config volumes are host directory binded volumes, mounting the corresponding directory in `./config`.
    # This is good to use for configurations, but not for secrets (and really not for content either since they should not be too large in size).
    # When the files have changed on disk, the containers(s) mounting this volume will be automatically signalled/restarted.
    # They can also be manually signalled by `pod reload-configs config1 config2 etc`. This will signal each container that have signal defined and is currently running.
    # If the container is not running so it can receive the signal, then the restart-policy decides if a config update restarts the container (on-config and on-interval does that).
    # See more about the signalling further down in this document.
    - name: config1
      type: config

    # This config is special since it has defined it is "encrypted", this is how Simplenetes manages secrets.
    # What happens behind the scenes is that there is expected to be a config on disk named "my-secret", which will
    # be mounted into a new automatically configured container which role is is decrypt the configurations and store
    # the result in a automatically created ramdisk.
    # Any user container mounting this specific config will actually be mounting that ramdisk instead, where it can find the unencrypted secret.
    # A new "decrypter container" runs a specific image which responsibility it is to
    # fetch the decryption key for the secret from a vault and decrypt the config and store in on the ramdisk.
    # The user container mounting this secret ramdisk will get indirectly signalled when the underlaying config is updated, because it
    # will get signalled by the "decrypter container" as it becomes ready (if the user container has a signal defined) so it can re-read the unencrypted secret, or it will get restarted if it has the restart
    # policy on-config or on-interval.
    # So, in practice a user container is signalled/retarted the same way for an encrypted config (secret) as for when mounting a regular config.
    # See more about the signalling further down in this document.
    # NOTE: encrypted secret NOT YET IMPLEMENTED.
    - name: my-secret
      type: config
      encrypted: true

    # A podman managed volume.
    # These volumes persist over pod lifetimes and versions, but are bound to the host on which they were created.
    # shared defines if volumes are not shared and just for the specific pod version, or if shared between pod versions or shared for all pods on the host referencing the volume.
    # If shared = "no" (which is the default) then the volume name is suffixed with podname and podversion, to make it unique for the specific pod and its version.
    # If shared = "pod" then only the volume name is suffixed with the podname, to make it unique for the specific pod but shared for all its versions.
    # If shared = "host" then nothing is suffixed to the volume name making it shared for all pods on the host referencing it.
    - name: log
      type: volume
      shared: no (default) | pod | host

    # Mount directory or device on host.
    # If the bind given is relative then it will be made absolute, based on the current working directory ($PWD).
    # Using relative bind paths are useful for dev mode workflows when mounting local build directories.
    # The basedir can be overridden by compiling with the -d option.
    - name: extradisk
      type: host
      bind: /dev/sda1

containers:
    # Each container has name, which will be suffixed by the podname and the version.
    - name: hello

      # Image, podman will try a few different registries by default.
      # Here ${podVersion} will be substituted in the preprocessing stage with the value defined above.
      # This is useful for keeping the image automatically in sync with the pod version.
      image: my-site:${podVersion}

      # entrypoint to the container can be changed.
      # Default is the Docker Image ENTRYPOINT.
      # Each argument as a separate list item
      command:
        - /usr/sbin/nginx
        - -c
        - /etc/nginx.conf

      # Arguments to the entrypoint command can be set, if the command only provides the binary.
      # Default is the docker Image CMD.
      # Each argument as a separate list item
      args:
        - -c
        - /etc/nginx.conf

      # Set the initial working directory of the container.
      # Defaults to the Docker image WORKDIR.
      workingDir: /opt/files

      # Define environment variables which will be accessible to the container.
      env:
          - name: WARP_SPEED
            value: activated

      # Restart policy for when a container exits. See above for options.
      # always - no matter exit code restart container)
      # on-config - restart when i) config files on disk have changed, ii) when container exited with error code or iii) when in exited state and signalled by another container or manually by user
      # on-interval:x - as on-config, but also restart on successful exists after x seconds has passed
      # on-failure - restart container when exit code is not equal to 0
      # never - never restart container, unless manually restarted by user using "pod rerun <container>"
      restart: on-interval:10

      # Define how this container is signalled, optional.
      # A container can get get 1) signalled by other containers when they started and become ready 2) signalled on configuration changes or 3) manually from cmd line.
      # 1) A container which defines `startupProbe/signal` and a list of `- name: container` will when ready signal all those containers which are defined.
      # 2) If a container mounts a config and the config changes on disk or a  `pod reload-configs <config>` command is issued for that specific config it will get signalled.
      # 3) By calling the pod executable `./pod signal [container1 container2 etc]`
      # When a container is signalled the main process of the container will get the signal. If the container exists but is has exited then it will be restarted upon signalling,
      # but only if it has the `on-config` or `on-interval` restart policy set.
      signal:
          # Define a signal to send the main process
          - sig: HUP
          # Or, define a command to be run in the container.
          # Each argument as a separate list item
          - cmd:
            - /usr/sbin/nginx
            - -s
            - reload

      # Define mount points for volumes create above.
      # As for now all volumes are mounted as shared, read-write and allowing devices to be mounted (:z,rw,dev), except for
      # mounted secrets which are read-only.
      mounts:
          # dest in the directory in the container
          - dest: /mnt/tmpstor
            volume: tmpstorage

          # By mounting a config this container will get signalled and possibly restarted (depending on restart-policy) when a configuration is updated.
          - dest: /mnt/config1
            volume: config1

          # By mounting a config which is defined as `encrypted: true` under `/volumes` this container actually mounts
          # a ramdisk instead which is to have the unencrypted secret inside of it.
          # A new "decrypter" container is inserted into the mix and it will be then one mounting the config and being signalled when it is updated. The decrypter runs and decrypts the secret, stores it
          # on the ramdisk and then upon its exit it will signal the user defined container which is mounting the secret config.
          # So, even though this container does not directly mount the config is will still get signalled or restarted when the underlaying config is updated (as long as it has the `on-config` or `on-interval` restart policy set.
          # This is because the decrypter container will get restarted/signalled when the underlaying config changes and then eventually when it exits it will signal/restart this container.
          - dest: /mnt/my-secret
            volume: my-secret

      # Startup probe of the container.
      # The pod startup process will not continue until a container is started up.
      # Note that a successful startup could mean that the container started and then exited with code 0.
      # If there is no startup probe then the startup is counted as succeesful as soon as the container has been started.
      # If a container fails to startup later it will be destroyed and restarted according to its restart policy.
      startupProbe:
          # Wait max 60 seconds for the container to be ready. Default is 120.
          # The pod daemon process sleeps 1 second between invoking the command and will abort the startup after timeout is reached.
          timeout: 60

          # Set to true to wait for the container to exit with code 0. When the container has exited is is treated as started and ready.
          # Any other exit code means that the startup process failed.
          # The exit probe is exclusively for the startupProbe (not available for readiness/liveness probes)
          exit: false

          # Or, define a command to be run inside the container to determine when the container has started up properly.
          # Each argument as a separate list item
          cmd:
              - sh
              - -c
              - '[ -e "/tmp/$USER/ready" ] || [ -e "/home/$USER/ready" ]'

          # Note that `exit and `cmd` are mutually exclusive to each other.
          # If none of them are defined then the container is treated as successfully started as soon as the container is started.
          # If wanting to run HTTP GET or TCP socket connection tests to determine the startup state, curl/wget/netcat needs to be run inside the container.

          # Defined below `signal` we find other containers the pod daemon shall signal when this container has started up successfully.
          # Only containers which are running will get signalled, stopped containers will get restarted if they have the `on-config` or `on-interval` restart policy.
          # When a Pod is starting up fresh then only containers defined above this container can possibly be running/existing and therefore only those can get signalled.
          # However, if the container is restarted then all containers defined under `signal` will get signalled (regardless the definition order) if the startup was successful.
          # Any running containers to be signalled must have defined the `signal` property, otherwise the signalling targeted at them is ignored,
          # however exited containers who are signalled and have appropiate restart policies will get restarted.
          signal:
              - container: hello
              - container: secret

      # Check to determine if the container is ready to recieve traffic.
      # This check is automatically run during the whole pod lifecycle.
      # In this example we do a HTTP GET request to probe if the container is ready to receive traffic.
      # This command is run inside the container, and in this case it would require that `curl` is installed inside the container. `wget` or `netcat` can also be used, since any command could be run as long as
      # it is installed in the container.
      readinessProbe:
        timeout: 6
        cmd:
            - sh
            - c
            - 'code=$(curl -Lso /dev/null http://127.0.0.1:8080/healthz -H "Host: example.org" -w "%{http_code}") && [ "${code}" -ge 200 ] && [ "${code}" -lt 400 ]'

      # Check to determine the health of the container.
      # This check is automatically run during the whole pod lifecycle, but only after the startupProbe (if any) has finished.
      # If a check fails then the container will be stopped. Depending on it's restart-policy it might get restarted.
      # This has the same syntax as the "readinessProbe".
      # Here we will show an example using `wget`. `curl` is more precise in checking, but often only `busybox wget` is available in containers.
      livenessProbe:
        timeout: 6
        cmd:
            - sh
            - c
            - "wget -O /dev/null http://127.0.0.1:8080/healthz"

      # Expose ports on the containers and possible create Ingress configuration to proxy traffic.
      expose:
          ## This first configuration is simply to expose a container port on the host on a specific host port.
          # targetPort is the port which the process inside the container is listening on.
          # Required if defining a hostPort.
          # Range is 1 to 65535.
          - targetPort: 80

            # hostPort is the what port of the node host machine we bind the container part to.
            # Required if using targetPort,
            # however in the context of a Simplenetes cluster project the hostPort can be assigned as `${HOSTPORTAUTOx}` and a unique host port will be assigned. The `x` is an integer meaning that if `${HOSTPORTAUTO1}` is used in two places in the yaml the same host port value will be substituted in. In standalone mode `${HOSTPORTAUTO1}` must then be defined in the `pod.env` file.
            # Host port must be between 1 and 65535 (but typically not between 61000-63999 nor 32767 (reserved for proxy)).
            hostPort: 8081

            # Optionally force the interface to bind host ports to.
            # Setting to "0.0.0.0" is typically required for pods which are receiving traffic from the public internet, such as the ingress.
            # However, for pods which are not to be publically exposed we should definetly not set it to "0.0.0.0".
            # If hostInterface is set it then overrides the "--host-interface" option which could be passed to the pod at creation time.
            # If no "--host-interface" option is passed on cmd line nor the "hostInterface" is set then podman defaults to "0.0.0.0".
            # When running pods in a Simplenetes cluster the simplenetesd passes the host local IP address to the pod using "--host-interface".
            # Most often do not set this value, except for the ingress pod which needs to have it set to "0.0.0.0".
            hostInterface: 0.0.0.0

            # Maximum connection count which the proxy will direct to this targetPort
            # Only relevant when using a clusterPort (within a Simplenetes cluster).
            # Default is 4096
            maxConn: 1024

            # Set to true to have the proxy connect using the PROXY-PROTOCOL
            # Only relevant when using a clusterPort so that the traffic is incoming via the cluster proxy mesh.
            # Default is false.
            sendProxy: true

          ## Second configuration shows how to map a clusterPort to the expose and also to configure Ingress details.
          - targetPort: 80
            hostPort: 8080

            # clusterPort is a TCP port in a given range which is cluster wide.
            # Cluster port must be between 1024 and 65535, but not between 30000-32767.
            # Anywhere in the cluster a pod can connect to this targetPort by connecting to this clusterPort on its local IP, as long a a `proxy pod` is running on the host.
            # Optional property, but required when wanting to route traffic within the cluster to the targetPort, either from other Pods or from the Ingress.
            # Only relevant when using pods in a cluster orchestrated by Simplenetes.
            # In the context of a sns cluster clusterPort can be assigned as `${CLUSTERPORTAUTOx}` and a unique cluster port will be assigned. The `x` is an integer meaning that if `${CLUSTERPORTAUTO1}` is used in two places in the yaml the same cluster port value will be substituted in.
            # If many pods and/or pod version use the same clusterPort they will all share incoming traffic.
            clusterPort: 1234

            # Define Ingress properties for the clusterPort.
            # Only relevant when using pods in a cluster orchestrated by Simplenetes.
            ingress:
              # This first ingress configuration example does not route traffic to any backend, it only redirects traffic up in the Ingress layer,
              # therefore it does not strictly require targetPort, hostPort and clusterPort.
              # Protocol must be set to http/https/tcp
              - protocol: http

                # default bind for http is 80, we can change that by defining the bind property.
                bind: 81

                # For for all protocol we can define domains, for tcp that is SNI checked.
                domain: abc.com def.com aaa.com *.yeees.com

                ## All redirections and errorfile below are exclusive to each other.

                # Redirect traffic to https, this does not require a backend answering any connections. It becomes purely a haproxy configuration.
                redirectToHttps: true

                # Redirect all traffic to another location.
                redirectLocation: https://domain/path

                # Serve an errorfile from HAProxy.
                # The format is HTTP_ERROR_CODE FILEPATH.
                # This can be used as a fallback with a low weight to become active when another pod with same ingress rules
                # is taken out of rotation and we want to display a nice "maintenance page".
                errorfile: 500 /mnt/errorfiles/500.http

                # Redirect to a different domain prefix.
                # Could be used to add/strip a www prefix to the domain.
                redirectPrefix: https://www.domain

              # Second ingress configuration does route traffic to targetPort and therefore requires targetPort, hostPort and clusterPort to be set.
              # https will terminate TLS in the Ingress for the domains provided.
              - protocol: https
                domain: abc.com

                # Match on path beginnings.
                pathBeg: / /static/

                # Match on path endings, can be used together with pathBeg.
                pathEnd: .jpg .gif

                # Match on full path, not include query parameters. Exlusive to pathBeg and pathEnd.
                path: /admin/ /superuser/

                # A heavier weight makes this match earlier in the Ingress. Default is 100.
                weight: 101
            - protocol: tcp

              # bind is mandatory for general TCP
              bind: 4433

              # HAProxy matches this on SNI.
              domain: aaa.com bbb.com
```

### Natively executable Pod Spec
Treat a single executable as a Pod.
It is the coders responsibility that the executable implements the Pod API in the right way.

```yaml
# For the podcompiler to know what the yaml structure is supposed to look like
api: 1.0.0-beta1

# Manage a single executable
runtime: executable

# The current version of this pod. This is used by Simplenetes project management to distinguish different version of the same pod from eachother.
podVersion: 0.0.1

executable:
    # The path to the executable, relative to the the pod.yaml file.
    # This file will be copied and named "pod".
    # The only requirement for this executable is that it implements the Pod API interface.
    # Note that the reason to not name the file "pod" straight away but copying it into place
    # is that we then can use preprocessing to choose between different executable depending
    # on target OS, etc.
    file: bin/proxy

    # An executable can have exposed ports.
    # The configuration is the same as for container pods except that there are no targetPorts, since
    # there are no containers.
    # The exposed hostPorts are in this case the ports which the executable will bind to itself.
    # The resulting "cluster-config" is generated and automatically stored alongside the "pod" executable in a "config" named "cluster".
    # The executable is expected to read the file in the "cluster" config and return it when the executable is invoked with the argument "cluster-config", just as the Pod API requires.
    expose:
          # hostPort is the port the executable will be listening to.
        - hostPort: 8080

          # Optional property, but required when wanting to route traffic within the cluster to the hostPort, either from other Pods or from the Ingress.
          # Only relevant when using pods in a cluster orchestrated by Simplenetes.
          clusterPort: 1234

          # Maximum connection count which the proxy will direct to this hostPort.
          # Only relevant when using a clusterPort
          # Default is 4096
          maxConn: 1024

          # Set to true to have the proxy connect using the PROXY-PROTOCOL
          # Only relevant when using a clusterPort and traffic is incoming via the Simplenetes Proxy.
          # Default is false.
          sendProxy: true

          # Define Ingress properties for the clusterPort.
          # See the container pod example about how to define ingress routes.
          ingress:
```
## Pod API
Compiled pod scripts and other executables who implement the Pod API can be used as pods.

The API is:
```sh
./pod action [arguments]
```

Where `action` `[arguments]` are one of the following:  

```sh
./pod help
# return 0
# stdout: help text
```
Will show general usage for the pod.

```sh
./pod version
# return 0
# stdout: version data
```
Will show version information as: `runtime: podman 0.1\npodVersion: version\n`. Where runtime is `podman`, `executable`, etc and followed the runtime impl. version.  
`podVersion` is the version as depicted by the `pod.yaml`.

"Podman" is the regular Pod runtime, "executable" can be any type of executable, script or binary. As example the Simplenetes Proxy uses an "executable" runtime.  
`version` is the version number of the runtime.

```sh
./pod info
# return 0 on success
# stdout: info data
# return 1 on error
```
Will show configuration and setup for the pod, not current status.

```sh
./pod ps
# return 0
# stdout: status data
```
Will show up to date runtime status about the pod and containers.

```sh
./pod download [-f|--force]
# return 0 on success
# return 1 on error
```
For a container pod this means to pull all images.  
If -f option is set then always pull for updated images, even if they already exist locally.  

For an executable pod it could mean to download and install packages needed to run the service.

```sh
./pod create [--host-interface=]
# return 0 on success
# return 1 on error
```
For a container pod it will create the pod-container, daemon process and the volumes.

For an executable pod it might not do anything.

This is an idempotent command.

```sh
./pod start
# return 0 on success
# return 1 on error
```
For a container pod it will start the pod, as long as it has been created first and is not running.

For an executable pod it will start the process, as long as it is not already started.

```sh
./pod stop
# return 0 on success
# return 1 on error
```
For a container pod it will stop the pod and all containers.

For an executable pod it will gracefully stop the process.

```sh
./pod kill
# return 0 on success
# return 1 on error
```
For a container pod it will kill the pod and all containers.

For an executable pod it will forcefully kill the process.

```sh
./pod run [--host-interface=]
# return 0 on success
# return 1 on error
```
For container pods this command makes sure all containers are in the running state. It creates and starts the pod and containers if necessary.

For executables they need to understand if their process is already running and not start another one else start the process and keep the PID somewhere.

```sh
./pod rerun [--host-interface=] [-k|--kill] [container1 container2 etc]
# return 0 on success
# return 1 on error
```
For container pods, first stop, then remove and then restart all containers.  
Same effect as issuing rm and run in sequence.  
If container name(s) are provided then only cycle the containers, not the full pod.  
If -k flag is set then pod will be killed instead of stopped (not valid when defining individual containers).

For executables, stop the current process and start a new one.

```sh
./pod signal [container1 container2 etc]
# return 0 on success
# return 1 on error
```
Send a signal to one, many or all containers.  
The signal sent is the SIG defined in the containers YAML specification.  
Invoking without arguments will invoke signals all all containers which have a SIG defined.

For executables, signal the process.

```sh
./pod create-volumes
# return 0 on success
# return 1 on error
```
For a containers pod create all volumes used by this pod.  

For an executable pod it can mean something similiar such as provisioning storage space.

```sh
./pod reload-configs config1 [config2 config3 etc]
    When a "config" has been updated on disk, this command is automatically invoked to signal the container who mount the specific config(s).
    It can also be manually run from command line to trigger a config reload.
    Each container mounting the config will be signalled as defined in the YAML specification.
# return 0 if successful
# return 1 if pod does not exist or if pod is not running.
```
For containers pods this means that containers who mount the configs will be notified about changes.

For executable pods it becomes implementation specific what it means.

```sh
./pod rm [-k|--kill]
# return 0 if successful
```
For container pods stop and destroy all pods, leave volumes intact.  
If the pod and containers are running they will be stopped first and then removed.  
If -k flag is set then containers will be killed instead of stopped.

For executable pods clean up any lingering files which are temporary.

```sh
./pod purge
# return 0 if successful
```
For container pods which are non existing, remove all volumes associated.

For executable pods remove all traces of activity, such as log files.


```sh
./pod shell -c container|--container= [-b|--bash] [-- commands]
# return 0 if successful
```

Open interactive shell inside container. If -b option is provided force bash shell.
If commands are provided run commands instead of opening interactive shell.


```sh
./pod create-ramdisks [-l|--list] [-d|--delete]
        If run as sudo/root create the ramdisks used by this pod.
        If -d flag is set then delete existing ramdisks, requires sudo/root.
        If -l flag is provided list ramdisks configuration (used by external tools to provide the ramdisks, for example the Simpleneted Daemon `simplenetesd`).
        If ramdisks are not prepared prior to the pod starting up then the pod will it self
        create regular directories (fake ramdisks) instead of real ramdisks. This is a fallback
        strategy in the case sudo/root priviligies are not available or if just running in dev mode.
        For applications where the security of ramdisks are important then ramdisks should be properly created.
# return 0
# stdout: disk1:10M
          disk2:2M
          etc
```
Output the ramdisks configuration for the pod.
A newline separated list of tuples describing to the Daemon what ramdisks it is expected to create: [name:size].
Ex: "tmp1:10M\ntmp2:5M"

Note that if ramdisks have not been created prior to starting the pod, they pod is expected to gracefully handle this by creating regular directories which is can use instead of provided ramdisks.

```sh
./pod logs [containers] [-p|--daemon-process] [-t timestamp|--timestamp=] [-l limit|--limit=] [-s streams|--stream=] [-d details|--details=]  
    Output logs for one, many or all [containers]. If none given then show for all.  
    -p Show pod daemon process logs (can also be used in combination with [containers])  
    -t timestamp=UNIX timestamp to get logs from, defaults to 0  
       If negative value is given it is seconds relative to now (now-ts).  
    -s streams=[stdout|stderr|stdout,stderr], defaults to \"stdout,stderr\".  
    -l limit=nr of lines to get in total from the top, negative gets from the bottom (latest).  
    -d details=[ts|name|stream|none], comma separated if many.  
        if \"ts\" set will show the UNIX timestamp for each row.  
        if \"age\" set will show age as seconds for each row.  
        if \"name\" is set will show the container name for each row.  
        if \"stream\" is set will show the std stream the logs came on.  
        To not show any details set to \"none\".  
        Defaults to \"ts,name\".  
# return 0
# stdout: logs
```
