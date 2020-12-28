"""
C implementation of the adaptation system.

This module maps each Python adaptation function to a C adaptation function.
Notice that C adaptation functions have a different signature because they can
avoid making a memory copy, however this makes impossible to expose them to
Python.

This module exposes facilities to map the builtin adapters in python to
equivalent C implementations.

"""

# Copyright (C) 2020 The Psycopg Team

from typing import Any

from cpython.bytes cimport PyBytes_AsStringAndSize
from cpython.bytearray cimport PyByteArray_FromStringAndSize, PyByteArray_Resize
from cpython.bytearray cimport PyByteArray_AS_STRING

from psycopg3_c.pq cimport _buffer_as_string_and_size

from psycopg3 import errors as e
from psycopg3.pq import Format
from psycopg3.pq.misc import error_message

import logging
logger = logging.getLogger("psycopg3.adapt")


cdef class CDumper:
    cdef object src
    cdef public libpq.Oid oid
    cdef readonly object connection
    cdef pq.PGconn _pgconn

    def __init__(self, src: type, context: Optional["AdaptContext"] = None):
        self.src = src
        self.connection = context.connection if context is not None else None
        self._pgconn = (
            self.connection.pgconn if self.connection is not None else None
        )

        # default oid is implicitly set to 0, subclasses may override it
        # PG 9.6 goes a bit bonker sending unknown oids, so use text instead
        # (this does cause side effect, and requres casts more often than >= 10)
        if (
            self.oid == 0
            and self._pgconn is not None
            and self._pgconn.server_version < 100000
        ):
            self.oid = oids.TEXT_OID

    def dump(self, obj: Any) -> bytes:
        raise NotImplementedError()

    def quote(self, obj: Any) -> bytearray:
        cdef char *ptr
        cdef char *ptr_out
        cdef Py_ssize_t length, len_out
        cdef int error
        cdef bytearray rv

        pyout = self.dump(obj)
        _buffer_as_string_and_size(pyout, &ptr, &length)
        rv = PyByteArray_FromStringAndSize("", 0)
        PyByteArray_Resize(rv, length * 2 + 3)  # Must include the quotes
        ptr_out = PyByteArray_AS_STRING(rv)

        if self._pgconn is not None:
            if self._pgconn.pgconn_ptr == NULL:
                raise e.OperationalError("the connection is closed")

            len_out = libpq.PQescapeStringConn(
                self._pgconn.pgconn_ptr, ptr_out + 1, ptr, length, &error
            )
            if error:
                raise e.OperationalError(
                    f"escape_string failed: {error_message(self._pgconn)}"
                )
        else:
            len_out = libpq.PQescapeString(ptr_out + 1, ptr, length)

        ptr_out[0] = b'\''
        ptr_out[len_out + 1] = b'\''
        PyByteArray_Resize(rv, len_out + 2)

        return rv

    @classmethod
    def register(
        cls,
        src: Union[type, str],
        context: Optional[AdaptContext] = None,
        format: Format = Format.TEXT,
    ) -> None:
        if context is not None:
            adapters = context.adapters
        else:
            from psycopg3.adapt import global_adapters as adapters

        adapters.register_dumper(src, cls, format=format)


cdef class CLoader:
    cdef public libpq.Oid oid
    cdef public connection

    def __init__(self, oid: int, context: Optional["AdaptContext"] = None):
        self.oid = oid
        self.connection = context.connection if context is not None else None

    cdef object cload(self, const char *data, size_t length):
        raise NotImplementedError()

    def load(self, data: bytes) -> Any:
        cdef char *buffer
        cdef Py_ssize_t length
        PyBytes_AsStringAndSize(data, &buffer, &length)
        return self.cload(data, length)

    @classmethod
    def register(
        cls,
        oid: int,
        context: Optional["AdaptContext"] = None,
        format: Format = Format.TEXT,
    ) -> None:
        if context is not None:
            adapters = context.adapters
        else:
            from psycopg3.adapt import global_adapters as adapters

        adapters.register_loader(oid, cls, format=format)


def register_builtin_c_adapters():
    """
    Register all the builtin optimized adpaters.

    This function is supposed to be called only once, after the Python adapters
    are registered.

    """
    logger.debug("registering optimised c adapters")
    register_numeric_c_adapters()
    register_singletons_c_adapters()
    register_text_c_adapters()