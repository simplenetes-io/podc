# nginx example with logs stored on volumes

In this example we will see how we can use podman volumes to store container logs elsewhere than in the pod directory.

All `stdout` and `stderr` for all containers and the pod daemon management process are stored in the directory `./log` and are accessible with the `pod logs` command.

However, we might want to redirect the nginx access log to be stored on a volume instead, which can make it accessible to monitoring tools, for example.

We do this by using a `volume` with `type: volume`, which we `mount` into the container at a specific directory. To this directory we point the nginx access log.

```sh
podc
./pod run
./pod ps
curl 127.0.0.1:8080

# Getting the pod logs will not show the access log
./pod logs

# We'll get the access log by accessing the volume. For example via the pod it self since it already has the volume mounted.
./pod shell -c nginx -- tail -f /mnt/access_log/access.log

./pod rm
```
