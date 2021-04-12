# Simplenetes Pod Compiler (podc)

`podc` takes a _Simplenetes_ Pod YAML [specification](PODSPEC.md) and turns it into a runnable standalone shell script.

The compiled shell script is a POSIX compliant shell script which manages the full pod life cycle. It uses `podman` (instead of Docker) to create and manage pods and containers in a root-less environment.

A Simplenetes pod is similar to a Kubernetes pod but is simpler. Simplenetes pods can be used on their own or within a [Simplenetes cluster](https://github.com/simplenetes-io/simplenetes).

`podc` is written in Bash.

## Features
podc features:

    - Standalone shell script to manage the full pod cycle
    - Uses podman for running root-less containers
    - Separates stdout and stderr logging, per container
    - Compile in dev mode to mount local directory while developing for quick iterations
    - Support for ramdisks to never put sensitive files on disk
    - Support for non interruptive config updates of processes running (say for updating haproxy.conf)
    - Step into a shell into any container in the pod
    - Signal some or all containers
    - Startup probes
    - Readiness probes
    - Liveness probes
    - Mount shared and private volumes
    - Small and easily understandable specification
    - Ingress configs if running in a Simplenetes cluster

## Examples

See [https://github.com/simplenetes-io/podc/tree/master/examples](https://github.com/simplenetes-io/podc/tree/master/examples) for more examples.

Quick example:  
```sh
cd examples/nginx
podc
./pod run
./pod ps
curl 127.0.0.1:8080
./pod logs
./pod rm
```

## How does this work?
The `podc` program (a bash script) parses the `pod.yaml` file and outputs a runnable shell script, which is the pod.

The yaml file can contain variables such as `${portHttp}`, which can be defined in the `pod.env` file and are then substituted in. Variables which are not in the `.env` file are read from environment.

The resulting `pod` file is embedded with shell script code to leverage `podman` to manage the full pod life cycle.

`podc` and it's `yaml processor` are both written in Bash, the resulting output is however in POSIX shell, so you can run the pod using `dash`, `ash`, `busybox ash`, etc, no bash needed.

Note: When podc is used by Simplenetes in a _cluster project_ it does it's own preprocessing and varibles are then not read from the pod's `.env` file nor from the environment but from the `cluster-vars.env` file only.

## But why?
`podc` and the `Simplenetes` cluster manager are both a reaction to the too much magic that Kubernetes packs.

`podc` was compiled using [space.sh](https://github.com/space-sh/space), which is your friend to make shell script applications.

## Install
`podc` is a standalone executable, written in Bash and will run anywhere Bash is installed.

Dependencies are:  
Optional dependecies used by the podman runtime to check if ports are busy prior to creating the pod:  
- `sockstat`, `netstat` or `lsof`.

`netstat` is commonly contained in the `net-tools` package and can be installed on Debian-based distributions as:  
```
sudo apt-get install -yq net-tools
```

The reason `podc` is written in Bash and not POSIX shell is that it has a built in YAML parser which requires the more feature rich Bash to run.
Even though `podc` it self is a standalone executable it requires a runtime template file for generating pod scripts. This file must also be accessible on the system.  
`podc` will look for the `podman-runtime` template file first in the same directory as it self (`./`), then in `./release` and finally in `/opt/podc`.  
The reason for that it looks in `./release` is because it makes developing the pod compiler easier.  

Check out the latest release [here](https://github.com/simplenetes-io/podc/releases/latest) or manually download it from the command line:
```sh
LATEST_VERSION=$(curl -L -s https://github.com/simplenetes-io/podc/releases/latest)
LATEST_VERSION=$(echo $LATEST_VERSION | sed -e 's/.*tag_name\=\([^"]*\)\&.*/\1/')
wget https://github.com/simplenetes-io/podc/releases/download/$LATEST_VERSION/podc
wget https://github.com/simplenetes-io/podc/releases/download/$LATEST_VERSION/podc-podman-runtime
chmod +x podc
sudo mv podc /usr/local/bin
sudo mv podc-podman-runtime /usr/local/bin
```

## Set up ssh-enabled VM for running
`podc` is for Linux only, run a VM if on any other OS.

```sh
./boot2podman_download_create_and_run.sh
```
