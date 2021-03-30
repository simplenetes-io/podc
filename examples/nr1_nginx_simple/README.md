# Simple nginx example

In this example we show the simplest way of running a pod with exposed ports.

The vanilla nginx image serves as the container to run since it does present a welcome page by default and needs no further configurations.

```sh
podc
./pod run
./pod ps
curl 127.0.0.1:8080
./pod logs
./pod rm
```
