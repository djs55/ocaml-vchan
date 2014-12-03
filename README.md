This is an implementation of the "libvchan" or "vchan" communication
protocol in OCaml. It allows fast communication anywhere where there is

- a memory sharing primitive
- an event signalling primitive
- a method of sharing configuration data

We provide two CLI tools as examples:

1. `unixcat`: uses Unix domain sockets for signalling; mmap(2) for
   shared memory; and Unix environment variables for configuration
2. `xencat`: uses Linux /dev/xen/evtchn for signalling; Linux gntdev
   and gntshr for shared memory; and Xenstore for configuration

Example: communicate between two Unix processes
-----------------------------------------------

In one terminal we can create a server process (note the domain id 2
and port "foo" are currently ignored):

```sh
$ ./unixcat.native -l 2 foo
XEN_ROOT=/tmp/unixcat.native.28585.0; export XEN_ROOT;
XEN_CONFIGURATION="((ring_ref 0) (event_channel /tmp/unixcat.native.28585.0/0))"; export XEN_CONFIGURATION
```

The CLI prints (to stderr) a pair of environment variables. These lines
should be cut 'n pasted into another terminal and then the client can
be run:

```sh
$ XEN_ROOT=/tmp/unixcat.native.28585.0; export XEN_ROOT;
$ XEN_CONFIGURATION="((ring_ref 0) (event_channel /tmp/unixcat.native.28585.0/0))"; export XEN_CONFIGURATION
$ ./unixcat.native 2 hello
Connected.
hello
there
Disconnected.
```

Example: communicate between two Xen domains
--------------------------------------------

First make sure your systems are properly configured. You may need to:
```
sudo modprobe xen-evtchn
sudo modprobe xen-gntdev
sudo modprobe xen-gntalloc
mount -t xenfs xenfs /proc/xen
```

On both of your VMs, find their domain ids:
```sh
xenstore-read domid
```

On the domain with domid ```<server domid>```, listen for a single connection from
`<client domid>` on `<port>`:

```sh
xencat -l <client domid> <port>
```

On the domain with domid `<client domid>`, connect to `<server domid>`:

```sh
xencat <server domid> <port>
```

So to transfer a file `foo` from domid 1 to domid 2:

On domain 2, listen for the connection and retrieve the file:

```sh
xencat -l 1 foo > copy-of-foo
```

On domain 1, transmit the file:

```sh
cat foo | xencat 2 foo
```

