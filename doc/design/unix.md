Vchan as a Unix IPC mechanism
=============================

Let's make the simplifying assumption that both ends of the IPC are running
under the same uid.

We need to satisfy the signatures

- S.CONFIGURATION: the ability to share configuration data between processes
  for bootstrapping
- S.MEMORY: the ability to grant read/write and read/only access to
  buffers to foreign processes
- S.EVENTS: the ability to notify another process that data is available

S.CONFIGURATION
---------------

We can replace Xenstore with the Unix filesystem. We could use either a
module parameter (driven e.g. from the command-line) or an environment
variable to nominate a shared "xenstore root" directory.

S.EVENTS
--------

We can create a tuple of
- a listening Unix domain socket
- an integer counter
- a mutex
- a condition variable.
We could advertise the path as the 'port'. The client can connect to this
port by connecting to our socket. Notify could be 'send one byte'; and a
background thread could read this byte, increment the counter and signal 
on the conditional variable. Wait could be 'use the condition variable to
wait for the counter to increase'.

On Linux this could probably be replaced with eventfd.

S.MEMORY
--------

We could use System V shared memory (shmget, shmat, shmdt etc). The 'key'
used to name a segment could be used as a grant reference. The key could
be derived from a path, which could be the "xenstore root" of the process
mentioned above.
 
