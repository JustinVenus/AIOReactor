# Copyright (c) 2012 Twisted Matrix Laboratories.
# See LICENSE for details.


"""
Distutils file for building low-level AIO bindings from their Pyrex source
"""

# since this is for solaris you will need to use the sunpro/solarisstudio
# compiler to build and link this module.
#
# example invocation
#
#   CC=/opt/solarisstudio/bin/cc python setup.py build

from distutils.core import setup
from distutils.extension import Extension
from Cython.Distutils import build_ext

setup(
    cmdclass = {'build_ext': build_ext},
    ext_modules = [
        Extension("_evcp", 
            ["_evcp.pyx"],
            libraries=[]
        )
    ]
)
