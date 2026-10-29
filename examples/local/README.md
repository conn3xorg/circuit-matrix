# Local example

Applies circuit-matrix to a throwaway Rocky Linux 10 container with systemd. You need Conn3x and Podman.

Synapse runs under Podman inside that container, so the host container is privileged, which is simplest with rootful Podman. On a Mac, use the Podman machine's root connection. On Linux, use `sudo podman`:

```sh
export CONTAINER_CONNECTION=podman-machine-default-root   # macOS
export PODMAN="sudo podman"                               # Linux
./up.sh
conn3x init
conn3x apply
conn3x plan
```

The first apply takes a few minutes: it installs Podman, pulls the Synapse image and creates the database. The second plan says `No changes.` To log in as the example's admin, whose password is `correct-horse-battery`, which you'd never keep on a real host:

```sh
ssh -p 2222 -i id_ed25519 -o UserKnownHostsFile=known_hosts root@127.0.0.1 \
  curl -s http://127.0.0.1:8008/_matrix/client/v3/login \
  -d "'"'{"type":"m.login.password","identifier":{"type":"m.id.user","user":"admin"},"password":"correct-horse-battery"}'"'"
```

The answer carries `"user_id":"@admin:matrix.test"` and an access token. Synapse only listens inside the container, on `127.0.0.1:8008`, as it would behind a reverse proxy.

`up.sh` listens on `127.0.0.1:2222`. Set `PORT` to use another port, and pass the same port to Conn3x with `-var port=PORT`. Set `CONTAINERFILE` to test another distro, such as one of the images in Conn3x's `test/images`, which CI uses.

`./down.sh` removes the container, its volumes, the key and the state.
