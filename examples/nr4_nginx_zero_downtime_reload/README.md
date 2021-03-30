# nginx example showing how to reload nginx without any downtime

When updating the `nginx.conf` file we have to send the nginx process a `HUP` signal to have it pick up the changes, without resorting to restarting the process.

With Simplenetes `podc` we can specify signals for containers and send those signals by calling `pod signal [container]`.

```sh
podc
./pod run
./pod ps
curl 127.0.0.1:8080
# Try changing some aspact of the nginx.conf file then run:
./pod signal
# nginx.conf will now have been reloaded.
./pod rm
```
