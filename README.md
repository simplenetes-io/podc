# Simplenetes Pod Compiler (podc)

This Space Module compiles a Simplenetes Pod YAML specification into a runnable Pod.

A `runtime` is either `podman` or `executable`.

The `podman` runtime creates a container pod which is very similar to Kubernetes Pods with the difference that it is a standalone `pod` Posix compliant shell script which manages the pods lifecycle. This shell script uses `podman` to create and manage containers.

The `executable` runtime uses a single user provided executable which conforms to the Pod API and packages it as a pod.

See `PODSPC.md` for details about Pod Specifications.

See the `./examples` for examples on pod configurations.

## Preprocessing of pod.yaml files
The compiler reads an `.env` file alongside the pod yaml file to get variable values for the preprocessing of the pod.yaml file. Variables which are not in the `.env` file are read from environment.

Note: When the compiler is used by Simplenetes in a "cluster-project" it does it's own preprocessing and varibles are then not read from the pod's `.env` file nor from the environment but from the `cluster-vars.env` file only.

## Update the podc and podman runtime releases

This podman runtime release is what is "linked" by the compiler into the standalone `pod` script when using the `podman` runtime.

```sh
./make.sh
```

## Install the pod compiler onto your system
The `podc` executable needs to be in the path to be used with `sns` or to be used without `space`.

The `podman-runtime` file needs to either be relative to the `podc` file in `./` or in `./release/` else it must be in `/opt/podc/`.

## Try it out
```sh
./release/podc helloworld -f ./examples/nginx/hello-world.yaml

./examples/nginx/hello-world run
curl 127.0.0.1:8080
./examples/nginx/hello-world rm
```

## Set up ssh-enabled VM for running
```sh
./boot2podman_download_create_and_run.sh
```
