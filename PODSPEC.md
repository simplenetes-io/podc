# Simplenetes Pod specifications

## Naming
Pod names, container names and volume names must all match `a-z`, `0-9` and underscore `(_)`, and has to start with a letter.

Container names are internally always automatically suffixed with `-podname-version` as they are created with podman. When referring to a container when calling the pod script the suffix is not expected.

Volume names are internally always automatically suffixed with `-podname` as they are created with podman. Note that since they do not have the version in their suffix volumes with the same names are shared between different pod versions.

## Configs
A config directory in a pod is something which the pod can mount to a container. The config dirs in a pod repo can be `imported` into the cluster project and from there they are available to the pod after it is compiled.

Underscore prefixed dirs are copied to the cluster project but are then not copied to pod releases nor synced to hosts in cluster.
Such underscores configs are used as templates for the cluster projects, such as the `ingress pod's` templates `(_tpl/)` for haproxy configuration snippets.

## Probes
There are three different probe supported:

    - Startup probes
    - Readiness probes
    - Liveness probes

All probes run a command in the container to determine if the probe was successful or not. The startup probe can also wait for a clean exit (code 0) of the container and consider it a successful startup.

Each probe has a timeout for how long the command or the repeated invocations (for startup) of the command is allowed to take.

A probe is always run inside the container, so when wanting to do TCP/HTTP probes, that would mean that `curl`, `wget` or `netcat` needs to be installed in the container for the probe to be able to run.

Simplenetes does not define a special case for command, HTTP or TCP probes, it is all command probes, and they all run inside the containers.

If needing to delay the Liveness probe then use a Startup probe to either determine that livenss is safe to run now or which simply sleeps a number of seconds before letting the pod creation continue.

## Proxy and Ingress confs
When a Pod is compiled, the compiler outputs alongside the `pod` executable possibly two extra files.  
These files only make sense when using pods not as standalone pods but within the Simplenetes pod orchestrator.

    - pod.proxy.conf
        A conf file which describes the clusterPort->HostPort relations for the Pod, and some more.
        Each entry is as:
        clusterPort:hostPort:maxConn:sendProxy
        This file is later accessed by the `snt` project manager when finding new unused host ports to delegate when
        compiling.
        Also the `sntd` accesses this file to configure the host-global `proxy.conf` file, so that
        internal routing works.
        This file is synced to the cluster together with the pod executable.

    - pod.ingress.conf
        A conf file which describes the ingress configuration for the compiled pod.
        This file is used only by the `snt` project manager when generating the ingress configuration for the ingress pod.
        This file is not synced to the cluster.

## The Simplenetes pod YAML specification
There are a couple of different types of Pods supported so far in Simplenetes.

    - Container Pods (using podman)
        These are what most people refer to as pods, a collection of containers on the same network.
        Just as Kuberenetes Pods.
    - Process Pods
        These are single executables which conform to the Pod API

Very important to note is the the `podc` yaml interpretor has a few restrictions compared to other yaml
processors (because it is implemented in Bash). The most notable is that lists *must be intended*.
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
# For the podcompiler to know what the yaml structure is supposed to look like
apiVersion: 1.0.0-beta1

# The current version of this pod. This is used by Simplenetes project management to distinguish different version of the same pod from eachother.
# It is also suffixed to the pod name, so that pod instances of different version will not collide.
# Must be on semver format: major.minor.patch[-tag]
podVersion: 0.0.1

# For container pods, podman is the only supported runtime as for now.
podRuntime: podman

# Define the volumes which this pod can use.
volumes:
    # Ramdisk volumes can be created
    - name: tmpstorage
      type: ramdisk
      size: 10M

    # Config volumes are host bind volumes, mounting the corresponding directory in ./config
    # This is good to use for configurations, but not for secrets.
    # When the files have changed on disk, the containers(s)
    # mounting this volume can be signalled by `pod reload-configs config1 config2 etc`. This will signal each container
    # that have signal defined and is currently Up.
    # If the container is not Up then the restart-policy decides if a config update restarts the container.
    - name: config1
      type: config

    # This config is special since it has defined it is encrypted, this is how Simplenetes manages secrets.
    # What happens behind the scenes is that there is expected to be a config name "my-secret", which will
    # be mounted into a new container which role is is decrypt the configurations and store the result in a automatically
    # created ramdisk.
    # Any user container mounting this specific config will actually be mounting that ramdisk instead, where it can find the
    # unencrypted secret.
    # New new "decrypter container" runs a specific image (simplenetes/secret-decrypter:1.0) which responsibility it is to
    # fetch the decryption key for the secret from a vault and decrypt the config and store in on the ramdisk.
    # Exactly how this is to be implemented is WIP.
    # The user container mounting this secret ramdisk will not get signalled when the underlaying config is updated, but it
    # will get signalled by the "decrypter container" as it becomes ready (if this container has a signal defined) so it can re-read the unencrypted secret.
    - name: my-secret
      type: config
      encrypted: true

    # A podman managed volume.
    - name: log
      type: volume

    # Mount directory/device on host
    # If the bind given is relative then it will be made absolute relative for the current working directory ($PWD),
    # using relative bind paths are useful for dev mode workflows when mounting local build directories.
    # The basedir can be overridden by compiling with the -d option.
    - name: extradisk
      type: host
      bind: /dev/sda1

containers:
    # Each container has name, which be suffixed by the podname.
    - name: hello

      # Image, podman will try a few different registries by default.
      image: kitematic/hello-world-nginx

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

      # Define environment variables which will be accessible to the container.
      env:
          - name: WARP_SPEED
            value: activated

      # Restart policy for when a container exits:
      # always (no matter exit code restart container)
      # on-config (restart when config files on disk are changed or when container exited with error code)
      # on-interval:x (as on-config, but also restart on successful exists after x seconds have passed)
      # on-failure (restart container when exit -ne 0)
      # never (never restart container)
      restart: on-interval:10

      # Define how this container is signalled, optional.
      # A container can get get 1) signalled by other containers 2) signalled by the daemon on configuration changes or 3) from cmd line.
      # 1) A container which defines `startupProbe/signal` and a list of `- name: container` will when ready signal all those
      #    containers which are defined, if those containers have a `signal` defined.
      # 2) If a container mounts a config and a `reload-configs` command is issued for that specific config,
      #    the container will then be signalled according to it's signal.
      # 3) By calling the pod executable `./pod signal [container1 container2 etc]`
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
          # This container will not get signalled nor restarted when the underlaying config is updated,
          # however it will get signalled by the "decrypter-container" when it is finished decrypting the config,
          # because the decrypter container will get restrarted when the underlaying config changes and that will eventually signal this container when it exits.
          - dest: /mnt/my-secret
            volume: my-secret

      # Startup probe of the container.
      # The pod startup process will not continue until a container is started up.
      # Note that a successful startup could mean that the container started and then exited with code 0.
      # If a container fails to startup properly in the pod creation phase then the pod will be destroyed, this also includes if there is a startup probe which fails.
      # If there is no startup probe then the startup is counted as suceesful as soon as the container has been started.
      # If a container fails to startup later it will be destroyed and restarted according to its restart policy.
      startupProbe:
          # Wait max 60 seconds for the container to be ready. Default is 120.
          # The pod executable sleeps 1 second between invoking the command and will abort the startup after timeout is reached.
          timeout: 60

          # Set to true to wait for the container to exit with code 0. When the container has exited is is treated as started and ready.
          # Any other exit code will fail the startup process.
          # The exit probe is exclusively for the startupProbe (not for readiness/liveness probes)
          exit: false

          # Or, define a command to be run inside the container to determine when the container has started up properly.
          # Each argument as a separate list item
          cmd:
              - sh
              - -c
              - '[ -e "/tmp/$USER/ready" ] || [ -e "/home/$USER/ready" ]'

          # Note that `exit and `cmd` are mutually exclusive to each other.
          # If none of them are defined then the container is treated as successfully started as soon as the container is started.
          # If wanting to run HTTP GET or TCP socket connection tests to determine the startup state, see the docs for how to do that.

          # Define under `signal` which other containers shall we signal that we have started successfully.
          # Only containers which are Up will get signalled. When Pod is starting up fresh then only containers defined above this container can possibly be Up and therefore get signalled.
          # However, if the container is restarted then all containers defined under `signal` will get signalled (regardless the definition order) if the startup was successful and target containers are Up.
          # Containers to be signalled must of course have defined the `signal` property, otherwise the signalling is ignored.
          signal:
              - container: hello
              - container: secret

      # Check to determine if the container is ready to recieve traffic.
      # This check is valid to run during the whole pod lifecycle.
      # If any test fails then the daemon will not include this pod in the proxying of traffic.
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
      # This check is valid to run during the whole pod lifecycle, but only after the startupProbe (if any) is finished.
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
          # This first configuration is simply to expose a container port on the host

          # targetPort is the port the process in the container is listening on.
          # Required if using clustertPort.
          - targetPort: 80

            # hostPort is the what port of the node host machine we bind the container part to.
            # Required if using clustertPort.
            # In the context of a snt cluster hostPort can be assigned as `${HOSTPORTAUTOx}` and a unique host port will be assigned. The `x` is an integer meaning that if `${HOSTPORTAUTO1}` is used in two places in the yaml the same host port value will be substituted in.
            hostPort: 8081

            # Maximum connection count which the proxy will direct to this targetPort
            # Only relevant when using a clusterPort
            # Default is 4096
            maxConn: 1024

            # Set to true to have the proxy connect using the PROXY-PROTOCOL
            # Only relevant when using a clusterPort
            # Default is false.
            sendProxy: true

          ## Second configuration is to map a clusterPort to the expose and also to configure Ingress details.
          - targetPort: 80
            hostPort: 8080

            # This is a TCP port in a given range which is cluster wide.
            # Anywhere in the cluster a pod can connect to this targetPort by connecting to this clusterPort on a proxy.
            # Optional property, but required when wanting to route traffic within the cluster to the targetPort, either from other Pods or from the Ingress.
            # Only relevant when using pods in a cluster orchestrated by Simplenetes.
            # In the context of a snt cluster clusterPort can be assigned as `${CLUSTERPORTAUTOx}` and a unique cluster port will be assigned. The `x` is an integer meaning that if `${CLUSTERPORTAUTO1}` is used in two places in the yaml the same cluster port value will be substituted in.
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

                # Redirect traffic to https, this does not require a backend answering any connections.
                redirectToHttps: true

                # Redirect all traffic to another location.
                redirectLocation: https://domain/path

                # Serve an errorfile from HAProxy.
                # The format is HTTP_ERROR_CODE FILEPATH.
                # This can be used as a fallback with a low importance to become active when another pod with same ingress rules
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

                # Match on full path, not include query parameters. Exlusice to pathBeg and pathEnd.
                path: /admin/ /superuser/

                # A higher importance makes this match earlier in the Ingress. Default is 100.
                importance: 101
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
apiVersion: 1.0.0-beta1

# Manage a single executable
podRuntime: executable

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
          # Only relevant when using a clusterPort
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
Will show version information as: `podRuntime: podman 0.1\npodVersion: version\n`. Where podRuntime is `podman`, `executable`, etc and followed the runtime impl. version.  
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
./pod status
# return 0 on success
# stdout: status data
# return 1 on error
```
Will show up to date runtime status about the pod.

```sh
./pod download
# return 0 on success
# return 1 on error
```
For a container pod this means to pull all images.  

For an executable pod it could mean to download and install packages needed to run the service.

```sh
./pod create
# return 0 on success
# return 1 on error
```
For a container pod it will create the pod-container and the volumes.

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
./pod run
# return 0 on success
# return 1 on error
```
For container pods this command makes sure all containers are in the running state. It creates and starts containers if necessary.

For executables they need to understand if their process is already running and not start another one else start the process and keep the PID somewhere.

```sh
./pod rerun
# return 0 on success
# return 1 on error
```
For container pods, first stop, then remove and then restart all containers.

For executables, stop the current process and start a new one.

```sh
./pod create-volumes
# return 0 on success
# return 1 on error
```
For a containers pod create all volumes used by this pod.  

For an executable pod it can mean something similiar such as provisioning storage space.

```sh
./pod reload-configs config1[ config2, etc]
# return 0 if successful
# return 1 if pod does not exist or if pod is not running.
```
For containers pods this means that containers who mount the configs will be notified about changes.

For executable pods it becomes implementation specific what it means.

```sh
./pod rm
# return 0 if successful
```
For container pods stop and destroy all pods, leave volumes intact.

For executable pods clean up any lingering files which are temporary.

```sh
./pod purge
# return 0 if successful
```
For container pods which are non existing, remove all volumes associated.

For executable pods remove all traces of activity, such as log files.

```sh
./pod readiness
# return 0 if ready
# return 1 if not ready
```
Check if this pod is ready to receive traffic.

For container pods the pod script will run the defined command.

For executable pods they need to understand themselves what "readiness" means and return 0 or 1.

```sh
./pod liveness
# return 0 always
```
Check so that the containers are still alive. Any container not responding properly will be killed, and it is then the subject of its restart policy.

For executable pods they need to understand themselves what "liveness" means and handle it appropriately.

```sh
./pod ramdisk-config
# return 0
# stdout: disk1:sizeM disk2:sizeM etc (ex: disk1:10M disk2:2M)
```
Output the ramdisks configuration for the pod.
A space separated list of tuples describing to the Daemon what ramdisks it is expected to create: [name:size].
Ex: "tmp1:10M tmp2:5M"

Note that if ramdisks have not been created prior to starting the pod, they pod is expected to gracefully handle this by creating regular directories which is can use instead of provided ramdisks.

```sh
./pod logs [channels since container1 container2]
# return 0
# stdout: logs
```

Check the status of the pod.
If the pod does not exists the result is "non-existent".
If it does exists and is in the "Created" state then the return is "created".
If it does exists and is in the "Running" state then the return is
    "not-ready", if not all containers return success on readiness
    "running", if all containers return success on readiness
    "broken", if
If the pod does exists and is in any other state state then the return is "stopped".

The status is calculated as 

```sh
./pod status
# return 0
# stdout: non-existent|created|downloading|not-ready|running|stopped
# readiness: true|false
# liveness: true|false
```
