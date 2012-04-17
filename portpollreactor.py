# -*- test-case-name: twisted.test.test_internet -*-
# Copyright (c) Twisted Matrix Laboratories.
# See LICENSE for details.

"""
A portpoll() based implementation of the twisted main loop.

To install the event loop (and you should do this before any connections,
listeners or connectors are added)::

    from twisted.internet import portpollreactor
    portpollreactor.install()
"""

import errno

from zope.interface import implements

from twisted.internet.interfaces import IReactorFDSet

from twisted.python import log
from twisted.internet import posixbase, errno

from twisted.internet.main import CONNECTION_DONE, CONNECTION_LOST

from twisted.python import _portpoll

_NO_FILEDESC = error.ConnectionFdescWentAway('Filedescriptor went away')

#FIXME for Solaris 11 twisted-trunk
#class PortPollReactor(posixbase.PosixReactorBase, posixbase._PollLikeMixin):
#FIXME for Solaris 11 twisted-10.1.0
class PortPollReactor(posixbase.PosixReactorBase):
    """
    A reactor that uses portpoll(4).

    @ivar _poller: A L{poll} which will be used to check for I/O
        readiness.

    @ivar _selectables: A dictionary mapping integer file descriptors to
        instances of L{FileDescriptor} which have been registered with the
        reactor.  All L{FileDescriptors} which are currently receiving read or
        write readiness notifications will be present as values in this
        dictionary.

    @ivar _reads: A dictionary mapping integer file descriptors to arbitrary
        values (this is essentially a set).  Keys in this dictionary will be
        registered with C{_poller} for read readiness notifications which will
        be dispatched to the corresponding L{FileDescriptor} instances in
        C{_selectables}.

    @ivar _writes: A dictionary mapping integer file descriptors to arbitrary
        values (this is essentially a set).  Keys in this dictionary will be
        registered with C{_poller} for write readiness notifications which will
        be dispatched to the corresponding L{FileDescriptor} instances in
        C{_selectables}.
    """
    implements(IReactorFDSet)

    # Attributes for _PollLikeMixin
    _POLL_DISCONNECTED = (_portpoll.PPOLLHUP | _portpoll.PPOLLERR)
    _POLL_IN = _portpoll.PPOLLIN
    _POLL_OUT = _portpoll.PPOLLOUT

    def __init__(self):
        """
        Initialize portpoll object, file descriptor tracking dictionaries, and the
        base class.
        """
        # Create the poller we're going to use.  This reactor is similar to the
        # epollreactor that is available in Linux.  Unlike Epoll the Solaris
        # port interfaces require re-association of FD's after every event
        # is retrieved.  The Solaris implementation hints at the maximum
        # event per port at 8192 events.  The underlying implementation supports
        # POSIX AIO, but it is not exposed to the reactor at this time.
        self._poller = _portpoll.portpoll()
        self._reads = {}
        self._writes = {}
        self._selectables = {}
        posixbase.PosixReactorBase.__init__(self)


    def _add(self, xer, primary, other, selectables, event):
        """
        Private method for adding a descriptor from the event loop.

        It takes care of adding it if  new or modifying it if already added
        for another state (read -> read/write for example).
        """
        fd = xer.fileno()
        if fd not in primary:
            self._poller.add(fd, event)

            # Update our own tracking state *only* after the epoll call has
            # succeeded.  Otherwise we may get out of sync.
            primary[fd] = 1
            selectables[fd] = xer


    def addReader(self, reader):
        """
        Add a FileDescriptor for notification of data available to read.
        """
        self._add(reader, self._reads, self._writes, self._selectables, _portpoll.PPOLLIN)


    def addWriter(self, writer):
        """
        Add a FileDescriptor for notification of data available to write.
        """
        self._add(writer, self._writes, self._reads, self._selectables, _portpoll.PPOLLOUT)


    def _remove(self, xer, primary, other, selectables, event):
        """
        Private method for removing a descriptor from the event loop.

        It does the inverse job of _add, and also add a check in case of the fd
        has gone away.
        """
        fd = xer.fileno()
        if fd == -1:
            for fd, fdes in selectables.items():
                if xer is fdes:
                    break
            else:
                return
        if fd in primary:
            if fd not in other:
                del selectables[fd]
                self._poller.remove(fd)
            del primary[fd]


    def removeReader(self, reader):
        """
        Remove a Selectable for notification of data available to read.
        """
        self._remove(reader, self._reads, self._writes, self._selectables)


    def removeWriter(self, writer):
        """
        Remove a Selectable for notification of data available to write.
        """
        self._remove(writer, self._writes, self._reads, self._selectables)

    def removeAll(self):
        """
        Remove all selectables, and return a list of them.
        """
        return self._removeAll(
            [self._selectables[fd] for fd in self._reads],
            [self._selectables[fd] for fd in self._writes])


    def getReaders(self):
        return [self._selectables[fd] for fd in self._reads]


    def getWriters(self):
        return [self._selectables[fd] for fd in self._writes]


    def doPoll(self, timeout):
        """
        Poll the poller for new events.
        """
        if timeout is None:
            timeout = -1  # Wait indefinitely.

        try:
            # Limit the number of events to the number of io objects we're
            # currently tracking (because that's maybe a good heuristic) and
            # the amount of time we block to the value specified by our
            # caller.
            l = self._poller.poll(timeout)
        except IOError, err:
            if err.errno == errno.EINTR:
                return
            # See epoll_wait(2) for documentation on the other conditions
            # under which this can fail.  They can only be due to a serious
            # programming error on our part, so let's just announce them
            # loudly.
            raise

        _drdw = self._doReadOrWrite
        for fd, event in l:
            try:
                selectable = self._selectables[fd]
            except KeyError:
                pass
            else:
                log.callWithLogger(selectable, _drdw, selectable, fd, event)


    def _doReadOrWrite(self, selectable, fd, event):
        """
        fd is available for read or write, do the work and raise errors if
        necessary.
        """
        why = None
        inRead = False
        if event & self._POLL_DISCONNECTED and not (event & self._POLL_IN):
            # Handle disconnection.  But only if we finished processing all
            # the pending input.
            if fd in self._reads:
                # If we were reading from the descriptor then this is a
                # clean shutdown.  We know there are no read events pending
                # because we just checked above.  It also might be a
                # half-close (which is why we have to keep track of inRead).
                inRead = True
                why = CONNECTION_DONE
            else:
                # If we weren't reading, this is an error shutdown of some
                # sort.
                why = CONNECTION_LOST
        else:
            # Any non-disconnect event turns into a doRead or a doWrite.
            try:
                # First check to see if the descriptor is still valid.  This
                # gives fileno() a chance to raise an exception, too. 
                # Ideally, disconnection would always be indicated by the
                # return value of doRead or doWrite (or an exception from
                # one of those methods), but calling fileno here helps make
                # buggy applications more transparent.
                if selectable.fileno() == -1:
                    # -1 is sort of a historical Python artifact.  Python
                    # files and sockets used to change their file descriptor
                    # to -1 when they closed.  For the time being, we'll
                    # continue to support this anyway in case applications
                    # replicated it, plus abstract.FileDescriptor.fileno
                    # returns -1.  Eventually it'd be good to deprecate this
                    # case.
                    why = _NO_FILEDESC
                else:
                    if event & self._POLL_IN:
                        # Handle a read event.
                        why = selectable.doRead()
                        inRead = True
                    if not why and event & self._POLL_OUT:
                        # Handle a write event, as long as doRead didn't
                        # disconnect us.
                        why = selectable.doWrite()
                        inRead = False
            except:
                # Any exception from application code gets logged and will
                # cause us to disconnect the selectable.
                why = sys.exc_info()[1]
                log.err()
        if why:
            self._disconnectSelectable(selectable, why, inRead)
        # We must re-associate the file descriptor for the next event
        elif inRead:
            del self._reads[fd]
            self.addReader(selectable)
        else:
            del self._writes[fd]
            self.addWriter(selelectable)

    doIteration = doPoll


def install():
    """
    Install the portpoll() reactor.
    """
    p = PortPollReactor()
    from twisted.internet.main import installReactor
    installReactor(p)


__all__ = ["PortPollReactor", "install"]

