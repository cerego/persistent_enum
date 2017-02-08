# PersistentEnum
[![Build Status](https://travis-ci.org/iknow/persistent_enum.svg?branch=master)](https://travis-ci.org/iknow/persistent_enum)

Provide an ActiveRecord model that behaves as a database-backed enumeration
between indices and symbolic values. This allows us to have a valid foreign key
which behaves like a enumeration. Values are cached at startup, and cannot be
changed.
