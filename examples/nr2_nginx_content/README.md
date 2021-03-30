# nginx example with content mounted from host

In this example we will see how to mount content from disk into a nginx container.

We do this by using a `volume` with `type: volume`, which we `mount` into the container at a specific directory, to where we point the nginx logs to be stored.

```sh
podc
./pod run
./pod ps
curl 127.0.0.1:8080
./pod logs
./pod rm
```
