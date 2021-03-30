# nginx example showing how leverege configs

In the last example we saw how to reload the `nginx.conf` file with zero downtime.

Here we will see a similar example but we are using a Simplenetes concept called `configs` to get a unified experience which also works when running the pod inside a Simplenetes cluster to automatically get the zero downtime reload feature when updating configs.

A `config` is a special volume type in Simplenetes which actually is a `host` type but with some extra functionality to it.

Config files must be located in a sub directory to the `config` directory in the pod dir. That sub directory is the name of the config.

We will put our nginx files there. In normal cases we don't put content inside configs, just small things such as config files and secrets.

We specify the `HUP` signal for the nginx container, so that the pod knows how to signal the container when the config is to be reloaded.


```sh
podc
./pod run
./pod ps
curl 127.0.0.1:8080
# Try changing some aspact of the nginx.conf file then run:
./pod reload-configs nginx_files
# nginx.conf will now have been reloaded.
./pod rm
```

This looks very similar to the previous example when we ran `pod signal` instead, however leveraging configs scales better and reloading configs will make sure all containers dependent on the config will get signalled.

Also when putting the pod inside a cluster the reloading part comes for free.

## Secrets
Providing secrets, such as API keys for a process is often crucial to have it working. However such secrets should not be stored within the image it self, both for security reasons but also that secrets might change over time, sometimes more rapidly than we want to release new versions of the pod.

Simplenetes offers a neat way of managing secrets by providing them to the pod as _configs_. Since configs have a nice trait of automatically signalling containers depending on them when they are updated they can be an excellent choice for secrets.

Secrets can be encrypted by Simplenetes to increase security even more when running inside a cluster, however encryption of secrets is not yet supported.
