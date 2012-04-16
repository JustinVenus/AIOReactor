#!/usr/bin/python

from _portpoll import *
import os
try:
    import fcntl
except ImportError:
    fcntl = None

#borrowed from twisted
def setNonBlocking(fd):
    """
    Make a file descriptor non-blocking.
    """
    flags = fcntl.fcntl(fd, fcntl.F_GETFL)
    flags = flags | os.O_NONBLOCK
    fcntl.fcntl(fd, fcntl.F_SETFL, flags)


def write_some_data(fd, data):
    print ">"*80
    os.write(fd, data)

def read_some_data(fd):
    print "<"*80
    print os.read(fd, 8192)

foo = open('/tmp/test.txt', 'w')
bar = open('/tmp/test.txt', 'r')

setNonBlocking(foo.fileno())
setNonBlocking(bar.fileno())
#open foo first so the fd will be 3, makes debug easier
x = port()

data = [
    'this is a test\n',
    'this is only a test\n',
    'stop testing\n',
]

#add a writer
x.add(PORT_FD, foo.fileno(), PORT_POLLOUT)
x.add(PORT_FD, bar.fileno(), PORT_POLLIN)
#read_some_data(bar.fileno())

while data:
    results = x.poll(1)
    for evt,src,obj,user in results:
        print user
        if src != PORT_FD:
            print "Got unexpected source"
            continue
        if evt in (PORT_POLLWRNORM,PORT_POLLWRBAND):
            write_some_data(obj, data.pop(0))
            x.add(src, obj, evt, user) 
        elif evt in (PORT_POLLRDNORM,PORT_POLLRDBAND,PORT_POLLIN):
            read_some_data(obj)
            x.add(src, obj, evt, user) 

x.remove(PORT_FD, foo.fileno(), PORT_POLLOUT)
x.remove(PORT_FD, bar.fileno(), PORT_POLLIN)

foo.close()
bar.close()
x.close()
