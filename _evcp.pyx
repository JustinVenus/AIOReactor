# Copyright (c) 2001-2012 Twisted Matrix Laboratories.
# See LICENSE for details.

"""
Interface to port I/O event notification facility.
"""

# NOTE: This interface is for Solaris 10+ and more than likely you will
# have to compile it with the official proprietary cc compiler that is
# provided as an addon from the OS vendor's website.  If you built python
# with gcc then you may use gcc to compile this module.  Don't mix and
# match compilers on Solaris, you've been warned.

# NOTE: This was developed using Cython-0.15.1. -jvenus

# TODO: Discuss implementation of POSIX AIO with the twisted community.
# I have some ideas on how epoll, kqueue, and portpoll reactors could
# make shared use of the AIO POSIX implementation for FILE I/O based on
# what this interface has taught me. -jvenus

# FIXME for some unexplained reason, this module segfaults if the
#   time module is not imported prior to the instantiation of ``port``.
#   this is really bothering me as I see know indication on why that
#   would matter.  A segv should happen reguardless if there is a
#   memory error somewhere.

cdef extern from "sys/time.h":
    cdef struct timespec:
        long tv_sec
        long tv_nsec

cdef extern from "sys/poll.h":
    enum: POLLIN
    enum: POLLPRI
    enum: POLLOUT
    enum: POLLRDNORM
    enum: POLLWRNORM
    enum: POLLRDBAND
    enum: POLLWRBAND
    enum: POLLNORM
    enum: POLLERR
    enum: POLLHUP
    enum: POLLNVAL

cdef extern from "port.h":
    # man -s 3C port_create
    enum: PORT_SOURCE_AIO   # struct aiocb
    enum: PORT_SOURCE_FD    # file descriptor
    enum: PORT_SOURCE_MQ    # mqd_t
    enum: PORT_SOURCE_TIMER # timer_t
    enum: PORT_SOURCE_USER  # unintptr_t/unsigned int
    enum: PORT_SOURCE_ALERT # unitptr_t/unsigned int
    enum: PORT_SOURCE_FILE  # file_obj_t

    # actually defined in "sys/siginfo.h"
    enum: SIGEV_PORT #For AIO support

    cdef extern int port_create()

    # actually defined in "sys/port.h"
    ctypedef struct port_event_t:
        int             portev_events  # event data is source specific
        unsigned short  portev_source  # event source
        unsigned short  portev_pad     # port internal use
        unsigned int    portev_object  # source specific object
        void            *portev_user   # user cookie

    ctypedef struct  port_notify:
        int             portnfy_port   # bind request(s) to port
        void            *portnfy_user  # user defined

    # man -s 3C port_get
    cdef extern int port_get(
        int port, port_event_t *pe, timespec *timeout
    )
    # man -s 3C port_getn
    cdef extern int port_getn(int port, port_event_t evts[], 
        unsigned int max, unsigned int *nget, timespec *timeout
    )
    # man -s 3C port_associate
    cdef extern int port_associate(int port, int source,
        unsigned int obj, int events, void *user
    )
    # man -s 3C port_dissociate
    cdef extern int port_dissociate(int port, int source, unsigned int obj)

cdef extern from "errno.h":
    cdef extern int errno
    cdef extern char *strerror(int)
    enum: EINTR
    enum: ETIME
    enum: ENOENT

cdef extern from "stdio.h":
    cdef extern void *malloc(int)
    cdef extern void free(void *)
    cdef extern int close(int)
    # was originally used for debugging
    cdef extern int printf(char *, ...)

cdef extern from "Python.h":
    ctypedef struct PyObject
    ctypedef struct PyThreadState
    cdef extern PyThreadState *PyEval_SaveThread()
    cdef extern void PyEval_RestoreThread(PyThreadState*)

# NOTE: This was only used during intial development
#   and it can probably be removed in the future.
cdef extern void debug(object message):
    """debug message printer"""
    msg = "<<DEBUG>> " + str(message) + "\n"
    cdef char *output
    output = <bytes>msg
    printf(output)

cdef class portpoll:
    """
    Represent a set of file descriptors being monitored for events.

    Note: There is a hard limit of 8192 monitored sources per port object.
    """

    cdef int port
    cdef int initialized

    def __init__(self):
        # hard max per port is 8192 monitored sources.
        self.port = port_create()
        if self.port == -1:
            raise IOError(errno, strerror(errno))
        self.initialized = 1

    def __dealloc__(self):
        if self.initialized:
            close(self.port)
            self.initialized = 0

    def close(self):
        """
        Close the port file descriptor.
        """
        if self.initialized:
            if close(self.port) == -1:
                raise IOError(errno, strerror(errno))
            self.initialized = 0

    def fileno(self):
        """
        Return the port file descriptor number.
        """
        return self.port

    def add(self, int fd, int events):
        """
        Monitor a particular file descriptor's state.
        
        Wrap port_associate(3C).

        Note: You may call this multiple times with different events.

        @type fd: C{int}
        @param fd: File descriptor to modify

        @type events: C{int}
        @param events: A bit set of PPOLLIN, PPOLLPRI, PPOLLOUT, PPOLLERR, 
          PPOLLHUP, PPOLLNVAL, PPOLLNORM, PPOLLRDNORM, PPOLLWRNORM, 
          PPOLLRDBAND, and PPOLLWRBAND.

        @raise IOError: Raised if the underlying port_associate() call fails.
        """
        cdef int result
        result = port_associate(self.port, PORT_SOURCE_FD, fd, events, <void*>0)
        if result == -1:
            raise IOError(errno, strerror(errno))
        return result

    def remove(self, int fd):
        """
        Unmonitor a particular file descriptor's state.
        
        Wrap port_dissociate(3C).

        @type fd: C{int}
        @param fd: File descriptor to modify

        @raise IOError: Raised if the underlying port_dissociate() call fails.
        """
        cdef int result
        result = port_dissociate(self.port, PORT_SOURCE_FD, fd)
        if result == -1:
            if errno != ENOENT:
                raise IOError(errno, strerror(errno))
        return result

    def peek(self):
        """
        A private C Method that provides the number of ready events.

        Wrap port_getn(3C).

        Note: This does not modify/de-queue any event state.

        @type timeout: <timespec *>
        @param timeout: A required structure for the underlying api call

        @type return: <unsigned int>
        @return: Returns the number of pending events.
        """
#        cdef timespec timeout
#        timeout.tv_sec = 0
#        timeout.tv_nsec = 0
        cdef unsigned int nget = 0
        cdef int maxevents = 0
        cdef int result
        # The max parameter specifies the maximum number of events that 
        # can be returned in list[]. If max is 0, the value pointed to 
        # by nget is set to the number of events available on the port. 
        # The port_getn() function returns immediately but no events are
        # retrieved. So why is this important? Well it allows us to check
        # for events and break early as opposed to waiting for a timeout.
        result = port_getn(self.port, NULL, maxevents, &nget, NULL)
        # Note: 32-bit port_getn() on Solaris 10 x86 returns large negative
        # values instead of 0 when returning immediately.
        if result == -1:
            raise IOError(errno, strerror(errno))
        return nget #number of pending results

    def poll(self, int tv_sec, unsigned int maximum):
        """
        Poll for an I/O event, wrap port_getn(3C).  If there are no
        events pending this method will return immediately.

        Note: PORT_FD sources must be re-associated using the method
          ``add`` when returned by this method.

        Note: Setting the tv parameters too low will result in an
          IOException(EFAULT, "timeout argument is not reasonable").
          a recommended minimum is 1 second.

        @type tv_sec: C{int} >= 0
        @param tv_sec: Number of seconds to wait for poll

        @type tv_nsec: C{int} >= 0 [default=0]
        @param tv_nsec: Number of nanoseconds to wait for poll

        
        @raise IOError: Raised if the underlying port_getn() call fails.
        """
        cdef timespec timeout
        timeout.tv_sec = tv_sec
        timeout.tv_nsec = 0
        # let's see if there is anything worth waiting for
        cdef unsigned int nget = maximum 
        # Set the max to the number we know we can get.
        cdef int maxevents = <int>nget # NOTE: hard max per port is 8192
        cdef size_t size = 0
        cdef int result = 0
        cdef PyThreadState *_save
        cdef int i = 0
       
        # just making it stand out 
        if not nget:
            return []

        # allocate memory based on the number of known pending events.
        _save = PyEval_SaveThread()
        size = sizeof(port_event_t *) * maxevents
        cdef port_event_t *_list = <port_event_t *>malloc(size)
        PyEval_RestoreThread(_save)

        if _list is NULL:
            return [] #fail silently
        
        try:
            _save = PyEval_SaveThread()
            # so we can double check that an event was returned
            for i from 0 <= i < maxevents: 
                _list[i].portev_user = <void *>-1

            result = port_getn(self.port, _list, maxevents, &nget, &timeout)
            PyEval_RestoreThread(_save)

            if result == -1:
                # This confusing API can return an event at the same time
                # that it reports EINTR or ETIME.  If that occurs, just
                # report the event.  With EINTR, nget can be > 0 without
                # any event, so check that portev_user was filled in.
                if (errno != EINTR) and (errno != ETIME):
                    raise IOError(errno, strerror(errno))
            i = 0 #reset counter
            results = []
            for i from 0 <= i < nget:
                # by default we set this to NULL during ``add`` method
                if _list[i].portev_user is not NULL:
                    # this means our event was not pulled as expected
                    # port_getn was probably interupted by a signal.
                    if _list[i].portev_user == <void *>-1:
                        continue
                # repair filedescriptor representation
                if _list[i].portev_source != PORT_SOURCE_FD:
                    continue
                results.append((int(_list[i].portev_object), int(_list[i].portev_events)))
            return results
        finally:
            free(_list)


PPOLLIN = POLLIN
PPOLLPRI = POLLPRI
PPOLLOUT = POLLOUT

PPOLLERR = POLLERR   # error
PPOLLHUP = POLLHUP   # hangup error
PPOLLNVAL = POLLNVAL # invalid
PPOLLNORM = POLLNORM

PPOLLRDNORM = POLLRDNORM
PPOLLWRNORM = POLLWRNORM
PPOLLRDBAND = POLLRDBAND
PPOLLWRBAND = POLLWRBAND

# potential sources
PAIO = PORT_SOURCE_AIO     # struct aiocb
PFD = PORT_SOURCE_FD       # file descriptor
PMQ = PORT_SOURCE_MQ       # mqd_t
PTIMER = PORT_SOURCE_TIMER # timer_t
PUSER = PORT_SOURCE_USER   # unintptr_t/unsigned int
PALERT = PORT_SOURCE_ALERT # unitptr_t/unsigned int
PFILE = PORT_SOURCE_FILE   # file_obj_t
