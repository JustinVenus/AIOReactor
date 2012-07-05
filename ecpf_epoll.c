#ifndef SOCKET
#  define SOCKET int
#endif

#include "Python.h"

/*FIXME Constants for bitmasks are currently wrong*/
/*TODO Verify reference counting is working*/
/*TODO Wire up AIO objects, because it would be sweet to have*/

#ifdef HAVE_ECPF
/* **************************************************************************
 *       Event Completion Port Framework interface for Solaris 5.10+
 *
 * Written by Justin Venus
 * Inspired by select.epoll()
 *
 * The whole purpose of this code is to look like the Linux epoll interface
 * so frameworks like Twisted can share as much code as possible without any
 * low level interface changes.
 */

#include <port.h>

/* Set one-shot behavior. After one event is pulled out, the fd is internally 
 * disabled. Solaris has this behavior by default, but as we are mimicking
 * epoll behavior which needs to be explicity told to one-shot.
 */
#define POLLONESHOT 1u << 30

/*NOTE to self PyDict_GetItem returns a borrowed reference*/
typedef struct {
    PyObject_HEAD
    SOCKET ecfd;           /*ecf control file descriptor*/
    PyObject *descriptors;
} pyEcf_Object;

static PyTypeObject pyEcf_Type;
#define pyecf_CHECK(op) (PyObject_TypeCheck((op), &pyEcf_Type)

static PyObject *
pyecf_err_closed(void)
{   
    PyErr_SetString(PyExc_ValueError, "I/O operation on closed ecf fd");
    return NULL;
}

static int
pyecf_internal_close(pyEcf_Object *self)
{   
    int save_errno = 0;
    if (self->ecfd >= 0) {
        int ecfd = self->ecfd;
        self->ecfd = -1;
        Py_BEGIN_ALLOW_THREADS
        if (close(ecfd) < 0)
            save_errno = errno;
        Py_END_ALLOW_THREADS
    }
    return save_errno;
}

static PyObject *
newPyEcf_Object(PyTypeObject *type, SOCKET fd)
{
    pyEcf_Object *self;

    assert(type != NULL && type->tp_alloc != NULL);
    self = (pyEcf_Object *) type->tp_alloc(type, 0);
    if (self == NULL)
        return NULL;

    /*track descriptors for modify and re-associate*/
    self->descriptors = PyDict_New()
    if (fd == -1) {
        Py_BEGIN_ALLOW_THREADS
        self->ecfd = port_create();
        Py_END_ALLOW_THREADS
    }
    else {
        self->ecfd = fd;
    }
    if (self->ecfd < 0) {
        Py_DECREF(self);
        PyErr_SetFromErrno(PyExc_OSError);
        return NULL;
    }
    return (PyObject *)self;
}

static PyObject *
pyecf_new(PyTypeObject *type, PyObject *args, PyObject *kwds)
{   
    return newPyEcf_Object(type, -1);
}

static void
pyecf_dealloc(pyEcf_Object *self)
{   
    (void)pyecf_internal_close(self);
    PyDict_Clear(self->descriptors)
    Py_DECREF(self->descriptors)
    Py_TYPE(self)->tp_free(self);
}

static PyObject*
pyecf_close(pyEcf_Object *self)
{
    errno = pyecf_internal_close(self);
    if (errno < 0) {
        PyErr_SetFromErrno(PyExc_OSError);
        return NULL;
    }
    Py_RETURN_NONE;
}

PyDoc_STRVAR(pyecf_close_doc,
"close() -> None\n\
\n\
Close the ecf control file descriptor. Further operations on the ecf\n\
object will raise an exception.");

static PyObject*
pyecf_get_closed(pyEcf_Object *self)
{
    if (self->ecfd < 0)
        Py_RETURN_TRUE;
    else
        Py_RETURN_FALSE;
}

static PyObject*
pyecf_fromfd(PyObject *cls, PyObject *args)
{   
    SOCKET fd;

    if (!PyArg_ParseTuple(args, "i:fromfd", &fd))
        return NULL;

    return newPyEcf_Object((PyTypeObject*)cls, fd);
}

PyDoc_STRVAR(pyecf_fromfd_doc,
"fromfd(fd) -> ecf\n\
\n\
Create an ecf object from a given control fd.");

static PyObject *
pyecf_register(pyEcf_Object *self, PyObject *args, PyObject *kwds)
{
    PyObject *pfd;
    int result;
    unsigned long events = POLLIN | POLLOUT | POLLPRI;
    static char *kwlist[] = {"fd", "eventmask", NULL};

    if (self->ecfd < 0)
        return pyecf_err_closed();

    if (!PyArg_ParseTupleAndKeywords(args, kwds, "O|I:register", kwlist,
                                     &pfd, &events)) {
        return NULL;
    }

    if PyDict_Contains(self->descriptors, pfd) {
        errno = EINVAL;
        PyErr_SetFromErrno(PyExc_OSError);
        return NULL;
    }

    /*we have to explicitly ask for error events*/
    events = events | POLLERR | POLLHUP
    int fd = PyObject_AsFileDescriptor(pfd);
    /*pass the original event mask so we know how to re-register the event*/
    Py_BEGIN_ALLOW_THREADS
    result = port_associate(self->epfd, PORT_SOURCE_FD, fd,
                            (unsigned int)events, (void*)events)
    Py_END_ALLOW_THREADS
    if (result == -1) {
        PyErr_SetFromErrno(PyExc_OSError);
        return NULL;
    }
    /*track the descriptor and mask*/
    PyDict_SetItem(self->descriptors, pfd, PyLong_FromUnsignedLong(events))
    Py_RETURN_NONE;
}

PyDoc_STRVAR(pyecf_register_doc,
"register(fd[, eventmask]) -> None\n\
\n\
Registers a new fd or raises an OSError if the fd is already registered.\n\
fd is the target file descriptor of the operation.\n\
events is a bit set composed of the various ECF constants; the default\n\
is ECF_IN | ECF_OUT | ECF_PRI.\n\
\n\
The ecf interface supports all file descriptors that support poll.");

static PyObject *
pyecf_modify(pyEcf_Object *self, PyObject *args, PyObject *kwds)
{
    PyObject *pfd;
    unsigned long events;
    static char *kwlist[] = {"fd", "eventmask", NULL};

    if (self->ecfd < 0)
        return pyecf_err_closed();

    if (!PyArg_ParseTupleAndKeywords(args, kwds, "OI:modify", kwlist,
                                     &pfd, &events)) {
        return NULL;
    }

    if (!PyDict_Contains(self->descriptors, pfd)) {
        errno = EINVAL;
        PyErr_SetFromErrno(PyExc_OSError);
        return NULL;
    }

    /*NOTE ``ev`` is a borrowed reference be careful*/
    PyObject *ev = PyDict_GetItem(self->descriptors, pfd);
    /*update the event bitmask from our tracking dictionary*/
    events = events | PyLong_AsUnsignedLong(ev);
    int fd = PyObject_AsFileDescriptor(pfd);
    int result;

    /*we must dissociate so that we may modify*/
    Py_BEGIN_ALLOW_THREADS
    result = port_dissociate(self->epfd, PORT_SOURCE_FD, fd);
    Py_END_ALLOW_THREADS

    if (result == -1)
        goto error;
    
    /*modify is a new association*/
    Py_BEGIN_ALLOW_THREADS
    result = port_associate(self->epfd, PORT_SOURCE_FD, fd, 
                            (unsigned int)events, (void*)events);
    Py_END_ALLOW_THREADS

    if (result == -1)
        goto error;

    /*update the tracking dictionary*/
    PyDict_SetItem(self->descriptors, pfd, PyLong_FromUnsignedLong(events));
    Py_RETURN_NONE;

    error:
    PyErr_SetFromErrno(PyExc_OSError);
    /*lose track of the selectable object on failure*/
    if PyDict_Contains(self->descriptors, pfd) {
        PyDict_DelItem(self->descriptors, pfd);
        Py_DECREF(pfd); //FIXME is this right?
    }
    return NULL;
} 

PyDoc_STRVAR(pyecf_modify_doc,
"modify(fd, eventmask) -> None\n\
\n\
fd is the target file descriptor of the operation\n\
events is a bit set composed of the various EPOLL constants");

static PyObject *
pyecf_unregister(pyEcf_Object *self, PyObject *args, PyObject *kwds)
{
    PyObject *pfd;
    static char *kwlist[] = {"fd", NULL};

    if (self->ecfd < 0)
        return pyecf_err_closed();

    if (!PyArg_ParseTupleAndKeywords(args, kwds, "O:unregister", kwlist,
                                     &pfd)) {
        return NULL;
    }

    int result;
    int saved_errno = 0;
    int fd = PyObject_AsFileDescriptor(pfd);
    Py_BEGIN_ALLOW_THREADS
    result = port_dissociate(self->ecfd, PORT_SOURCE_FD, fd);
    Py_END_ALLOW_THREADS
    saved_errno = errno

    /*clean up our tracking dictionary before handling exceptions*/
    if PyDict_Contains(self->descriptors, pfd)
        PyDict_DelItem(self->descriptors, pfd);

    /*set OSError on errno if the file descriptor exists*/
    if (saved_errno && saved_errno != ENOENT) {
        errno = saved_errno
        PyErr_SetFromErrno(PyExc_OSError);
        return NULL;
    }
    Py_RETURN_NONE;
}

/*FIXME finish this implementation*/
static PyObject *
pyecf_poll(pyEcf_Object *self, PyObject *args, PyObject *kwds)
{

}

PyDoc_STRVAR(pyecf_poll_doc,
"poll([timeout=-1[, maxevents=-1]]) -> [(fd, events), (...)]\n\
\n\
Wait for events on the ecp file descriptor for a maximum time of timeout\n\
in seconds (as float). -1 makes poll wait indefinitely.\n\
Up to maxevents are returned to the caller.");

PyDoc_STRVAR(pyecf_unregister_doc,
"unregister(fd) -> None\n\
\n\
fd is the target file descriptor of the operation.");

static PyMethodDef pyecf_methods[] = {
    {"fromfd",          (PyCFunction)pyecf_fromfd,
     METH_VARARGS | METH_CLASS, pyecf_fromfd_doc},
    {"close",           (PyCFunction)pyecf_close,     METH_NOARGS,
     pyecf_close_doc},
    {"fileno",          (PyCFunction)pyecf_fileno,    METH_NOARGS,
     pyecf_fileno_doc},
    {"modify",          (PyCFunction)pyecf_modify,
     METH_VARARGS | METH_KEYWORDS,      pyecf_modify_doc},
    {"register",        (PyCFunction)pyecf_register, 
     METH_VARARGS | METH_KEYWORDS,      pyecf_register_doc},
    {"unregister",      (PyCFunction)pyecf_unregister,
     METH_VARARGS | METH_KEYWORDS,      pyecf_unregister_doc},
    {"poll",            (PyCFunction)pyecf_poll,
     METH_VARARGS | METH_KEYWORDS,      pyecf_poll_doc},
    {NULL,      NULL},
};
 
static PyGetSetDef pyecf_getsetlist[] = {
    {"closed", (getter)pyecf_get_closed, NULL,
     "True if the ecf handler is closed"},
    {0},
};

PyDoc_STRVAR(pyecf_doc,
"select.epoll()\n\
\n\
Returns an event completion port pollable object.");

/*make the solaris event completion framework look like linux epoll*/
static PyTypeObject pyEcf_Type = {
    PyVarObject_HEAD_INIT(NULL, 0)
    "select.epoll",                                     /* tp_name */
    sizeof(pyEcf_Object),                               /* tp_basicsize */
    0,                                                  /* tp_itemsize */
    (destructor)pyecf_dealloc,                          /* tp_dealloc */
    0,                                                  /* tp_print */
    0,                                                  /* tp_getattr */
    0,                                                  /* tp_setattr */
    0,                                                  /* tp_reserved */
    0,                                                  /* tp_repr */
    0,                                                  /* tp_as_number */
    0,                                                  /* tp_as_sequence */
    0,                                                  /* tp_as_mapping */
    0,                                                  /* tp_hash */
    0,                                                  /* tp_call */
    0,                                                  /* tp_str */
    PyObject_GenericGetAttr,                            /* tp_getattro */
    0,                                                  /* tp_setattro */
    0,                                                  /* tp_as_buffer */
    Py_TPFLAGS_DEFAULT,                                 /* tp_flags */
    pyecf_doc,                                          /* tp_doc */
    0,                                                  /* tp_traverse */
    0,                                                  /* tp_clear */
    0,                                                  /* tp_richcompare */
    0,                                                  /* tp_weaklistoffset */
    0,                                                  /* tp_iter */
    0,                                                  /* tp_iternext */
    pyecf_methods,                                      /* tp_methods */
    0,                                                  /* tp_members */
    pyecf_getsetlist,                                   /* tp_getset */
    0,                                                  /* tp_base */
    0,                                                  /* tp_dict */
    0,                                                  /* tp_descr_get */
    0,                                                  /* tp_descr_set */
    0,                                                  /* tp_dictoffset */
    0,                                                  /* tp_init */
    0,                                                  /* tp_alloc */
    pyecf_new,                                          /* tp_new */
    0,                                                  /* tp_free */
};

#endif /* HAVE_ECF */


#ifdef HAVE_ECPF
    Py_TYPE(&pyEcf_Type) = &PyType_Type;
    if (PyType_Ready(&pyEcf_Type) < 0) 
        return NULL;

    Py_INCREF(&pyEcf_Type);
    PyModule_AddObject(m, "epoll", (PyObject *) &pyEcf_Type);

    PyModule_AddIntConstant(m, "EPOLLIN", POLLIN);
    PyModule_AddIntConstant(m, "EPOLLOUT", POLLOUT);
    PyModule_AddIntConstant(m, "EPOLLPRI", POLLPRI);
    PyModule_AddIntConstant(m, "EPOLLERR", POLLERR);
    PyModule_AddIntConstant(m, "EPOLLHUP", POLLHUP);
    /* Solaris Doesn't have an equivalent for EPOLLET*/
    PyModule_AddIntConstant(m, "EPOLLET", 0);
    /* Solaris default behavior is oneshot (suppressed) this bitmask enables
     * the original event completion port behaviour.
     */
    PyModule_AddIntConstant(m, "EPOLLONESHOT", POLLONESHOT);
    PyModule_AddIntConstant(m, "EPOLLRDNORM", POLLRDNORM);
    PyModule_AddIntConstant(m, "EPOLLRDBAND", POLLRDBAND);
    PyModule_AddIntConstant(m, "EPOLLWRNORM", POLLWRNORM);
    PyModule_AddIntConstant(m, "EPOLLWRBAND", POLLWRBAND);
    /* Solaris Doesn't have an equivalent for EPOLLMSG it's ignored anyway */
    PyModule_AddIntConstant(m, "EPOLLMSG", 0);

#endif /* HAVE_ECPF */
