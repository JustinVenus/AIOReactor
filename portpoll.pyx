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
import time

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

    cdef extern int port_create()

    # actually defined in "sys/port.h"
    ctypedef struct port_event_t:
        int             portev_events  # event data is source specific
        unsigned short  portev_source  # event source
        unsigned short  portev_pad     # port internal use
        unsigned int    portev_object  # source specific object
        void            *portev_user   # user cookie

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

DEF DEBUG = 1
cdef extern void debug(object message):
    """debug message printer"""
    IF DEBUG == 0: return
    msg = "<<DEBUG>> " + str(message) + "\n"
    cdef char *output
    output = <bytes>msg
    printf(output)

cdef class port:
    """
    Represent a set of file descriptors being monitored for events.

    Note: There is a hard limit of 8192 monitored sources per port object.
    """

    cdef int fd
    cdef int initialized

    def __init__(self):
        # hard max per port is 8192 monitored sources.
        self.fd = port_create()
        if self.fd == -1:
            raise IOError(errno, strerror(errno))
        self.initialized = 1
        debug("port initialized")

    def __dealloc__(self):
        if self.initialized:
            close(self.fd)
            self.initialized = 0
        debug("port deallocated")

    def close(self):
        """
        Close the port file descriptor.
        """
        if self.initialized:
            if close(self.fd) == -1:
                raise IOError(errno, strerror(errno))
            self.initialized = 0
            debug("port closed")

    def fileno(self):
        """
        Return the port file descriptor number.
        """
        return self.fd

    def add(self, int src, int fd, int events, object uobject=None):
        """
        Monitor a particular file descriptor's state.
        
        Wrap port_associate(3C).

        @type src: C{int}
        @param src: One of PORT_FD, PORT_AIO, PORT_MQ, PORT_TIMER,
          PORT_USER, PORT_ALERT, or PORT_FILE.

        @type fd: C{int}
        @param fd: File descriptor to modify

        @type events: C{int}
        @param events: A bit set of POLLIN, POLLPRI, POLLOUT, POLLERR, 
          POLLHUP, POLLNVAL, POLLNORM, POLLRDNORM, POLLWRNORM, 
          POLLRDBAND, and POLLWRBAND.

        @type uobject: C{object} [default=None]
        @param uobject: A user defined object to follow the event

        @raise IOError: Raised if the underlying port_associate() call fails.
        """
        debug("called ``add``")
        cdef PyObject *user
        cdef void *ud
        ud = NULL # assume None by default
        if uobject:
            user = <PyObject *>uobject
            ud = <void *>user
        cdef int result
        result = port_associate(self.fd, src, fd, events, ud)
        if result == -1:
            raise IOError(errno, strerror(errno))
        return result

    def remove(self, int src, int fd, int events):
        """
        Unmonitor a particular file descriptor's state.
        
        Wrap port_dissociate(3C).

        @type src: C{int}
        @param src: One of PORT_FD, PORT_AIO, PORT_MQ, PORT_TIMER,
          PORT_USER, PORT_ALERT, or PORT_FILE.

        @type fd: C{int}
        @param fd: File descriptor to modify

        @type events: C{int}
        @param events: A bit set of POLLIN, POLLPRI, POLLOUT, POLLERR, 
          POLLHUP, POLLNVAL, POLLNORM, POLLRDNORM, POLLWRNORM, 
          POLLRDBAND, and POLLWRBAND.

        @raise IOError: Raised if the underlying port_dissociate() call fails.
        """
        debug("called ``remove``")
        cdef int result
        result = port_dissociate(self.fd, src, fd)
        if result == -1:
            raise IOError(errno, strerror(errno))
        return result

    cdef unsigned int _peek(self, timespec *timeout):
        """
        A private C Method that provides the number of ready events.

        Wrap port_getn(3C).

        Note: This does not modify/de-queue any event state.

        @type timeout: <timespec *>
        @param timeout: A required structure for the underlying api call

        @type return: <unsigned int>
        @return: Returns the number of pending events.
        """
        debug("called ``peek``")
        cdef unsigned int nget = 0
        cdef int maxevents = 0
        cdef int result
        # The max parameter specifies the maximum number of events that 
        # can be returned in list[]. If max is 0, the value pointed to 
        # by nget is set to the number of events available on the port. 
        # The port_getn() function returns immediately but no events are
        # retrieved. So why is this important? Well it allows us to check
        # for events and break early as opposed to waiting for a timeout.
        result = port_getn(self.fd, NULL, maxevents, &nget, timeout)
        # Note: 32-bit port_getn() on Solaris 10 x86 returns large negative
        # values instead of 0 when returning immediately.
        if result == -1:
            raise IOError(errno, strerror(errno))
        return nget #number of pending results

    def poll(self, unsigned int tv_sec, unsigned int tv_nsec=0):
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
        timeout.tv_nsec = tv_nsec
        # let's see if there is anything worth waiting for
        cdef unsigned int nget = self._peek(&timeout)
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
        debug("allocating")
        size = sizeof(port_event_t *) * maxevents
        cdef port_event_t *_list = <port_event_t *>malloc(size)
        debug("allocated")

        if _list is NULL:
            raise MemoryError()
        
        try:
            debug("saving state")
            _save = PyEval_SaveThread()
            # so we can double check that an event was returned
            for i from 0 <= i < maxevents: 
                _list[i].portev_user = <void *>-1

            result = port_getn(self.fd, _list, maxevents, &nget, &timeout)
            PyEval_RestoreThread(_save)
            debug("state restored")

            if result == -1:
                # This confusing API can return an event at the same time
                # that it reports EINTR or ETIME.  If that occurs, just
                # report the event.  With EINTR, nget can be > 0 without
                # any event, so check that portev_user was filled in.
                if (errno != EINTR) and (errno != ETIME):
                    raise IOError(errno, strerror(errno))
                debug("problem")
            i = 0 #reset counter
            results = []
            debug("entering")
            for i from 0 <= i < nget:
                debug("retrieving element %d" % i)
                user = None # assume no user object in result
                # by default we set this to NULL during ``add`` method
                if _list[i].portev_user is not NULL:
                    # this means our event was not pulled as expected
                    # port_getn was probably interupted by a signal.
                    if _list[i].portev_user == <void *>-1:
                        debug("skipping interation")
                        continue
                    # Woot we have a python object to recover!!!
                    user = <object>_list[i].portev_user
                    debug(user)
                debug("retrieving associated object %s" % str(user))
                # get event, source, and source specific object
                evt = _list[i].portev_events # event type
                src = _list[i].portev_source # source type
                obj = _list[i].portev_object # FD, AIO, FILE, TIMER, MQ .. etc
                # repair filedescriptor representation
                if src == PORT_SOURCE_FD:
                    obj = int(obj) # convert long to python int
#TODO use this section for handling PORT_SOURCE_AIO in the future

                # ex. (POLLIN, PORT_FD, 4, None)
                results.append((evt, src, obj, user))
            debug("returning")
            return results
        finally:
            debug("calling free")
            free(_list)


PORT_POLLIN = POLLIN
PORT_POLLPRI = POLLPRI
PORT_POLLOUT = POLLOUT

PORT_POLLERR = POLLERR   # error
PORT_POLLHUP = POLLHUP   # hangup error
PORT_POLLNVAL = POLLNVAL # invalid
PORT_POLLNORM = POLLNORM

PORT_POLLRDNORM = POLLRDNORM
PORT_POLLWRNORM = POLLWRNORM
PORT_POLLRDBAND = POLLRDBAND
PORT_POLLWRBAND = POLLWRBAND

# potential sources
PORT_AIO = PORT_SOURCE_AIO     # struct aiocb
PORT_FD = PORT_SOURCE_FD       # file descriptor
PORT_MQ = PORT_SOURCE_MQ       # mqd_t
PORT_TIMER = PORT_SOURCE_TIMER # timer_t
PORT_USER = PORT_SOURCE_USER   # unintptr_t/unsigned int
PORT_ALERT = PORT_SOURCE_ALERT # unitptr_t/unsigned int
PORT_FILE = PORT_SOURCE_FILE   # file_obj_t
